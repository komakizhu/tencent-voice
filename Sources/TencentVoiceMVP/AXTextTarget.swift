import ApplicationServices
import AppKit
import Foundation

private enum KeyboardDocumentStateReadError: Error {
    case retryable
    case unavailable
}

@MainActor
final class AXTextTarget: KeyboardAcknowledgingTarget {
    private(set) var requiresKeyboardAcknowledgement = false
    private var confirmedKeyboardDocument: String?
    private var pendingKeyboardWrite: KeyboardDocumentState?
    private var pendingKeyboardReplacement: (selected: KeyboardDocumentState, insertion: String)?
    private var replacementWasSent = false
    private var confirmedKeyboardRawText: String?
    private var confirmedKeyboardMapping: AXTextCoordinateMapping?
    private var lastResolvedCodexDocument: AXTextDocumentState?
    private var codexPlaceholderEvidence: AXPlaceholderEvidence?
    private var codexAXValueFallbackAllowed = false
    private var keyboardGeneration: UInt64 = 0
    private var isCodexTarget = false
    private var targetElement: AXUIElement?
    private var targetProcessID: pid_t?
    private var targetApplicationProcessID: pid_t?
    private var expectedKeyboardSelection: TextRange?
    private let keyboardEventSender: KeyboardEventSender
    private var diagnostics: [TextInputDiagnostic] = []
    private var droppedDiagnosticCount = 0
    private var diagnosticOperationContext: TextInputDiagnosticContext?
    private var previousDiagnosticOperationContext: TextInputDiagnosticContext?
    private var lastKeyboardDispatch: UInt64?
    private var lastAXWriteStatus: Int32?
    private var lastAXWriteKind = "none"
    private var lastCoordinateDiagnosticKey: String?

    init(operationObserver: ((String) -> Void)? = nil) {
        keyboardEventSender = KeyboardEventSender(stageObserver: operationObserver)
    }

    func drainDiagnostics() -> [TextInputDiagnostic] {
        defer { diagnostics.removeAll(keepingCapacity: true) }
        var result = diagnostics
        if droppedDiagnosticCount > 0 {
            result.append(TextInputDiagnostic(
                timestamp: Date(),
                event: "target_diagnostics_truncated",
                fields: ["droppedEventCount": String(droppedDiagnosticCount)]
            ))
            droppedDiagnosticCount = 0
        }
        return result
    }

    func setDiagnosticOperation(_ context: TextInputDiagnosticContext?) {
        if context == nil {
            previousDiagnosticOperationContext = diagnosticOperationContext
        }
        diagnosticOperationContext = context
    }

    private func recordDiagnostic(
        _ event: String,
        _ fields: [String: String] = [:],
        context: TextInputDiagnosticContext? = nil
    ) {
        guard diagnostics.count < 64 else {
            droppedDiagnosticCount += 1
            return
        }
        var merged = (context ?? diagnosticOperationContext)?.fields ?? [:]
        merged.merge(fields) { _, new in new }
        diagnostics.append(TextInputDiagnostic(timestamp: Date(), event: event, fields: merged))
    }

    func currentApplication() -> TextTargetApplication? {
        NSWorkspace.shared.frontmostApplication.map {
            TextTargetApplication(
                name: $0.localizedName ?? "未知应用",
                bundleIdentifier: $0.bundleIdentifier,
                processIdentifier: Int32($0.processIdentifier)
            )
        }
    }

