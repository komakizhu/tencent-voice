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
    private(set) var latestFailure: InputContextWindow?
    private(set) var startedAt: Date?
    private var dropped: [Date] = []
    let capacity: Int

    init(capacity: Int = 2000) { self.capacity = max(1, capacity) }

    mutating func start(at date: Date) {
        events = []
        latestFailure = nil
        dropped = []
        startedAt = date
    }

    mutating func stop() {
        events = []
        latestFailure = nil
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

    mutating func freezeFailure(at date: Date) {
        guard startedAt != nil else { return }
        latestFailure = snapshot(at: date)
        latestFailure?.collectionStatus["failureProbeStatus"] = "pending"
    }

    mutating func appendFailureProbe(_ event: InputContextEvent, failureAt: Date) {
        guard let window = latestFailure, window.capturedAt == failureAt else { return }
        latestFailure = InputContextWindow(requestedStart: window.requestedStart,
            recordingStartedAt: window.recordingStartedAt, capturedAt: window.capturedAt,
            enabled: window.enabled, droppedEventCount: window.droppedEventCount,
            events: window.events + [event], collectionStatus: window.collectionStatus)
        latestFailure?.collectionStatus["failureProbeStatus"] = "completed"
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
    private var latestFailureDiagnostics: [SessionLogEntry] = []
    private var latestFailureDiagnosticsTruncated = false
    private var lastOperationProbe: Date = .distantPast

    var latestFailure: InputFailureEvidence? {
        guard let context = buffer.latestFailure else { return nil }
        return InputFailureEvidence(desktopContext: context, diagnosticEvents: latestFailureDiagnostics,
            diagnosticEventsTruncated: latestFailureDiagnosticsTruncated)
    }

    func observeTarget(_ diagnostic: TextInputDiagnostic, element: AXUIElement?, pid: pid_t?, logger: SessionLogger) {
        guard isEnabled else { return }
        let failure = diagnostic.event == "keyboard_write_unconfirmed"
        let capture = diagnostic.event == "input_target_captured"
        let dispatch = diagnostic.event == "keyboard_write_submitted"
        let acknowledged = diagnostic.event == "keyboard_write_acknowledged"
        guard failure || capture || dispatch || acknowledged else { return }
        let now = diagnostic.timestamp
        if failure {
            record(diagnostic.event, fields: DiagnosticLogSanitizer.fields(diagnostic.fields), at: now)
            buffer.freezeFailure(at: now)
            latestFailureDiagnostics = logger.failureEvents(at: now)
            latestFailureDiagnosticsTruncated = logger.failureContextEventsTruncated
        }
        guard failure || capture || now.timeIntervalSince(lastOperationProbe) >= 1 else { return }
        lastOperationProbe = now
        guard let pid else { return }
        let reference = InputContextElementReference(element: element)
        let token = generation
        let probe = self.probe
        let queue = probeQueue
        Task { @MainActor [weak self] in
            let details = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: probe.sample(pid: pid, target: reference.element, includeEditors: true)) }
            }
            guard let self, self.isEnabled, self.generation == token else { return }
            var fields = DiagnosticLogSanitizer.fields(diagnostic.fields)
            fields.merge(details) { _, new in new }
            fields["phase"] = diagnostic.event
            fields["pid"] = String(pid)
            fields["requestedAt"] = now.ISO8601Format()
            fields["frontmostPIDAtCompletion"] = String(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
            let event = InputContextEvent(timestamp: Date(), event: "input_editor_probe", fields: fields)
            self.buffer.append(event, now: event.timestamp)
            if failure { self.buffer.appendFailureProbe(event, failureAt: now) }
        }
    }

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
        latestFailureDiagnostics = []
        latestFailureDiagnosticsTruncated = false
        lastOperationProbe = .distantPast
    }

    func snapshot(at date: Date) -> InputContextWindow {
        var window = buffer.snapshot(at: date)
        window.collectionStatus = ["globalMonitorInstalled": String(globalMonitor != nil),
            "accessibilityGranted": String(AXIsProcessTrusted()), "secureInputActive": String(IsSecureEventInputEnabled()),
            "focusPollingIntervalMilliseconds": "500", "typedCharactersRecorded": "false", "screenshotsRecorded": "false", "latestFailureRetained": String(buffer.latestFailure != nil),
            "editorProbeNodeLimit": "160", "editorProbeDepthLimit": "64",
            "editorProbeTraversal": "reverse_depth_first", "editorProbeBudgetMilliseconds": "250"]
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
            guard ["com.openai.codex", "com.apple.Safari", "md.obsidian"].contains(app?.bundleIdentifier ?? ""),
                  !event.isARepeat, !IsSecureEventInputEnabled() else { return }
            if let shortcut = InputContextKeyFilter.shortcut(keyCode: event.keyCode, flags: event.modifierFlags) {
                fields["shortcut"] = shortcut
                record(app?.bundleIdentifier == "com.openai.codex" ? "codex_shortcut" : "application_shortcut", fields: fields, at: now)
            } else if now.timeIntervalSince(lastActivity) >= 1 {
                lastActivity = now
                record(app?.bundleIdentifier == "com.openai.codex" ? "codex_keyboard_activity" : "application_keyboard_activity", fields: fields, at: now)
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
                probeQueue.async { continuation.resume(returning: probe.sample(pid: pid, includeEditors: true)) }
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

struct InputFailureEvidence: Codable, Sendable {
    let desktopContext: InputContextWindow
    let diagnosticEvents: [SessionLogEntry]
    let diagnosticEventsTruncated: Bool
}

struct InputFailureReport: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let generatedAt: Date
    let desktopContext: InputContextWindow
    let diagnosticReport: DiagnosticReport
    let diagnosticEventsTruncated: Bool
    var latestFailure: InputFailureEvidence? = nil
}
