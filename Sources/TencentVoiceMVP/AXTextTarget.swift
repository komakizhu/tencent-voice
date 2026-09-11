import ApplicationServices
import AppKit
import Foundation

private enum KeyboardDocumentStateReadError: Error {
    case retryable
    case unavailable
}

private enum KeyboardReceiptRepresentation {
    static let trailingNewlineCollapsed = "trailing_newline_collapsed"
}

private struct PendingKeyboardReplacement {
    let selected: KeyboardDocumentState
    let insertion: String
    let originalSelection: TextRange
    let sessionGeneration: UInt64
    let operationGeneration: UInt64
}

private struct PendingKeyboardRepresentationTransition {
    let alternate: KeyboardDocumentState
    let sessionGeneration: UInt64
    let operationGeneration: UInt64
}

@MainActor
protocol AXTextTargetAccess {
    func requestInputPermissions() throws
    func currentApplication() -> TextTargetApplication?
    func focusedElement() throws -> AXUIElement
    func processIdentifier(of element: AXUIElement) -> pid_t?
    func text(in element: AXUIElement) throws -> String?
    func selection(in element: AXUIElement) throws -> TextRange?
    func coordinateText(for range: TextRange, in element: AXUIElement) throws -> String?
    func placeholderEvidence(in element: AXUIElement) -> AXPlaceholderEvidence
    func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool
    func setSelection(_ range: TextRange, on element: AXUIElement) throws -> Int32
    func setSelectedText(_ text: String, on element: AXUIElement) throws -> Int32
    func setValue(_ text: String, on element: AXUIElement) throws -> Int32
}

@MainActor
protocol AXTextTargetKeyboardEventSending: AnyObject {
    func selectTrailingText(_ previousText: String, processID: pid_t?) throws
    func replaceSelection(with text: String, processID: pid_t?) throws
    func send(_ text: String, processID: pid_t?) throws
    func replaceTrailingText(_ previousText: String, with text: String, processID: pid_t?) throws
}

struct AXTextTargetWriteTiming {
    let now: () -> UInt64
    let sleep: (UInt64) async throws -> Void

    init(
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }
}

@MainActor
final class AXTextTarget: KeyboardAcknowledgingTarget {
    private(set) var requiresKeyboardAcknowledgement = false
    private var confirmedKeyboardDocument: String?
    private var confirmedKeyboardState: KeyboardDocumentState?
    private var pendingKeyboardWrite: KeyboardDocumentState?
    private var pendingKeyboardRepresentationTransition: PendingKeyboardRepresentationTransition?
    private var pendingKeyboardReplacement: PendingKeyboardReplacement?
    private var replacementWasSent = false
    private var confirmedKeyboardRawText: String?
    private var confirmedKeyboardMapping: AXTextCoordinateMapping?
    private var lastResolvedCodexDocument: AXTextDocumentState?
    private var codexPlaceholderEvidence: AXPlaceholderEvidence?
    private var codexAXValueFallbackAllowed = false
    private var keyboardGeneration: UInt64 = 0
    private var keyboardOperationGeneration: UInt64 = 0
    private var isCodexTarget = false
    private var targetElement: AXUIElement?
    private var targetProcessID: pid_t?
    private var targetApplicationProcessID: pid_t?
    private var expectedKeyboardSelection: TextRange?
    private let access: any AXTextTargetAccess
    private let keyboardEventSender: any AXTextTargetKeyboardEventSending
    private let writeTiming: AXTextTargetWriteTiming
    private let preflightTimeoutNanoseconds: UInt64
    private let acknowledgementTimeoutNanoseconds: UInt64
    private var diagnostics: [TextInputDiagnostic] = []
    private var droppedDiagnosticCount = 0
    private var diagnosticOperationContext: TextInputDiagnosticContext?
    private var previousDiagnosticOperationContext: TextInputDiagnosticContext?
    private var lastKeyboardDispatch: UInt64?
    private var lastAXWriteStatus: Int32?
    private var lastAXWriteKind = "none"
    private var lastCoordinateDiagnosticKey: String?

    init(
        operationObserver: ((String) -> Void)? = nil,
        access: (any AXTextTargetAccess)? = nil,
        keyboardEventSender: (any AXTextTargetKeyboardEventSending)? = nil,
        writeTiming: AXTextTargetWriteTiming = .init(),
        preflightTimeoutNanoseconds: UInt64 = 5_000_000_000,
        acknowledgementTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.access = access ?? SystemAXTextTargetAccess()
        self.keyboardEventSender = keyboardEventSender
            ?? KeyboardEventSender(stageObserver: operationObserver)
        self.writeTiming = writeTiming
        self.preflightTimeoutNanoseconds = preflightTimeoutNanoseconds
        self.acknowledgementTimeoutNanoseconds = acknowledgementTimeoutNanoseconds
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
        access.currentApplication()
    }