    func capture() throws -> TextSnapshot {
        keyboardGeneration &+= 1
        pendingKeyboardWrite = nil
        pendingKeyboardReplacement = nil
        replacementWasSent = false
        confirmedKeyboardRawText = nil
        confirmedKeyboardMapping = nil
        lastResolvedCodexDocument = nil
        codexPlaceholderEvidence = nil
        codexAXValueFallbackAllowed = false
        confirmedKeyboardDocument = nil
        requiresKeyboardAcknowledgement = false
        diagnostics.removeAll(keepingCapacity: true)
        droppedDiagnosticCount = 0
        diagnosticOperationContext = nil
        previousDiagnosticOperationContext = nil
        lastKeyboardDispatch = nil
        lastAXWriteStatus = nil
        lastAXWriteKind = "none"
        lastCoordinateDiagnosticKey = nil
        try requestInputPermissionsIfNeeded()
        targetElement = nil
        targetProcessID = nil
        targetApplicationProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        expectedKeyboardSelection = nil
        let targetApplication = currentApplication()
        isCodexTarget = targetApplication?.bundleIdentifier == "com.openai.codex"

        // Some Electron/WebKit controls expose neither a stable AX value nor
        // a stable focused AX element while the DOM is being rebuilt. That is
        // still a valid keyboard target as long as a frontmost application is
        // known; the keyboard append path only owns the text it sends.
        let element = try? focusedElement()
        targetElement = element
        if let element {
            var focusedProcessID: pid_t = 0
            _ = AXUIElementGetPid(element, &focusedProcessID)
            targetProcessID = focusedProcessID == 0
                ? targetApplicationProcessID
                : focusedProcessID
        } else {
            targetProcessID = targetApplicationProcessID
        }
        guard targetProcessID != nil else {
            throw TextTargetError.unsupported
        }

        // Electron/web content controls do not always expose kAXValueAttribute,
        // even though they still accept Unicode keyboard events. Keep the
        // focused element as a keyboard target instead of falling all the way
        // back to append-only mode. When Codex exposes readable text, however,
        // its AXValue and selection coordinates must be interpreted together.
        let rawText = element.flatMap { readableText(in: $0) }
        let readableKeyboardSelection = element.flatMap { readableSelection(in: $0) }
        let rawSelection = readableKeyboardSelection
            ?? TextRange(location: rawText?.utf16.count ?? 0, length: 0)
        let hasReadableAXTextState = rawText != nil && readableKeyboardSelection != nil
        var codexState: AXTextDocumentState?
        if isCodexTarget, let element, let rawText, let readableKeyboardSelection {
            let evidence = placeholderEvidence(in: element)
            codexPlaceholderEvidence = evidence
            do {
                let state = try readCodexTextDocument(
                    rawText: rawText,
                    selection: readableKeyboardSelection,
                    evidence: evidence,
                    element: element
                )
                codexState = state
                lastResolvedCodexDocument = state
                recordCoordinateResolution(state: state, evidence: evidence)
            } catch let error as AXTextDocumentResolutionError {
                recordCoordinateResolutionFailure(
                    error,
                    rawText: rawText,
                    selection: readableKeyboardSelection,
                    evidence: evidence
                )
            } catch {
                recordCoordinateResolutionFailure(
                    .coordinateReadUnavailable,
                    rawText: rawText,
                    selection: readableKeyboardSelection,
                    evidence: evidence
                )
            }
        }
        let text = codexState?.text ?? rawText ?? ""
        let selection = codexState?.selection ?? rawSelection
        expectedKeyboardSelection = readableKeyboardSelection
        requiresKeyboardAcknowledgement = hasReadableAXTextState
        confirmedKeyboardDocument = if let codexState {
            codexState.text
        } else if !isCodexTarget, let rawText {
            rawText
        } else {
            nil
        }
        confirmedKeyboardRawText = codexState?.rawText
        confirmedKeyboardMapping = codexState?.mapping
        recordDiagnostic("input_target_captured", [
            "hasElement": String(element != nil), "hasReadableState": String(hasReadableAXTextState),
            "selectedSettable": String(element.map { selectedTextIsSettable(on: $0) } ?? false),
            "valueSettable": String(element.map { valueIsSettable(on: $0) } ?? false),
            "documentLength": String(text.utf16.count),
            "axValueLengthUTF16": String(rawText?.utf16.count ?? 0),
            "axCoordinateLengthUTF16": String(codexState?.text.utf16.count ?? text.utf16.count),
            "selectionLocation": String(selection.location), "selectionLength": String(selection.length),
            "keyboardCompatibility": String(targetApplication?.bundleIdentifier == "com.openai.codex")
        ])
        return TextSnapshot(
            element: element,
            text: text,
            selection: selection,
            supportsAXReplacement: hasReadableAXTextState && (element.map {
                selectedTextIsSettable(on: $0) || valueIsSettable(on: $0)
            } ?? false),
            targetApplication: targetApplication,
            rawText: rawText ?? text,
            coordinateText: codexState?.text ?? text,
            placeholderNormalized: codexState?.placeholderNormalized ?? false,
            coordinateMapping: codexState?.mapping
        )
    }

