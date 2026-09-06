import Carbon.HIToolbox
import AppKit
import CoreGraphics
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

private final class HotkeyEventTapContext: @unchecked Sendable {
    private let lock = NSLock()
    private var processor: HotkeyEventProcessor
    private var onPress: (@Sendable () -> Void)?
    private var onRelease: (@Sendable () -> Void)?
    private var tap: CFMachPort?

    init(
        shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) {
        processor = HotkeyEventProcessor(shortcut: shortcut)
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func attach(tap: CFMachPort) {
        lock.lock()
        self.tap = tap
        lock.unlock()
    }

    func update(
        shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        processor.update(shortcut: shortcut)
        self.onPress = onPress
        self.onRelease = onRelease
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let tap = self.tap
        self.tap = nil
        processor.reset()
        onPress = nil
        onRelease = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableTap()
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let result: (HotkeyEventAction, (@Sendable () -> Void)?) = {
            lock.lock()
            let action = processor.process(type: type, keyCode: keyCode, flags: event.flags)
            let callback: (@Sendable () -> Void)?
            switch action {
            case .press:
                callback = onPress
            case .release:
                callback = onRelease
            case .pass, .consume:
                callback = nil
            }
            lock.unlock()
            return (action, callback)
        }()

        switch result.0 {
        case .press, .release:
            result.1?()
            return nil
        case .consume:
            return nil
        case .pass:
            return Unmanaged.passUnretained(event)
        }
    }

    private func reenableTap() {
        lock.lock()
        let tap = self.tap
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

private final class ActiveHotkeyEventTap {
    private let context: HotkeyEventTapContext
    private let tap: CFMachPort
    private let runLoopSource: CFRunLoopSource

    init(
        shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) throws {
        let context = HotkeyEventTapContext(
            shortcut: shortcut,
            onPress: onPress,
            onRelease: onRelease
        )
        let eventMask =
            (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)) |
            (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))

        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            throw EventTapCreationError.unavailable
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        ) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            throw EventTapCreationError.unavailable
        }

        self.context = context
        self.tap = tap
        self.runLoopSource = runLoopSource
        context.attach(tap: tap)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }

    func update(
        shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) {
        context.update(shortcut: shortcut, onPress: onPress, onRelease: onRelease)
    }

    func invalidate() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        context.invalidate()
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged<HotkeyEventTapContext>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return context.handle(type: type, event: event)
    }
}

private enum EventTapCreationError: Error {
    case unavailable
}

@MainActor
final class CarbonHotkeyManager: HotkeyManaging {
    private static let hotKeyID = EventHotKeyID(signature: OSType(0x54564D50), id: 1)
    private var hotKeyRef: EventHotKeyRef?
    private var globalMonitor: Any?
    private var eventTap: ActiveHotkeyEventTap?
    private var eventHandler: EventHandlerRef?
    private var isPressed = false
    private var activeShortcut: Shortcut?
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

        if activeShortcut == shortcut,
           eventTap != nil || hotKeyRef != nil || globalMonitor != nil {
            self.onPress = onPress
            self.onRelease = onRelease
            eventTap?.update(shortcut: shortcut, onPress: onPress, onRelease: onRelease)
            return
        }

        // The active tap runs before the frontmost application and can return
        // nil for the registered key events, preventing menu shortcuts from
        // seeing them. It is deliberately attempted for every registration.
        if let newEventTap = try? ActiveHotkeyEventTap(
            shortcut: shortcut,
            onPress: onPress,
            onRelease: onRelease
        ) {
            replaceBackend(
                eventTap: newEventTap,
                shortcut: shortcut,
                onPress: onPress,
                onRelease: onRelease
            )
            return
        }

        var carbonStatus: OSStatus = OSStatus(eventNotHandledErr)
        if (try? installEventHandlerIfNeeded()) != nil {
            var newRef: EventHotKeyRef?
            carbonStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                Self.hotKeyID,
                GetApplicationEventTarget(),
                UInt32(kEventHotKeyExclusive),
                &newRef
            )
            if carbonStatus == noErr, let newRef {
                replaceBackend(
                    hotKeyRef: newRef,
                    shortcut: shortcut,
                    onPress: onPress,
                    onRelease: onRelease
                )
                return
            }
        }

        guard let monitor = makeGlobalMonitor(for: shortcut) else {
            if hotKeyRef == nil {
                removeEventHandlerIfNeeded()
            }
            throw HotkeyError.hotkeyUnavailable(carbonStatus)
        }
        replaceBackend(
            globalMonitor: monitor,
            shortcut: shortcut,
            onPress: onPress,
            onRelease: onRelease
        )
    }

    func unregister() {
        let oldHotKeyRef = hotKeyRef
        let oldGlobalMonitor = globalMonitor
        let oldEventTap = eventTap

        hotKeyRef = nil
        globalMonitor = nil
        eventTap = nil
        activeShortcut = nil
        onPress = nil
        onRelease = nil
        isPressed = false

        if let oldHotKeyRef {
            UnregisterEventHotKey(oldHotKeyRef)
        }
        if let oldGlobalMonitor {
            NSEvent.removeMonitor(oldGlobalMonitor)
        }
        oldEventTap?.invalidate()
        removeEventHandlerIfNeeded()
    }

    private func replaceBackend(
        eventTap newEventTap: ActiveHotkeyEventTap? = nil,
        hotKeyRef newHotKeyRef: EventHotKeyRef? = nil,
        globalMonitor newGlobalMonitor: Any? = nil,
        shortcut: Shortcut,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) {
        let oldHotKeyRef = hotKeyRef
        let oldGlobalMonitor = globalMonitor
        let oldEventTap = eventTap

        hotKeyRef = newHotKeyRef
        globalMonitor = newGlobalMonitor
        eventTap = newEventTap
        activeShortcut = shortcut
        self.onPress = onPress
        self.onRelease = onRelease
        isPressed = false

        if let oldHotKeyRef {
            UnregisterEventHotKey(oldHotKeyRef)
        }
        if let oldGlobalMonitor {
            NSEvent.removeMonitor(oldGlobalMonitor)
        }
        oldEventTap?.invalidate()

        if newHotKeyRef == nil {
            removeEventHandlerIfNeeded()
        }
    }

    private func makeGlobalMonitor(for shortcut: Shortcut) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard Self.eventMatches(event, shortcut: shortcut) else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeShortcut == shortcut,
                      self.eventTap == nil,
                      self.hotKeyRef == nil,
                      self.globalMonitor != nil else {
                    return
                }

                switch event.type {
                case .keyDown:
                    guard !self.isPressed else { return }
                    self.isPressed = true
                    self.onPress?()
                case .keyUp:
                    guard self.isPressed else { return }
                    self.isPressed = false
                    self.onRelease?()
                default:
                    break
                }
            }
        }
    }

    private nonisolated static func eventMatches(_ event: NSEvent, shortcut: Shortcut) -> Bool {
        guard UInt32(event.keyCode) == shortcut.keyCode else { return false }
        if event.type == .keyUp {
            return true
        }

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

    private func removeEventHandlerIfNeeded() {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
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
