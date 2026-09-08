import ApplicationServices
import AppKit
import Foundation

@MainActor
final class AXTextTarget: TextTarget {
    private var targetElement: AXUIElement?
    private var targetProcessID: pid_t?
    private var targetApplicationProcessID: pid_t?
    private var expectedKeyboardSelection: TextRange?
    private let keyboardEventSender = KeyboardEventSender()
    private var diagnostics: [TextInputDiagnostic] = []
    private var droppedDiagnosticCount = 0
    private var diagnosticOperationContext: TextInputDiagnosticContext?
    private var previousDiagnosticOperationContext: TextInputDiagnosticContext?
    private var lastKeyboardDispatch: UInt64?
    private var lastAXWriteStatus: Int32?
    private var lastAXWriteKind = "none"

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
        diagnostics.removeAll(keepingCapacity: true)
        droppedDiagnosticCount = 0
        diagnosticOperationContext = nil
        previousDiagnosticOperationContext = nil
        lastKeyboardDispatch = nil
        lastAXWriteStatus = nil
        lastAXWriteKind = "none"
        try requestInputPermissionsIfNeeded()
        targetElement = nil
        targetProcessID = nil
        targetApplicationProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        expectedKeyboardSelection = nil
        let targetApplication = currentApplication()

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
        // back to append-only mode. The keyboard append path uses the caret at
        // capture time and never rewrites the document prefix afterwards.
        let text = element.flatMap { readableText(in: $0) } ?? ""
        let readableKeyboardSelection = element.flatMap { readableSelection(in: $0) }
        let selection = readableKeyboardSelection
            ?? TextRange(location: text.utf16.count, length: 0)
        let hasReadableAXTextState = element.map {
            readableText(in: $0) != nil && readableSelection(in: $0) != nil
        } ?? false
        let role = element.flatMap {
            (try? attribute(kAXRoleAttribute, from: $0) as? String)
        } ?? "unknown"
        let selectedAttributeSettable = element.map { selectedTextIsSettable(on: $0) } ?? false
        let valueAttributeSettable = element.map { valueIsSettable(on: $0) } ?? false
        expectedKeyboardSelection = readableKeyboardSelection
        recordDiagnostic("input_target_captured", [
            "hasElement": String(element != nil), "hasReadableState": String(hasReadableAXTextState),
            "role": role,
            "selectedSettable": String(selectedAttributeSettable),
            "valueSettable": String(valueAttributeSettable),
            "valueReadable": String(element.map { readableText(in: $0) != nil } ?? false),
            "selectionReadable": String(readableKeyboardSelection != nil),
            "documentLength": String(text.utf16.count), "selectionLocation": String(selection.location),
            "selectionLength": String(selection.length),
            "keyboardCompatibility": String(targetApplication?.bundleIdentifier == "com.openai.codex"),
            "targetApplicationProcessID": targetApplicationProcessID.map(String.init) ?? "unknown",
            "targetElementProcessID": targetProcessID.map(String.init) ?? "unknown",
            "frontmostApplicationProcessID": targetApplicationProcessID.map(String.init) ?? "unknown",
            "frontmostApplicationMatchesTarget": "true",
            "elementProcessMatchesTarget": String(targetProcessID == targetApplicationProcessID)
        ])
        return TextSnapshot(
            element: element,
            text: text,
            selection: selection,
            supportsAXReplacement: hasReadableAXTextState && (element.map {
                selectedTextIsSettable(on: $0) || valueIsSettable(on: $0)
            } ?? false),
            targetApplication: targetApplication
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
        let plannedSelection = expectedKeyboardSelection
        let stats = try keyboardEventSender.send(text, processID: eventProcessID)
        lastKeyboardDispatch = DispatchTime.now().uptimeNanoseconds
        recordDiagnostic("keyboard_dispatch", [
            "dispatchKind": "append",
            "plannedSelectionLocation": plannedSelection.map { String($0.location) } ?? "unknown",
            "plannedSelectionLength": plannedSelection.map { String($0.length) } ?? "unknown",
            "targetProcessID": eventProcessID.map(String.init) ?? "unknown",
            "localDispatchCompleted": "true",
            "targetCompletionConfirmed": "false",
            "postToPidAcknowledgement": "false",
            "plannedKeyboardEventCount": String(stats.plannedKeyboardEventCount),
            "postedKeyboardEventCount": String(stats.postedKeyboardEventCount),
            "unicodeBlockCount": String(stats.unicodeBlockCount),
            "shiftKeyEventCount": String(stats.shiftKeyEventCount),
            "unicodeKeyEventCount": String(stats.unicodeKeyEventCount),
            "deleteKeyEventCount": String(stats.deleteKeyEventCount),
            "shiftActiveDuringReplacement": String(stats.shiftActiveDuringReplacement)
        ])
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
        let stats = try keyboardEventSender.replaceTrailingText(
            previousText,
            with: text,
            processID: eventProcessID
        )
        lastKeyboardDispatch = DispatchTime.now().uptimeNanoseconds
        recordDiagnostic("keyboard_dispatch", [
            "dispatchKind": "tail_replacement",
            "plannedSelectionLocation": expectedKeyboardSelection.map { String($0.location) } ?? "unknown",
            "plannedSelectionLength": String(previousText.utf16.count),
            "targetProcessID": eventProcessID.map(String.init) ?? "unknown",
            "localDispatchCompleted": "true",
            "targetCompletionConfirmed": "false",
            "postToPidAcknowledgement": "false",
            "plannedKeyboardEventCount": String(stats.plannedKeyboardEventCount),
            "postedKeyboardEventCount": String(stats.postedKeyboardEventCount),
            "unicodeBlockCount": String(stats.unicodeBlockCount),
            "shiftKeyEventCount": String(stats.shiftKeyEventCount),
            "unicodeKeyEventCount": String(stats.unicodeKeyEventCount),
            "deleteKeyEventCount": String(stats.deleteKeyEventCount),
            "shiftActiveDuringReplacement": String(stats.shiftActiveDuringReplacement)
        ])
        expectedKeyboardSelection = updatedSelection
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
            recordDiagnostic("keyboard_focus_changed", [
                "elementSame": "false",
                "targetApplicationMatches": "true"
            ])
            throw TextTargetError.targetChanged
        }
        if let expectedKeyboardSelection {
            let actualSelection = readableSelection(in: currentElement)
            let age = lastKeyboardDispatch.map {
                Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000
            } ?? -1
            let baseFields = [
                "expectedLocation": String(expectedKeyboardSelection.location),
                "expectedLength": String(expectedKeyboardSelection.length),
                "initialLocation": String(actualSelection?.location ?? -1),
                "initialLength": String(actualSelection?.length ?? -1),
                "actualLocation": String(actualSelection?.location ?? -1),
                "actualLength": String(actualSelection?.length ?? -1),
                "lastDispatchAgeMilliseconds": String(age),
                "waitBudgetMilliseconds": "150",
                "waitQualificationMaxAgeMilliseconds": "250",
                "polls": "0",
                "waitMilliseconds": "0",
                "selectedRangeNonEmpty": String((actualSelection?.length ?? 0) > 0),
                "elementSame": "true",
                "targetApplicationMatches": "true"
            ]
            if actualSelection == expectedKeyboardSelection {
                recordDiagnostic(
                    "keyboard_caret_observed",
                    baseFields.merging([
                        "waitClassification": "matched_without_wait",
                        "feedbackObservedMonotonicMilliseconds": String(
                            TextInputDiagnosticClock.milliseconds()
                        )
                    ]) { _, new in new },
                    context: previousDiagnosticOperationContext ?? diagnosticOperationContext
                )
            } else if age < 0 || age > 250 {
                recordDiagnostic(
                    "keyboard_wait_skipped",
                    baseFields.merging([
                        "waitClassification": "wait_skipped",
                        "waitSkippedReason": age < 0 ? "no_recent_dispatch" : "dispatch_age_exceeded",
                        "feedbackObservedMonotonicMilliseconds": String(
                            TextInputDiagnosticClock.milliseconds()
                        )
                    ]) { _, new in new },
                    context: previousDiagnosticOperationContext ?? diagnosticOperationContext
                )
                throw TextTargetError.targetChanged
            } else {
                let result = try KeyboardCaretSynchronizer.wait(
                    expected: expectedKeyboardSelection, initial: actualSelection,
                    canWait: true
                ) {
                    try self.ensureTargetApplicationIsFrontmost()
                    let focused = try self.focusedElement()
                    guard CFEqual(focused, targetElement) else {
                        self.recordDiagnostic("keyboard_focus_changed", ["elementSame": "false"])
                        throw TextTargetError.targetChanged
                    }
                    return self.readableSelection(in: focused)
                }
                let recovered = result.selection == expectedKeyboardSelection
                recordDiagnostic(
                    recovered ? "keyboard_caret_recovered" : "keyboard_wait_timeout",
                    baseFields.merging([
                        "waitClassification": recovered ? "recovered_after_wait" : "wait_timeout",
                        "actualLocation": String(result.selection?.location ?? -1),
                        "actualLength": String(result.selection?.length ?? -1),
                        "polls": String(result.polls),
                        "waitMilliseconds": String(result.elapsedMilliseconds),
                        "feedbackObservedMonotonicMilliseconds": String(
                            TextInputDiagnosticClock.milliseconds()
                        )
                    ]) { _, new in new },
                    context: previousDiagnosticOperationContext ?? diagnosticOperationContext
                )
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

private struct KeyboardDispatchStats {
    var plannedKeyboardEventCount = 0
    var postedKeyboardEventCount = 0
    var unicodeBlockCount = 0
    var shiftKeyEventCount = 0
    var unicodeKeyEventCount = 0
    var deleteKeyEventCount = 0
    var shiftActiveDuringReplacement = false
}

private final class KeyboardEventSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.tencent.voice.mvp.keyboard-events")
    private let leftArrowKeyCode: CGKeyCode = 123
    private let deleteKeyCode: CGKeyCode = 51

    func send(_ text: String, processID: pid_t?) throws -> KeyboardDispatchStats {
        try queue.sync {
            var stats = KeyboardDispatchStats()
            try sendText(text, processID: processID, stats: &stats)
            return stats
        }
    }

    func replaceTrailingText(
        _ previousText: String,
        with text: String,
        processID: pid_t?
    ) throws -> KeyboardDispatchStats {
        try queue.sync {
            var stats = KeyboardDispatchStats()
            guard !previousText.isEmpty else {
                try sendText(text, processID: processID, stats: &stats)
                return stats
            }
            guard let source = CGEventSource(stateID: .privateState) else {
                throw TextTargetError.writeFailed
            }
            stats.shiftActiveDuringReplacement = true
            for _ in previousText {
                try sendKey(
                    keyCode: leftArrowKeyCode,
                    flags: .maskShift,
                    source: source,
                    processID: processID,
                    stats: &stats
                )
            }
            if text.isEmpty {
                try sendKey(
                    keyCode: deleteKeyCode,
                    source: source,
                    processID: processID,
                    stats: &stats
                )
            } else {
                try sendText(text, processID: processID, stats: &stats)
            }
            return stats
        }
    }

    private func sendText(
        _ text: String,
        processID: pid_t?,
        stats: inout KeyboardDispatchStats
    ) throws {
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
            stats.unicodeBlockCount += 1
            stats.unicodeKeyEventCount += 2
            stats.plannedKeyboardEventCount += 2
            post(keyDown, processID: processID, stats: &stats)
            post(keyUp, processID: processID, stats: &stats)
            start = end
        }
    }

    private func sendKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        source: CGEventSource,
        processID: pid_t?,
        stats: inout KeyboardDispatchStats
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
        stats.plannedKeyboardEventCount += 2
        if flags.contains(.maskShift) {
            stats.shiftKeyEventCount += 2
        } else if keyCode == deleteKeyCode {
            stats.deleteKeyEventCount += 2
        }
        post(keyDown, processID: processID, stats: &stats)
        post(keyUp, processID: processID, stats: &stats)
    }

    private func post(
        _ event: CGEvent,
        processID: pid_t?,
        stats: inout KeyboardDispatchStats
    ) {
        stats.postedKeyboardEventCount += 1
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
