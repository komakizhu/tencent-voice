import ApplicationServices
import AppKit
import Foundation

@MainActor
final class AXTextTarget: TextTarget {
    private var targetElement: AXUIElement?
    private var targetProcessID: pid_t?
    private var targetApplicationProcessID: pid_t?
    private let keyboardEventSender = KeyboardEventSender()

    func capture() throws -> TextSnapshot {
        try requestInputPermissionsIfNeeded()
        targetElement = nil
        targetProcessID = nil
        targetApplicationProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Some Electron/WebKit controls expose neither a stable AX value nor
        // a stable focused AX element while the DOM is being rebuilt. That is
        // still a valid keyboard target as long as a frontmost application is
        // known; the keyboard transaction below owns only the text it sends.
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
        // back to append-only mode. The keyboard transaction only needs the
        // caret/selection to exist at capture time; it owns the text it sends
        // afterwards and never needs to rewrite the document prefix.
        let text = element.flatMap { readableText(in: $0) } ?? ""
        let selection = element.flatMap { readableSelection(in: $0) }
            ?? TextRange(location: text.utf16.count, length: 0)
        let hasReadableAXTextState = element.map {
            readableText(in: $0) != nil && readableSelection(in: $0) != nil
        } ?? false
        return TextSnapshot(
            element: element,
            text: text,
            selection: selection,
            supportsAXReplacement: hasReadableAXTextState && (element.map {
                selectedTextIsSettable(on: $0) || valueIsSettable(on: $0)
            } ?? false)
        )
    }

    func replace(snapshot: TextSnapshot, range: TextRange, expectedText: String, with text: String) throws -> TextRange {
        guard let expectedElement = snapshot.element else { throw TextTargetError.unsupported }
        let element = try focusedElement()
        guard CFEqual(element, expectedElement) else { throw TextTargetError.targetChanged }
        guard let currentText = try attribute(kAXValueAttribute, from: element) as? String,
              currentText == expectedText,
              let currentSelectionObject = try attribute(kAXSelectedTextRangeAttribute, from: element) else {
            throw TextTargetError.targetChanged
        }
        guard let currentSelectionValue = axValue(from: currentSelectionObject) else {
            throw TextTargetError.targetChanged
        }
        guard let currentSelection = textRange(from: currentSelectionValue),
              currentSelection.location == range.location + range.length,
              range.location >= 0,
              range.length >= 0,
              range.location + range.length <= currentText.utf16.count else {
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
            guard AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                delta.insertion as CFTypeRef
            ) == .success else {
                throw TextTargetError.writeFailed
            }
        } else {
            guard valueIsSettable(on: element) else { throw TextTargetError.writeFailed }
            let document = NSMutableString(string: currentText)
            document.replaceCharacters(
                in: NSRange(location: range.location, length: range.length),
                with: text
            )
            guard AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                document.copy() as CFTypeRef
            ) == .success else {
                throw TextTargetError.writeFailed
            }
        }

        let newRange = TextRange(location: range.location, length: text.utf16.count)
        try setSelection(TextRange(location: newRange.location + newRange.length, length: 0), on: element)
        return newRange
    }

    func replacePastedText(previousText: String, with text: String) throws {
        try ensureTargetApplicationIsFrontmost()
        try keyboardEventSender.replace(
            previousText: previousText,
            with: text,
            processID: eventProcessID
        )
    }

    func paste(_ text: String) throws {
        try ensureTargetApplicationIsFrontmost()
        try keyboardEventSender.send(text, processID: eventProcessID)
    }

    func copyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextTargetError.writeFailed
        }
    }

    private func setSelection(_ range: TextRange, on element: AXUIElement) throws {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else {
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

    private func ensureTargetIsFocused() throws {
        try ensureTargetApplicationIsFrontmost()
        guard let targetElement else { return }
        let currentElement = try focusedElement()
        guard CFEqual(currentElement, targetElement) else {
            throw TextTargetError.targetChanged
        }
    }

    private func ensureTargetApplicationIsFrontmost() throws {
        guard let targetApplicationProcessID else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApplicationProcessID else {
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
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw TextTargetError.accessibilityDenied
        }
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            throw TextTargetError.postEventDenied
        }
    }

    private func attribute(_ name: String, from element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success else {
            if status == .attributeUnsupported || status == .noValue { throw TextTargetError.unsupported }
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
    private let queue = DispatchQueue(label: "local.tencent.voice.mvp.keyboard-events")

    func replace(previousText: String, with text: String, processID: pid_t?) throws {
        let delta = PastedTextDelta(previousText: previousText, newText: text)
        try queue.sync {
            try sendBackspaces(count: delta.backspaceCount, processID: processID)
            try sendText(delta.insertion, processID: processID)
        }
    }

    func send(_ text: String, processID: pid_t?) throws {
        try queue.sync {
            try sendText(text, processID: processID)
        }
    }

    private func sendBackspaces(count: Int, processID: pid_t?) throws {
        guard count > 0 else { return }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw TextTargetError.writeFailed
        }
        for _ in 0..<count {
            guard let keyDown = SyntheticKeyboardEventFactory.keyEvent(
                source: source,
                keyCode: 0x33,
                keyDown: true
            ),
                  let keyUp = SyntheticKeyboardEventFactory.keyEvent(
                    source: source,
                    keyCode: 0x33,
                    keyDown: false
                  ) else {
                throw TextTargetError.writeFailed
            }
            post(keyDown, processID: processID)
            post(keyUp, processID: processID)
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
        keyDown: Bool
    ) -> CGEvent? {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else { return nil }
        event.flags = []
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
