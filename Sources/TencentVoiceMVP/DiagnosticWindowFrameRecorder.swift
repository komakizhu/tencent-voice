import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct DiagnosticWindowFrameAsset: Sendable {
    let relativePath: String
    let timestamp: Date
    let monotonicNanoseconds: UInt64
    let jpegData: Data
}

struct DiagnosticWindowFrameReference: Codable, Equatable, Sendable {
    let relativePath: String
    let timestamp: Date
    let monotonicNanoseconds: UInt64
    let byteCount: Int
}

struct DiagnosticWindowFrameStatusTransition: Codable, Equatable, Sendable {
    let timestamp: Date
    let monotonicNanoseconds: UInt64
    let status: String
    let reason: String?
}

struct DiagnosticWindowFrameEvidence: Codable, Equatable, Sendable {
    let enabled: Bool
    let status: String
    let permissionGranted: Bool
    let sessionID: UUID?
    let targetPID: Int32?
    let targetBundleIdentifier: String?
    let targetWindowID: UInt32?
    let startedAt: Date?
    let stoppedAt: Date?
    let maximumFramesPerSecond: Int
    let ringDurationSeconds: Int
    let memoryLimitBytes: Int
    let ringMemoryLimitBytes: Int
    let retainedFrameCount: Int
    let droppedFrameCount: Int
    let retainedBytes: Int
    let frames: [DiagnosticWindowFrameReference]
    let archiveStatus: String
    var stopReason: String? = nil
    var statusTransitions: [DiagnosticWindowFrameStatusTransition]? = nil

    func replacingArchiveStatus(_ status: String) -> Self {
        Self(
            enabled: enabled,
            status: self.status,
            permissionGranted: permissionGranted,
            sessionID: sessionID,
            targetPID: targetPID,
            targetBundleIdentifier: targetBundleIdentifier,
            targetWindowID: targetWindowID,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            maximumFramesPerSecond: maximumFramesPerSecond,
            ringDurationSeconds: ringDurationSeconds,
            memoryLimitBytes: memoryLimitBytes,
            ringMemoryLimitBytes: ringMemoryLimitBytes,
            retainedFrameCount: retainedFrameCount,
            droppedFrameCount: droppedFrameCount,
            retainedBytes: retainedBytes,
            frames: status == "included" ? frames : [],
            archiveStatus: status,
            stopReason: stopReason,
            statusTransitions: statusTransitions
        )
    }
}

struct DiagnosticWindowFrameSnapshot: Sendable {
    let evidence: DiagnosticWindowFrameEvidence
    let assets: [DiagnosticWindowFrameAsset]
}

enum DiagnosticWindowFrameVerification {
    enum FocusState: Equatable {
        case available
        case unavailable
        case windowMismatch
    }

    static func failureReason(
        candidateWindowCount: Int,
        candidateWindowID: UInt32?,
        expectedWindowID: UInt32,
        focusState: FocusState,
        fingerprintMatches: Bool
    ) -> String? {
        guard candidateWindowCount > 0 else { return "candidate_window_count_mismatch" }
        guard candidateWindowID == expectedWindowID else { return "window_identifier_changed" }
        guard focusState != .unavailable else { return "focused_window_unavailable" }
        guard focusState != .windowMismatch, fingerprintMatches else { return "window_information_mismatch" }
        return nil
    }

