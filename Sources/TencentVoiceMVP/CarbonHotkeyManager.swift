import Carbon.HIToolbox
import AppKit
import Foundation

@MainActor
protocol HotkeyManaging: AnyObject {
    func register(
        _ shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) throws
    func unregister()
}

enum HotkeyError: Error, LocalizedError {
    case invalidShortcut
    case hotkeyUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidShortcut: return "这个快捷键不能使用"
        case let .hotkeyUnavailable(status): return "快捷键注册失败（\(status)）"
        }
    }
}

@MainActor
final class CarbonHotkeyManager: HotkeyManaging {
    private static let hotKeyID = EventHotKeyID(signature: OSType(0x54564D50), id: 1)
    private var hotKeyRef: EventHotKeyRef?
    private var globalMonitor: Any?
    private var eventHandler: EventHandlerRef?
    private var isPressed = false
    private var globalShortcut: Shortcut?
    private var onPress: (@Sendable () -> Void)?
    private var onRelease: (@Sendable () -> Void)?

    func register(
        _ shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) throws {
        guard ShortcutValidator.isAllowed(shortcut) else {
            throw HotkeyError.invalidShortcut
        }

        try installEventHandlerIfNeeded()
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        if status == noErr, let newRef {
            if let oldRef = hotKeyRef {
                UnregisterEventHotKey(oldRef)
            }
            removeGlobalMonitor()
            hotKeyRef = newRef
            globalShortcut = nil
            self.onPress = onPress
            self.onRelease = onRelease
            isPressed = false
            return
        }

        guard let monitor = makeGlobalMonitor(for: shortcut, onPress: onPress, onRelease: onRelease) else {
            throw HotkeyError.hotkeyUnavailable(status)
        }
        if let oldRef = hotKeyRef {
            UnregisterEventHotKey(oldRef)
        }
        removeGlobalMonitor()
        hotKeyRef = nil
        globalMonitor = monitor
        globalShortcut = shortcut
        self.onPress = onPress
        self.onRelease = onRelease
        isPressed = false
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        removeGlobalMonitor()
        globalShortcut = nil
        onPress = nil
        onRelease = nil
        isPressed = false
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    private func makeGlobalMonitor(
        for shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard Self.eventMatches(event, shortcut: shortcut) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event.type {
                case .keyDown:
                    guard !self.isPressed else { return }
                    self.isPressed = true
                    onPress()
                case .keyUp:
                    guard self.isPressed else { return }
                    self.isPressed = false
                    onRelease()
                default:
                    break
                }
            }
        }
    }

    private func removeGlobalMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
    }

    private nonisolated static func eventMatches(_ event: NSEvent, shortcut: Shortcut) -> Bool {
        guard UInt32(event.keyCode) == shortcut.keyCode else { return false }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers == shortcut.modifiers
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<CarbonHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handle(event)
            },
            specs.count,
            &specs,
            userData,
            &eventHandler
        )
        guard status == noErr else { throw HotkeyError.hotkeyUnavailable(status) }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var eventHotKeyID = EventHotKeyID(signature: 0, id: 0)
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventHotKeyID
        )
        guard parameterStatus == noErr,
              eventHotKeyID.signature == Self.hotKeyID.signature,
              eventHotKeyID.id == Self.hotKeyID.id else {
            return OSStatus(eventNotHandledErr)
        }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else { return noErr }
            isPressed = true
            onPress?()
        case UInt32(kEventHotKeyReleased):
            guard isPressed else { return noErr }
            isPressed = false
            onRelease?()
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
