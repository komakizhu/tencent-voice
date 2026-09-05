import AppKit
import Carbon.HIToolbox
import Foundation

struct Shortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultCommand0 = Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey))
    static let defaultF5 = Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0)
}

enum ShortcutValidator {
    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5),
        UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10),
        UInt32(kVK_F11), UInt32(kVK_F12), UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15),
        UInt32(kVK_F16), UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
    ]

    static func isAllowed(_ shortcut: Shortcut) -> Bool {
        let isFunctionKey = functionKeyCodes.contains(shortcut.keyCode)
        let hasModifier = shortcut.modifiers != 0
        return isFunctionKey || hasModifier
    }
}

enum ShortcutFormatter {
    static func string(for shortcut: Shortcut) -> String {
        let keyName: String
        switch shortcut.keyCode {
        case UInt32(kVK_F1): keyName = "F1"
        case UInt32(kVK_F2): keyName = "F2"
        case UInt32(kVK_F3): keyName = "F3"
        case UInt32(kVK_F4): keyName = "F4"
        case UInt32(kVK_F5): keyName = "F5"
        case UInt32(kVK_F6): keyName = "F6"
        case UInt32(kVK_F7): keyName = "F7"
        case UInt32(kVK_F8): keyName = "F8"
        case UInt32(kVK_F9): keyName = "F9"
        case UInt32(kVK_F10): keyName = "F10"
        case UInt32(kVK_F11): keyName = "F11"
        case UInt32(kVK_F12): keyName = "F12"
        case UInt32(kVK_F13): keyName = "F13"
        case UInt32(kVK_F14): keyName = "F14"
        case UInt32(kVK_F15): keyName = "F15"
        case UInt32(kVK_F16): keyName = "F16"
        case UInt32(kVK_F17): keyName = "F17"
        case UInt32(kVK_F18): keyName = "F18"
        case UInt32(kVK_F19): keyName = "F19"
        case UInt32(kVK_F20): keyName = "F20"
        case UInt32(kVK_ANSI_A)...UInt32(kVK_ANSI_Z):
            keyName = String(UnicodeScalar(UInt8(shortcut.keyCode) + Character("A").asciiValue!))
        default:
            keyName = "键码 \(shortcut.keyCode)"
        }

        var prefix = ""
        if shortcut.modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if shortcut.modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyName
    }

    static func menuKeyEquivalent(for shortcut: Shortcut) -> String {
        switch shortcut.keyCode {
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        case UInt32(kVK_ANSI_A)...UInt32(kVK_ANSI_Z):
            return String(UnicodeScalar(UInt8(shortcut.keyCode) + Character("a").asciiValue!))
        case UInt32(kVK_F1): return String(UnicodeScalar(NSF1FunctionKey)!)
        case UInt32(kVK_F2): return String(UnicodeScalar(NSF2FunctionKey)!)
        case UInt32(kVK_F3): return String(UnicodeScalar(NSF3FunctionKey)!)
        case UInt32(kVK_F4): return String(UnicodeScalar(NSF4FunctionKey)!)
        case UInt32(kVK_F5): return String(UnicodeScalar(NSF5FunctionKey)!)
        case UInt32(kVK_F6): return String(UnicodeScalar(NSF6FunctionKey)!)
        case UInt32(kVK_F7): return String(UnicodeScalar(NSF7FunctionKey)!)
        case UInt32(kVK_F8): return String(UnicodeScalar(NSF8FunctionKey)!)
        case UInt32(kVK_F9): return String(UnicodeScalar(NSF9FunctionKey)!)
        case UInt32(kVK_F10): return String(UnicodeScalar(NSF10FunctionKey)!)
        case UInt32(kVK_F11): return String(UnicodeScalar(NSF11FunctionKey)!)
        case UInt32(kVK_F12): return String(UnicodeScalar(NSF12FunctionKey)!)
        case UInt32(kVK_F13): return String(UnicodeScalar(NSF13FunctionKey)!)
        case UInt32(kVK_F14): return String(UnicodeScalar(NSF14FunctionKey)!)
        case UInt32(kVK_F15): return String(UnicodeScalar(NSF15FunctionKey)!)
        case UInt32(kVK_F16): return String(UnicodeScalar(NSF16FunctionKey)!)
        case UInt32(kVK_F17): return String(UnicodeScalar(NSF17FunctionKey)!)
        case UInt32(kVK_F18): return String(UnicodeScalar(NSF18FunctionKey)!)
        case UInt32(kVK_F19): return String(UnicodeScalar(NSF19FunctionKey)!)
        case UInt32(kVK_F20): return String(UnicodeScalar(NSF20FunctionKey)!)
        default: return "键码 \(shortcut.keyCode)"
        }
    }

    static func menuModifierFlags(for shortcut: Shortcut) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if shortcut.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }
}