    func capture() throws -> TextSnapshot {
        keyboardGeneration &+= 1
        keyboardOperationGeneration = 0
        pendingKeyboardWrite = nil
        pendingKeyboardRepresentationTransition = nil
        pendingKeyboardReplacement = nil
        replacementWasSent = false
        confirmedKeyboardRawText = nil
        confirmedKeyboardMapping = nil
        lastResolvedCodexDocument = nil
        codexPlaceholderEvidence = nil
        codexAXValueFallbackAllowed = false
        confirmedKeyboardDocument = nil
        confirmedKeyboardState = nil
        requiresKeyboardAcknowledgement = false
        diagnostics.removeAll(keepingCapacity: true)
        droppedDiagnosticCount = 0
        diagnosticOperationContext = nil
        previousDiagnosticOperationContext = nil
        lastKeyboardDispatch = nil
        lastAXWriteStatus = nil
        lastAXWriteKind = "none"
        lastCoordinateDiagnosticKey = nil
        try access.requestInputPermissions()
        targetElement = nil
        targetProcessID = nil
        expectedKeyboardSelection = nil
        let targetApplication = currentApplication()
        targetApplicationProcessID = targetApplication.map { pid_t($0.processIdentifier) }
        isCodexTarget = targetApplication?.bundleIdentifier == "com.openai.codex"

        // Some Electron/WebKit controls expose neither a stable AX value nor
        // a stable focused AX element while the DOM is being rebuilt. That is
        // still a valid keyboard target as long as a frontmost application is
        // known; the keyboard append path only owns the text it sends.
        let element = try? focusedElement()
        targetElement = element
        if let element {
            targetProcessID = access.processIdentifier(of: element) ?? targetApplicationProcessID
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
        let rawText = try element.flatMap { try captureReadableText(in: $0) }
        let readableKeyboardSelection = try element.flatMap { try captureReadableSelection(in: $0) }
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
            } catch let error as TextTargetError {
                throw error
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
        expectedKeyboardSelection = selection
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
        confirmedKeyboardState = if let codexState {
            KeyboardDocumentState(
                text: codexState.text,
                selection: codexState.selection,
                rawText: codexState.rawText,
                mapping: codexState.mapping
            )
        } else if !isCodexTarget, let rawText, let readableKeyboardSelection {
            KeyboardDocumentState(text: rawText, selection: readableKeyboardSelection)
        } else {
            nil
        }
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
        guard let currentText = readableText(in: element) else {
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
        guard let currentSelection = readableSelection(in: element),
              currentSelection.location == range.location + range.length,
              range.location >= 0,
              range.length >= 0,
              range.location + range.length <= currentText.utf16.count else {
            recordDiagnostic("ax_selection_mismatch", [
                "expectedLocation": String(range.location + range.length),
                "actualLocation": String(readableSelection(in: element)?.location ?? -1),
                "actualLength": String(readableSelection(in: element)?.length ?? -1)
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
            let status = try access.setSelectedText(delta.insertion, on: element)
            lastAXWriteStatus = status
            lastAXWriteKind = "selected"
            guard status == AXError.success.rawValue else {
                recordDiagnostic("ax_write_failed", ["status": String(status), "writeKind": "selected"])
                throw TextTargetError.writeFailed
            }
        } else {
            guard valueIsSettable(on: element) else { throw TextTargetError.writeFailed }
            let document = NSMutableString(string: currentText)
            document.replaceCharacters(
                in: NSRange(location: range.location, length: range.length),
                with: text
            )
            let status = try access.setValue(document as String, on: element)
            lastAXWriteStatus = status
            lastAXWriteKind = "value"
            guard status == AXError.success.rawValue else {
                recordDiagnostic("ax_write_failed", ["status": String(status), "writeKind": "value"])
                throw TextTargetError.writeFailed
            }
        }

        let newRange = TextRange(location: range.location, length: text.utf16.count)
        try setSelection(TextRange(location: newRange.location + newRange.length, length: 0), on: element)
        return newRange
    }

    func writeKeyboardText(previousText: String, with text: String) async throws {
        guard requiresKeyboardAcknowledgement else {
            if previousText.isEmpty {
                try paste(text)
            } else {
                try replaceTrailingText(previousText, with: text)
            }
            return
        }

        let generation = keyboardGeneration
        try await waitForConfirmedKeyboardState(generation: generation)
        try Task.checkCancellation()
        guard generation == keyboardGeneration else { throw CancellationError() }
        try ensureKeyboardTargetIdentityIsSafe()
        try Task.checkCancellation()
        guard generation == keyboardGeneration else { throw CancellationError() }
        if previousText.isEmpty {
            try submitPaste(text)
        } else {
            try submitTrailingReplacement(previousText, with: text)
        }
        try await acknowledgeKeyboardWrite()
    }

    func paste(_ text: String) throws {
        try ensureKeyboardTargetIsSafe()
        try submitPaste(text)
    }

    private func submitPaste(_ text: String) throws {
        keyboardOperationGeneration &+= 1
        let operationGeneration = keyboardOperationGeneration
        let receipt = try keyboardReceipt(
            replacing: expectedKeyboardSelection,
            with: text,
            operationGeneration: operationGeneration
        )
        do {
            try keyboardEventSender.send(text, processID: eventProcessID)
        } catch {
            pendingKeyboardRepresentationTransition = nil
            throw error
        }
        lastKeyboardDispatch = writeTiming.now()
        if let receipt {
            pendingKeyboardWrite = receipt
            let fields = [
                "expectedLocation": String(receipt.selection.location),
                "expectedDocumentLength": String(receipt.text.utf16.count),
                "receiptRepresentationTransition": pendingKeyboardRepresentationTransition != nil
                    ? KeyboardReceiptRepresentation.trailingNewlineCollapsed
                    : "none"
            ]
            recordDiagnostic("keyboard_write_submitted", fields)
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
        try submitTrailingReplacement(previousText, with: text)
    }

    private func submitTrailingReplacement(_ previousText: String, with text: String) throws {
        let previousCoordinateLength = coordinateLength(forKeyboardText: previousText)
        let insertionCoordinateLength = coordinateLength(forKeyboardText: text)
        let updatedSelection: TextRange?
        if let selection = expectedKeyboardSelection {
            guard selection.length == 0,
                  selection.location >= previousCoordinateLength else {
                throw TextTargetError.targetChanged
            }
            updatedSelection = TextRange(
                location: selection.location - previousCoordinateLength + insertionCoordinateLength,
                length: 0
            )
        } else {
            updatedSelection = nil
        }
        let replacementRange = expectedKeyboardSelection.map {
            TextRange(location: $0.location - previousCoordinateLength, length: previousCoordinateLength)
        }
        let receipt = try keyboardReceipt(replacing: replacementRange, with: text, previousText: previousText)
        if let receipt, let replacementRange, let document = confirmedKeyboardDocument {
            let selected = KeyboardDocumentState(
                text: document,
                selection: replacementRange,
                rawText: confirmedKeyboardRawText,
                mapping: confirmedKeyboardMapping
            )
            let originalSelection = expectedKeyboardSelection ?? TextRange(
                location: replacementRange.location + replacementRange.length,
                length: 0
            )
            keyboardOperationGeneration &+= 1
            let operationGeneration = keyboardOperationGeneration
            let usesAXSelection = targetElement.map {
                selectedTextRangeIsSettable(on: $0)
            } ?? false
            if usesAXSelection, let targetElement {
                // AXSelectedTextRange and AXStringForRange use the same
                // coordinate space. The raw mapping is only for predicting
                // the AXValue receipt, not for moving the accessibility caret.
                try setSelection(replacementRange, on: targetElement)
            } else {
                try keyboardEventSender.selectTrailingText(previousText, processID: eventProcessID)
            }
            pendingKeyboardReplacement = PendingKeyboardReplacement(
                selected: selected,
                insertion: text,
                originalSelection: originalSelection,
                sessionGeneration: keyboardGeneration,
                operationGeneration: operationGeneration
            )
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
        lastKeyboardDispatch = writeTiming.now()
        if let receipt {
            pendingKeyboardWrite = receipt
            recordDiagnostic("keyboard_write_submitted", ["expectedLocation": String(receipt.selection.location),
                "expectedDocumentLength": String(receipt.text.utf16.count), "replacementCharacters": String(previousText.count)])
            return
        }
        expectedKeyboardSelection = updatedSelection
    }

    private func waitForConfirmedKeyboardState(generation: UInt64) async throws {
        guard let expected = confirmedKeyboardState else {
            recordDiagnostic("keyboard_confirmed_state_unavailable")
            throw TextTargetError.writeFailed
        }
        _ = try await KeyboardWriteAcknowledgement.wait(
            for: expected,
            timeoutNanoseconds: preflightTimeoutNanoseconds,
            now: writeTiming.now,
            sleep: writeTiming.sleep
        ) {
            let observed = try self.readKeyboardDocumentObservation(
                generation: generation,
                phase: "preflight"
            )
            guard observed == expected else {
                self.recordDiagnostic("keyboard_confirmed_state_changed", [
                    "expectedDocumentLength": String(expected.text.utf16.count),
                    "actualDocumentLength": String(observed.text.utf16.count),
                    "expectedSelectionLocation": String(expected.selection.location),
                    "actualSelectionLocation": String(observed.selection.location)
                ])
                throw TextTargetError.targetChanged
            }
            return observed
        }
    }

    private func readKeyboardDocumentObservation(
        generation: UInt64,
        phase: String
    ) throws -> KeyboardDocumentState {
        guard generation == keyboardGeneration else { throw CancellationError() }
        try ensureTargetApplicationIsFrontmost()
        let element = try focusedElement()
        guard let targetElement, CFEqual(element, targetElement) else {
            throw TextTargetError.targetChanged
        }
        do {
            let state = try KeyboardWriteAcknowledgement.readObservation {
                try self.keyboardDocumentState(in: element, confirming: true)
            }
            try ensureTargetApplicationIsFrontmost()
            let afterElement = try focusedElement()
            guard CFEqual(afterElement, targetElement) else {
                throw TextTargetError.targetChanged
            }
            return state
        } catch KeyboardWriteReadError.retryable {
            recordDiagnostic("keyboard_state_read_retryable", ["phase": phase])
            throw KeyboardWriteReadError.retryable
        } catch KeyboardDocumentStateReadError.retryable,
                KeyboardDocumentStateReadError.unavailable {
            recordDiagnostic("keyboard_state_read_retryable", ["phase": phase])
            throw KeyboardWriteReadError.retryable
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TextTargetError {
            throw error
        } catch {
            throw TextTargetError.targetChanged
        }
    }

    func acknowledgeKeyboardWrite() async throws {
        guard let receipt = pendingKeyboardWrite else { return }
        let generation = keyboardGeneration
        let operationGeneration = keyboardOperationGeneration
        let start = writeTiming.now()
        let pendingRepresentationTransition = pendingKeyboardRepresentationTransition
        var lastObservedState: KeyboardDocumentState?
        var lastComparison: KeyboardDocumentComparison?
        var usedRepresentationTransition = false
        let read = { () throws -> KeyboardDocumentState in
            let observed = try self.readKeyboardDocumentObservation(
                generation: generation,
                phase: "acknowledgement"
            )
            lastObservedState = observed
            return observed
        }
        let matches: (KeyboardDocumentState, KeyboardDocumentState) -> Bool = { expected, observed in
            let comparison = observed.compare(
                to: expected,
                allowingStructuralRawDifference: self.isCodexTarget
            )
            lastComparison = comparison
            guard comparison != .matched else { return true }
            guard let transition = pendingRepresentationTransition,
                  transition.sessionGeneration == generation,
                  transition.operationGeneration == operationGeneration,
                  let expectedRawText = transition.alternate.rawText,
                  observed.rawText == expectedRawText,
                  observed.mapping == transition.alternate.mapping,
                  observed.compare(
                      to: transition.alternate,
                      allowingStructuralRawDifference: self.isCodexTarget
                  ) == .matched else {
                return false
            }
            usedRepresentationTransition = true
            lastComparison = .matched
            return true
        }
        do {
            let acknowledgedState: KeyboardDocumentState
            if let replacement = pendingKeyboardReplacement {
                acknowledgedState = try await KeyboardWriteAcknowledgement.replaceSelection(
                    selected: replacement.selected,
                    result: receipt,
                    matches: matches,
                    timeoutNanoseconds: acknowledgementTimeoutNanoseconds,
                    now: writeTiming.now,
                    sleep: writeTiming.sleep,
                    read: read
                ) {
                    self.recordDiagnostic(
                        "keyboard_selection_acknowledged",
                        context: self.previousDiagnosticOperationContext
                    )
                    try self.keyboardEventSender.replaceSelection(with: replacement.insertion, processID: self.eventProcessID)
                    self.replacementWasSent = true
                    self.lastKeyboardDispatch = self.writeTiming.now()
                    self.recordDiagnostic(
                        "keyboard_replacement_submitted",
                        context: self.previousDiagnosticOperationContext
                    )
                }
            } else {
                acknowledgedState = try await KeyboardWriteAcknowledgement.wait(
                    for: receipt,
                    matches: matches,
                    timeoutNanoseconds: acknowledgementTimeoutNanoseconds,
                    now: writeTiming.now,
                    sleep: writeTiming.sleep,
                    read: read
                )
            }
            guard generation == keyboardGeneration else { throw CancellationError() }
            confirmedKeyboardDocument = acknowledgedState.text
            expectedKeyboardSelection = acknowledgedState.selection
            confirmedKeyboardRawText = acknowledgedState.rawText
            confirmedKeyboardMapping = acknowledgedState.mapping
            confirmedKeyboardState = acknowledgedState
            pendingKeyboardWrite = nil
            pendingKeyboardRepresentationTransition = nil
            pendingKeyboardReplacement = nil
            replacementWasSent = false
            recordDiagnostic("keyboard_write_acknowledged", [
                "elapsedMilliseconds": String((writeTiming.now() - start) / 1_000_000),
                "documentMatches": "true", "selectionMatches": "true",
                "comparison": lastComparison?.rawValue ?? "matched",
                "observedLengthUTF16": String(acknowledgedState.text.utf16.count),
                "observedRawLengthUTF16": String(acknowledgedState.rawText?.utf16.count ?? 0),
                "receiptRepresentationTransition": usedRepresentationTransition
                    ? KeyboardReceiptRepresentation.trailingNewlineCollapsed
                    : "none"
            ], context: previousDiagnosticOperationContext)
        } catch {
            recordDiagnostic(
                "keyboard_write_unconfirmed",
                [
                    "code": DiagnosticErrorFormatter.code(for: error),
                    "comparison": lastComparison?.rawValue ?? "unreadable",
                    "observedLengthUTF16": String(lastObservedState?.text.utf16.count ?? 0),
                    "observedRawLengthUTF16": String(lastObservedState?.rawText?.utf16.count ?? 0),
                    "receiptRepresentationTransition": pendingRepresentationTransition != nil
                        ? KeyboardReceiptRepresentation.trailingNewlineCollapsed
                        : "none"
                ],
                context: previousDiagnosticOperationContext
            )
            pendingKeyboardRepresentationTransition = nil
            recoverPendingSelectionIfSafe(generation: generation)
            throw error
        }
    }

    private func keyboardReceipt(replacing range: TextRange?, with text: String,
                                 previousText: String? = nil,
                                 operationGeneration: UInt64? = nil) throws -> KeyboardDocumentState? {
        pendingKeyboardRepresentationTransition = nil
        guard requiresKeyboardAcknowledgement else { return nil }
        guard let range, let document = confirmedKeyboardDocument,
              range.location >= 0, range.length >= 0,
              range.location <= document.utf16.count,
              range.length <= document.utf16.count - range.location else { throw TextTargetError.targetChanged }
        let nsRange = NSRange(location: range.location, length: range.length)
        if let previousText,
           (document as NSString).substring(with: nsRange) != coordinateText(forKeyboardText: previousText) {
            throw TextTargetError.targetChanged
        }
        let coordinateText = coordinateText(forKeyboardText: text)
        let result = NSMutableString(string: document)
        result.replaceCharacters(in: nsRange, with: coordinateText)
        let rawResult: String?
        var rawDocumentForTransition: String?
        var rawRangeForTransition: TextRange?
        var mappingForTransition: AXTextCoordinateMapping?
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
            rawDocumentForTransition = rawDocument
            rawRangeForTransition = rawRange
            mappingForTransition = mapping
        } else {
            rawResult = nil
            rawDocumentForTransition = nil
            rawRangeForTransition = nil
            mappingForTransition = nil
        }
        let primary = KeyboardDocumentState(
            text: result as String,
            selection: TextRange(location: range.location + coordinateText.utf16.count, length: 0),
            rawText: rawResult
        )
        if previousText == nil,
           let rawDocumentForTransition,
           let rawRangeForTransition,
           let mappingForTransition,
           let alternate = trailingNewlineCollapsedReceipt(
               document: document,
               range: range,
               text: text,
               rawDocument: rawDocumentForTransition,
               rawRange: rawRangeForTransition,
               mapping: mappingForTransition
           ) {
            pendingKeyboardRepresentationTransition = PendingKeyboardRepresentationTransition(
                alternate: alternate,
                sessionGeneration: keyboardGeneration,
                operationGeneration: operationGeneration ?? keyboardOperationGeneration
            )
        }
        return primary
    }

    private func trailingNewlineCollapsedReceipt(
        document: String,
        range: TextRange,
        text: String,
        rawDocument: String,
        rawRange: TextRange,
        mapping: AXTextCoordinateMapping
    ) -> KeyboardDocumentState? {
        guard isCodexTarget,
              !text.isEmpty,
              !text.unicodeScalars.contains(where: isStructuralSeparator),
              range.length == 0,
              !document.isEmpty,
              range.location == document.utf16.count - 1,
              mapping.source == .axStringForRange,
              mapping.coordinateDocumentLength == document.utf16.count,
              mapping.rawDocumentLength == rawDocument.utf16.count,
              rawRange.length == 0,
              rawRange.location == rawDocument.utf16.count - 1,
              utf16Unit(at: range.location, in: document) == 0x0A,
              utf16Unit(at: rawRange.location, in: rawDocument) == 0x0A else {
            return nil
        }

        let alternateSelection = TextRange(
            location: range.location + text.utf16.count,
            length: 0
        )
        let alternateCoordinate = NSMutableString(string: document)
        alternateCoordinate.replaceCharacters(
            in: NSRange(location: range.location, length: 0),
            with: text
        )
        let insertedTextEnd = range.location + text.utf16.count
        guard insertedTextEnd < alternateCoordinate.length,
              alternateCoordinate.substring(
                  with: NSRange(location: insertedTextEnd, length: 1)
              ) == "\n" else {
            return nil
        }
        alternateCoordinate.deleteCharacters(
            in: NSRange(location: insertedTextEnd, length: 1)
        )

        let alternateRaw = NSMutableString(string: rawDocument)
        alternateRaw.replaceCharacters(
            in: NSRange(location: rawRange.location + 1, length: 0),
            with: text
        )
        let alternateText = alternateCoordinate as String
        let alternateRawText = alternateRaw as String
        let probe = AXTextCoordinateProbe { requestedRange in
            guard requestedRange.location >= 0,
                  requestedRange.length >= 0,
                  requestedRange.location <= alternateText.utf16.count,
                  requestedRange.length <= alternateText.utf16.count - requestedRange.location else {
                return nil
            }
            return (alternateText as NSString).substring(
                with: NSRange(
                    location: requestedRange.location,
                    length: requestedRange.length
                )
            )
        }
        guard let resolved = try? AXTextDocumentResolver.resolve(
            rawText: alternateRawText,
            selection: alternateSelection,
            placeholderEvidence: .init(),
            probe: probe
        ),
        resolved.rawText == alternateRawText,
        resolved.text == alternateText,
        resolved.selection == alternateSelection,
        resolved.mapping.source == .axStringForRange,
        resolved.mapping.rawRange(for: alternateSelection) != nil else {
            return nil
        }
        return KeyboardDocumentState(
            text: resolved.text,
            selection: resolved.selection,
            rawText: resolved.rawText,
            mapping: resolved.mapping
        )
    }

    private func utf16Unit(at offset: Int, in text: String) -> UInt16? {
        guard offset >= 0 else { return nil }
        let units = Array(text.utf16)
        guard offset < units.count else { return nil }
        return units[offset]
    }

    private func isStructuralSeparator(_ scalar: UnicodeScalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    private func coordinateLength(forKeyboardText text: String) -> Int {
        coordinateText(forKeyboardText: text).utf16.count
    }

    private func coordinateText(forKeyboardText text: String) -> String {
        guard isCodexTarget,
              (confirmedKeyboardMapping?.omittedStructuralSeparatorCount ?? 0) > 0 else {
            return text
        }
        return String(text.unicodeScalars.filter { scalar in
            scalar != "\n" && scalar != "\r" && scalar != "\u{2028}" && scalar != "\u{2029}"
        })
    }

    private func keyboardDocumentState(in element: AXUIElement, confirming: Bool = false) throws -> KeyboardDocumentState {
        guard let rawText = try access.text(in: element),
              let selection = try access.selection(in: element) else {
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
                    rawText: document.rawText,
                    mapping: document.mapping
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
                        rawText: document.rawText,
                        mapping: document.mapping
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
            } catch let error as TextTargetError {
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
        let status = try access.setSelection(range, on: element)
        guard status == AXError.success.rawValue else {
            recordDiagnostic("ax_write_failed", ["status": String(status), "writeKind": "selection"])
            throw TextTargetError.writeFailed
        }
    }

    private func selectedTextIsSettable(on element: AXUIElement) -> Bool {
        access.isAttributeSettable(kAXSelectedTextAttribute as String, on: element)
    }

    private func valueIsSettable(on element: AXUIElement) -> Bool {
        access.isAttributeSettable(kAXValueAttribute as String, on: element)
    }

    private func selectedTextRangeIsSettable(on element: AXUIElement) -> Bool {
        access.isAttributeSettable(kAXSelectedTextRangeAttribute as String, on: element)
    }

    private func rawRange(for range: TextRange) throws -> TextRange {
        guard isCodexTarget else { return range }
        guard let mapping = confirmedKeyboardMapping,
              let rawRange = mapping.rawRange(for: range) else {
            throw TextTargetError.targetChanged
        }
        return rawRange
    }

    private func ensureKeyboardTargetIdentityIsSafe() throws {
        try ensureTargetApplicationIsFrontmost()
        guard let targetElement else { return }
        let currentElement = try focusedElement()
        guard CFEqual(currentElement, targetElement) else {
            recordDiagnostic("keyboard_focus_changed")
            throw TextTargetError.targetChanged
        }
    }

    private func ensureKeyboardTargetIsSafe() throws {
        try ensureKeyboardTargetIdentityIsSafe()
        guard let targetElement else { return }
        let currentElement = try focusedElement()
        if requiresKeyboardAcknowledgement {
            guard pendingKeyboardWrite == nil else { throw TextTargetError.writeFailed }
            guard let currentState = try? keyboardDocumentState(in: currentElement),
                  let expectedState = currentConfirmedKeyboardState() else {
                recordDiagnostic("keyboard_confirmed_state_changed", ["comparison": "unreadable"])
                throw TextTargetError.targetChanged
            }
            let comparison = keyboardStateComparison(currentState, expected: expectedState)
            guard comparison == .matched else {
                recordDiagnostic(
                    "keyboard_confirmed_state_changed",
                    [
                        "comparison": comparison.rawValue,
                        "expectedDocumentLengthUTF16": String(expectedState.text.utf16.count),
                        "currentDocumentLengthUTF16": String(currentState.text.utf16.count),
                        "expectedSelectionLocation": String(expectedState.selection.location),
                        "expectedSelectionLength": String(expectedState.selection.length),
                        "currentSelectionLocation": String(currentState.selection.location),
                        "currentSelectionLength": String(currentState.selection.length)
                    ]
                )
                throw TextTargetError.targetChanged
            }
            commitConfirmedKeyboardState(currentState)
            return
        }
        if let expectedKeyboardSelection {
            let actualSelection = readableSelection(in: currentElement)
            if actualSelection != expectedKeyboardSelection {
                let age = lastKeyboardDispatch.map {
                    Double(writeTiming.now() - $0) / 1_000_000
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

    func reconcileKeyboardStateForUserEdit() throws -> KeyboardReconciliation {
        guard requiresKeyboardAcknowledgement, isCodexTarget else { return .matched }
        try ensureTargetApplicationIsFrontmost()
        guard let targetElement else { return .matched }
        let currentElement = try focusedElement()
        guard CFEqual(currentElement, targetElement) else {
            recordDiagnostic("keyboard_focus_changed")
            throw TextTargetError.targetChanged
        }
        guard pendingKeyboardWrite == nil, pendingKeyboardReplacement == nil else {
            recordDiagnostic("own_write_in_flight", [
                "pendingReplacement": String(pendingKeyboardReplacement != nil),
                "keyboardGeneration": String(keyboardGeneration)
            ])
            return .ownWriteInFlight
        }
        let currentState: KeyboardDocumentState
        do {
            currentState = try keyboardDocumentState(in: currentElement)
        } catch KeyboardDocumentStateReadError.retryable,
                KeyboardWriteReadError.retryable {
            // The atomic writer performs the same preflight with its bounded
            // retry loop. A transient AX snapshot here must not be mistaken
            // for an external edit before that loop gets a chance to recover.
            recordDiagnostic("keyboard_state_read_retryable", ["phase": "reconciliation"])
            return .matched
        } catch {
            recordDiagnostic("keyboard_user_edit_read_failed")
            throw TextTargetError.targetChanged
        }
        guard let expectedState = currentConfirmedKeyboardState() else {
            recordDiagnostic("keyboard_user_edit_read_failed")
            throw TextTargetError.targetChanged
        }
        let comparison = keyboardStateComparison(currentState, expected: expectedState)
        guard comparison != .rawMappingUnavailable else {
            recordDiagnostic("keyboard_user_edit_ambiguous", ["reason": "mapping_unavailable"])
            throw TextTargetError.targetChanged
        }
        guard comparison != .matched else {
            commitConfirmedKeyboardState(currentState)
            return .matched
        }

        recordDiagnostic("keyboard_user_edit_detected", [
            "comparison": comparison.rawValue,
            "previousDocumentLengthUTF16": String(expectedState.text.utf16.count),
            "currentDocumentLengthUTF16": String(currentState.text.utf16.count),
            "previousSelectionLocation": String(expectedState.selection.location),
            "previousSelectionLength": String(expectedState.selection.length),
            "currentSelectionLocation": String(currentState.selection.location),
            "currentSelectionLength": String(currentState.selection.length)
        ])
        commitConfirmedKeyboardState(currentState)
        recordDiagnostic("keyboard_state_rebased_after_user_edit", [
            "documentLengthUTF16": String(currentState.text.utf16.count),
            "selectionLocation": String(currentState.selection.location),
            "selectionLength": String(currentState.selection.length)
        ])
        return .externalEdit
    }

    private func recoverPendingSelectionIfSafe(generation: UInt64) {
        guard let pending = pendingKeyboardReplacement else { return }
        guard pending.sessionGeneration == generation,
              generation == keyboardGeneration,
              pending.operationGeneration == keyboardOperationGeneration else {
            recordDiagnostic("selection_recovery_skipped", ["reason": "operation_generation_changed"])
            return
        }
        guard !replacementWasSent else {
            recordDiagnostic("selection_recovery_skipped", ["reason": "replacement_already_sent"])
            return
        }
        guard let targetElement else {
            recordDiagnostic("selection_recovery_skipped", ["reason": "target_unavailable"])
            return
        }

        do {
            try ensureTargetApplicationIsFrontmost()
            let currentElement = try focusedElement()
            guard CFEqual(currentElement, targetElement) else {
                recordDiagnostic("selection_recovery_skipped", ["reason": "focus_changed"])
                return
            }
            guard let currentState = try? keyboardDocumentState(in: currentElement) else {
                recordDiagnostic("selection_recovery_skipped", ["reason": "read_failed"])
                return
            }
            let comparison = keyboardStateComparison(currentState, expected: pending.selected)
            guard comparison == .matched else {
                recordDiagnostic("selection_recovery_skipped", ["reason": comparison.rawValue])
                return
            }
            try setSelection(pending.originalSelection, on: currentElement)
            guard readableSelection(in: currentElement) == pending.originalSelection else {
                recordDiagnostic("selection_recovery_skipped", ["reason": "selection_not_restored"])
                return
            }
            expectedKeyboardSelection = pending.originalSelection
            pendingKeyboardReplacement = nil
            pendingKeyboardWrite = nil
            replacementWasSent = false
            recordDiagnostic("selection_recovery_succeeded", [
                "selectionLocation": String(pending.originalSelection.location),
                "selectionLength": String(pending.originalSelection.length)
            ])
        } catch {
            recordDiagnostic("selection_recovery_skipped", [
                "reason": DiagnosticErrorFormatter.code(for: error)
            ])
        }
    }

    private func currentConfirmedKeyboardState() -> KeyboardDocumentState? {
        guard let confirmedKeyboardDocument,
              let expectedKeyboardSelection else { return nil }
        return KeyboardDocumentState(
            text: confirmedKeyboardDocument,
            selection: expectedKeyboardSelection,
            rawText: confirmedKeyboardRawText,
            mapping: confirmedKeyboardMapping
        )
    }

    private func keyboardStateComparison(
        _ current: KeyboardDocumentState,
        expected: KeyboardDocumentState
    ) -> KeyboardDocumentComparison {
        current.compare(
            to: expected,
            allowingStructuralRawDifference: isCodexTarget
        )
    }

    private func commitConfirmedKeyboardState(_ state: KeyboardDocumentState) {
        confirmedKeyboardDocument = state.text
        expectedKeyboardSelection = state.selection
        confirmedKeyboardRawText = state.rawText
        confirmedKeyboardMapping = state.mapping
        confirmedKeyboardState = state
    }

    private func ensureTargetApplicationIsFrontmost() throws {
        guard let targetApplicationProcessID else { return }
        guard access.currentApplication()?.processIdentifier == Int32(targetApplicationProcessID) else {
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
        try access.focusedElement()
    }

    private func readableText(in element: AXUIElement) -> String? {
        try? access.text(in: element)
    }

    private func captureReadableText(in element: AXUIElement) throws -> String? {
        do {
            return try access.text(in: element)
        } catch KeyboardWriteReadError.retryable, TextTargetError.unsupported {
            return nil
        }
    }

    private func readCodexTextDocument(
        rawText: String,
        selection: TextRange,
        evidence: AXPlaceholderEvidence,
        element: AXUIElement
    ) throws -> AXTextDocumentState {
        let probe = AXTextCoordinateProbe { [weak self] range in
            guard let self else { return nil }
            return try self.access.coordinateText(for: range, in: element)
        }
        return try AXTextDocumentResolver.resolve(
            rawText: rawText,
            selection: selection,
            placeholderEvidence: evidence,
            probe: probe
        )
    }

    private func placeholderEvidence(in element: AXUIElement) -> AXPlaceholderEvidence {
        access.placeholderEvidence(in: element)
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
        try? access.selection(in: element)
    }

    private func captureReadableSelection(in element: AXUIElement) throws -> TextRange? {
        do {
            return try access.selection(in: element)
        } catch KeyboardWriteReadError.retryable, TextTargetError.unsupported {
            return nil
        }
    }

}

@MainActor
final class SystemAXTextTargetAccess: AXTextTargetAccess {
    func requestInputPermissions() throws {
        guard AXIsProcessTrusted() else {
            throw TextTargetError.accessibilityDenied
        }
        guard CGPreflightPostEventAccess() else {
            throw TextTargetError.postEventDenied
        }
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

    func focusedElement() throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        guard let elementObject = try attribute(kAXFocusedUIElementAttribute as String, from: system) else {
            throw TextTargetError.unsupported
        }
        return elementObject as! AXUIElement
    }

    func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success, processID != 0 else {
            return nil
        }
        return processID
    }

    func text(in element: AXUIElement) throws -> String? {
        let value: CFTypeRef?
        do {
            value = try attribute(kAXValueAttribute as String, from: element)
        } catch TextTargetError.unsupported {
            return nil
        }
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let attributedText = value as? NSAttributedString { return attributedText.string }
        return nil
    }

    func selection(in element: AXUIElement) throws -> TextRange? {
        let value: CFTypeRef?
        do {
            value = try attribute(kAXSelectedTextRangeAttribute as String, from: element)
        } catch TextTargetError.unsupported {
            return nil
        }
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return TextRange(location: range.location, length: range.length)
    }

    func coordinateText(for range: TextRange, in element: AXUIElement) throws -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            throw TextTargetError.writeFailed
        }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        switch status {
        case .success:
            guard let result else { return nil }
            if let text = result as? String { return text }
            if let attributedText = result as? NSAttributedString { return attributedText.string }
            return nil
        case .attributeUnsupported, .noValue:
            return nil
        case .cannotComplete:
            throw KeyboardWriteReadError.retryable
        default:
            throw TextTargetError.writeFailed
        }
    }

    func placeholderEvidence(in element: AXUIElement) -> AXPlaceholderEvidence {
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
               let text = stringAttribute(kAXValueAttribute as String, from: node),
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

    func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    func setSelection(_ range: TextRange, on element: AXUIElement) throws -> Int32 {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            throw TextTargetError.writeFailed
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ).rawValue
    }

    func setSelectedText(_ text: String, on element: AXUIElement) throws -> Int32 {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ).rawValue
    }

    func setValue(_ text: String, on element: AXUIElement) throws -> Int32 {
        AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        ).rawValue
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

    private func attribute(_ name: String, from element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch status {
        case .success:
            return value
        case .attributeUnsupported, .noValue:
            throw TextTargetError.unsupported
        case .cannotComplete:
            throw KeyboardWriteReadError.retryable
        default:
            throw TextTargetError.writeFailed
        }
    }
}

@MainActor
private final class KeyboardEventSender: AXTextTargetKeyboardEventSending, @unchecked Sendable {
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
