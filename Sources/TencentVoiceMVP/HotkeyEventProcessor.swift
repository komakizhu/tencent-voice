import Carbon.HIToolbox
import CoreGraphics

enum HotkeyEventAction: Equatable {
    case pass
    case consume
    case press
    case release
}

struct HotkeyEventProcessor {
    private(set) var shortcut: Shortcut
    private(set) var isPressed = false
    private var pressedKeyCode: UInt32?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        pressedKeyCode = nil
    }

    mutating func update(shortcut: Shortcut) {
        self.shortcut = shortcut
        reset()
    }

    mutating func reset() {
        isPressed = false
        pressedKeyCode = nil
    }

    mutating func process(
        type: CGEventType,
        keyCode: UInt32,
        flags: CGEventFlags
    ) -> HotkeyEventAction {
        switch type {
        case .keyDown:
            guard keyCode == shortcut.keyCode else {
                return .pass
            }

            // Once the matching key is down, consume repeat events even if
            // the system changes the modifier flags between deliveries.
            if isPressed, pressedKeyCode == keyCode {
                return .consume
            }

            guard Self.carbonModifiers(from: flags) == shortcut.modifiers else {
                return .pass
            }

            isPressed = true
            pressedKeyCode = keyCode
            return .press

        case .keyUp:
            // Key-up events do not reliably retain the modifier flags. The
            // recorded press is the source of truth for releasing the toggle.
            guard isPressed, pressedKeyCode == keyCode else {
                return .pass
            }

            isPressed = false
            pressedKeyCode = nil
            return .release

        default:
            return .pass
        }
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }
}
