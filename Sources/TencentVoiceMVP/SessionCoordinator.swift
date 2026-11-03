import AVFoundation
import AppKit
import Foundation

enum SessionState: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case recovering
    case stopping
    case stoppingUnresponsive
    case error(String)
}

enum SessionError: Error, LocalizedError {
    case credentialsMissing
    case microphoneDenied
    case noTextTarget
    case busy
    case cancelled
    case recognitionEnded
    case finalizationIncomplete

    var errorDescription: String? {
        switch self {
        case .credentialsMissing: return "尚未配置腾讯云凭证，请打开设置"
        case .microphoneDenied: return "麦克风权限未开启"
        case .noTextTarget: return "没有找到可输入的文本目标"
        case .busy: return "上一段语音还没有结束"
        case .cancelled: return "语音会话已取消"
        case .recognitionEnded: return "识别连接意外结束，录音已停止；已收到的文字已保留，请重新开始录音"
        case .finalizationIncomplete: return "录音已停止，但最后的识别尚未确认完成；已收到的文字已保留"
        }
    }
}

private enum ASRFinalizationOutcome: Equatable {
    case completed
    case failed(String)
    case userEnded
    case cancelled
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
    private struct PendingKeyboardCompletion {
        let token: UUID
        let sessionID: UUID
        let operationGeneration: UInt64
        let deadlineNanoseconds: UInt64
        let finalText: String
        let injector: TextInjector
        let evidenceStartedAt: UInt64
        let evidenceRecorder: @Sendable (ASRFinalizationEvidenceEvent) -> Void
    }

    private static let pendingCompletionWindowNanoseconds: UInt64 = 60_000_000_000
    let asr: RealtimeASRClient
    let audio: AudioCapture
    let textTarget: TextTarget
    let settingsStore: SettingsStore
    let credentialStore: CredentialStore
    let logger: SessionLogger
    private let onSessionStart: (UUID) -> Void
    private let onStateChange: (SessionState) -> Void
    private let onPendingCompletionChange: (Bool) -> Void
    private var onFinalizationEvidence: @Sendable (ASRFinalizationEvidenceEvent) -> Void
    private let finalizationEvidenceRecorder: (() -> @Sendable (ASRFinalizationEvidenceEvent) -> Void)?
    private var stateObserver: ((SessionState) -> Void)?
    private(set) var state: SessionState = .idle

