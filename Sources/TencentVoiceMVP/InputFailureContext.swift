import AppKit
import ApplicationServices
import Carbon
import Foundation

struct InputContextEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let event: String
    let fields: [String: String]
    var eventID: UUID? = nil
    var monotonicTimestampNanoseconds: UInt64? = nil
    var sessionID: UUID? = nil
    var operationID: Int? = nil
    var targetApplicationBundleIdentifier: String? = nil
    var targetApplicationProcessID: Int32? = nil
}

struct InputContextWindow: Codable, Sendable {
    let requestedStart: Date
    let recordingStartedAt: Date?
    let capturedAt: Date
    let enabled: Bool
    let droppedEventCount: Int
    let events: [InputContextEvent]
    var collectionStatus: [String: String] = [:]
    var droppedEventTimestamps: [Date]? = nil
    var droppedEventTimestampOverflowRange: [Date]? = nil
    var capturedAtMonotonicNanoseconds: UInt64? = nil
    var recordingStartedAtMonotonicNanoseconds: UInt64? = nil

    static func ordered(_ events: [InputContextEvent]) -> [InputContextEvent] {
        let indexed = Array(events.enumerated())
        if events.allSatisfy({ $0.monotonicTimestampNanoseconds != nil }) {
            return indexed.sorted {
                let lhs = $0.element.monotonicTimestampNanoseconds ?? 0
                let rhs = $1.element.monotonicTimestampNanoseconds ?? 0
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.map(\.element)
        }
        return indexed.sorted {
            $0.element.timestamp == $1.element.timestamp
                ? $0.offset < $1.offset
                : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
    }

    func restricted(to start: Date, through end: Date) -> Self {
        var status = collectionStatus
        status["reportWindowStart"] = DiagnosticReportTime.format(start)
        status["reportWindowEnd"] = DiagnosticReportTime.format(end)
        status["outOfWindowEventsExcluded"] = "true"
        let windowDropTimestamps = droppedEventTimestamps?.filter { $0 >= start && $0 <= end }
        let overflowRange = droppedEventTimestampOverflowRange
        let overflowIntersectsWindow: Bool = {
            guard let overflowRange, overflowRange.count == 2,
                  let earliest = overflowRange.min(), let latest = overflowRange.max() else { return false }
            return latest >= start && earliest <= end
        }()
        let windowDropCount: Int
        if let windowDropTimestamps {
            windowDropCount = windowDropTimestamps.count
            status["droppedEventCountScope"] = overflowIntersectsWindow
                ? "report_window_lower_bound_capacity_overflow"
                : "report_window"
        } else if droppedEventCount == 0 {
            windowDropCount = 0
            status["droppedEventCountScope"] = "report_window"
        } else {
            windowDropCount = droppedEventCount
            status["droppedEventCountScope"] = "legacy_recording_total_window_unknown"
        }
        return Self(
            requestedStart: max(requestedStart, start),
            recordingStartedAt: recordingStartedAt,
            capturedAt: min(capturedAt, end),
            enabled: enabled,
            droppedEventCount: windowDropCount,
            events: Self.ordered(events.filter { $0.timestamp >= start && $0.timestamp <= end }),
            collectionStatus: status,
            droppedEventTimestamps: nil,
            droppedEventTimestampOverflowRange: nil,
            capturedAtMonotonicNanoseconds: capturedAtMonotonicNanoseconds,
            recordingStartedAtMonotonicNanoseconds: recordingStartedAtMonotonicNanoseconds
        )
    }
}

// The buffer stores bounded interaction metadata. Full text is stored separately in typed session evidence.
struct InputContextBuffer {
    private(set) var events: [InputContextEvent] = []
    private(set) var latestFailure: InputContextWindow?
    private(set) var firstFailure: InputContextWindow?
    private(set) var startedAt: Date?
    private(set) var startedAtMonotonicNanoseconds: UInt64?
    private var dropped = 0
    private var eventIDs = Set<UUID>()
    private var droppedEventTimestamps: [Date] = []
    private var droppedEventTimestampHead = 0
    private var droppedEventTimestampOverflowRange: [Date]?
    private let droppedEventTimestampLimit = 200_000
    let capacity: Int

    init(capacity: Int = 2000) { self.capacity = max(1, capacity) }

    mutating func start(at date: Date) {
        events = []
        latestFailure = nil
        firstFailure = nil
        dropped = 0
        eventIDs = []
        droppedEventTimestamps = []
        droppedEventTimestampHead = 0
        droppedEventTimestampOverflowRange = nil
        startedAt = date
        startedAtMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    mutating func stop() {
        events = []
        latestFailure = nil
        firstFailure = nil
        dropped = 0
        eventIDs = []
        droppedEventTimestamps = []
        droppedEventTimestampHead = 0
        droppedEventTimestampOverflowRange = nil
        startedAt = nil
        startedAtMonotonicNanoseconds = nil
    }

    mutating func append(_ event: InputContextEvent, now: Date) {
        guard startedAt != nil else { return }
        if let eventID = event.eventID, !eventIDs.insert(eventID).inserted { return }
        events.append(event)
        if events.count > capacity {
            let overflow = events.count - capacity
            dropped += overflow
            for removedEvent in events.prefix(overflow) {
                droppedEventTimestamps.append(removedEvent.timestamp)
                if let eventID = removedEvent.eventID { eventIDs.remove(eventID) }
            }
            events.removeFirst(overflow)
            while droppedEventTimestamps.count - droppedEventTimestampHead > droppedEventTimestampLimit {
                let omittedTimestamp = droppedEventTimestamps[droppedEventTimestampHead]
                let previous = droppedEventTimestampOverflowRange ?? [omittedTimestamp, omittedTimestamp]
                droppedEventTimestampOverflowRange = [min(previous.min() ?? omittedTimestamp, omittedTimestamp), max(previous.max() ?? omittedTimestamp, omittedTimestamp)]
                droppedEventTimestampHead += 1
            }
            if droppedEventTimestampHead >= 1024 && droppedEventTimestampHead * 2 >= droppedEventTimestamps.count {
                droppedEventTimestamps.removeFirst(droppedEventTimestampHead)
                droppedEventTimestampHead = 0
            }
        }
    }

    mutating func snapshot(at now: Date) -> InputContextWindow {
        return InputContextWindow(requestedStart: startedAt ?? now,
            recordingStartedAt: startedAt, capturedAt: now, enabled: startedAt != nil,
            droppedEventCount: dropped,
            events: InputContextWindow.ordered(events.filter { $0.timestamp <= now }),
            droppedEventTimestamps: droppedEventTimestamps[droppedEventTimestampHead...].filter { $0 <= now },
            droppedEventTimestampOverflowRange: droppedEventTimestampOverflowRange,
            capturedAtMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            recordingStartedAtMonotonicNanoseconds: startedAtMonotonicNanoseconds)
    }

    mutating func freezeFailure(at date: Date, probeStatus: String = "pending") {
        guard startedAt != nil else { return }
        latestFailure = snapshot(at: date)
        latestFailure?.collectionStatus["failureProbeStatus"] = probeStatus
        if date < (firstFailure?.capturedAt ?? .distantFuture) { firstFailure = latestFailure }
    }

    mutating func appendFailureProbe(_ event: InputContextEvent, failureAt: Date) {
        if let first = firstFailure, first.capturedAt == failureAt {
            firstFailure = InputContextWindow(requestedStart: first.requestedStart,
                recordingStartedAt: first.recordingStartedAt, capturedAt: first.capturedAt,
                enabled: first.enabled, droppedEventCount: first.droppedEventCount,
                events: first.events + [event], collectionStatus: first.collectionStatus,
                droppedEventTimestamps: first.droppedEventTimestamps,
                droppedEventTimestampOverflowRange: first.droppedEventTimestampOverflowRange,
                capturedAtMonotonicNanoseconds: first.capturedAtMonotonicNanoseconds,
                recordingStartedAtMonotonicNanoseconds: first.recordingStartedAtMonotonicNanoseconds)
            firstFailure?.collectionStatus["failureProbeStatus"] = "completed"
        }
        guard let window = latestFailure, window.capturedAt == failureAt else { return }
        latestFailure = InputContextWindow(requestedStart: window.requestedStart,
            recordingStartedAt: window.recordingStartedAt, capturedAt: window.capturedAt,
            enabled: window.enabled, droppedEventCount: window.droppedEventCount,
            events: window.events + [event], collectionStatus: window.collectionStatus,
            droppedEventTimestamps: window.droppedEventTimestamps,
            droppedEventTimestampOverflowRange: window.droppedEventTimestampOverflowRange,
            capturedAtMonotonicNanoseconds: window.capturedAtMonotonicNanoseconds,
            recordingStartedAtMonotonicNanoseconds: window.recordingStartedAtMonotonicNanoseconds)
        latestFailure?.collectionStatus["failureProbeStatus"] = "completed"
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
protocol InputFailureAXNotificationObserving: AnyObject {
    func start(
        processID: pid_t,
        target: AXUIElement?,
        targetObservationID: String?,
        onNotification: @escaping @Sendable (String, Date, UInt64) -> Void
    ) -> [String: String]
    func stop()
}

private final class InputFailureAXObserverCallbackContext: @unchecked Sendable {
    let onNotification: @Sendable (String, Date, UInt64) -> Void

    init(onNotification: @escaping @Sendable (String, Date, UInt64) -> Void) {
        self.onNotification = onNotification
    }
}

private let inputFailureAXObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let context = Unmanaged<InputFailureAXObserverCallbackContext>.fromOpaque(refcon).takeUnretainedValue()
    context.onNotification(
        notification as String,
        Date(),
        DispatchTime.now().uptimeNanoseconds
    )
}

@MainActor
private final class SystemInputFailureAXNotificationObserver: InputFailureAXNotificationObserving {
    private struct Registration {
        let element: AXUIElement
        let notification: CFString
    }

    private var observer: AXObserver?
    private var callbackContext: InputFailureAXObserverCallbackContext?
    private var registrations: [Registration] = []
    private var runLoopSource: CFRunLoopSource?

    func start(
        processID: pid_t,
        target: AXUIElement?,
        targetObservationID: String?,
        onNotification: @escaping @Sendable (String, Date, UInt64) -> Void
    ) -> [String: String] {
        stop()
        var status = [
            "accessibilityPermission": AXIsProcessTrusted() ? "granted" : "denied",
            "targetObservationID": targetObservationID ?? "unknown"
        ]
        guard AXIsProcessTrusted() else {
            status["state"] = "permission_denied"
            return status
        }

        var createdObserver: AXObserver?
        let createError = AXObserverCreate(processID, inputFailureAXObserverCallback, &createdObserver)
        guard createError == .success, let createdObserver else {
            status["state"] = "observer_create_failed"
            status["observerCreateError"] = String(createError.rawValue)
            return status
        }

        let callbackContext = InputFailureAXObserverCallbackContext(onNotification: onNotification)
        let refcon = Unmanaged.passUnretained(callbackContext).toOpaque()
        let appElement = AXUIElementCreateApplication(processID)
        status["focusedElementChanged"] = register(
            kAXFocusedUIElementChangedNotification as CFString,
            on: appElement,
            observer: createdObserver,
            refcon: refcon
        )
        if let target {
            status["selectedTextChanged"] = register(
                kAXSelectedTextChangedNotification as CFString,
                on: target,
                observer: createdObserver,
                refcon: refcon
            )
            status["valueChanged"] = register(
                kAXValueChangedNotification as CFString,
                on: target,
                observer: createdObserver,
                refcon: refcon
            )
        } else {
            status["selectedTextChanged"] = "target_handle_unavailable"
            status["valueChanged"] = "target_handle_unavailable"
        }

        guard !registrations.isEmpty else {
            status["state"] = "no_notifications_supported"
            self.callbackContext = nil
            registrations = []
            return status
        }
        let source = AXObserverGetRunLoopSource(createdObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        observer = createdObserver
        self.callbackContext = callbackContext
        runLoopSource = source
        status["state"] = registrations.count == 3 ? "active" : "partially_active"
        status["registeredNotificationCount"] = String(registrations.count)
        status["evidenceSource"] = "AX_notification_not_independent_DOM_or_screen_evidence"
        return status
    }

    func stop() {
        if let observer {
            for registration in registrations {
                AXObserverRemoveNotification(observer, registration.element, registration.notification)
            }
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        observer = nil
        callbackContext = nil
        registrations = []
        runLoopSource = nil
    }

    private func register(
        _ notification: CFString,
        on element: AXUIElement,
        observer: AXObserver,
        refcon: UnsafeMutableRawPointer
    ) -> String {
        let result = AXObserverAddNotification(observer, element, notification, refcon)
        guard result == .success else { return "unsupported_or_failed_\(result.rawValue)" }
        registrations.append(Registration(element: element, notification: notification))
        return "registered"
    }
}

@MainActor
final class InputFailureContextRecorder {
    static let focusProbeApplicationBundleIdentifiers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.openai.codex"
    ]

    private(set) var isEnabled = false
    private var buffer = InputContextBuffer()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var sampleTask: Task<Void, Never>?
    private var applicationObserver: NSObjectProtocol?
    private let probeQueue = DispatchQueue(label: "local.tencent.voice.mvp.failure-context", qos: .utility)
    private let probe: any InputContextSampling
    private var previousSample: [String: String]?
    private var lastActivity: Date = .distantPast
    private var generation = 0
    private var latestFailureDiagnostics: [SessionLogEntry] = []
    private var latestFailureDiagnosticsTruncated = false
    private var firstFailureDiagnostics: [SessionLogEntry] = []
    private var firstFailureDiagnosticsTruncated = false
    private var lastOperationProbe: Date = .distantPast
    private var activeSessionID: UUID?
    private let axNotificationObserver: any InputFailureAXNotificationObserving
    private var axNotificationStatus: [String: String] = ["state": "not_started"]
    private var observedAXTargetPID: pid_t?
    private var observedAXTargetID: String?
    private var interactionCaptureCounts: [String: Int] = [:]
    private var observedAXTargetElement: AXUIElement?
    private var axNotificationGeneration = 0

    private static let timelineTargetEvents: Set<String> = [
        "keyboard_selection_stabilization_skipped", "keyboard_selection_stabilized",
        "keyboard_selection_stabilization_failed", "keyboard_selection_submitted",
        "ax_selected_text_range_set_requested", "ax_selected_text_range_set_returned",
        "ax_selected_text_range_set_threw", "keyboard_document_observed",
        "keyboard_state_change_observed", "keyboard_document_observation_discarded", "keyboard_write_submitted",
        "keyboard_write_acknowledged", "keyboard_write_unconfirmed",
        "keyboard_focus_changed", "ax_focus_changed", "keyboard_target_reacquired",
        "keyboard_target_reacquire_retryable", "keyboard_target_reacquire_rejected",
        "safari_keyboard_target_reacquired", "safari_keyboard_target_reacquire_retryable",
        "safari_keyboard_target_reacquire_rejected", "safari_editor_continuity_scan_diagnostic",
        "keyboard_editor_continuity_captured", "editor_continuity_scan_summary",
        "ax_read_diagnostic_queue_summary",
        AXTextEditorContinuityScanDiagnostic.event,
        "text_dispatch_returned"
    ]
    private static let diagnosticOnlyTimelineEvents: Set<String> = [
        "keyboard_editor_continuity_captured", "editor_continuity_scan_summary",
        "ax_read_diagnostic_queue_summary", "keyboard_document_observation_discarded",
        AXTextEditorContinuityScanDiagnostic.event
    ]

    static func shouldProbeTarget(
        event: String,
        isFailure: Bool,
        isCapture: Bool,
        elapsedSinceLastProbe: TimeInterval
    ) -> Bool {
        isFailure || isCapture
            || (!diagnosticOnlyTimelineEvents.contains(event) && elapsedSinceLastProbe >= 1)
    }

    init(
        axNotificationObserver: (any InputFailureAXNotificationObserving)? = nil,
        probe: any InputContextSampling = InputContextAXProbe()
    ) {
        self.axNotificationObserver = axNotificationObserver ?? SystemInputFailureAXNotificationObserver()
        self.probe = probe
    }

    var latestFailure: InputFailureEvidence? {
        guard let context = buffer.latestFailure else { return nil }
        return InputFailureEvidence(desktopContext: context, diagnosticEvents: latestFailureDiagnostics,
            diagnosticEventsTruncated: latestFailureDiagnosticsTruncated)
    }

    var firstFailure: InputFailureEvidence? {
        guard let context = buffer.firstFailure else { return nil }
        return InputFailureEvidence(desktopContext: context, diagnosticEvents: firstFailureDiagnostics,
            diagnosticEventsTruncated: firstFailureDiagnosticsTruncated)
    }

    private func retainFirstFailureDiagnostics(at date: Date) {
        if buffer.firstFailure?.capturedAt == date {
            firstFailureDiagnostics = latestFailureDiagnostics
            firstFailureDiagnosticsTruncated = latestFailureDiagnosticsTruncated
        }
    }

    func sessionBegan(_ sessionID: UUID) {
        activeSessionID = sessionID
    }

    func sessionEnded() {
        activeSessionID = nil
        stopAXNotificationObserver(status: "session_ended")
    }

    func observeSessionEntry(_ entry: SessionLogEntry, logger: SessionLogger) {
        guard isEnabled else { return }
        guard DiagnosticAnomaly.events.contains(entry.event) else { return }
        // Target observations can precede the unified log. Preserve their pending
        // probe; injector/session-only failures have no safe editor handle to probe.
        if buffer.latestFailure?.capturedAt != entry.timestamp {
            record(
                entry.event,
                fields: entry.metadata,
                at: entry.timestamp,
                sessionID: entry.sessionID,
                operationID: Int(entry.metadata["operationID"] ?? ""),
                targetApplicationBundleIdentifier: entry.targetApplicationBundleIdentifier,
                targetApplicationProcessID: entry.targetApplicationProcessID,
                eventID: entry.eventID,
                monotonicTimestampNanoseconds: entry.monotonicTimestampNanoseconds
            )
            buffer.freezeFailure(at: entry.timestamp, probeStatus: "not_requested_no_target_handle")
        }
        latestFailureDiagnostics = logger.failureEvents(at: entry.timestamp, recoverPersisted: false)
        latestFailureDiagnosticsTruncated = logger.failureContextEvidenceTruncated(at: entry.timestamp)
        retainFirstFailureDiagnostics(at: entry.timestamp)
    }

    func observeTarget(_ diagnostic: TextInputDiagnostic, element: AXUIElement?, pid: pid_t?, logger: SessionLogger) {
        guard isEnabled else { return }
        let failure = DiagnosticAnomaly.events.contains(diagnostic.event)
        let capture = diagnostic.event == "input_target_captured"
        let dispatch = ["keyboard_write_submitted", "ax_write_submitted"].contains(diagnostic.event)
        let acknowledged = ["keyboard_write_acknowledged", "ax_write_acknowledged"].contains(diagnostic.event)
        let timelineEvent = Self.timelineTargetEvents.contains(diagnostic.event)
        guard failure || capture || dispatch || acknowledged || timelineEvent else { return }
        let now = diagnostic.timestamp
        let bundleIdentifier = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        if capture, let pid {
            bindAXNotificationObserver(
                processID: pid,
                target: element,
                bundleIdentifier: bundleIdentifier,
                targetObservationID: diagnostic.fields["targetElementObservationID"]
            )
        }
        if failure {
            record(
                diagnostic.event,
                fields: DiagnosticLogSanitizer.fields(diagnostic.fields),
                at: now,
                sessionID: activeSessionID,
                operationID: Int(diagnostic.fields["operationID"] ?? ""),
                targetApplicationBundleIdentifier: bundleIdentifier,
                targetApplicationProcessID: pid.map { Int32($0) },
                eventID: diagnostic.eventID,
                monotonicTimestampNanoseconds: diagnostic.monotonicTimestampNanoseconds
            )
            buffer.freezeFailure(at: now, probeStatus: pid == nil ? "not_requested_no_target_pid" : "pending")
            latestFailureDiagnostics = logger.failureEvents(at: now, recoverPersisted: false)
            latestFailureDiagnosticsTruncated = logger.failureContextEvidenceTruncated(at: now)
            retainFirstFailureDiagnostics(at: now)
        } else if timelineEvent || dispatch || acknowledged || capture {
            record(
                diagnostic.event,
                fields: DiagnosticLogSanitizer.fields(diagnostic.fields),
                at: now,
                sessionID: activeSessionID,
                operationID: Int(diagnostic.fields["operationID"] ?? ""),
                targetApplicationBundleIdentifier: bundleIdentifier,
                targetApplicationProcessID: pid.map { Int32($0) },
                eventID: diagnostic.eventID,
                monotonicTimestampNanoseconds: diagnostic.monotonicTimestampNanoseconds
            )
        }
        guard Self.shouldProbeTarget(
            event: diagnostic.event,
            isFailure: failure,
            isCapture: capture,
            elapsedSinceLastProbe: now.timeIntervalSince(lastOperationProbe)
        ) else { return }
        lastOperationProbe = now
        guard let pid else { return }
        let reference = InputContextElementReference(element: element)
        let token = generation
        let probe = self.probe
        let queue = probeQueue
        Task { @MainActor [weak self] in
            let details = await withCheckedContinuation { continuation in
                    queue.async {
                        continuation.resume(returning: probe.sample(
                            pid: pid,
                            target: reference.element,
                            includeEditors: true
                        ))
                    }
            }
            guard let self, self.isEnabled, self.generation == token else { return }
            var fields = DiagnosticLogSanitizer.fields(diagnostic.fields)
            fields.merge(details) { _, new in new }
            fields["phase"] = diagnostic.event
            fields["pid"] = String(pid)
            fields["requestedAt"] = now.ISO8601Format()
            fields["frontmostPIDAtCompletion"] = String(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
            let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            let event = InputContextEvent(
                timestamp: Date(),
                event: "input_editor_probe",
                fields: fields,
                monotonicTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                sessionID: self.activeSessionID,
                operationID: Int(diagnostic.fields["operationID"] ?? ""),
                targetApplicationBundleIdentifier: bundleIdentifier,
                targetApplicationProcessID: Int32(pid)
            )
            self.buffer.append(event, now: event.timestamp)
            if failure { self.buffer.appendFailureProbe(event, failureAt: now) }
        }
    }

    private func bindAXNotificationObserver(
        processID: pid_t,
        target: AXUIElement?,
        bundleIdentifier: String?,
        targetObservationID: String?
    ) {
        if observedAXTargetPID == processID,
           observedAXTargetID == targetObservationID,
           ((observedAXTargetElement == nil && target == nil)
                || (observedAXTargetElement.flatMap { old in target.map { CFEqual(old, $0) } } == true)) {
            return
        }
        stopAXNotificationObserver(status: "target_rebound")
        observedAXTargetPID = processID
        observedAXTargetID = targetObservationID
        observedAXTargetElement = target
        axNotificationGeneration += 1
        let token = axNotificationGeneration
        axNotificationStatus = axNotificationObserver.start(
            processID: processID,
            target: target,
            targetObservationID: targetObservationID
        ) { [weak self] name, timestamp, monotonic in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.axNotificationGeneration == token else { return }
                self.record(
                    "ax_notification_observed",
                    fields: [
                        "notification": name,
                        "observation": "AX_callback_only",
                        "independentPageEvidence": "false",
                        "targetObservationID": targetObservationID ?? "unknown"
                    ],
                    at: timestamp,
                    sessionID: self.activeSessionID,
                    targetApplicationBundleIdentifier: bundleIdentifier,
                    targetApplicationProcessID: Int32(processID),
                    monotonicTimestampNanoseconds: monotonic
                )
            }
        }
        var fields = axNotificationStatus
        fields["targetApplicationBundleIdentifier"] = bundleIdentifier ?? "unknown"
        fields["targetApplicationProcessID"] = String(processID)
        fields["targetObservationID"] = targetObservationID ?? "unknown"
        fields["scope"] = "selected_text_value_and_application_focus_notifications"
        record(
            "ax_notification_observer_status",
            fields: fields,
            targetApplicationBundleIdentifier: bundleIdentifier,
            targetApplicationProcessID: Int32(processID)
        )
    }

    private func stopAXNotificationObserver(status: String) {
        axNotificationGeneration += 1
        axNotificationObserver.stop()
        observedAXTargetPID = nil
        observedAXTargetID = nil
        observedAXTargetElement = nil
        axNotificationStatus = ["state": status]
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        stop()
        guard enabled else { return }
        isEnabled = true
        buffer.start(at: Date())
        interactionCaptureCounts = [
            "syntheticInputFilteredCount": 0,
            "unsupportedAppKeyboardFilteredCount": 0,
            "repeatKeyboardFilteredCount": 0,
            "secureInputFilteredCount": 0,
            "keyboardActivityThrottledCount": 0,
            "scrollActivityThrottledCount": 0
        ]
        axNotificationStatus = ["state": "awaiting_target_capture"]
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
        record("recording_started", fields: [
            "globalMonitorInstalled": String(globalMonitor != nil),
            "localMonitorInstalled": String(localMonitor != nil),
            "accessibilityGranted": String(AXIsProcessTrusted()),
            "pollIntervalMilliseconds": "500",
            "typedCharactersRecorded": "false"
        ])
        sampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        stopAXNotificationObserver(status: "disabled")
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
        firstFailureDiagnostics = []
        firstFailureDiagnosticsTruncated = false
        lastOperationProbe = .distantPast
        interactionCaptureCounts = [:]
    }

    func snapshot(at date: Date) -> InputContextWindow {
        var window = buffer.snapshot(at: date)
        window.collectionStatus = ["globalMonitorInstalled": String(globalMonitor != nil),
            "accessibilityGranted": String(AXIsProcessTrusted()), "secureInputActive": String(IsSecureEventInputEnabled()),
            "focusPollingIntervalMilliseconds": "500", "typedCharactersRecorded": "false", "screenshotsRecorded": "false", "latestFailureRetained": String(buffer.latestFailure != nil),
            "wallClockPairedWithMonotonicUptime": "true", "monotonicClock": "DispatchTime.uptimeNanoseconds",
            "sessionOperationAndTargetIDsIncludedWhenAvailable": "true",
            "editorProbeNodeLimit": "160", "editorProbeDepthLimit": "64",
            "editorProbeTraversal": "reverse_depth_first", "editorProbeBudgetMilliseconds": "250"]
        window.collectionStatus["safariContinuityDiagnosticScope"] = "AX_editor_rebuild_scan_and_previous_handle_role_read_only"
        window.collectionStatus["safariContinuityDiagnosticTextCaptured"] = "false"
        window.collectionStatus["safariContinuityDiagnosticAudioCaptured"] = "false"
        window.collectionStatus["safariContinuityDiagnosticPermission"] = "existing_accessibility_permission"
        window.collectionStatus["safariContinuityDiagnosticRetention"] = "same_bounded_input_failure_window"
        window.collectionStatus["localMonitorInstalled"] = String(localMonitor != nil)
        window.collectionStatus["axNotificationCaptureScope"] = "focused_target_value_selection_and_application_focus_only"
        window.collectionStatus["axNotificationIsIndependentPageEvidence"] = "false"
        window.collectionStatus["axNotificationNoCallbackMeaning"] = "no_callback_is_not_evidence_of_no_change"
        window.collectionStatus["axNotificationTargetState"] = axNotificationStatus["state"] ?? "unknown"
        window.collectionStatus["axNotificationRetention"] = "same_bounded_input_failure_window"
        for (key, value) in axNotificationStatus where key != "state" {
            window.collectionStatus["axNotification_\(key)"] = value
        }
        for (key, value) in interactionCaptureCounts {
            window.collectionStatus[key] = String(value)
        }
        return window
    }

    private func record(
        _ name: String,
        fields: [String: String],
        at date: Date = Date(),
        sessionID: UUID? = nil,
        operationID: Int? = nil,
        targetApplicationBundleIdentifier: String? = nil,
        targetApplicationProcessID: Int32? = nil,
        eventID: UUID? = nil,
        monotonicTimestampNanoseconds: UInt64? = nil
    ) {
        buffer.append(InputContextEvent(
            timestamp: date,
            event: name,
            fields: fields,
            eventID: eventID ?? UUID(),
            monotonicTimestampNanoseconds: monotonicTimestampNanoseconds ?? DispatchTime.now().uptimeNanoseconds,
            sessionID: sessionID ?? activeSessionID,
            operationID: operationID ?? Int(fields["operationID"] ?? ""),
            targetApplicationBundleIdentifier: targetApplicationBundleIdentifier
                ?? fields["application"]
                ?? fields["targetApplicationBundleIdentifier"],
            targetApplicationProcessID: targetApplicationProcessID
                ?? fields["pid"].flatMap(Int32.init)
        ), now: date)
    }

    private func observe(_ event: NSEvent) {
        guard isEnabled else { return }
        // Do not confuse our injected Unicode events with the user's actions.
        if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier) {
            incrementInteractionCount("syntheticInputFilteredCount")
            return
        }
        let now = Date()
        let app = NSWorkspace.shared.frontmostApplication
        var fields = ["application": app?.bundleIdentifier ?? "unknown", "pid": String(app?.processIdentifier ?? 0)]
        if event.type == .keyDown {
            guard ["com.openai.codex", "com.apple.Safari", "com.google.Chrome", "md.obsidian"].contains(app?.bundleIdentifier ?? "") else {
                incrementInteractionCount("unsupportedAppKeyboardFilteredCount")
                return
            }
            guard !event.isARepeat else {
                incrementInteractionCount("repeatKeyboardFilteredCount")
                return
            }
            guard !IsSecureEventInputEnabled() else {
                incrementInteractionCount("secureInputFilteredCount")
                return
            }
            if let shortcut = InputContextKeyFilter.shortcut(keyCode: event.keyCode, flags: event.modifierFlags) {
                fields["shortcut"] = shortcut
                record(app?.bundleIdentifier == "com.openai.codex" ? "codex_shortcut" : "application_shortcut", fields: fields, at: now)
            } else if now.timeIntervalSince(lastActivity) >= 1 {
                lastActivity = now
                record(app?.bundleIdentifier == "com.openai.codex" ? "codex_keyboard_activity" : "application_keyboard_activity", fields: fields, at: now)
            } else {
                incrementInteractionCount("keyboardActivityThrottledCount")
            }
        } else if event.type == .scrollWheel {
            guard now.timeIntervalSince(lastActivity) >= 1 else {
                incrementInteractionCount("scrollActivityThrottledCount")
                return
            }
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

    private func incrementInteractionCount(_ key: String) {
        interactionCaptureCounts[key, default: 0] += 1
    }

    private func sample() async {
        guard isEnabled else { return }
        let token = generation
        let now = Date()
        let app = NSWorkspace.shared.frontmostApplication
        var fields = ["application": app?.bundleIdentifier ?? "unknown", "pid": String(app?.processIdentifier ?? 0),
            "accessibilityGranted": String(AXIsProcessTrusted())]
        if let bundleIdentifier = app?.bundleIdentifier,
           Self.focusProbeApplicationBundleIdentifiers.contains(bundleIdentifier),
           let pid = app?.processIdentifier {
            let probe = self.probe
            let details = await withCheckedContinuation { continuation in
                probeQueue.async {
                    continuation.resume(returning: probe.sample(pid: pid, target: nil, includeEditors: true))
                }
            }
            guard isEnabled, generation == token else { return }
            // Do not attribute a slow AX result to an app that is no longer active.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            fields.merge(details) { _, new in new }
            fields["detailedProbeApplication"] = bundleIdentifier
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

    func restricted(to start: Date, through end: Date) -> Self {
        Self(
            desktopContext: desktopContext.restricted(to: start, through: end),
            diagnosticEvents: diagnosticEvents.filter { $0.timestamp >= start && $0.timestamp <= end },
            diagnosticEventsTruncated: diagnosticEventsTruncated
        )
    }

    func retainingFailureContext(reportWindowStart: Date, through end: Date) -> Self {
        let failureWindowStart = desktopContext.capturedAt.addingTimeInterval(-60)
        let joinedStart = min(reportWindowStart, failureWindowStart)
        var context = desktopContext.restricted(to: joinedStart, through: end)
        context.collectionStatus["reportPrimaryWindowStart"] = DiagnosticReportTime.format(reportWindowStart)
        context.collectionStatus["associatedFailureWindowStart"] = DiagnosticReportTime.format(failureWindowStart)
        context.collectionStatus["associatedFailureAt"] = DiagnosticReportTime.format(desktopContext.capturedAt)
        context.collectionStatus["timelineIncludesOlderFailureContext"] = String(failureWindowStart < reportWindowStart)
        return Self(
            desktopContext: context,
            diagnosticEvents: diagnosticEvents.filter { $0.timestamp >= joinedStart && $0.timestamp <= end },
            diagnosticEventsTruncated: diagnosticEventsTruncated
        )
    }

    var sessionIDs: Set<UUID> { Set(diagnosticEvents.map(\.sessionID)) }
}

struct InputFailureReport: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let generatedAt: Date
    let desktopContext: InputContextWindow
    let diagnosticReport: DiagnosticReport
    let diagnosticEventsTruncated: Bool
    var latestFailure: InputFailureEvidence? = nil
    var sessionEvidenceSummaries: [DiagnosticSessionSummary]? = nil
    var firstFailure: InputFailureEvidence? = nil
    let evidenceScopeNote: String?
    var windowFrameCapture: DiagnosticWindowFrameEvidence? = nil

    func replacingDiagnosticReport(_ diagnosticReport: DiagnosticReport) -> Self {
        Self(
            schemaVersion: schemaVersion,
            id: id,
            generatedAt: generatedAt,
            desktopContext: desktopContext,
            diagnosticReport: diagnosticReport,
            diagnosticEventsTruncated: diagnosticEventsTruncated,
            latestFailure: latestFailure,
            sessionEvidenceSummaries: sessionEvidenceSummaries,
            firstFailure: firstFailure,
            evidenceScopeNote: evidenceScopeNote,
            windowFrameCapture: windowFrameCapture
        )
    }

    func replacingWindowFrameCapture(_ evidence: DiagnosticWindowFrameEvidence) -> Self {
        Self(
            schemaVersion: schemaVersion,
            id: id,
            generatedAt: generatedAt,
            desktopContext: desktopContext,
            diagnosticReport: diagnosticReport,
            diagnosticEventsTruncated: diagnosticEventsTruncated,
            latestFailure: latestFailure,
            sessionEvidenceSummaries: sessionEvidenceSummaries,
            firstFailure: firstFailure,
            evidenceScopeNote: evidenceScopeNote,
            windowFrameCapture: evidence
        )
    }
}
