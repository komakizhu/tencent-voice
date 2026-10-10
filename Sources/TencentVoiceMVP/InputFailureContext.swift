import AppKit
import ApplicationServices
import Carbon
import Foundation

struct InputContextEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let event: String
    let fields: [String: String]
}

struct InputContextWindow: Codable, Sendable {
    let requestedStart: Date
    let recordingStartedAt: Date?
    let capturedAt: Date
    let enabled: Bool
    let droppedEventCount: Int
    let events: [InputContextEvent]
    var collectionStatus: [String: String] = [:]
}

// The buffer never stores ordinary key codes, typed characters, titles or AXValue.
struct InputContextBuffer {
    private(set) var events: [InputContextEvent] = []
    private(set) var startedAt: Date?
    private var dropped: [Date] = []
    let capacity: Int

    init(capacity: Int = 2000) { self.capacity = max(1, capacity) }

    mutating func start(at date: Date) {
        events = []
        dropped = []
        startedAt = date
    }

    mutating func stop() {
        events = []
        dropped = []
        startedAt = nil
    }

    mutating func append(_ event: InputContextEvent, now: Date) {
        guard startedAt != nil else { return }
        prune(at: now)
        guard event.timestamp >= now.addingTimeInterval(-60) else { return }
        events.append(event)
        if events.count > capacity {
            dropped.append(contentsOf: events.prefix(events.count - capacity).map(\.timestamp))
            events.removeFirst(events.count - capacity)
        }
    }

    mutating func snapshot(at now: Date) -> InputContextWindow {
        prune(at: now)
        return InputContextWindow(requestedStart: now.addingTimeInterval(-60),
            recordingStartedAt: startedAt, capturedAt: now, enabled: startedAt != nil,
            droppedEventCount: dropped.count, events: events.filter { $0.timestamp <= now })
    }

    private mutating func prune(at now: Date) {
        let start = now.addingTimeInterval(-60)
        events.removeAll { $0.timestamp < start }
        dropped.removeAll { $0 < start }
    }
}

enum InputContextKeyFilter {
    static func shortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        // Known navigation/clipboard shortcuts only. No arbitrary modified typing.
        guard flags.contains(.command) else { return nil }
        let keys: [UInt16: String] = [0: "A", 8: "C", 9: "V", 13: "W", 45: "N", 48: "Tab", 33: "[", 30: "]", 50: "`"]
        guard let key = keys[keyCode] else { return nil }
        let modifiers = [(NSEvent.ModifierFlags.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
        return (modifiers.compactMap { flags.contains($0.0) ? $0.1 : nil } + [key]).joined(separator: "+")
    }
}

// AX queries run on a separate serial queue, never in the input event handler.
private final class InputContextAXProbe: @unchecked Sendable {
    private var previousFocus: AXUIElement?
    private var previousWindow: AXUIElement?
    private var focusID = 0
    private var windowID = 0

    func sample(pid: pid_t) -> [String: String] {
        guard AXIsProcessTrusted() else { return ["axAvailable": "false"] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var result = ["axAvailable": "true"]
        if let window = element("AXFocusedWindow", in: app) {
            if previousWindow.map({ CFEqual($0, window) }) != true {
                windowID += 1
                previousWindow = window
            }
            result["windowID"] = String(windowID)
        }
        guard let focus = element("AXFocusedUIElement", in: app) else {
            result["focusAvailable"] = "false"
            return result
        }
        AXUIElementSetMessagingTimeout(focus, 0.1)
        if previousFocus.map({ CFEqual($0, focus) }) != true {
            focusID += 1
            previousFocus = focus
        }
        result["focusID"] = String(focusID)
        result["focusAvailable"] = "true"
        result["role"] = attribute("AXRole", in: focus) as? String
        result["subrole"] = attribute("AXSubrole", in: focus) as? String
        var owner: pid_t = 0
        if AXUIElementGetPid(focus, &owner) == .success { result["focusOwnerPID"] = String(owner) }
        if result["subrole"] != "AXSecureTextField" {
            if let value = attribute("AXSelectedTextRange", in: focus), CFGetTypeID(value) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) {
                    result["selectionLocation"] = String(range.location)
                    result["selectionLength"] = String(range.length)
                }
            }
            if let count = attribute("AXNumberOfCharacters", in: focus) as? NSNumber {
                result["documentLength"] = count.stringValue
            }
        }
        return result
    }

