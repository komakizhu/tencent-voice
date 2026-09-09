import AVFoundation
import Foundation

enum SessionState: Equatable {
    case idle
    case connecting
    case listening
    case recovering
    case stopping
    case error(String)
}

enum SessionError: Error, LocalizedError {
    case credentialsMissing
    case microphoneDenied
    case noTextTarget
    case busy
    case cancelled

    var errorDescription: String? {
        switch self {
        case .credentialsMissing: return "尚未配置腾讯云凭证，请打开设置"
        case .microphoneDenied: return "麦克风权限未开启"
        case .noTextTarget: return "没有找到可输入的文本目标"
        case .busy: return "上一段语音还没有结束"
        case .cancelled: return "语音会话已取消"
        }
    }
}

private enum ASRFinalizationPhase: String {
    case listening
    case finalizing
    case finalized
    case hardStopped
}

@MainActor
protocol SessionCoordinating: AnyObject {
    var state: SessionState { get }
    func begin() async throws
    func end() async throws
    func cancel()
}

@MainActor
final class SessionCoordinator: SessionCoordinating {
    let asr: RealtimeASRClient
    let audio: AudioCapture
    let textTarget: TextTarget
    let settingsStore: SettingsStore
    let credentialStore: CredentialStore
    let logger: SessionLogger
    private let onStateChange: (SessionState) -> Void
    private var stateObserver: ((SessionState) -> Void)?
    private(set) var state: SessionState = .idle {
        didSet {
            onStateChange(state)
            stateObserver?(state)
        }
    }

    private var injector: TextInjector?
    private var prebuffer: AudioPrebuffer?
    private var audioForwarder: AudioChunkForwarder?
    private var eventTask: Task<Void, Never>?
    private var latestProjection: ASRProjection?
    private var asrStreamEnded = false
    private var finishSent = false
    private var asrReady = false
    private var audioRecovering = false
    private var sessionID: UUID?
    private let finishTimeoutNanoseconds: UInt64
    private let keyboardSmoothing: KeyboardSmoothingConfiguration
    private let pacingClock: KeyboardPacingClock
    private var discardCount = 0
    private var errorCount = 0
    private var degradationWasLogged = false
    private var asrFinalizationPhase: ASRFinalizationPhase = .listening

    init(
        asr: RealtimeASRClient,
        audio: AudioCapture,
        textTarget: TextTarget,
        settingsStore: SettingsStore,
        credentialStore: CredentialStore,
        logger: SessionLogger? = nil,
        finishTimeoutNanoseconds: UInt64 = 3_000_000_000,
        keyboardSmoothing: KeyboardSmoothingConfiguration = .live,
        pacingClock: KeyboardPacingClock? = nil,
        onStateChange: @escaping (SessionState) -> Void
    ) {
        self.asr = asr
        self.audio = audio
        self.textTarget = textTarget
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.logger = logger ?? SessionLogger(enabled: { false })
        self.finishTimeoutNanoseconds = finishTimeoutNanoseconds
        self.keyboardSmoothing = keyboardSmoothing
        self.pacingClock = pacingClock ?? ContinuousKeyboardPacingClock()
        self.onStateChange = onStateChange
    }