    static func uniqueWindowID(
        candidateWindowIDs: [UInt32],
        matchingFocusedWindowIDs: [UInt32]
    ) -> UInt32? {
        let matchingSet = Set(matchingFocusedWindowIDs)
        let matches = candidateWindowIDs.filter { matchingSet.contains($0) }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

enum DiagnosticWindowFrameCapturePolicy {
    static func mayCapture(
        enabled: Bool,
        sessionIsActive: Bool,
        permissionGranted: Bool,
        secureInputActive: Bool
    ) -> Bool {
        enabled && sessionIsActive && permissionGranted && !secureInputActive
    }
}

struct DiagnosticWindowFrameRing {
    private(set) var frames: [DiagnosticWindowFrameAsset] = []
    private(set) var droppedFrameCount = 0
    private(set) var retainedBytes = 0
    private var nextFrameNumber = 1

    mutating func append(
        jpegData: Data,
        timestamp: Date,
        monotonicNanoseconds: UInt64,
        now: Date,
        maximumFrameCount: Int = 300,
        maximumBytes: Int = 80 * 1_024 * 1_024,
        duration: TimeInterval = 60
    ) {
        trim(now: now, duration: duration)
        guard !jpegData.isEmpty, jpegData.count <= maximumBytes else {
            droppedFrameCount += 1
            return
        }
        let path = String(format: "frames/%06d.jpg", nextFrameNumber)
        nextFrameNumber += 1
        frames.append(DiagnosticWindowFrameAsset(
            relativePath: path,
            timestamp: timestamp,
            monotonicNanoseconds: monotonicNanoseconds,
            jpegData: jpegData
        ))
        retainedBytes += jpegData.count
        while frames.count > maximumFrameCount || retainedBytes > maximumBytes {
            let removed = frames.removeFirst()
            retainedBytes -= removed.jpegData.count
            droppedFrameCount += 1
        }
    }

    mutating func trim(now: Date, duration: TimeInterval = 60) {
        let cutoff = now.addingTimeInterval(-duration)
        while let first = frames.first, first.timestamp < cutoff {
            retainedBytes -= frames.removeFirst().jpegData.count
        }
    }

    mutating func noteDroppedFrame() {
        droppedFrameCount += 1
    }
}

private final class DiagnosticWindowFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var ring = DiagnosticWindowFrameRing()
    private var status = "disabled"
    private var enabled = false
    private var permissionGranted = false
    private var sessionID: UUID?
    private var targetPID: Int32?
    private var bundleIdentifier: String?
    private var windowID: UInt32?
    private var startedAt: Date?
    private var stoppedAt: Date?
    private var stopReason: String?
    private var statusTransitions: [DiagnosticWindowFrameStatusTransition] = []

    func begin(pid: pid_t, bundleIdentifier: String, windowID: CGWindowID, sessionID: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        ring = DiagnosticWindowFrameRing()
        enabled = true
        permissionGranted = true
        status = "starting"
        self.sessionID = sessionID
        targetPID = Int32(pid)
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        startedAt = Date()
        stoppedAt = nil
        stopReason = nil
        statusTransitions = []
        appendStatusTransition(status: "starting", reason: nil, at: startedAt ?? Date())
    }

    func setStatus(_ status: String, reason: String? = nil, permissionGranted: Bool? = nil, stop: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if self.status != status || stopReason != reason {
            appendStatusTransition(status: status, reason: reason, at: Date())
        }
        self.status = status
        stopReason = reason
        if let permissionGranted { self.permissionGranted = permissionGranted }
        if stop { stoppedAt = Date() }
    }

    func append(_ jpegData: Data) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard enabled, status == "capturing" else { return }
        ring.append(
            jpegData: jpegData,
            timestamp: now,
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            now: now
        )
    }

    func noteDroppedFrame() {
        lock.lock()
        defer { lock.unlock() }
        ring.noteDroppedFrame()
    }

    func prune(at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        ring.trim(now: date)
    }

    func clear(status: String, enabled: Bool, permissionGranted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        ring = DiagnosticWindowFrameRing()
        self.enabled = enabled
        self.permissionGranted = permissionGranted
        self.status = status
        sessionID = nil
        targetPID = nil
        bundleIdentifier = nil
        windowID = nil
        startedAt = nil
        stoppedAt = Date()
        stopReason = nil
        statusTransitions = []
    }

    func snapshot(at date: Date) -> DiagnosticWindowFrameSnapshot {
        lock.lock()
        defer { lock.unlock() }
        ring.trim(now: date)
        let assets = ring.frames
        let references = assets.map {
            DiagnosticWindowFrameReference(
                relativePath: $0.relativePath,
                timestamp: $0.timestamp,
                monotonicNanoseconds: $0.monotonicNanoseconds,
                byteCount: $0.jpegData.count
            )
        }
        return DiagnosticWindowFrameSnapshot(
            evidence: DiagnosticWindowFrameEvidence(
                enabled: enabled,
                status: status,
                permissionGranted: permissionGranted,
                sessionID: sessionID,
                targetPID: targetPID,
                targetBundleIdentifier: bundleIdentifier,
                targetWindowID: windowID,
                startedAt: startedAt,
                stoppedAt: stoppedAt,
                maximumFramesPerSecond: 5,
                ringDurationSeconds: 60,
                memoryLimitBytes: 80 * 1_024 * 1_024,
                ringMemoryLimitBytes: 80 * 1_024 * 1_024,
                retainedFrameCount: assets.count,
                droppedFrameCount: ring.droppedFrameCount,
                retainedBytes: ring.retainedBytes,
                frames: references,
                archiveStatus: assets.isEmpty ? "not_included" : "included",
                stopReason: stopReason,
                statusTransitions: statusTransitions.filter {
                    $0.timestamp >= date.addingTimeInterval(-60) && $0.timestamp <= date
                }
            ),
            assets: assets
        )
    }