    func replace(snapshot: TextSnapshot, range: TextRange, expectedText: String, with text: String) throws -> TextRange {
        guard let expectedElement = snapshot.element else { throw TextTargetError.unsupported }
        let element = try focusedElement()
        guard CFEqual(element, expectedElement) else {
            recordDiagnostic("ax_focus_changed")
            throw TextTargetError.targetChanged
        }
        guard let currentText = try attribute(kAXValueAttribute, from: element) as? String else {
            recordDiagnostic("ax_value_unreadable")
            throw TextTargetError.targetChanged
        }
        guard currentText == expectedText else {
            recordDiagnostic("ax_document_mismatch", [
                "expectedDocumentLength": String(expectedText.utf16.count),
                "actualDocumentLength": String(currentText.utf16.count), "documentMatches": "false",
                "lastAXStatus": lastAXWriteStatus.map(String.init) ?? "none", "lastAXWriteKind": lastAXWriteKind
            ])
            throw TextTargetError.targetChanged
        }
        guard let currentSelectionObject = try attribute(kAXSelectedTextRangeAttribute, from: element) else {
            recordDiagnostic("ax_selection_unreadable")
            throw TextTargetError.targetChanged
        }
        guard let currentSelectionValue = axValue(from: currentSelectionObject) else {
            recordDiagnostic("ax_selection_unreadable")
            throw TextTargetError.targetChanged
        }
        guard let currentSelection = textRange(from: currentSelectionValue),
              currentSelection.location == range.location + range.length,
              range.location >= 0,
              range.length >= 0,
              range.location + range.length <= currentText.utf16.count else {
            let observed = textRange(from: currentSelectionValue)
            recordDiagnostic("ax_selection_mismatch", [
                "expectedLocation": String(range.location + range.length),
                "actualLocation": String(observed?.location ?? -1), "actualLength": String(observed?.length ?? -1)
            ])
            throw TextTargetError.targetChanged
        }

        if selectedTextIsSettable(on: element) {
            let previousText = (currentText as NSString).substring(
                with: NSRange(location: range.location, length: range.length)
            )
            let delta = TextReplacementDelta(previousText: previousText, newText: text)
            let replacementRange = TextRange(
                location: range.location + delta.prefixUTF16Length,
                length: delta.previousMiddleUTF16Length
            )
            try setSelection(replacementRange, on: element)
            let status = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                delta.insertion as CFTypeRef
            )
            lastAXWriteStatus = status.rawValue
            lastAXWriteKind = "selected"
            guard status == .success else {
                recordDiagnostic("ax_write_failed", ["status": String(status.rawValue), "writeKind": "selected"])
                throw TextTargetError.writeFailed
            }
        } else {
            guard valueIsSettable(on: element) else { throw TextTargetError.writeFailed }
            let document = NSMutableString(string: currentText)
            document.replaceCharacters(
                in: NSRange(location: range.location, length: range.length),
                with: text
            )
            let status = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                document.copy() as CFTypeRef
            )
            lastAXWriteStatus = status.rawValue
            lastAXWriteKind = "value"
            guard status == .success else {
                recordDiagnostic("ax_write_failed", ["status": String(status.rawValue), "writeKind": "value"])
                throw TextTargetError.writeFailed
            }
        }

        let newRange = TextRange(location: range.location, length: text.utf16.count)
        try setSelection(TextRange(location: newRange.location + newRange.length, length: 0), on: element)
        return newRange
    }

    func paste(_ text: String) throws {
        try ensureKeyboardTargetIsSafe()
        let receipt = try keyboardReceipt(replacing: expectedKeyboardSelection, with: text)
        try keyboardEventSender.send(text, processID: eventProcessID)
        lastKeyboardDispatch = DispatchTime.now().uptimeNanoseconds
        if let receipt {
            pendingKeyboardWrite = receipt
            recordDiagnostic("keyboard_write_submitted", ["expectedLocation": String(receipt.selection.location),
                                                        "expectedDocumentLength": String(receipt.text.utf16.count)])
            return
        }
        if let selection = expectedKeyboardSelection {
            expectedKeyboardSelection = TextRange(
                location: selection.location + text.utf16.count,
                length: 0
            )
        }
    }

    func replaceTrailingText(_ previousText: String, with text: String) throws {
        try ensureKeyboardTargetIsSafe()
        let updatedSelection: TextRange?
        if let selection = expectedKeyboardSelection {
            guard selection.length == 0,
                  selection.location >= previousText.utf16.count else {
                throw TextTargetError.targetChanged
            }
            updatedSelection = TextRange(
                location: selection.location - previousText.utf16.count + text.utf16.count,
                length: 0
            )
        } else {
            updatedSelection = nil
        }
        let replacementRange = expectedKeyboardSelection.map {
            TextRange(location: $0.location - previousText.utf16.count, length: previousText.utf16.count)
        }
        let receipt = try keyboardReceipt(replacing: replacementRange, with: text, previousText: previousText)
        if let receipt, let replacementRange, let document = confirmedKeyboardDocument {
            let selected = KeyboardDocumentState(
                text: document,
                selection: replacementRange,
                rawText: confirmedKeyboardRawText
            )
            let usesAXSelection = targetElement.map {
                isAttributeSettable($0, kAXSelectedTextRangeAttribute as CFString)
            } ?? false
            if usesAXSelection, let targetElement {
                try setSelection(replacementRange, on: targetElement)
            } else {
                try keyboardEventSender.selectTrailingText(previousText, processID: eventProcessID)
            }
            pendingKeyboardReplacement = (selected, text)
            pendingKeyboardWrite = receipt
            recordDiagnostic("keyboard_selection_submitted", [
                "route": usesAXSelection ? "ax_range" : "keyboard",
                "expectedLocation": String(replacementRange.location),
                "expectedLength": String(replacementRange.length)
            ])
            return
        }
        try keyboardEventSender.replaceTrailingText(
            previousText,
            with: text,
            processID: eventProcessID
        )
        lastKeyboardDispatch = DispatchTime.now().uptimeNanoseconds
        if let receipt {
            pendingKeyboardWrite = receipt
            recordDiagnostic("keyboard_write_submitted", ["expectedLocation": String(receipt.selection.location),
                "expectedDocumentLength": String(receipt.text.utf16.count), "replacementCharacters": String(previousText.count)])
            return
        }
        expectedKeyboardSelection = updatedSelection
    }

    func acknowledgeKeyboardWrite() async throws {
        guard let receipt = pendingKeyboardWrite else { return }
        let generation = keyboardGeneration
        let start = DispatchTime.now().uptimeNanoseconds
        let read = { () throws -> KeyboardDocumentState in
            guard generation == self.keyboardGeneration else { throw CancellationError() }
            try self.ensureTargetApplicationIsFrontmost()
            let element = try self.focusedElement()
            guard let targetElement = self.targetElement, CFEqual(element, targetElement) else {
                throw TextTargetError.targetChanged
            }
            do {
                return try KeyboardWriteAcknowledgement.readObservation {
                    try self.keyboardDocumentState(in: element, confirming: true)
                }
            } catch KeyboardWriteReadError.retryable {
                throw KeyboardWriteReadError.retryable
            } catch KeyboardDocumentStateReadError.retryable {
                throw KeyboardWriteReadError.retryable
            } catch {
                throw TextTargetError.targetChanged
            }
        }
        do {
            if let replacement = pendingKeyboardReplacement {
                try await KeyboardWriteAcknowledgement.replaceSelection(
                    selected: replacement.selected, result: receipt, read: read
                ) {
                    self.recordDiagnostic(
                        "keyboard_selection_acknowledged",
                        context: self.previousDiagnosticOperationContext
                    )
                    try self.keyboardEventSender.replaceSelection(with: replacement.insertion, processID: self.eventProcessID)
                    self.replacementWasSent = true
                    self.lastKeyboardDispatch = DispatchTime.now().uptimeNanoseconds
                    self.recordDiagnostic(
                        "keyboard_replacement_submitted",
                        context: self.previousDiagnosticOperationContext
                    )
                }
            } else {
                try await KeyboardWriteAcknowledgement.wait(for: receipt, read: read)
            }
            guard generation == keyboardGeneration else { throw CancellationError() }
            confirmedKeyboardDocument = receipt.text
            expectedKeyboardSelection = receipt.selection
            if self.isCodexTarget, let resolved = self.lastResolvedCodexDocument {
                confirmedKeyboardRawText = resolved.rawText
                confirmedKeyboardMapping = resolved.mapping
            } else {
                confirmedKeyboardRawText = receipt.rawText
                confirmedKeyboardMapping = nil
            }
            pendingKeyboardWrite = nil
            pendingKeyboardReplacement = nil
            replacementWasSent = false
            recordDiagnostic("keyboard_write_acknowledged", [
                "elapsedMilliseconds": String((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000),
                "documentMatches": "true", "selectionMatches": "true"
            ], context: previousDiagnosticOperationContext)
        } catch {
            recordDiagnostic(
                "keyboard_write_unconfirmed",
                ["code": DiagnosticErrorFormatter.code(for: error)],
                context: previousDiagnosticOperationContext
            )
            throw error
        }
    }

    private func keyboardReceipt(replacing range: TextRange?, with text: String,
                                 previousText: String? = nil) throws -> KeyboardDocumentState? {
        guard requiresKeyboardAcknowledgement else { return nil }
        guard let range, let document = confirmedKeyboardDocument,
              range.location >= 0, range.length >= 0,
              range.location <= document.utf16.count,
              range.length <= document.utf16.count - range.location else { throw TextTargetError.targetChanged }
        let nsRange = NSRange(location: range.location, length: range.length)
        if let previousText, (document as NSString).substring(with: nsRange) != previousText {
            throw TextTargetError.targetChanged
        }
        let result = NSMutableString(string: document)
        result.replaceCharacters(in: nsRange, with: text)
        let rawResult: String?
        if isCodexTarget {
            guard let rawDocument = confirmedKeyboardRawText,
                  let mapping = confirmedKeyboardMapping,
                  let rawRange = mapping.rawRange(for: range),
                  rawRange.location >= 0,
                  rawRange.length >= 0,
                  rawRange.location <= rawDocument.utf16.count,
                  rawRange.length <= rawDocument.utf16.count - rawRange.location else {
                throw TextTargetError.targetChanged
            }
            let raw = NSMutableString(string: rawDocument)
            raw.replaceCharacters(
                in: NSRange(location: rawRange.location, length: rawRange.length),
                with: text
            )
            rawResult = raw as String
        } else {
            rawResult = nil
        }
        return KeyboardDocumentState(text: result as String,
                                     selection: TextRange(location: range.location + text.utf16.count, length: 0),
                                     rawText: rawResult)
    }

    private func keyboardDocumentState(in element: AXUIElement, confirming: Bool = false) throws -> KeyboardDocumentState {
        guard let rawText = readableText(in: element),
              let selection = readableSelection(in: element) else {
            throw KeyboardDocumentStateReadError.unavailable
        }
        if isCodexTarget {
            if AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: rawText,
                selection: selection,
                confirmedRawText: confirmedKeyboardRawText,
                expectedSelection: pendingKeyboardWrite?.selection
            ) {
                let key = "retryable:\(rawText.utf16.count):\(selection.location)"
                if key != lastCoordinateDiagnosticKey {
                    lastCoordinateDiagnosticKey = key
                    recordDiagnostic("ax_coordinate_mapping_retryable", [
                        "reason": "ax_value_stale_behind_selection",
                        "axValueLengthUTF16": String(rawText.utf16.count),
                        "selectionLocation": String(selection.location),
                        "selectionLength": String(selection.length)
                    ])
                }
                throw KeyboardDocumentStateReadError.retryable
            }
            let evidence = codexPlaceholderEvidence ?? placeholderEvidence(in: element)
            do {
                let document = try AXTextDocumentResolver.readDuringReplacement(
                    rawText: rawText,
                    selection: selection,
                    acknowledgedSelection: replacementWasSent ? pendingKeyboardReplacement?.selected : nil
                ) {
                    try readCodexTextDocument(
                        rawText: rawText, selection: selection, evidence: evidence, element: element
                    )
                }
                lastResolvedCodexDocument = document
                return KeyboardDocumentState(
                    text: document.text,
                    selection: document.selection,
                    rawText: document.rawText
                )
            } catch KeyboardWriteReadError.retryable {
                recordDiagnostic("ax_coordinate_mapping_retryable", [
                    "reason": "replacement_previous_selection_still_visible",
                    "axValueLengthUTF16": String(rawText.utf16.count),
                    "selectionLocation": String(selection.location),
                    "selectionLength": String(selection.length)
                ])
                throw KeyboardDocumentStateReadError.retryable
            } catch let error as AXTextDocumentResolutionError {
                if error == .coordinateReadUnavailable,
                   let previous = lastResolvedCodexDocument,
                   let document = try? AXTextDocumentResolver.resolveUsingValidatedAXValueAfterPlaceholder(
                       rawText: rawText,
                       selection: selection,
                       previousState: previous,
                       continuationAllowed: codexAXValueFallbackAllowed
                   ) {
                    codexAXValueFallbackAllowed = true
                    lastResolvedCodexDocument = document
                    recordCoordinateResolution(state: document, evidence: evidence)
                    return KeyboardDocumentState(
                        text: document.text,
                        selection: document.selection,
                        rawText: document.rawText
                    )
                }
                recordCoordinateResolutionFailure(
                    error,
                    rawText: rawText,
                    selection: selection,
                    evidence: evidence,
                    confirming: confirming
                )
                throw error
            } catch {
                recordCoordinateResolutionFailure(
                    .coordinateReadUnavailable,
                    rawText: rawText,
                    selection: selection,
                    evidence: evidence
                )
                throw KeyboardDocumentStateReadError.unavailable
            }
        }
        return KeyboardDocumentState(text: rawText, selection: selection)
    }

    func copyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.clearContents()
            if let previousString {
                _ = pasteboard.setString(previousString, forType: .string)
            }
            throw TextTargetError.writeFailed
        }
    }

    private func setSelection(_ range: TextRange, on element: AXUIElement) throws {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            recordDiagnostic("ax_selection_unreadable")
            throw TextTargetError.writeFailed
        }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        guard status == .success else {
            recordDiagnostic("ax_write_failed", ["status": String(status.rawValue), "writeKind": "selection"])
            throw TextTargetError.writeFailed
        }
    }

    private func selectedTextIsSettable(on element: AXUIElement) -> Bool {
        isAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString
        )
    }

    private func valueIsSettable(on element: AXUIElement) -> Bool {
        isAttributeSettable(element, kAXValueAttribute as CFString)
    }

    private func isAttributeSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    private func ensureKeyboardTargetIsSafe() throws {
        try ensureTargetApplicationIsFrontmost()
        guard let targetElement else { return }
        let currentElement = try focusedElement()
        guard CFEqual(currentElement, targetElement) else {
            recordDiagnostic("keyboard_focus_changed")
            throw TextTargetError.targetChanged
        }
        if requiresKeyboardAcknowledgement {
            guard pendingKeyboardWrite == nil else { throw TextTargetError.writeFailed }
            guard let currentState = try? keyboardDocumentState(in: currentElement),
                  currentState.text == confirmedKeyboardDocument,
                  currentState.selection == expectedKeyboardSelection,
                  !isCodexTarget || currentState.rawText == confirmedKeyboardRawText else {
                recordDiagnostic("keyboard_confirmed_state_changed")
                throw TextTargetError.targetChanged
            }
            return
        }
        if let expectedKeyboardSelection {
            let actualSelection = readableSelection(in: currentElement)
            if actualSelection != expectedKeyboardSelection {
                let age = lastKeyboardDispatch.map {
                    Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000
                } ?? -1
                let result = try KeyboardCaretSynchronizer.wait(
                    expected: expectedKeyboardSelection, initial: actualSelection,
                    canWait: age >= 0 && age <= 250
                ) {
                    try self.ensureTargetApplicationIsFrontmost()
                    let focused = try self.focusedElement()
                    guard CFEqual(focused, targetElement) else {
                        self.recordDiagnostic("keyboard_focus_changed")
                        throw TextTargetError.targetChanged
                    }
                    return self.readableSelection(in: focused)
                }
                let recovered = result.selection == expectedKeyboardSelection
                recordDiagnostic(recovered ? "keyboard_caret_recovered" : "keyboard_caret_timeout", [
                    "expectedLocation": String(expectedKeyboardSelection.location),
                    "expectedLength": String(expectedKeyboardSelection.length),
                    "initialLocation": String(actualSelection?.location ?? -1),
                    "initialLength": String(actualSelection?.length ?? -1),
                    "actualLocation": String(result.selection?.location ?? -1),
                    "actualLength": String(result.selection?.length ?? -1),
                    "millisecondsSinceDispatch": String(age), "waitMilliseconds": String(result.elapsedMilliseconds),
                    "polls": String(result.polls)
                ])
                guard recovered else { throw TextTargetError.targetChanged }
            }
        }
    }

    private func ensureTargetApplicationIsFrontmost() throws {
        guard let targetApplicationProcessID else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApplicationProcessID else {
            recordDiagnostic("input_application_changed")
            throw TextTargetError.targetChanged
        }
    }

    // AX may report an Electron/WebKit accessibility element owned by a
    // renderer process. Synthetic keyboard input must be delivered to the
    // frontmost application process so its normal event routing reaches the
    // focused web control.
    private var eventProcessID: pid_t? {
        targetApplicationProcessID ?? targetProcessID
    }

    private func focusedElement() throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        guard let elementObject = try attribute(kAXFocusedUIElementAttribute, from: system) else {
            throw TextTargetError.unsupported
        }
        return elementObject as! AXUIElement
    }

    private func readableText(in element: AXUIElement) -> String? {
        guard let value = try? attribute(kAXValueAttribute, from: element) else { return nil }
        if let text = value as? String { return text }
        if let attributedText = value as? NSAttributedString { return attributedText.string }
        return nil
    }

    private func readCodexTextDocument(
        rawText: String,
        selection: TextRange,
        evidence: AXPlaceholderEvidence,
        element: AXUIElement
    ) throws -> AXTextDocumentState {
        let probe = AXTextCoordinateProbe { [weak self] range in
            self?.readAXString(for: range, from: element)
        }
        return try AXTextDocumentResolver.resolve(
            rawText: rawText,
            selection: selection,
            placeholderEvidence: evidence,
            probe: probe
        )
    }

    private func readAXString(for range: TextRange, from element: AXUIElement) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard status == .success, let result else { return nil }
        if let text = result as? String { return text }
        if let attributedText = result as? NSAttributedString { return attributedText.string }
        return nil
    }

    private func placeholderEvidence(in element: AXUIElement) -> AXPlaceholderEvidence {
        let explicitPlaceholder = stringAttribute("AXPlaceholderValue", from: element)
        var markedTexts: [String] = []
        var unmarkedTexts: [String] = []
        var visitedCount = 0

        func visit(
            _ node: AXUIElement,
            depth: Int,
            inheritedPlaceholder: Bool,
            isRoot: Bool
        ) {
            guard depth <= 6, visitedCount < 64 else { return }
            visitedCount += 1
            let marked = inheritedPlaceholder || classTokens(in: node).contains("placeholder")
            if !isRoot,
               stringAttribute("AXRole", from: node) == "AXStaticText",
               let text = stringAttribute(kAXValueAttribute, from: node),
               !text.isEmpty {
                if marked {
                    markedTexts.append(text)
                } else {
                    unmarkedTexts.append(text)
                }
            }
            for child in childElements(in: node) {
                visit(child, depth: depth + 1, inheritedPlaceholder: marked, isRoot: false)
            }
        }

        visit(element, depth: 0, inheritedPlaceholder: false, isRoot: true)
        return AXPlaceholderEvidence(
            explicitPlaceholder: explicitPlaceholder,
            markedTexts: markedTexts,
            unmarkedTexts: unmarkedTexts
        )
    }

    private func childElements(in element: AXUIElement) -> [AXUIElement] {
        guard let value = try? attribute("AXChildren", from: element) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        guard let value = try? attribute(name, from: element) else { return nil }
        if let text = value as? String { return text }
        if let attributedText = value as? NSAttributedString { return attributedText.string }
        return nil
    }

    private func classTokens(in element: AXUIElement) -> Set<String> {
        guard let value = try? attribute("AXDOMClassList", from: element) else { return [] }
        if let values = value as? [String] {
            return Set(values.flatMap { classTokens(in: $0) })
        }
        return classTokens(in: String(describing: value))
    }

    private func classTokens(in value: String) -> Set<String> {
        Set(
            value
                .split { character in
                    !(character.isLetter || character.isNumber)
                }
                .map { $0.lowercased() }
        )
    }

    private func recordCoordinateResolution(
        state: AXTextDocumentState,
        evidence: AXPlaceholderEvidence
    ) {
        let key = "resolved:\(state.mapping.source.rawValue):\(state.mapping.coordinateDocumentLength)"
        guard key != lastCoordinateDiagnosticKey else { return }
        lastCoordinateDiagnosticKey = key
        recordDiagnostic("ax_coordinate_mapping_resolved", [
            "coordinateSource": state.mapping.source.rawValue,
            "placeholderNormalized": String(state.placeholderNormalized),
            "axValueLengthUTF16": String(state.mapping.rawDocumentLength),
            "axCoordinateLengthUTF16": String(state.mapping.coordinateDocumentLength),
            "omittedStructuralSeparatorCount": String(state.mapping.omittedStructuralSeparatorCount),
            "placeholderAttributePresent": String(evidence.explicitPlaceholder?.isEmpty == false),
            "placeholderMarkedNodeCount": String(evidence.markedTexts.count),
            "placeholderOtherNodeCount": String(evidence.unmarkedTexts.filter { !$0.isEmpty }.count)
        ])
    }

    private func recordCoordinateResolutionFailure(
        _ error: AXTextDocumentResolutionError,
        rawText: String,
        selection: TextRange,
        evidence: AXPlaceholderEvidence,
        confirming: Bool = false
    ) {
        let reason = coordinateResolutionCode(for: error)
        let key = "failed:\(reason):\(rawText.utf16.count):\(selection.location):\(selection.length)"
        guard key != lastCoordinateDiagnosticKey else { return }
        lastCoordinateDiagnosticKey = key
        recordDiagnostic(confirming ? "ax_coordinate_mapping_retryable" : "ax_coordinate_mapping_failed", [
            "reason": reason,
            "axValueLengthUTF16": String(rawText.utf16.count),
            "selectionLocation": String(selection.location),
            "selectionLength": String(selection.length),
            "placeholderAttributePresent": String(evidence.explicitPlaceholder?.isEmpty == false),
            "placeholderMarkedNodeCount": String(evidence.markedTexts.count),
            "placeholderOtherNodeCount": String(evidence.unmarkedTexts.filter { !$0.isEmpty }.count)
        ])
    }

    private func coordinateResolutionCode(for error: AXTextDocumentResolutionError) -> String {
        switch error {
        case .invalidSelection: return "invalid_selection"
        case .coordinateReadUnavailable: return "coordinate_read_unavailable"
        case .coordinateLengthMismatch: return "coordinate_length_mismatch"
        case .coordinateTextMismatch: return "coordinate_text_mismatch"
        case .selectionOutOfBounds: return "selection_out_of_bounds"
        case .selectedRangeUnavailable: return "selected_range_unavailable"
        }
    }

    private func readableSelection(in element: AXUIElement) -> TextRange? {
        guard let value = try? attribute(kAXSelectedTextRangeAttribute, from: element),
              let axValue = axValue(from: value) else { return nil }
        return textRange(from: axValue)
    }

    private func axValue(from value: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private func requestInputPermissionsIfNeeded() throws {
        guard AXIsProcessTrusted() else {
            throw TextTargetError.accessibilityDenied
        }
        guard CGPreflightPostEventAccess() else {
            throw TextTargetError.postEventDenied
        }
    }

    private func attribute(_ name: String, from element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success else {
            if status == .attributeUnsupported || status == .noValue { throw TextTargetError.unsupported }
            recordDiagnostic("ax_read_failed", ["attribute": name, "status": String(status.rawValue)])
            throw TextTargetError.writeFailed
        }
        return value
    }

    private func textRange(from value: AXValue) -> TextRange? {
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return TextRange(location: range.location, length: range.length)
    }
}