    private func attribute(_ name: String, in element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ name: String, in node: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, in: node), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

@MainActor
final class InputFailureContextRecorder {
    private(set) var isEnabled = false
    private var buffer = InputContextBuffer()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var sampleTask: Task<Void, Never>?
    private var applicationObserver: NSObjectProtocol?
    private let probeQueue = DispatchQueue(label: "local.tencent.voice.mvp.failure-context", qos: .utility)
    private let probe = InputContextAXProbe()
    private var previousSample: [String: String]?
    private var lastActivity: Date = .distantPast
    private var generation = 0

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        stop()
        guard enabled else { return }
        isEnabled = true
        buffer.start(at: Date())
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event)
            return event
        }
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let fields = ["application": app?.bundleIdentifier ?? "unknown", "pid": String(app?.processIdentifier ?? 0)]
            let date = Date()
            Task { @MainActor [weak self] in
                self?.record("application_activated", fields: fields, at: date)
            }
        }
        record("recording_started", fields: ["globalMonitorInstalled": String(globalMonitor != nil),
            "accessibilityGranted": String(AXIsProcessTrusted()), "pollIntervalMilliseconds": "500"])
        sampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        sampleTask?.cancel()
        sampleTask = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver) }
        applicationObserver = nil
        isEnabled = false
        previousSample = nil
        lastActivity = .distantPast
        buffer.stop()
    }

    func snapshot(at date: Date) -> InputContextWindow {
        var window = buffer.snapshot(at: date)
        window.collectionStatus = ["globalMonitorInstalled": String(globalMonitor != nil),
            "accessibilityGranted": String(AXIsProcessTrusted()), "secureInputActive": String(IsSecureEventInputEnabled()),
            "focusPollingIntervalMilliseconds": "500", "typedCharactersRecorded": "false", "screenshotsRecorded": "false"]
        return window
    }

    private func record(_ name: String, fields: [String: String], at date: Date = Date()) {
        buffer.append(InputContextEvent(timestamp: date, event: name, fields: fields), now: date)
    }

    private func observe(_ event: NSEvent) {
        guard isEnabled else { return }
        // Do not confuse our injected Unicode events with the user's actions.
        if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier) { return }
        let now = Date()
        let app = NSWorkspace.shared.frontmostApplication
        var fields = ["application": app?.bundleIdentifier ?? "unknown", "pid": String(app?.processIdentifier ?? 0)]
        if event.type == .keyDown {
            guard app?.bundleIdentifier == "com.openai.codex", !event.isARepeat, !IsSecureEventInputEnabled() else { return }
            if let shortcut = InputContextKeyFilter.shortcut(keyCode: event.keyCode, flags: event.modifierFlags) {
                fields["shortcut"] = shortcut
                record("codex_shortcut", fields: fields, at: now)
            } else if now.timeIntervalSince(lastActivity) >= 1 {
                lastActivity = now
                record("codex_keyboard_activity", fields: fields, at: now)
            }
        } else if event.type == .scrollWheel {
            guard now.timeIntervalSince(lastActivity) >= 1 else { return }
            lastActivity = now
            record("desktop_scroll", fields: fields, at: now)
        } else {
            fields["button"] = String(event.buttonNumber)
            if let point = event.cgEvent?.location {
                fields["screenX"] = String(Int(point.x.rounded()))
                fields["screenY"] = String(Int(point.y.rounded()))
            }
            record("desktop_click", fields: fields, at: now)
        }
    }

    private func sample() async {
        guard isEnabled else { return }
        let token = generation
        let now = Date()
        let app = NSWorkspace.shared.frontmostApplication
        var fields = ["application": app?.bundleIdentifier ?? "unknown", "pid": String(app?.processIdentifier ?? 0),
            "accessibilityGranted": String(AXIsProcessTrusted())]
        if app?.bundleIdentifier == "com.openai.codex", let pid = app?.processIdentifier {
            let probe = self.probe
            let details = await withCheckedContinuation { continuation in
                probeQueue.async { continuation.resume(returning: probe.sample(pid: pid)) }
            }
            guard isEnabled, generation == token else { return }
            // Do not attribute a slow AX result to an app that is no longer active.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            fields.merge(details) { _, new in new }
        }
        guard generation == token, isEnabled else { return }
        if previousSample != fields {
            previousSample = fields
            record("desktop_focus", fields: fields, at: now)
        }
    }
}

struct InputFailureReport: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let generatedAt: Date
    let desktopContext: InputContextWindow
    let diagnosticReport: DiagnosticReport
    let diagnosticEventsTruncated: Bool
}