    private func appendStatusTransition(status: String, reason: String?, at date: Date) {
        statusTransitions.append(DiagnosticWindowFrameStatusTransition(
            timestamp: date,
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            status: status,
            reason: reason
        ))
        let cutoff = date.addingTimeInterval(-60)
        statusTransitions.removeAll { $0.timestamp < cutoff }
        if statusTransitions.count > 128 {
            statusTransitions.removeFirst(statusTransitions.count - 128)
        }
    }
}

@MainActor
final class DiagnosticWindowFrameRecorder {
    private let buffer = DiagnosticWindowFrameBuffer()
    private var isEnabled = false
    private var sessionIsActive = false
    private var activeSessionID: UUID?
    private var sessionCaptureClosed = false
    private var stream: SCStream?
    private var output: DiagnosticWindowFrameStreamOutput?
    private var startupTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var expectedPID: pid_t?
    private var expectedWindowID: CGWindowID?
    private var expectedBundleIdentifier: String?

    func setCaptureEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard enabled else {
            retentionTask?.cancel()
            retentionTask = nil
            stop(status: "disabled", clearFrames: true)
            sessionCaptureClosed = false
            return
        }
        sessionCaptureClosed = false
        let permissionGranted = CGPreflightScreenCaptureAccess()
        buffer.clear(
            status: permissionGranted ? "waiting_for_target" : "permission_denied",
            enabled: true,
            permissionGranted: permissionGranted
        )
        retentionTask?.cancel()
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                self?.buffer.prune(at: Date())
            }
        }
    }

    func targetCaptured(pid: pid_t, bundleIdentifier: String?, targetElement: AXUIElement?) {
        guard isEnabled, sessionIsActive, !sessionCaptureClosed else { return }
        guard DiagnosticWindowFrameCapturePolicy.mayCapture(
            enabled: isEnabled,
            sessionIsActive: sessionIsActive,
            permissionGranted: CGPreflightScreenCaptureAccess(),
            secureInputActive: IsSecureEventInputEnabled()
        ) else {
            if IsSecureEventInputEnabled() {
                stop(status: "secure_input_active")
            } else {
                stop(status: "permission_denied", clearFrames: true, permissionGranted: false)
            }
            return
        }
        if expectedPID == pid, stream != nil { return }
        if expectedPID == pid, startupTask != nil { return }
        if let expectedPID, expectedPID != pid {
            stop(status: "target_application_changed")
            return
        }
        startupTask?.cancel()
        monitorTask?.cancel()
        monitorTask = nil
        stopStreamOnly()
        buffer.setStatus("starting", permissionGranted: true)
        expectedPID = pid
        expectedBundleIdentifier = bundleIdentifier
        startupTask = Task { [weak self] in
            await self?.startCapture(pid: pid, bundleIdentifier: bundleIdentifier, targetElement: targetElement)
        }
    }

    func targetBecameAmbiguous(status: String = "target_ambiguous") {
        guard isEnabled, sessionIsActive, !sessionCaptureClosed,
              stream != nil || startupTask != nil || expectedPID != nil else { return }
        stop(status: status)
    }

    func sessionBegan(_ sessionID: UUID) {
        sessionIsActive = true
        activeSessionID = sessionID
        sessionCaptureClosed = false
    }

    func sessionEnded() {
        if isEnabled, sessionIsActive,
           stream != nil || startupTask != nil || expectedPID != nil {
            stop(status: "session_ended", closeSession: false)
        }
        sessionIsActive = false
        activeSessionID = nil
        sessionCaptureClosed = false
    }

    func snapshot(at date: Date) -> DiagnosticWindowFrameSnapshot {
        buffer.snapshot(at: date)
    }

    private func startCapture(pid: pid_t, bundleIdentifier: String?, targetElement: AXUIElement?) async {
        defer {
            if expectedPID == pid { startupTask = nil }
        }
        do {
            guard !Task.isCancelled, isEnabled, sessionIsActive else { return }
            guard DiagnosticWindowFrameCapturePolicy.mayCapture(
                enabled: isEnabled,
                sessionIsActive: sessionIsActive,
                permissionGranted: CGPreflightScreenCaptureAccess(),
                secureInputActive: IsSecureEventInputEnabled()
            ) else {
                if IsSecureEventInputEnabled() {
                    stop(status: "secure_input_active")
                } else {
                    stop(status: "permission_denied", clearFrames: true, permissionGranted: false)
                }
                return
            }
            let content = try await Self.shareableContent()
            guard !Task.isCancelled else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                stop(status: "target_not_frontmost")
                return
            }
            let candidateWindows = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
            }
            guard let targetElement else {
                stop(status: "target_window_unverified", reason: "focused_window_unavailable")
                return
            }
            let focusedRead = Self.focusedWindowFingerprint(pid: pid, targetElement: targetElement)
            guard case .available(let focusedWindow) = focusedRead else {
                let reason: String
                if case .windowMismatch = focusedRead {
                    reason = "window_information_mismatch"
                } else {
                    reason = "focused_window_unavailable"
                }
                stop(status: "target_window_unverified", reason: reason)
                return
            }
            let matchingWindows = candidateWindows.filter { Self.matches(focusedWindow, window: $0) }
            let selectedWindowID = DiagnosticWindowFrameVerification.uniqueWindowID(
                candidateWindowIDs: candidateWindows.map(\.windowID),
                matchingFocusedWindowIDs: matchingWindows.map(\.windowID)
            )
            guard let selectedWindowID,
                  let window = matchingWindows.first(where: { $0.windowID == selectedWindowID }) else {
                stop(status: "target_window_unverified", reason: "window_information_mismatch")
                return
            }
            expectedWindowID = window.windowID
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard application?.processIdentifier != pid else { return }
                Task { @MainActor [weak self] in
                    self?.pauseCapture(status: "target_app_inactive", reason: "target_application_not_frontmost")
                }
            }
            monitorTask?.cancel()
            monitorTask = Task { [weak self] in
                await self?.monitorTarget(pid: pid, windowID: window.windowID)
            }
            // Keep the activation and verification paths alive while ScreenCaptureKit
            // is starting. The target can lose focus during startCapture(); in that
            // case startStream intentionally returns without a stream, and the
            // monitor must still be able to resume the same original window later.
            try await startStream(window: window, pid: pid, bundleIdentifier: bundleIdentifier, initial: true)
        } catch {
            stop(status: "capture_failed")
        }
    }

    private func startStream(
        window: SCWindow,
        pid: pid_t,
        bundleIdentifier: String?,
        initial: Bool
    ) async throws {
        guard isEnabled, sessionIsActive,
              expectedPID == pid, expectedWindowID == window.windowID else { return }
        let configuration = SCStreamConfiguration()
        let sourceWidth = max(1, window.frame.width * 2)
        let sourceHeight = max(1, window.frame.height * 2)
        let scale = min(CGFloat(1), min(1_440 / sourceWidth, 900 / sourceHeight))
        configuration.width = max(1, Int(sourceWidth * scale))
        configuration.height = max(1, Int(sourceHeight * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let frameOutput = DiagnosticWindowFrameStreamOutput(buffer: buffer)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: frameOutput)
        if initial {
            buffer.begin(
                pid: pid,
                bundleIdentifier: bundleIdentifier ?? "unknown",
                windowID: window.windowID,
                sessionID: activeSessionID
            )
        } else {
            buffer.setStatus("resuming", permissionGranted: true)
        }
        try newStream.addStreamOutput(frameOutput, type: .screen, sampleHandlerQueue: frameOutput.sampleQueue)
        try await newStream.startCapture()
        guard !Task.isCancelled, isEnabled, sessionIsActive,
              expectedPID == pid, expectedWindowID == window.windowID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            try? await newStream.stopCapture()
            return
        }
        stream = newStream
        output = frameOutput
        buffer.setStatus("capturing", permissionGranted: true)
    }

    private func pauseCapture(status: String, reason: String) {
        guard expectedPID != nil else { return }
        buffer.setStatus(status, reason: reason)
        stopStreamOnly()
    }

    private func monitorTarget(pid: pid_t, windowID: CGWindowID) async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard isEnabled else { return }
            if IsSecureEventInputEnabled() {
                stop(status: "secure_input_active")
                return
            }
            guard CGPreflightScreenCaptureAccess() else {
                stop(status: "permission_lost", permissionGranted: false)
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                pauseCapture(status: "target_app_inactive", reason: "target_application_not_frontmost")
                continue
            }
            do {
                let content = try await Self.shareableContent()
                let windows = content.windows.filter {
                    $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                }
                let originalWindows = windows.filter { $0.windowID == windowID }
                guard originalWindows.count == 1, let window = originalWindows.first else {
                    pauseCapture(status: "target_window_changed", reason: "original_target_window_unavailable")
                    continue
                }
                guard expectedWindowID == window.windowID else {
                    stop(status: "target_window_changed", reason: "window_identifier_changed")
                    return
                }
                let focusedRead = Self.focusedWindowFingerprint(pid: pid)
                let focusState: DiagnosticWindowFrameVerification.FocusState
                let fingerprintMatches: Bool
                switch focusedRead {
                case .available(let fingerprint):
                    focusState = .available
                    let matchingFocusedWindowIDs = windows
                        .filter { Self.matches(fingerprint, window: $0) }
                        .map(\.windowID)
                    fingerprintMatches = DiagnosticWindowFrameVerification.uniqueWindowID(
                        candidateWindowIDs: windows.map(\.windowID),
                        matchingFocusedWindowIDs: matchingFocusedWindowIDs
                    ) == windowID
                case .unavailable:
                    focusState = .unavailable
                    fingerprintMatches = false
                case .windowMismatch:
                    focusState = .windowMismatch
                    fingerprintMatches = false
                }
                if let reason = DiagnosticWindowFrameVerification.failureReason(
                    candidateWindowCount: originalWindows.count,
                    candidateWindowID: window.windowID,
                    expectedWindowID: windowID,
                    focusState: focusState,
                    fingerprintMatches: fingerprintMatches
                ) {
                    pauseCapture(status: "target_window_changed", reason: reason)
                    continue
                }
                if stream == nil, startupTask == nil {
                    startupTask = Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.startStream(
                                window: window,
                                pid: pid,
                                bundleIdentifier: self.expectedBundleIdentifier,
                                initial: false
                            )
                        } catch {
                            self.stop(status: "capture_resume_failed")
                        }
                        if self.expectedPID == pid { self.startupTask = nil }
                    }
                }
            } catch {
                stop(status: "target_verification_failed")
                return
            }
        }
    }

    private func stop(
        status: String,
        reason: String? = nil,
        clearFrames: Bool = false,
        permissionGranted: Bool? = nil,
        closeSession: Bool = true
    ) {
        if closeSession { sessionCaptureClosed = true }
        startupTask?.cancel()
        startupTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        stopStreamOnly()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        expectedPID = nil
        expectedWindowID = nil
        expectedBundleIdentifier = nil
        if clearFrames {
            buffer.clear(
                status: status,
                enabled: isEnabled,
                permissionGranted: permissionGranted ?? CGPreflightScreenCaptureAccess()
            )
        } else {
            buffer.setStatus(status, reason: reason, permissionGranted: permissionGranted, stop: true)
        }
    }

    private func stopStreamOnly() {
        guard let stream else { return }
        self.stream = nil
        output = nil
        Task { try? await stream.stopCapture() }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCShareableContent, Error>) in
            SCShareableContent.getExcludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ) { content, error in
                if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: error ?? NSError(
                        domain: "DiagnosticWindowFrameRecorder",
                        code: 1
                    ))
                }
            }
        }
    }

    private static func focusedWindowFingerprint(
        pid: pid_t,
        targetElement: AXUIElement? = nil
    ) -> FocusedWindowFingerprintRead {
        let application = AXUIElementCreateApplication(pid)
        let focusedWindowRead = copyAXAttribute(
            kAXFocusedWindowAttribute as String, from: application, targetBound: targetElement != nil
        )
        guard focusedWindowRead.0 == .success,
              let value = focusedWindowRead.1,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
        let window = value as! AXUIElement
        if let targetElement {
            let targetWindowRead = copyAXAttribute(
                kAXWindowAttribute as String, from: targetElement, targetBound: true
            )
            guard targetWindowRead.0 == .success,
                  let targetWindowValue = targetWindowRead.1,
                  CFGetTypeID(targetWindowValue) == AXUIElementGetTypeID() else { return .unavailable }
            if !CFEqual(window, targetWindowValue) { return .windowMismatch }
        }
        let titleRead = copyAXAttribute(kAXTitleAttribute as String, from: window, targetBound: true)
        let title: String? = titleRead.0 == .success ? titleRead.1 as? String : nil
        guard let size = Self.sizeAttribute(kAXSizeAttribute, from: window) else { return .unavailable }
        return .available(FocusedWindowFingerprint(title: title, size: size))
    }

    private static func copyAXAttribute(
        _ attribute: String,
        from element: AXUIElement,
        targetBound: Bool
    ) -> (AXError, CFTypeRef?) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        AXReadEvidenceRuntime.shared.record(
            AXReadEvidenceRuntime.sample(
                source: "window_monitor",
                attribute: attribute,
                element: element,
                startedAt: startedAt,
                status: status,
                targetBound: targetBound
            )
        )
        return (status, value)
    }

    private static func matches(_ fingerprint: FocusedWindowFingerprint, window: SCWindow) -> Bool {
        if let axTitle = fingerprint.title, !axTitle.isEmpty, let scTitle = window.title, !scTitle.isEmpty,
           axTitle != scTitle {
            return false
        }
        let widthMatches = abs(fingerprint.size.width - window.frame.width) <= 3
        let heightMatches = abs(fingerprint.size.height - window.frame.height) <= 3
        return widthMatches && heightMatches
    }

    private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        let read = copyAXAttribute(attribute, from: element, targetBound: true)
        guard read.0 == .success,
              let value = read.1,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