    func begin() async throws {
        guard state == .idle else { throw SessionError.busy }
        let id = UUID()
        sessionID = id
        setState(.connecting)
        do {
            guard let credentials = try credentialStore.load() else {
                throw SessionError.credentialsMissing
            }
            try await ensureMicrophonePermission()

            let settings = settingsStore.load()
            let newInjector = TextInjector(
                target: textTarget,
                keyboardSmoothing: keyboardSmoothing,
                pacingClock: pacingClock,
                safeCopyEnabled: settings.safeCopyEnabled
            )
            do {
                try newInjector.begin()
            } catch {
                throw SessionError.noTextTarget
            }
            injector = newInjector
            latestProjection = nil
            asrStreamEnded = false
            finishSent = false
            asrReady = false
            audioRecovering = false
            discardCount = 0
            errorCount = 0
            degradationWasLogged = false
            asrFinalizationPhase = .listening

            let wordInfo = settings.engineModelType == TencentEnginePreset.largeV2.rawValue ? 0 : 1
            let configuration = TencentSessionConfiguration(
                appID: credentials.appID,
                secretID: credentials.secretID,
                secretKey: credentials.secretKey,
                engineModelType: settings.engineModelType,
                voiceID: UUID().uuidString,
                needVAD: 1,
                wordInfo: wordInfo
            )
            let buffer = AudioPrebuffer()
            let forwarder = AudioChunkForwarder()
            prebuffer = buffer
            audioForwarder = forwarder
            try await audio.start(
                sessionID: id,
                onChunk: { [weak self, weak buffer] chunk in
                guard let buffer else { return }
                forwarder.submit { [weak self, weak buffer] in
                    guard let buffer else { return }
                    do {
                        try await buffer.append(chunk)
                    } catch {
                        await self?.handleAudioError(error, sessionID: id)
                    }
                }
                },
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleAudioEvent(event)
                    }
                }
            )
            log(event: "audio_capture_started")
            guard sessionID == id,
                  state == .connecting || state == .recovering || state == .listening
            else { throw SessionError.cancelled }