    private var injector: TextInjector?
    private var prebuffer: AudioPrebuffer?
    private var audioForwarder: AudioChunkForwarder?
    private var eventTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var pendingCompletionTask: Task<Void, Never>?
    private var pendingKeyboardCompletion: PendingKeyboardCompletion?
    private var applicationActivationObserver: NSObjectProtocol?
    private var operationGeneration: UInt64 = 0
    private var audioProgress: AudioPipelineProgress?
    private var latestProjection: ASRProjection?
    private var asrStreamEnded = false
    private var finishSent = false
    private var asrReady = false
    private var audioRecovering = false
    private var sessionID: UUID?
    private let finalizationWarningNanoseconds: UInt64
    private let finalizationClock: KeyboardPacingClock
    private var finalizationOutcome: ASRFinalizationOutcome?
    private var finalizationContinuation: CheckedContinuation<ASRFinalizationOutcome, Never>?
    private var finalizationWarningTask: Task<Void, Never>?
    private var finalizationProgressGeneration: UInt64 = 0
    private var finalizationFinishSentSuccessfully = false
    private var finalizationOperationGeneration: UInt64?
    private var finalizationAudioUploadCompleted = false
    private var sessionStartedAtUptimeNanoseconds: UInt64?
    private let keyboardSmoothing: KeyboardSmoothingConfiguration
    private let pacingClock: KeyboardPacingClock
    private let monotonicNow: () -> UInt64
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
        finalizationWarningNanoseconds: UInt64 = 30_000_000_000,
        keyboardSmoothing: KeyboardSmoothingConfiguration = .live,
        pacingClock: KeyboardPacingClock? = nil,
        finalizationClock: KeyboardPacingClock? = nil,
        monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        onSessionStart: @escaping (UUID) -> Void = { _ in },
        onPendingCompletionChange: @escaping (Bool) -> Void = { _ in },
        onFinalizationEvidence: @escaping @Sendable (ASRFinalizationEvidenceEvent) -> Void = { _ in },
        finalizationEvidenceRecorder: (() -> @Sendable (ASRFinalizationEvidenceEvent) -> Void)? = nil,
        onStateChange: @escaping (SessionState) -> Void
    ) {
        self.asr = asr
        self.audio = audio
        self.textTarget = textTarget
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.logger = logger ?? SessionLogger(enabled: { false })
        self.finalizationWarningNanoseconds = finalizationWarningNanoseconds
        self.keyboardSmoothing = keyboardSmoothing
        self.pacingClock = pacingClock ?? ContinuousKeyboardPacingClock()
        self.finalizationClock = finalizationClock ?? ContinuousKeyboardPacingClock()
        self.monotonicNow = monotonicNow
        self.onSessionStart = onSessionStart
        self.onPendingCompletionChange = onPendingCompletionChange
        self.onFinalizationEvidence = onFinalizationEvidence
        self.finalizationEvidenceRecorder = finalizationEvidenceRecorder
        self.onStateChange = onStateChange
    }

    func begin() async throws {
        guard state == .idle else { throw SessionError.busy }
        cancelPendingCompletion(reason: "new_recording_started")
        operationGeneration &+= 1
        let id = UUID()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        sessionStartedAtUptimeNanoseconds = startedAt
        if let finalizationEvidenceRecorder {
            onFinalizationEvidence = finalizationEvidenceRecorder()
        }
        finalizationAudioUploadCompleted = false
        sessionID = id
        onSessionStart(id)
        setState(.connecting)
        recordFinalizationEvidence(kind: .sessionStarted, stage: .recording)
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
                alwaysSaveVoiceContent: settings.alwaysSaveVoiceContent
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
            let progress = AudioPipelineProgress()
            let evidenceRecorder = onFinalizationEvidence
            let evidenceOperationGeneration = operationGeneration
            audioProgress = progress
            prebuffer = buffer
            audioForwarder = forwarder
            try await audio.start(
                sessionID: id,
                onChunk: { [weak self, weak buffer] chunk in
                guard let buffer else { return }
                progress.captured(pcm: chunk)
                let now = DispatchTime.now().uptimeNanoseconds
                evidenceRecorder(ASRFinalizationEvidenceEvent(
                    recordedAt: Date(),
                    elapsedMilliseconds: now >= startedAt ? (now - startedAt) / 1_000_000 : 0,
                    sessionID: id,
                    operationGeneration: evidenceOperationGeneration,
                    kind: .audioCaptured,
                    stage: .recording,
                    audioProgress: progress.finalizationEvidenceSnapshot(),
                    recognitionSequence: nil,
                    recognitionPhase: nil,
                    recognizedCharacterCount: nil,
                    finalSignalReceived: nil,
                    failureCategory: nil,
                    errorCode: nil,
                    textDeliveryStatus: nil
                ))
                forwarder.submit { [weak self, weak buffer] in
                    guard let buffer else { return }
                    do {
                        try await buffer.append(chunk)
                    } catch {
                        await self?.handleAudioError(error, sessionID: id)
                    }
                }
                },
                onLevel: { level in
                    progress.observed(level: level)
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
            progress.setCapturing(true)
            stateObserver?(state)

            let stream = try await asr.start(configuration: configuration)
            log(event: "asr_started")
            guard sessionID == id,
                  state == .connecting || state == .recovering || state == .listening
            else { throw SessionError.cancelled }
            try await buffer.attach { [weak self, asr, evidenceRecorder] chunk in
                do {
                    try await asr.sendAudio(chunk)
                    progress.uploaded(byteCount: chunk.count)
                    let now = DispatchTime.now().uptimeNanoseconds
                    evidenceRecorder(ASRFinalizationEvidenceEvent(
                        recordedAt: Date(),
                        elapsedMilliseconds: now >= startedAt ? (now - startedAt) / 1_000_000 : 0,
                        sessionID: id,
                        operationGeneration: evidenceOperationGeneration,
                        kind: .audioUploaded,
                        stage: .uploadingTail,
                        audioProgress: progress.finalizationEvidenceSnapshot(),
                        recognitionSequence: nil,
                        recognitionPhase: nil,
                        recognizedCharacterCount: nil,
                        finalSignalReceived: nil,
                        failureCategory: nil,
                        errorCode: nil,
                        textDeliveryStatus: nil
                    ))
                    await self?.noteFinalizationProgress(sessionID: id, reason: "audio_uploaded")
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
            startProgressObservation(sessionID: id)
            eventTask = Task { [weak self] in
                do {
                    for try await update in stream {
                        if Task.isCancelled { return }
                        self?.process(update, sessionID: id)
                    }
                    self?.handleASRError(SessionError.recognitionEnded, sessionID: id)
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

    func recordingDisplaySnapshot() -> RecordingDisplaySnapshot {
        RecordingDisplaySnapshot(
            sessionID: sessionID,
            state: state,
            audio: audioProgress?.captureMetrics() ?? .empty,
            isCapturing: audioProgress?.captureState() ?? false
        )
    }

    func refreshDiagnosticCollectionSettings() {
        (textTarget as? AXTextTarget)?.refreshDiagnosticCollectionSettings()
    }

    func end() async throws {
        guard state != .idle else { return }
        if case .error = state {
            cancel()
            return
        }
        guard state != .stopping, state != .stoppingUnresponsive else { return }
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
        let stopRequestedAtNanoseconds = monotonicNow()
        let evidenceStartedAt = sessionStartedAtUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
        let evidenceRecorder = onFinalizationEvidence
        let endingOperationGeneration = operationGeneration
        // Set the guard immediately, but notify observers only after capture stops.
        state = .stopping
        asrFinalizationPhase = .finalizing
        finalizationOperationGeneration = endingOperationGeneration
        let currentAudioForwarder = audioForwarder
        // Stop input before logging, target reconciliation, or any async work.
        audio.stop()
        audioProgress?.setCapturing(false)
        setState(.stopping)
        startFinalizationProgressWatch(endingSessionID)
        recordFinalizationEvidence(kind: .stopRequested, stage: .stoppingCapture)
        stateObserver?(state)
        log(event: "stop_requested")
        log(event: "audio_capture_stop_requested")
        injector?.beginFinalization()
        log(event: "asr_finalization_started")
        logDegradationIfNeeded(projection: latestProjection)
        // AudioCapture.stop() synchronously flushes the final partial PCM chunk.
        // Drain every callback accepted before stop before sending the end marker.
        currentAudioForwarder?.stopAccepting()
        await currentAudioForwarder?.drain()
        guard isCurrentFinalization(sessionID: endingSessionID, operationGeneration: endingOperationGeneration),
              state == .stopping || state == .stoppingUnresponsive
        else { return }
        log(event: "audio_capture_drained")
        if finalizationOutcome == nil {
            finalizationAudioUploadCompleted = true
            recordFinalizationEvidence(kind: .audioUploadCompleted, stage: .waitingForService)
        } else if !finalizationAudioUploadCompleted {
            recordFinalizationEvidence(
                kind: .audioUploadIncomplete,
                stage: finalizationOutcome == .userEnded ? .userEnded : .failed
            )
        }
        let finalizationOutcome = await waitForASRFinalization(
            sessionID: endingSessionID,
            operationGeneration: endingOperationGeneration
        )

        guard isCurrentFinalization(sessionID: endingSessionID, operationGeneration: endingOperationGeneration),
              state == .stopping || state == .stoppingUnresponsive
        else { return }

        let finalCompletionText = latestProjection?.text ?? ""
        var injectorAwaitingTargetReturn: TextInjector?
        var visibleError: String?
        var textDeliveryStatus: ASRFinalizationEvidenceEvent.TextDeliveryStatus = .notAttempted
        if let injector {
            do {
                try await injector.finish(finalText: finalCompletionText)
                guard isCurrentFinalization(sessionID: endingSessionID, operationGeneration: endingOperationGeneration)
                else { return }
                if injector.isAwaitingTargetReturn {
                    textDeliveryStatus = .waitingForTarget
                    injectorAwaitingTargetReturn = injector
                    logger.recordDiagnosticAction(
                        "input_waiting_for_target_return",
                        sessionID: endingSessionID,
                        fields: ["deadlineMilliseconds": "60000", "operationGeneration": String(operationGeneration)]
                    )
                } else {
                    textDeliveryStatus = deliveryStatus(for: injector, finalText: finalCompletionText)
                    injector.cancel()
                }
            } catch {
                guard isCurrentFinalization(sessionID: endingSessionID, operationGeneration: endingOperationGeneration)
                else { return }
                logDegradationIfNeeded(projection: latestProjection)
                log(event: "finish_error", error: error)
                visibleError = error.localizedDescription
                textDeliveryStatus = .failed
            }
        } else {
            injector?.cancel()
        }
        recordFinalizationEvidence(
            kind: .textDeliveryResult,
            stage: .writingText,
            failureCategory: textDeliveryStatus == .failed ? .textDelivery : nil,
            textDeliveryStatus: textDeliveryStatus
        )

        switch finalizationOutcome {
        case .completed:
            asrFinalizationPhase = .finalized
            log(event: "asr_finalization_completed", projection: latestProjection)
        case let .failed(message):
            asrFinalizationPhase = .hardStopped
            visibleError = "录音已停止，收尾未完成：\(message)"
            log(event: "asr_finalization_error", projection: latestProjection,
                failureCode: "asr_finalization_incomplete")
        case .cancelled:
            asrFinalizationPhase = .hardStopped
            log(event: "asr_finalization_cancelled", projection: latestProjection)
        case .userEnded:
            asrFinalizationPhase = .hardStopped
            visibleError = SessionError.finalizationIncomplete.localizedDescription
            log(event: "asr_finalization_user_ended_wait", projection: latestProjection,
                failureCode: "asr_finalization_user_ended")
        }
        logAudioProgress()
        asr.cancel()
        await prebuffer?.clear()
        guard isCurrentFinalization(sessionID: endingSessionID, operationGeneration: endingOperationGeneration)
        else { return }
        eventTask?.cancel()
        finalizationWarningTask?.cancel()
        finalizationWarningTask = nil
        resetSession()
        if let visibleError {
            setState(.error(visibleError))
        } else {
            setState(.idle)
        }
        if let injectorAwaitingTargetReturn {
            let pending = PendingKeyboardCompletion(
                token: UUID(),
                sessionID: endingSessionID,
                operationGeneration: operationGeneration,
                deadlineNanoseconds: stopRequestedAtNanoseconds &+ Self.pendingCompletionWindowNanoseconds,
                finalText: finalCompletionText,
                injector: injectorAwaitingTargetReturn,
                evidenceStartedAt: evidenceStartedAt,
                evidenceRecorder: evidenceRecorder
            )
            pendingKeyboardCompletion = pending
            onPendingCompletionChange(true)
            installApplicationActivationObserverIfNeeded()
            startPendingCompletionObservation(token: pending.token)
        }
    }

    func cancel() {
        if let sessionID {
            recordFinalizationEvidence(kind: .sessionCancelled, stage: .cancelled)
            if !finalizationAudioUploadCompleted {
                recordFinalizationEvidence(kind: .audioUploadIncomplete, stage: .cancelled)
            }
            resolveASRFinalization(.cancelled, sessionID: sessionID)
        }
        cancelPendingCompletion(reason: "session_cancelled")
        asrFinalizationPhase = .hardStopped
        log(event: "cancel_requested")
        logAudioProgress()
        audioForwarder?.cancel()
        audio.stop()
        audioProgress?.setCapturing(false)
        asr.cancel()
        finishTask?.cancel()
        eventTask?.cancel()
        eventTask = nil
        Task { [prebuffer] in await prebuffer?.clear() }
        injector?.cancel()
        resetSession()
        setState(.idle)
    }

    func endFinalizationWaitPreservingText() {
        guard state == .stopping || state == .stoppingUnresponsive,
              finalizationOutcome == nil, let sessionID else { return }
        log(event: "asr_finalization_user_ended_wait")
        recordFinalizationEvidence(kind: .userEndedWait, stage: .userEnded)
        if !finalizationAudioUploadCompleted {
            recordFinalizationEvidence(kind: .audioUploadIncomplete, stage: .userEnded)
        }
        audioForwarder?.cancel()
        asr.cancel()
        finishTask?.cancel()
        eventTask?.cancel()
        resolveASRFinalization(.userEnded, sessionID: sessionID)
    }

    private func process(_ update: ASRUpdate, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        guard finalizationOutcome == nil else { return }
        guard state == .listening || state == .stopping || state == .stoppingUnresponsive || state == .recovering else { return }
        let recognitionObservedAt = Date()
        let recognitionMonotonic = TextInputDiagnosticClock.milliseconds()
        audioProgress?.receivedRecognitionUpdate()
        if update.isStreamEnded {
            asrStreamEnded = true
            recordFinalizationEvidence(
                kind: .serviceFinalSignalReceived,
                stage: .writingText,
                update: update,
                finalSignalReceived: true
            )
            noteFinalizationProgress(sessionID: sessionID, reason: "stream_ended")
            if let projection = projectionAccumulator.apply(update) {
                latestProjection = projection
                injector?.apply(projection: projection)
                log(event: "stream_ended", update: update, projection: projection,
                    recognitionObservation: (recognitionObservedAt, recognitionMonotonic))
                logDegradationIfNeeded(update: update, projection: projection)
            }
            resolveCompletedFinalizationIfReady(sessionID: sessionID)
            return
        }
        recordFinalizationEvidence(
            kind: .recognitionUpdate,
            stage: state == .stopping || state == .stoppingUnresponsive ? .waitingForService : .recording,
            update: update,
            finalSignalReceived: update.wireFinal
        )
        guard let projection = projectionAccumulator.apply(update) else {
            discardCount += 1
            log(event: "discarded", update: update, projection: latestProjection,
                recognitionObservation: (recognitionObservedAt, recognitionMonotonic))
            return
        }
        let previousProjection = latestProjection
        let meaningfulProgress = previousProjection?.text != projection.text
            || previousProjection?.activeSegmentID != projection.activeSegmentID
            || previousProjection?.isFinal != projection.isFinal
        latestProjection = projection
        injector?.apply(projection: projection)
        log(event: projection.isFinal ? "final" : "partial", update: update, projection: projection,
            recognitionObservation: (recognitionObservedAt, recognitionMonotonic))
        logDegradationIfNeeded(update: update, projection: projection)
        if meaningfulProgress {
            noteFinalizationProgress(sessionID: sessionID, reason: projection.isFinal ? "segment_final" : "recognition_changed")
        }
    }

    private var projectionAccumulator = ASRProjectionAccumulator()

    private func logDegradationIfNeeded(
        update: ASRUpdate? = nil,
        projection: ASRProjection? = nil
    ) {
        guard let injector,
              injector.modeDescription == "safe_copy",
              !degradationWasLogged else { return }
        degradationWasLogged = true
        log(
            event: "safe_copy",
            update: update,
            projection: projection,
            failureCode: injector.degradationCode,
            failureMessage: injector.degradationReason
        )
    }

    private func handleASRError(_ error: Error, sessionID: UUID? = nil) {
        if let sessionID, self.sessionID != sessionID { return }
        if state == .stopping || state == .stoppingUnresponsive {
            if asrStreamEnded,
               let sessionError = error as? SessionError,
               case .recognitionEnded = sessionError {
                return
            }
            guard let currentSessionID = self.sessionID else { return }
            let isUnexpectedClosure = (error as? SessionError).map {
                if case .recognitionEnded = $0 { return true }
                return false
            } ?? false
            handleFinalizationError(
                error,
                sessionID: currentSessionID,
                kind: isUnexpectedClosure ? .streamClosedWithoutFinal : .receiveFailed,
                failureCategory: isUnexpectedClosure ? .streamClosedWithoutFinal : .asrReceive
            )
            return
        }
        guard state == .connecting || state == .listening || state == .recovering else { return }
        asrFinalizationPhase = .hardStopped
        audioForwarder?.cancel()
        audio.stop()
        audioProgress?.setCapturing(false)
        asr.cancel()
        errorCount += 1
        recordFinalizationEvidence(
            kind: .receiveFailed,
            stage: .failed,
            failureCategory: .asrReceive,
            error: error
        )
        log(event: "error", error: error)
        let finalProjection = latestProjection
        do {
            try injector?.finishImmediately(finalText: finalProjection?.text ?? "")
        } catch {
            errorCount += 1
            log(event: "finish_error", projection: finalProjection, error: error)
        }
        recordFinalizationEvidence(
            kind: .textDeliveryResult,
            stage: .failed,
            textDeliveryStatus: injector?.modeDescription == "safe_copy" ? .safeCopy : .submittedUnconfirmed
        )
        logDegradationIfNeeded(projection: finalProjection)
        logAudioProgress()
        let currentPrebuffer = prebuffer
        eventTask?.cancel()
        resetSession()
        setState(.error(error.localizedDescription))
        Task { await currentPrebuffer?.clear() }
    }

    private func handleAudioError(_ error: Error, sessionID: UUID? = nil) {
        if state == .stopping || state == .stoppingUnresponsive,
           let currentSessionID = self.sessionID,
           sessionID == nil || sessionID == currentSessionID {
            handleFinalizationError(
                error,
                sessionID: currentSessionID,
                kind: .audioUploadFailed,
                failureCategory: .audioUpload
            )
            return
        }
        handleASRError(error, sessionID: sessionID)
    }

    private func handleAudioEvent(_ event: AudioCaptureEvent) {
        guard sessionID == event.sessionID else { return }
        switch event.kind {
        case let .interrupted(previousFormat):
            guard state == .connecting || state == .listening || state == .recovering else { return }
            audioRecovering = true
            audioProgress?.setCapturing(false)
            audioProgress?.resetWaveformWindow()
            if state != .recovering {
                setState(.recovering)
            } else {
                stateObserver?(state)
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
            audioProgress?.setCapturing(false)
            audioProgress?.resetWaveformWindow()
            if state != .recovering {
                setState(.recovering)
            } else {
                stateObserver?(state)
            }
            log(
                event: "audio_capture_recovery_attempt",
                metadata: ["attempt": String(attempt)],
                sessionID: event.sessionID
            )
        case let .recovered(format, durationNanoseconds):
            guard state == .recovering else { return }
            audioRecovering = false
            audioProgress?.setCapturing(true)
            if asrReady {
                setState(.listening)
            } else {
                stateObserver?(state)
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
        guard sessionID == expectedSessionID else { return }
        eventTask?.cancel()
        eventTask = nil
        injector?.cancel()
        resetSession()
    }

    private func resetSession() {
        progressTask?.cancel()
        progressTask = nil
        finalizationWarningTask?.cancel()
        finalizationWarningTask = nil
        finishTask?.cancel()
        finishTask = nil
        finalizationContinuation = nil
        finalizationOutcome = nil
        finalizationProgressGeneration = 0
        finalizationFinishSentSuccessfully = false
        finalizationOperationGeneration = nil
        finalizationAudioUploadCompleted = false
        sessionStartedAtUptimeNanoseconds = nil
        audioProgress = nil
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
        if pendingKeyboardCompletion == nil {
            removeApplicationActivationObserver()
        }
    }

    private func startProgressObservation(sessionID id: UUID) {
        progressTask?.cancel()
        installApplicationActivationObserverIfNeeded()
        progressTask = Task { [weak self] in
            var progressTicks = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch { return }
                guard let self, self.sessionID == id else { return }
                self.pollActiveTargetReturn()
                progressTicks += 1
                if progressTicks >= 10 {
                    progressTicks = 0
                    self.logAudioProgress()
                }
            }
        }
    }

    private func pollActiveTargetReturn() {
        guard let injector, injector.isAwaitingTargetReturn else { return }
        if injector.resumeTargetIfAvailable() {
            logger.recordDiagnosticAction("input_target_resumed", sessionID: sessionID, fields: [
                "operationGeneration": String(operationGeneration),
                "resumeSource": "periodic_target_check"
            ])
        }
    }

    func pollTargetAvailabilityForTesting() async {
        pollActiveTargetReturn()
        guard let pending = pendingKeyboardCompletion else { return }
        guard pending.operationGeneration == operationGeneration,
              pending.token == pendingKeyboardCompletion?.token else {
            cancelPendingCompletion(reason: "stale_operation_generation")
            return
        }
        guard monotonicNow() < pending.deadlineNanoseconds else {
            pending.injector.expirePendingCompletion()
            logger.recordDiagnosticAction("input_pending_completion_expired", sessionID: pending.sessionID, fields: [
                "operationGeneration": String(pending.operationGeneration)
            ])
            finishPendingCompletion(pending)
            return
        }
        do {
            let completed = try await pending.injector.finishPendingAfterTargetReturn(finalText: pending.finalText)
            guard pending.token == pendingKeyboardCompletion?.token else { return }
            if completed {
                logger.recordDiagnosticAction("input_target_resumed_after_stop", sessionID: pending.sessionID, fields: [
                    "operationGeneration": String(pending.operationGeneration),
                    "result": "completed_or_safely_stopped"
                ])
                finishPendingCompletion(pending)
            }
        } catch {
            logger.recordDiagnosticAction("input_target_resume_failed", sessionID: pending.sessionID, fields: [
                "operationGeneration": String(pending.operationGeneration),
                "failureCode": DiagnosticErrorFormatter.code(for: error)
            ])
            pending.injector.expirePendingCompletion()
            finishPendingCompletion(pending)
        }
    }

    func cancelPendingCompletion() {
        cancelPendingCompletion(reason: "user_cancelled")
    }

    private func startPendingCompletionObservation(token: UUID) {
        pendingCompletionTask?.cancel()
        pendingCompletionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch { return }
                guard let self, self.pendingKeyboardCompletion?.token == token else { return }
                await self.pollTargetAvailabilityForTesting()
            }
        }
    }

    private func finishPendingCompletion(_ pending: PendingKeyboardCompletion) {
        guard pendingKeyboardCompletion?.token == pending.token else { return }
        pendingCompletionTask?.cancel()
        pendingCompletionTask = nil
        pendingKeyboardCompletion = nil
        recordPendingTextDelivery(pending)
        pending.injector.cancel()
        onPendingCompletionChange(false)
        if sessionID == nil { removeApplicationActivationObserver() }
    }

    private func cancelPendingCompletion(reason: String) {
        guard let pending = pendingKeyboardCompletion else { return }
        pendingCompletionTask?.cancel()
        pendingCompletionTask = nil
        pendingKeyboardCompletion = nil
        logger.recordDiagnosticAction("input_pending_completion_cancelled", sessionID: pending.sessionID, fields: [
            "reason": reason,
            "operationGeneration": String(pending.operationGeneration)
        ])
        pending.injector.cancelPendingCompletion()
        recordPendingTextDelivery(pending)
        pending.injector.cancel()
        onPendingCompletionChange(false)
        if sessionID == nil { removeApplicationActivationObserver() }
    }

    private func installApplicationActivationObserverIfNeeded() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollTargetAvailabilityForTesting()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        guard let applicationActivationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
        self.applicationActivationObserver = nil
    }

    private func logAudioProgress() {
        guard let audioProgress else { return }
        log(event: "audio_pipeline_progress", metadata: audioProgress.metadata())
    }

    private func deliveryStatus(
        for injector: TextInjector,
        finalText: String
    ) -> ASRFinalizationEvidenceEvent.TextDeliveryStatus {
        if finalText.isEmpty { return .notAttempted }
        if injector.isAwaitingTargetReturn { return .waitingForTarget }
        if injector.modeDescription == "safe_copy" {
            return injector.hasCopiedFinalText(finalText) ? .safeCopy : .failed
        }
        return injector.finalTextWriteConfirmed ? .confirmed : .submittedUnconfirmed
    }

    private func recordPendingTextDelivery(_ pending: PendingKeyboardCompletion) {
        let now = DispatchTime.now().uptimeNanoseconds
        let status = deliveryStatus(for: pending.injector, finalText: pending.finalText)
        pending.evidenceRecorder(ASRFinalizationEvidenceEvent(
            recordedAt: Date(),
            elapsedMilliseconds: now >= pending.evidenceStartedAt ? (now - pending.evidenceStartedAt) / 1_000_000 : 0,
            sessionID: pending.sessionID,
            operationGeneration: pending.operationGeneration,
            kind: .textDeliveryResult,
            stage: .writingText,
            audioProgress: nil,
            recognitionSequence: nil,
            recognitionPhase: nil,
            recognizedCharacterCount: pending.finalText.count,
            finalSignalReceived: nil,
            failureCategory: status == .failed ? .textDelivery : nil,
            errorCode: nil,
            textDeliveryStatus: status
        ))
    }

    private func recordFinalizationEvidence(
        kind: ASRFinalizationEvidenceEvent.Kind,
        stage: ASRFinalizationEvidenceEvent.Stage,
        update: ASRUpdate? = nil,
        finalSignalReceived: Bool? = nil,
        failureCategory: ASRFinalizationEvidenceEvent.FailureCategory? = nil,
        error: Error? = nil,
        textDeliveryStatus: ASRFinalizationEvidenceEvent.TextDeliveryStatus? = nil
    ) {
        guard let sessionID, let sessionStartedAtUptimeNanoseconds else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let errorCode: Int?
        if let error, case let TencentASRError.server(code, _) = error {
            errorCode = code
        } else {
            errorCode = nil
        }
        onFinalizationEvidence(ASRFinalizationEvidenceEvent(
            recordedAt: Date(),
            elapsedMilliseconds: now >= sessionStartedAtUptimeNanoseconds
                ? (now - sessionStartedAtUptimeNanoseconds) / 1_000_000 : 0,
            sessionID: sessionID,
            operationGeneration: operationGeneration,
            kind: kind,
            stage: stage,
            audioProgress: audioProgress?.finalizationEvidenceSnapshot(),
            recognitionSequence: update?.sequence,
            recognitionPhase: update?.isStreamEnded == true ? nil : update?.phase,
            recognizedCharacterCount: update?.isStreamEnded == true ? nil : update?.segmentText.count,
            finalSignalReceived: finalSignalReceived ?? update?.wireFinal,
            failureCategory: failureCategory,
            errorCode: errorCode,
            textDeliveryStatus: textDeliveryStatus
        ))
    }

    private func setState(_ newState: SessionState) {
        state = newState
        onStateChange(state)
        stateObserver?(state)
    }

    private func waitForASRFinalization(
        sessionID: UUID,
        operationGeneration: UInt64
    ) async -> ASRFinalizationOutcome {
        await withCheckedContinuation { continuation in
            guard isCurrentFinalization(sessionID: sessionID, operationGeneration: operationGeneration) else {
                continuation.resume(returning: .cancelled)
                return
            }
            if let finalizationOutcome {
                continuation.resume(returning: finalizationOutcome)
                return
            }

            finalizationContinuation = continuation
            noteFinalizationProgress(sessionID: sessionID, reason: "waiting_for_service")
            guard !finishSent else { return }
            finishSent = true
            recordFinalizationEvidence(kind: .finishMarkerRequested, stage: .waitingForService)
            log(event: "asr_finish_requested")
            finishTask = Task { [weak self, asr] in
                do {
                    try await asr.finish()
                    self?.handleFinishMarkerSent(
                        sessionID: sessionID,
                        operationGeneration: operationGeneration
                    )
                } catch {
                    self?.handleFinalizationSendError(
                        error,
                        sessionID: sessionID,
                        operationGeneration: operationGeneration
                    )
                }
            }
        }
    }

    private func handleFinishMarkerSent(sessionID: UUID, operationGeneration: UInt64) {
        guard isCurrentFinalization(sessionID: sessionID, operationGeneration: operationGeneration),
              finalizationOutcome == nil,
              state == .stopping || state == .stoppingUnresponsive else { return }
        finalizationFinishSentSuccessfully = true
        recordFinalizationEvidence(kind: .finishMarkerSent, stage: .waitingForService)
        log(event: "asr_finish_sent")
        noteFinalizationProgress(sessionID: sessionID, reason: "finish_marker_sent")
        resolveCompletedFinalizationIfReady(sessionID: sessionID)
    }

    private func resolveCompletedFinalizationIfReady(sessionID: UUID) {
        guard finalizationFinishSentSuccessfully, asrStreamEnded else { return }
        resolveASRFinalization(.completed, sessionID: sessionID)
    }

    private func handleFinalizationSendError(
        _ error: Error,
        sessionID: UUID,
        operationGeneration: UInt64
    ) {
        guard isCurrentFinalization(sessionID: sessionID, operationGeneration: operationGeneration),
              state == .stopping || state == .stoppingUnresponsive else { return }
        handleFinalizationError(
            error,
            sessionID: sessionID,
            kind: .finishMarkerFailed,
            failureCategory: .finishMarkerSend
        )
    }

    private func handleFinalizationError(
        _ error: Error,
        sessionID: UUID,
        kind: ASRFinalizationEvidenceEvent.Kind = .receiveFailed,
        failureCategory: ASRFinalizationEvidenceEvent.FailureCategory = .asrReceive
    ) {
        guard self.sessionID == sessionID,
              state == .stopping || state == .stoppingUnresponsive,
              finalizationOutcome == nil else { return }
        errorCount += 1
        recordFinalizationEvidence(
            kind: kind,
            stage: .failed,
            failureCategory: failureCategory,
            error: error
        )
        log(event: "asr_finalization_error", error: error)
        audioForwarder?.cancel()
        asr.cancel()
        finishTask?.cancel()
        eventTask?.cancel()
        resolveASRFinalization(.failed(error.localizedDescription), sessionID: sessionID)
    }

    private func resolveASRFinalization(
        _ outcome: ASRFinalizationOutcome,
        sessionID expectedSessionID: UUID?
    ) {
        guard let expectedSessionID, self.sessionID == expectedSessionID,
              finalizationOutcome == nil else { return }
        finalizationOutcome = outcome
        finalizationWarningTask?.cancel()
        finalizationWarningTask = nil
        finalizationContinuation?.resume(returning: outcome)
        finalizationContinuation = nil
    }

    private func isCurrentFinalization(sessionID: UUID, operationGeneration: UInt64) -> Bool {
        self.sessionID == sessionID
            && self.operationGeneration == operationGeneration
            && finalizationOperationGeneration == operationGeneration
    }

    private func startFinalizationProgressWatch(_ sessionID: UUID) {
        noteFinalizationProgress(sessionID: sessionID, reason: "audio_capture_stopped")
    }

    private func noteFinalizationProgress(sessionID: UUID, reason: String) {
        guard self.sessionID == sessionID,
              state == .stopping || state == .stoppingUnresponsive else { return }
        finalizationProgressGeneration &+= 1
        let generation = finalizationProgressGeneration
        finalizationWarningTask?.cancel()
        if state == .stoppingUnresponsive {
            setState(.stopping)
        }
        finalizationWarningTask = Task { [weak self, finalizationClock, finalizationWarningNanoseconds] in
            do {
                try await finalizationClock.sleep(nanoseconds: finalizationWarningNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.sessionID == sessionID,
                  self.finalizationProgressGeneration == generation,
                  self.finalizationOutcome == nil,
                  self.state == .stopping else { return }
            self.setState(.stoppingUnresponsive)
            self.recordFinalizationEvidence(kind: .noProgressWarning, stage: .waitingForService)
            self.log(event: "asr_finalization_no_progress_warning", metadata: ["stage": reason])
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
        recognitionObservation: (Date, UInt64)? = nil,
        sessionID overrideSessionID: UUID? = nil
    ) {
        guard let sessionID = overrideSessionID ?? sessionID else { return }
        let stateName: String = switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .listening: "listening"
        case .recovering: "recovering"
        case .stopping: "stopping"
        case .stoppingUnresponsive: "stopping_unresponsive"
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
        var entryMetadata = [
            "sourceBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "sourceAppPath": Bundle.main.bundlePath,
            "writeCountMeaning": "submission_call_not_target_confirmation",
            "asrFinalizationPhase": asrFinalizationPhase.rawValue
        ]
        entryMetadata.merge(metadata) { existing, _ in existing }
        if event == "safe_copy" || event == "input_error",
           let degradationOccurredAt = injector?.degradationOccurredAt,
           let degradationOccurredMonotonicMilliseconds = injector?.degradationOccurredMonotonicMilliseconds {
            entryMetadata["failureOccurredAt"] = Self.iso8601(degradationOccurredAt)
            entryMetadata["failureOccurredMonotonicMilliseconds"] = String(degradationOccurredMonotonicMilliseconds)
            entryMetadata["degradationRecordedAt"] = Self.iso8601(Date())
            entryMetadata["degradationRecordedOnASREvent"] = String(update != nil)
            entryMetadata["degradationRecordTiming"] = update == nil
                ? "lifecycle_event"
                : "asr_event_or_following_update"
        }
        var textEvidence: [DiagnosticTextEvidence] = []
        if let update, !update.isStreamEnded {
            textEvidence.append(DiagnosticTextEvidence(
                kind: .rawRecognition,
                source: .observed,
                text: update.segmentText,
                revision: projection?.revision,
                targetApplicationBundleIdentifier: injector?.targetApplication?.bundleIdentifier,
                targetApplicationProcessID: injector?.targetApplication?.processIdentifier,
                observedAt: recognitionObservation?.0,
                monotonicMilliseconds: recognitionObservation?.1
            ))
        }
        if let projection {
            textEvidence.append(DiagnosticTextEvidence(
                kind: .processedRecognition,
                source: .observed,
                text: projection.text,
                revision: projection.revision,
                targetApplicationBundleIdentifier: injector?.targetApplication?.bundleIdentifier,
                targetApplicationProcessID: injector?.targetApplication?.processIdentifier,
                observedAt: recognitionObservation?.0,
                monotonicMilliseconds: recognitionObservation?.1
            ))
        }
        let entry = SessionLogEntry(
            timestamp: recognitionObservation?.0 ?? Date(),
            monotonicTimestampNanoseconds: recognitionObservation.map { $0.1 &* 1_000_000 }
                ?? DispatchTime.now().uptimeNanoseconds,
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
            metadata: entryMetadata,
            textEvidence: textEvidence
        )
        try? logger.append(entry)
        for diagnostic in injector?.drainDiagnostics() ?? [] {
            var fields = diagnostic.fields
            fields.merge(entry.metadata) { _, new in new }
            fields["diagnosticRecordedAt"] = Self.iso8601(Date())
            try? logger.append(SessionLogEntry(
                timestamp: diagnostic.timestamp,
                monotonicTimestampNanoseconds: diagnostic.monotonicTimestampNanoseconds,
                sessionID: sessionID,
                eventID: diagnostic.eventID,
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
                metadata: fields,
                textEvidence: diagnostic.textEvidence
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