private final class KeyboardEventSender: @unchecked Sendable {
    private let stageObserver: ((String) -> Void)?

    init(stageObserver: ((String) -> Void)? = nil) {
        self.stageObserver = stageObserver
    }
    private let queue = DispatchQueue(label: "local.tencent.voice.mvp.keyboard-events")
    private let leftArrowKeyCode: CGKeyCode = 123
    private let deleteKeyCode: CGKeyCode = 51

    func selectTrailingText(_ previousText: String, processID: pid_t?) throws {
        try queue.sync {
            guard let source = CGEventSource(stateID: .privateState) else { throw TextTargetError.writeFailed }
            stageObserver?("selection_post_begin")
            for _ in previousText {
                try sendKey(keyCode: leftArrowKeyCode, flags: .maskShift, source: source, processID: processID)
            }
            stageObserver?("selection_post_end")
        }
    }

    func replaceSelection(with text: String, processID: pid_t?) throws {
        try queue.sync {
            stageObserver?("replacement_post_begin")
            if text.isEmpty {
                guard let source = CGEventSource(stateID: .privateState) else { throw TextTargetError.writeFailed }
                try sendKey(keyCode: deleteKeyCode, source: source, processID: processID)
            } else {
                try sendText(text, processID: processID)
            }
            stageObserver?("replacement_post_end")
        }
    }