            let stream = try await asr.start(configuration: configuration)
            log(event: "asr_started")
            guard sessionID == id,
                  state == .connecting || state == .recovering || state == .listening
            else { throw SessionError.cancelled }
            try await buffer.attach { [weak self, asr] chunk in
                do {
                    try await asr.sendAudio(chunk)
                } catch {
                    await self?.handleAudioError(error, sessionID: id)
                    throw error
                }
            }
            guard sessionID == id,
                  state == .connecting || state == .recovering || state == .listening
            else { throw SessionError.cancelled }
            asrReady = true
            if !audioRecovering && (state == .connecting || state == .recovering) {
                setState(.listening)
                log(event: "started")
            }
            eventTask = Task { [weak self] in
                do {
                    for try await update in stream {
                        if Task.isCancelled { return }
                        self?.process(update, sessionID: id)
                    }
                } catch {
                    self?.handleASRError(error, sessionID: id)
                }
            }
        } catch {
            if case SessionError.cancelled = error {
                guard sessionID == id else { return }
                await cleanUpAfterFailedStart(sessionID: id)
                if sessionID == nil {
                    setState(.idle)
                }
                return
            }
            guard sessionID == id else { return }
            // Keep startup failures diagnosable after cleanup without writing
            // credentials, signed URLs, audio, or recognized text.
            log(event: "startup_error", error: error, sessionID: id)
            await cleanUpAfterFailedStart(sessionID: id)
            if sessionID == nil {
                setState(.error(error.localizedDescription))
            }
            throw error
        }
    }

    func setStateObserver(_ observer: @escaping (SessionState) -> Void) {
        stateObserver = observer
    }

    func end() async throws {
        guard state != .idle else { return }
        if case .error = state {
            cancel()
            return
        }
        guard state != .stopping else { return }
        // Startup still owns setup until the connection and prebuffer are ready.
        // Do not run graceful end concurrently with cancelled-start cleanup.
        guard asrReady else {
            cancel()
            return
        }
        guard let endingSessionID = sessionID else {
            cancel()
            return
        }
        setState(.stopping)
        asrFinalizationPhase = .finalizing
        log(event: "stop_requested")
        injector?.beginFinalization()
        log(event: "asr_finalization_started")
        logDegradationIfNeeded(projection: latestProjection)
        let currentAudioForwarder = audioForwarder
        audio.stop()
        log(event: "audio_capture_stop_requested")
        currentAudioForwarder?.stopAccepting()
        await currentAudioForwarder?.drain()
        log(event: "audio_capture_drained")
        var finishTask: Task<Void, Never>?
        if !finishSent {
            finishSent = true
            log(event: "asr_finish_requested")
            // Sending the end marker must not block the UI if the socket is stuck.
            finishTask = Task { [asr] in try? await asr.finish() }
        }

        var streamCompleted = true
        if let eventTask {
            streamCompleted = await waitForEventTask(
                eventTask,
                timeoutNanoseconds: finishTimeoutNanoseconds
            )
            if !streamCompleted {
                eventTask.cancel()
                asr.cancel()
                log(event: "finish_timeout")
                log(event: "asr_finalization_timeout")
            } else if asrStreamEnded {
                log(event: "asr_finalization_stream_ended")
            }
        }
        finishTask?.cancel()

        guard sessionID == endingSessionID, state == .stopping else { return }

        if let injector {
            do {
                try await injector.finish(finalText: latestProjection?.text ?? "")
                asrFinalizationPhase = .finalized
                logDegradationIfNeeded(projection: latestProjection)
                log(event: streamCompleted ? "finished" : "finished_timeout", projection: latestProjection)
                injector.cancel()
            } catch {
                logDegradationIfNeeded(projection: latestProjection)
                log(event: "finish_error", error: error)
                setState(.error(error.localizedDescription))
                resetSession()
                throw error
            }
        } else {
            injector?.cancel()
        }
        asr.cancel()
        await prebuffer?.clear()
        eventTask?.cancel()
        resetSession()
        setState(.idle)
    }

    func cancel() {
        asrFinalizationPhase = .hardStopped
        log(event: "cancel_requested")
        audioForwarder?.cancel()
        audio.stop()
        asr.cancel()
        eventTask?.cancel()
        eventTask = nil
        Task { [prebuffer] in await prebuffer?.clear() }
        injector?.cancel()
        resetSession()
        setState(.idle)
    }

    private func process(_ update: ASRUpdate, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        guard state == .listening || state == .stopping || state == .recovering else { return }
        if update.isStreamEnded {
            asrStreamEnded = true
            if let projection = projectionAccumulator.apply(update) {
                latestProjection = projection
                injector?.apply(projection: projection)
                log(event: "stream_ended", update: update, projection: projection)
                logDegradationIfNeeded(update: update, projection: projection)
            }
            return
        }
        guard let projection = projectionAccumulator.apply(update) else {
            discardCount += 1
            log(event: "discarded", update: update, projection: latestProjection)
            return
        }
        latestProjection = projection
        injector?.apply(projection: projection)
        log(event: projection.isFinal ? "final" : "partial", update: update, projection: projection)
        logDegradationIfNeeded(update: update, projection: projection)
    }

    private var projectionAccumulator = ASRProjectionAccumulator()

    private func logDegradationIfNeeded(
        update: ASRUpdate? = nil,
        projection: ASRProjection? = nil
    ) {
        guard let injector,
              ["safe_copy", "disabled_after_error"].contains(injector.modeDescription),
              !degradationWasLogged else { return }
        degradationWasLogged = true
        log(
            event: injector.modeDescription == "safe_copy" ? "safe_copy" : "input_error",
            update: update,
            projection: projection,
            failureCode: injector.degradationCode,
            failureMessage: injector.degradationReason
        )
    }

    private func handleASRError(_ error: Error, sessionID: UUID? = nil) {
        if let sessionID, self.sessionID != sessionID { return }
        guard state == .connecting || state == .listening || state == .recovering else { return }
        asrFinalizationPhase = .hardStopped
        audio.stop()
        asr.cancel()
        errorCount += 1
        log(event: "error", error: error)
        let finalProjection = latestProjection
        do {
            try injector?.finishImmediately(finalText: finalProjection?.text ?? "")
        } catch {
            errorCount += 1
            log(event: "finish_error", projection: finalProjection, error: error)
        }
        logDegradationIfNeeded(projection: finalProjection)
        let currentPrebuffer = prebuffer
        eventTask?.cancel()
        resetSession()
        setState(.error(error.localizedDescription))
        Task { await currentPrebuffer?.clear() }
    }

    private func handleAudioError(_ error: Error, sessionID: UUID? = nil) {
        handleASRError(error, sessionID: sessionID)
    }

    private func handleAudioEvent(_ event: AudioCaptureEvent) {
        guard sessionID == event.sessionID else { return }
        switch event.kind {
        case let .interrupted(previousFormat):
            guard state == .connecting || state == .listening || state == .recovering else { return }
            audioRecovering = true
            if state != .recovering {
                setState(.recovering)
            }
            log(
                event: "audio_capture_interrupted",
                failureCode: "microphone_configuration_changed",
                metadata: previousFormat?.metadata ?? [:],
                sessionID: event.sessionID
            )
        case let .recovering(attempt):
            guard state == .connecting || state == .listening || state == .recovering else { return }
            audioRecovering = true
            if state != .recovering {
                setState(.recovering)
            }
            log(
                event: "audio_capture_recovery_attempt",
                metadata: ["attempt": String(attempt)],
                sessionID: event.sessionID
            )
        case let .recovered(format, durationNanoseconds):
            guard state == .recovering else { return }
            audioRecovering = false
            if asrReady {
                setState(.listening)
            }
            var metadata = format.metadata
            metadata["duration_ms"] = String(durationNanoseconds / 1_000_000)
            log(
                event: "audio_capture_recovered",
                metadata: metadata,
                sessionID: event.sessionID
            )
        case let .failed(error):
            guard state == .connecting || state == .listening || state == .recovering else { return }
            handleASRError(error, sessionID: event.sessionID)
        }
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted, .notDetermined:
            // Permission requests are intentionally owned by the explicit
            // install/request script. Starting a recording must never trigger
            // a new macOS prompt or re-request a permission the user denied.
            throw SessionError.microphoneDenied
        @unknown default:
            throw SessionError.microphoneDenied
        }
    }

    private func cleanUpAfterFailedStart(sessionID expectedSessionID: UUID) async {
        guard sessionID == expectedSessionID else { return }
        audioForwarder?.cancel()
        audio.stop()
        asr.cancel()
        await prebuffer?.clear()
        eventTask?.cancel()
        eventTask = nil
        injector?.cancel()
        resetSession()
    }

    private func resetSession() {
        injector = nil
        prebuffer = nil
        audioForwarder = nil
        eventTask = nil
        latestProjection = nil
        asrStreamEnded = false
        finishSent = false
        asrReady = false
        audioRecovering = false
        sessionID = nil
        discardCount = 0
        errorCount = 0
        degradationWasLogged = false
        asrFinalizationPhase = .listening
        projectionAccumulator = ASRProjectionAccumulator()
    }

    private func setState(_ newState: SessionState) {
        state = newState
    }

    private func waitForEventTask(
        _ task: Task<Void, Never>,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return false
                } catch {
                    return false
                }
            }
            let completed = await group.next() ?? false
            if !completed {
                task.cancel()
            }
            group.cancelAll()
            return completed
        }
    }

    private func log(
        event: String,
        update: ASRUpdate? = nil,
        projection: ASRProjection? = nil,
        error: Error? = nil,
        failureCode: String? = nil,
        failureMessage: String? = nil,
        metadata: [String: String] = [:],
        sessionID overrideSessionID: UUID? = nil
    ) {
        guard let sessionID = overrideSessionID ?? sessionID else { return }
        let stateName: String = switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .listening: "listening"
        case .recovering: "recovering"
        case .stopping: "stopping"
        case .error: "error"
        }
        let errorCode: Int?
        if let error, case let TencentASRError.server(code, _) = error {
            errorCode = code
        } else {
            errorCode = nil
        }
        let resolvedFailureCode = failureCode ?? error.map(DiagnosticErrorFormatter.code(for:))
        let resolvedFailureMessage = failureMessage ?? error.map(DiagnosticErrorFormatter.message(for:))
        var metadata = [
            "sourceBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "sourceAppPath": Bundle.main.bundlePath,
            "writeCountMeaning": "submission_call_not_target_confirmation",
            "asrFinalizationPhase": asrFinalizationPhase.rawValue
        ]
        if event == "safe_copy" || event == "input_error",
           let degradationOccurredAt = injector?.degradationOccurredAt,
           let degradationOccurredMonotonicMilliseconds = injector?.degradationOccurredMonotonicMilliseconds {
            metadata["failureOccurredAt"] = Self.iso8601(degradationOccurredAt)
            metadata["failureOccurredMonotonicMilliseconds"] = String(degradationOccurredMonotonicMilliseconds)
            metadata["degradationRecordedAt"] = Self.iso8601(Date())
            metadata["degradationRecordedOnASREvent"] = String(update != nil)
            metadata["degradationRecordTiming"] = update == nil
                ? "lifecycle_event"
                : "asr_event_or_following_update"
        }
        let entry = SessionLogEntry(
            timestamp: Date(),
            sessionID: sessionID,
            event: event,
            state: stateName,
            injectionMode: injector?.modeDescription,
            targetApplicationName: injector?.targetApplication?.name,
            targetApplicationBundleIdentifier: injector?.targetApplication?.bundleIdentifier,
            targetApplicationProcessID: injector?.targetApplication?.processIdentifier,
            sequence: update?.sequence,
            sliceType: update?.sliceType,
            wireFinal: update?.wireFinal,
            segmentID: update?.segmentID,
            segmentPhase: update?.phase.rawValue,
            committedLength: projection?.committedText.count,
            activeLength: projection?.activeSegmentText.count,
            renderedLength: projection?.text.count,
            revision: projection?.revision,
            writeCount: injector?.writeCount,
            backspaceCount: injector?.backspaceCount,
            deepReplacementCount: injector?.deepReplacementCount,
            maximumTrailingReplacementLength: injector?.maximumTrailingReplacementLength,
            discardCount: discardCount,
            errorCount: errorCount + (injector?.errorCount ?? 0),
            errorCode: errorCode,
            failureCode: resolvedFailureCode,
            failureMessage: resolvedFailureMessage,
            metadata: metadata
        )
        try? logger.append(entry)
        for diagnostic in injector?.drainDiagnostics() ?? [] {
            var fields = diagnostic.fields
            fields.merge(entry.metadata) { _, new in new }
            fields["diagnosticRecordedAt"] = Self.iso8601(Date())
            try? logger.append(SessionLogEntry(
                timestamp: diagnostic.timestamp, sessionID: sessionID,
                event: diagnostic.event, state: stateName, injectionMode: injector?.modeDescription,
                targetApplicationName: injector?.targetApplication?.name,
                targetApplicationBundleIdentifier: injector?.targetApplication?.bundleIdentifier,
                targetApplicationProcessID: injector?.targetApplication?.processIdentifier,
                sequence: update?.sequence,
                sliceType: update?.sliceType,
                wireFinal: update?.wireFinal,
                segmentID: update?.segmentID ?? projection?.activeSegmentID,
                segmentPhase: update?.isStreamEnded == true
                    ? "streamEnd"
                    : (update?.phase.rawValue ?? (projection?.isFinal == true ? "final" : nil)),
                committedLength: projection?.committedText.count,
                activeLength: projection?.activeSegmentText.count,
                renderedLength: projection?.text.count,
                revision: projection?.revision,
                writeCount: injector?.writeCount,
                backspaceCount: injector?.backspaceCount,
                deepReplacementCount: injector?.deepReplacementCount,
                maximumTrailingReplacementLength: injector?.maximumTrailingReplacementLength,
                discardCount: discardCount,
                errorCount: errorCount + (injector?.errorCount ?? 0),
                failureCode: injector?.degradationCode,
                metadata: fields
            ))
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

}

actor AudioPrebuffer {
    private let maxChunkCount = 5
    private var pending: [Data] = []
    private var sink: (@Sendable (Data) async throws -> Void)?

    func append(_ data: Data) async throws {
        if let sink {
            try await sink(data)
            return
        }
        pending.append(data)
        if pending.count > maxChunkCount { pending.removeFirst() }
    }

    func attach(_ sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        self.sink = sink
        let buffered = pending
        pending.removeAll(keepingCapacity: true)
        for chunk in buffered { try await sink(chunk) }
    }

    func clear() {
        pending.removeAll(keepingCapacity: true)
        sink = nil
    }
}