private struct FocusedWindowFingerprint {
    let title: String?
    let size: CGSize
}

private enum FocusedWindowFingerprintRead {
    case available(FocusedWindowFingerprint)
    case unavailable
    case windowMismatch
}

private final class DiagnosticWindowFrameStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let buffer: DiagnosticWindowFrameBuffer
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    let sampleQueue = DispatchQueue(label: "local.tencent.voice.mvp.diagnostic-window-frames", qos: .utility)

    init(buffer: DiagnosticWindowFrameBuffer) {
        self.buffer = buffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachmentArray.first?[.status] as? Int else {
            buffer.noteDroppedFrame()
            return
        }
        guard statusValue == SCFrameStatus.complete.rawValue
                || statusValue == SCFrameStatus.started.rawValue else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            buffer.noteDroppedFrame()
            return
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent),
              let jpeg = NSBitmapImageRep(cgImage: cgImage).representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.72]
              ) else {
            buffer.noteDroppedFrame()
            return
        }
        buffer.append(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        buffer.setStatus("capture_failed", stop: true)
    }
}

enum DiagnosticWindowFrameArchiveWriter {
    static func write(
        reportData: Data,
        snapshot: DiagnosticWindowFrameSnapshot,
        destination: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !snapshot.assets.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("InputFailure-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("InputFailure-\(UUID().uuidString).zip")
        defer {
            try? fileManager.removeItem(at: stagingRoot)
            if fileManager.fileExists(atPath: archiveURL.path) {
                try? fileManager.removeItem(at: archiveURL)
            }
        }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let reportURL = stagingRoot.appendingPathComponent("report.json")
        try reportData.write(to: reportURL, options: .atomic)
        let framesDirectory = stagingRoot.appendingPathComponent("frames", isDirectory: true)
        try fileManager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        for asset in snapshot.assets {
            let pathComponents = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard pathComponents.count == 2,
                  pathComponents[0] == "frames",
                  pathComponents[1] != ".",
                  pathComponents[1] != ".." else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let outputURL = framesDirectory.appendingPathComponent(String(pathComponents[1]))
            try asset.jpegData.write(to: outputURL, options: .atomic)
        }
        let indexData = try DiagnosticJSON.encoder().encode(snapshot.evidence.frames)
        try indexData.write(to: framesDirectory.appendingPathComponent("index.json"), options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", stagingRoot.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fileManager.fileExists(atPath: archiveURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: archiveURL, to: destination)
    }
}