    func send(_ text: String, processID: pid_t?) throws {
        try queue.sync {
            stageObserver?("append_post_begin")
            try sendText(text, processID: processID)
            stageObserver?("append_post_end")
        }
    }

    func replaceTrailingText(
        _ previousText: String,
        with text: String,
        processID: pid_t?
    ) throws {
        try queue.sync {
            guard !previousText.isEmpty else {
                try sendText(text, processID: processID)
                return
            }
            guard let source = CGEventSource(stateID: .privateState) else {
                throw TextTargetError.writeFailed
            }
            stageObserver?("selection_post_begin")
            for _ in previousText {
                try sendKey(
                    keyCode: leftArrowKeyCode,
                    flags: .maskShift,
                    source: source,
                    processID: processID
                )
            }
            stageObserver?("selection_post_end")
            stageObserver?("replacement_post_begin")
            if text.isEmpty {
                try sendKey(
                    keyCode: deleteKeyCode,
                    source: source,
                    processID: processID
                )
            } else {
                try sendText(text, processID: processID)
            }
            stageObserver?("replacement_post_end")
        }
    }

    private func sendText(_ text: String, processID: pid_t?) throws {
        guard !text.isEmpty else { return }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw TextTargetError.writeFailed
        }

        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count,
               units[end - 1] >= 0xD800,
               units[end - 1] <= 0xDBFF,
               units[end] >= 0xDC00,
               units[end] <= 0xDFFF {
                end -= 1
            }
            guard end > start else { throw TextTargetError.writeFailed }
            let chunk = String(decoding: units[start..<end], as: UTF16.self)
            guard let keyDown = SyntheticKeyboardEventFactory.unicodeEvent(
                source: source,
                text: chunk,
                keyDown: true
            ),
                  let keyUp = SyntheticKeyboardEventFactory.unicodeEvent(
                    source: source,
                    text: "",
                    keyDown: false
                  ) else {
                throw TextTargetError.writeFailed
            }
            post(keyDown, processID: processID)
            post(keyUp, processID: processID)
            start = end
        }
    }

    private func sendKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        source: CGEventSource,
        processID: pid_t?
    ) throws {
        guard let keyDown = SyntheticKeyboardEventFactory.keyEvent(
            source: source,
            keyCode: keyCode,
            keyDown: true,
            flags: flags
        ),
              let keyUp = SyntheticKeyboardEventFactory.keyEvent(
                source: source,
                keyCode: keyCode,
                keyDown: false,
                flags: flags
              ) else {
            throw TextTargetError.writeFailed
        }
        post(keyDown, processID: processID)
        post(keyUp, processID: processID)
    }

    private func post(_ event: CGEvent, processID: pid_t?) {
        if let processID {
            event.postToPid(processID)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}

enum SyntheticKeyboardEventFactory {
    static func keyEvent(
        source: CGEventSource,
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags = []
    ) -> CGEvent? {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else { return nil }
        event.flags = flags
        return event
    }

    static func unicodeEvent(
        source: CGEventSource,
        text: String,
        keyDown: Bool
    ) -> CGEvent? {
        guard let event = keyEvent(source: source, keyCode: 0, keyDown: keyDown) else {
            return nil
        }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        event.flags = []
        return event
    }
}
