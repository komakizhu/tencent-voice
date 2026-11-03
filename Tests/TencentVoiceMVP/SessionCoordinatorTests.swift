import Foundation
import XCTest
@testable import TencentVoiceMVP

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    func testPipelineDiagnosticsIncludeCapturedUploadedAndReturnedProgress() async throws {
        let asr = FakeRealtimeASRClient()
        let audio = FakeAudioCapture()
        let logger = SessionLogger(enabled: { false })
        var startedSessionID: UUID?
        let coordinator = SessionCoordinator(
            asr: asr, audio: audio, textTarget: FakeTextTarget(text: ""),
            settingsStore: UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
            credentialStore: InMemoryCredentialStore(TencentCredentials(appID: "app", secretID: "id", secretKey: "key")),
            logger: logger,
            keyboardSmoothing: .immediate,
            onSessionStart: { startedSessionID = $0 },
            onStateChange: { _ in }
        )
        try await coordinator.begin()
        XCTAssertEqual(startedSessionID, logger.recentEntries().first(where: { $0.event == "audio_capture_started" })?.sessionID)
        audio.emit(Data(repeating: 0, count: 6400))
        audio.emit(Data(repeating: 0, count: 3200))
        asr.emit(ASRUpdate(text: "正文不能进入诊断日志", isFinal: true, sequence: 0))
        await settleCoordinator()
        try await coordinator.end()
        let progress = try XCTUnwrap(logger.recentEntries().last { $0.event == "audio_pipeline_progress" })
        XCTAssertEqual(progress.metadata["capturedChunkCount"], "2")
        XCTAssertEqual(progress.metadata["uploadedChunkCount"], "2")
        XCTAssertEqual(progress.metadata["capturedDurationMilliseconds"], "300")
        XCTAssertEqual(progress.metadata["uploadedDurationMilliseconds"], "300")
        XCTAssertEqual(progress.metadata["recognitionUpdateCount"], "2")
        XCTAssertFalse(progress.metadata.values.contains { $0.contains("正文") })
    }

    func testASRFinalizationEvidenceTracksCompletionWithoutKeepingAudioOrText() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let audio = FakeAudioCapture()
        let evidenceBuffer = ASRFinalizationEvidenceBuffer()
        let start = Date()
        evidenceBuffer.setEnabled(true, at: start)
        let coordinator = SessionCoordinator(
            asr: asr,
            audio: audio,
            textTarget: FakeTextTarget(text: "", supportsAXReplacement: false),
            settingsStore: UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
            credentialStore: InMemoryCredentialStore(
                TencentCredentials(appID: "credential-marker", secretID: "secret-id-marker", secretKey: "secret-key-marker")
            ),
            keyboardSmoothing: .immediate,
            onFinalizationEvidence: { evidenceBuffer.append($0) },
            onStateChange: { _ in }
        )

        try await coordinator.begin()
        audio.emit(Data(repeating: 0x5A, count: 3_200))
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "ASR正文秘密",
            phase: .partial
        ))
        await settleCoordinator()
        let ending = Task { @MainActor in try? await coordinator.end() }
        await settleCoordinator()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 2,
            segmentText: "ASR正文秘密已完成",
            phase: .final,
            wireFinal: true
        ))
        asr.emit(.streamEnded)
        asr.finishStream()
        await ending.value

        let evidence = evidenceBuffer.snapshot().evidence
        let encoded = try DiagnosticJSON.encoder().encode(evidence)
        let serialized = String(decoding: encoded, as: UTF8.self)
        XCTAssertEqual(evidence.audioUploadCompleted, true)
        XCTAssertEqual(evidence.serviceConfirmedComplete, true)
        XCTAssertEqual(evidence.textDeliveryStatus, .submittedUnconfirmed)
        XCTAssertEqual(evidence.textWriteConfirmed, false)
        XCTAssertTrue(evidence.events.contains { $0.kind == .audioCaptured })
        XCTAssertTrue(evidence.events.contains { $0.kind == .audioUploaded })
        XCTAssertTrue(evidence.events.contains { $0.kind == .serviceFinalSignalReceived })
        XCTAssertFalse(serialized.contains("ASR正文秘密"))
        XCTAssertFalse(serialized.contains("credential-marker"))
        XCTAssertFalse(serialized.contains("secret-key-marker"))
        XCTAssertFalse(serialized.contains("5A5A5A"))
    }

    func testRecordingDisplaySnapshotTracksRecoveryStopAndFreshSessionState() async throws {
        let asr = FakeRealtimeASRClient()
        let audio = FakeAudioCapture()
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: FakeTextTarget(text: ""))
        try await coordinator.begin()
        let sessionID = try XCTUnwrap(coordinator.recordingDisplaySnapshot().sessionID)
        XCTAssertTrue(coordinator.recordingDisplaySnapshot().isCapturing)

        audio.emit(Data(repeating: 0x40, count: 3_200))
        audio.emit(AudioCaptureLevel(rms: 0.5, durationSeconds: 0.1, timestampUptimeNanoseconds: 10))
        let captured = coordinator.recordingDisplaySnapshot()
        XCTAssertEqual(captured.state, .listening)
        XCTAssertEqual(captured.audio.durationSeconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(captured.audio.sampleSequence, 1)

        audio.emit(AudioCaptureEvent(
            sessionID: sessionID,
            kind: .interrupted(previousFormat: nil)
        ))
        await settleCoordinator()
        let recovering = coordinator.recordingDisplaySnapshot()
        XCTAssertEqual(recovering.state, .recovering)
        XCTAssertFalse(recovering.isCapturing)
        XCTAssertEqual(recovering.audio.durationSeconds, captured.audio.durationSeconds)
        XCTAssertEqual(recovering.audio.latestRMS, 0)
        XCTAssertNil(recovering.audio.latestLevelAtUptimeNanoseconds)

        audio.emit(AudioCaptureEvent(
            sessionID: sessionID,
            kind: .recovered(
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
                durationNanoseconds: 250_000_000
            )
        ))
        await settleCoordinator()
        XCTAssertEqual(coordinator.recordingDisplaySnapshot().state, .listening)
        XCTAssertTrue(coordinator.recordingDisplaySnapshot().isCapturing)

        audio.emit(Data(repeating: 0, count: 3_200))
        audio.emit(AudioCaptureLevel(rms: 0, durationSeconds: 0.1, timestampUptimeNanoseconds: 20))
        let resumed = coordinator.recordingDisplaySnapshot()
        XCTAssertEqual(resumed.audio.durationSeconds, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(resumed.audio.sampleSequence, 3)
        XCTAssertEqual(resumed.audio.latestRMS, 0)
        XCTAssertEqual(resumed.audio.latestLevelAtUptimeNanoseconds, 20)

        try await coordinator.end()
        let ended = coordinator.recordingDisplaySnapshot()
        XCTAssertNil(ended.sessionID)
        XCTAssertEqual(ended.state, .idle)
        XCTAssertFalse(ended.isCapturing)
        XCTAssertEqual(ended.audio, .empty)
    }

    func testRecordingDisplayIncludesStopFlushAndResetsForNextSession() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let audio = FakeAudioCapture()
        audio.dataToEmitOnStop = Data(repeating: 0x40, count: 6_400)
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: FakeTextTarget(text: ""))
        try await coordinator.begin()
        audio.emit(Data(repeating: 0, count: 3_200))

        let ending = Task { @MainActor in try? await coordinator.end() }
        await settleCoordinator()
        audio.dataToEmitOnStop = nil
        let stopping = coordinator.recordingDisplaySnapshot()
        XCTAssertEqual(stopping.state, .stopping)
        XCTAssertFalse(stopping.isCapturing)
        XCTAssertEqual(stopping.audio.durationSeconds, 0.3, accuracy: 0.000_001)
        audio.emit(Data(repeating: 0x50, count: 3_200))
        await settleCoordinator()
        XCTAssertEqual(coordinator.recordingDisplaySnapshot().audio, stopping.audio)
        XCTAssertEqual(audio.stopCallCount, 1)

        asr.finishStream()
        await ending.value
        XCTAssertEqual(coordinator.recordingDisplaySnapshot().audio, .empty)

        try await coordinator.begin()
        let next = coordinator.recordingDisplaySnapshot()
        XCTAssertNotEqual(next.sessionID, stopping.sessionID)
        XCTAssertEqual(next.audio.durationSeconds, 0)
        XCTAssertNil(next.audio.latestLevelAtUptimeNanoseconds)
        audio.emitStale(AudioCaptureLevel(rms: 0.9, durationSeconds: 0.2, timestampUptimeNanoseconds: 50))
        XCTAssertNil(coordinator.recordingDisplaySnapshot().audio.latestLevelAtUptimeNanoseconds)
        coordinator.cancel()
    }

    func testUnexpectedRecognitionEndDoesNotLeaveMicrophoneListening() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let settings = UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)")
        settings.save(AppSettings(alwaysSaveVoiceContent: true))
        let coordinator = makeCoordinator(asr: asr, target: target, settingsStore: settings)
        try await coordinator.begin()
        let text = String(repeating: "长语音内容。", count: 200)
        asr.emit(ASRUpdate(text: text, isFinal: true, sequence: 0))
        await settleCoordinator()
        asr.finishStream()
        await settleCoordinator()
        guard case .error = coordinator.state else {
            return XCTFail("Unexpected ASR end must stop recording instead of showing listening")
        }
        XCTAssertEqual(target.copiedText, text)
    }

    func testStopFlushesPendingKeyboardSmoothingCharacters() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(
            asr: asr,
            target: target,
            keyboardSmoothing: .live
        )

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "甲乙丙丁戊",
            phase: .partial
        ))
        await Task.yield()
        await Task.yield()

        try await coordinator.end()

        XCTAssertEqual(target.text, "甲乙丙丁戊")
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testStopWhileTargetAwayKeepsTranscriptAndCompletesWhenTargetReturns() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        target.keyboardAvailability = .temporarilyAway
        var pendingStates: [Bool] = []
        let evidence = ASRFinalizationEvidenceBuffer()
        evidence.setEnabled(true)
        let coordinator = SessionCoordinator(
            asr: asr,
            audio: FakeAudioCapture(),
            textTarget: target,
            settingsStore: UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
            credentialStore: InMemoryCredentialStore(TencentCredentials(appID: "app", secretID: "id", secretKey: "key")),
            keyboardSmoothing: .immediate,
            onPendingCompletionChange: { pendingStates.append($0) },
            onFinalizationEvidence: { evidence.append($0) },
            onStateChange: { _ in }
        )

        try await coordinator.begin()
        asr.emit(ASRUpdate(text: "123", isFinal: true, sequence: 0))
        await settleCoordinator()
        XCTAssertEqual(target.text, "")

        try await coordinator.end()
        XCTAssertEqual(coordinator.state, .idle, "Waiting to complete text must not keep recording active")
        XCTAssertEqual(target.text, "")
        XCTAssertEqual(pendingStates, [true])
        XCTAssertEqual(evidence.snapshot().evidence.textDeliveryStatus, .waitingForTarget)

        target.keyboardAvailability = .active
        await coordinator.pollTargetAvailabilityForTesting()
        XCTAssertEqual(target.text, "123")
        XCTAssertEqual(target.pastedTexts, ["123"])
        XCTAssertEqual(pendingStates, [true, false])
        XCTAssertEqual(evidence.snapshot().evidence.textDeliveryStatus, .submittedUnconfirmed)

        asr.emit(ASRUpdate(text: "late callback", isFinal: true, sequence: 1))
        await settleCoordinator()
        XCTAssertEqual(target.text, "123", "A late callback from the stopped session must be ignored")
    }

    func testRecognitionAcrossAwayAndReturnCoalescesTo123456789ExactlyOnce() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target, keyboardSmoothing: .immediate)

        try await coordinator.begin()
        asr.emit(ASRUpdate(text: "123", isFinal: false, sequence: 0))
        await settleCoordinator()
        XCTAssertEqual(target.text, "123")

        target.keyboardAvailability = .temporarilyAway
        asr.emit(ASRUpdate(text: "123456", isFinal: false, sequence: 0))
        await settleCoordinator()
        XCTAssertEqual(target.text, "123")

        target.keyboardAvailability = .active
        await coordinator.pollTargetAvailabilityForTesting()
        XCTAssertEqual(target.text, "123456", "Return polling must resume even without a new ASR callback")

        target.keyboardAvailability = .temporarilyAway
        asr.emit(ASRUpdate(text: "123456789", isFinal: false, sequence: 0))
        await settleCoordinator()
        XCTAssertEqual(target.text, "123456")
        target.keyboardAvailability = .active
        await coordinator.pollTargetAvailabilityForTesting()
        try await coordinator.end()

        XCTAssertEqual(target.text, "123456789")
        XCTAssertEqual(target.pastedTexts.joined(), "123456789")
        XCTAssertEqual(target.text.components(separatedBy: "123456789").count - 1, 1)
    }

    func testStoppedPendingCompletionExpiresAtOriginalSixtySecondDeadline() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        target.keyboardAvailability = .temporarilyAway
        var now: UInt64 = 1_000
        let coordinator = SessionCoordinator(
            asr: asr,
            audio: FakeAudioCapture(),
            textTarget: target,
            settingsStore: UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
            credentialStore: InMemoryCredentialStore(TencentCredentials(appID: "app", secretID: "id", secretKey: "key")),
            keyboardSmoothing: .immediate,
            monotonicNow: { now },
            onStateChange: { _ in }
        )
        try await coordinator.begin()
        asr.emit(ASRUpdate(text: "到期要复制", isFinal: true, sequence: 0))
        await settleCoordinator()
        try await coordinator.end()

        now = 60_000_001_000
        await coordinator.pollTargetAvailabilityForTesting()
        XCTAssertEqual(target.text, "")
        XCTAssertEqual(target.copiedText, "到期要复制")
        XCTAssertEqual(target.pastedTexts, [])
    }

    func testCancellingStoppedPendingCompletionCopiesTranscriptAndInvalidatesReturn() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        target.keyboardAvailability = .temporarilyAway
        let coordinator = makeCoordinator(asr: asr, target: target)
        try await coordinator.begin()
        asr.emit(ASRUpdate(text: "用户取消的补齐", isFinal: true, sequence: 0))
        await settleCoordinator()
        try await coordinator.end()

        coordinator.cancelPendingCompletion()
        target.keyboardAvailability = .active
        await coordinator.pollTargetAvailabilityForTesting()

        XCTAssertEqual(target.text, "")
        XCTAssertEqual(target.pastedTexts, [])
        XCTAssertEqual(target.copiedText, "用户取消的补齐")
    }

    func testStoppingDefersPacingFlushUntilASRFinalizationCompletes() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let clock = ManualKeyboardPacingClock()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(
            asr: asr,
            target: target,
            keyboardSmoothing: .live,
            pacingClock: clock
        )

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "甲乙丙丁戊",
            phase: .partial
        ))
        await settleCoordinator()
        XCTAssertEqual(target.text, "甲")

        let ending = Task { @MainActor in
            try? await coordinator.end()
        }
        await settleCoordinator()
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertEqual(target.text, "甲")

        clock.advance(by: 120_000_000)
        await settleCoordinator()
        XCTAssertEqual(target.text, "甲乙")

        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "甲乙丙丁戊",
            phase: .final,
            wireFinal: true
        ))
        await settleCoordinator()
        XCTAssertEqual(target.text, "甲乙")

        asr.finishStream()
        await settleCoordinator()
        clock.advance(by: 120_000_000)
        await settleCoordinator()
        await ending.value
        XCTAssertEqual(target.text, "甲乙丙丁戊")
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testLateFinalDoesNotTreatOwnAcknowledgementAsMixedInput() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FinalizationAcknowledgingKeyboardTarget()
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "未完成",
            phase: .partial
        ))
        await settleCoordinator()
        XCTAssertEqual(target.postCount, 1)
        XCTAssertEqual(target.text, "草稿：")

        let ending = Task { @MainActor in
            try? await coordinator.end()
        }
        await settleCoordinator()
        XCTAssertEqual(coordinator.state, .stopping)

        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "未完成尾部",
            phase: .final,
            wireFinal: true
        ))
        asr.finishStream()
        await settleCoordinator()
        target.blockAcknowledgement = false
        await ending.value

        XCTAssertEqual(target.text, "草稿：未完成尾部")
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testUserEditDuringASRFinalizationFreezesOldVoiceWrite() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FinalizationAcknowledgingKeyboardTarget()
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "旧语音",
            phase: .partial
        ))
        await settleCoordinator()

        let ending = Task { @MainActor in
            try? await coordinator.end()
        }
        await settleCoordinator()
        target.appendManualText("用户输入")
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "旧语音新结果",
            phase: .final,
            wireFinal: true
        ))
        asr.finishStream()
        await settleCoordinator()
        target.blockAcknowledgement = false
        await ending.value

        XCTAssertEqual(target.text, "草稿：用户输入")
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testLateFinalDuringStoppingUsesTheShortFlushWindow() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let clock = ManualKeyboardPacingClock()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(
            asr: asr,
            target: target,
            keyboardSmoothing: .live,
            pacingClock: clock
        )

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "这是一句未完成",
            phase: .partial
        ))
        await settleCoordinator()

        let ending = Task { @MainActor in
            try? await coordinator.end()
        }
        await settleCoordinator()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "这是一句未完成的话",
            phase: .final,
            wireFinal: true
        ))
        await settleCoordinator()
        clock.advance(by: 120_000_000)
        await settleCoordinator()

        XCTAssertNotEqual(target.text, "这是一句未完成的话")
        asr.finishStream()
        await settleCoordinator()
        clock.advance(by: 120_000_000)
        await ending.value

        XCTAssertEqual(target.text, "这是一句未完成的话")
    }

    func testKeyboardPartialThenFinalIsAppendedWithoutReplacement() async throws {
        let asr = FakeRealtimeASRClient()
        let audio = FakeAudioCapture()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: target)

        try await coordinator.begin()
        asr.emit(.init(text: "你", isFinal: false, sequence: 0))
        asr.emit(.init(text: "你好", isFinal: false, sequence: 0))
        asr.emit(.init(text: "你好呀", isFinal: false, sequence: 0))
        asr.emit(.init(text: "你好呀", isFinal: true, sequence: 0))
        try await coordinator.end()

        XCTAssertEqual(target.text, "你好呀")
        XCTAssertEqual(target.pastedTexts, ["你", "好", "呀"])
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertEqual(asr.finishCallCount, 1)
    }

    func testKeyboardPartialAppearsImmediatelyBeforeFinal() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "这是一个稳定",
            phase: .partial
        ))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(target.text, "这是一个稳定")

        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "这是一个稳定的长句",
            phase: .partial
        ))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(target.text, "这是一个稳定的长句")

        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 2,
            segmentText: "这是一个稳定的长句，继续说",
            phase: .partial
        ))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(target.text, "这是一个稳定的长句，继续说")
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertEqual(coordinator.state, .listening)

        coordinator.cancel()
    }

    func testKeyboardServerStableMetadataDoesNotDelayVisiblePartial() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "这是一个正在变化的句子",
            phase: .partial,
            stablePrefixText: "这是一个"
        ))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(target.text, "这是一个正在变化的句子")
        XCTAssertEqual(coordinator.state, .listening)

        coordinator.cancel()
    }

    func testBeginEnablesTencentVADForPauseDrivenFinalization() async throws {
        let asr = FakeRealtimeASRClient()
        let coordinator = makeCoordinator(asr: asr, target: FakeTextTarget(text: ""))

        try await coordinator.begin()

        XCTAssertEqual(asr.startedConfiguration?.needVAD, 1)
        XCTAssertEqual(asr.startedConfiguration?.wordInfo, 1)
        coordinator.cancel()
    }

    func testAudioInterruptionMovesToRecoveringAndThenBackToListening() async throws {
        let audio = FakeAudioCapture()
        let coordinator = makeCoordinator(
            audio: audio,
            target: FakeTextTarget(text: "")
        )

        try await coordinator.begin()
        guard let sessionID = audio.lastSessionID else {
            return XCTFail("audio session ID was not captured")
        }

        audio.emit(AudioCaptureEvent(
            sessionID: sessionID,
            kind: .interrupted(previousFormat: AudioCaptureFormat(sampleRate: 24_000, channelCount: 1))
        ))
        await settleCoordinator()
        XCTAssertEqual(coordinator.state, .recovering)

        audio.emit(AudioCaptureEvent(sessionID: sessionID, kind: .recovering(attempt: 1)))
        audio.emit(AudioCaptureEvent(
            sessionID: sessionID,
            kind: .recovered(
                format: AudioCaptureFormat(sampleRate: 48_000, channelCount: 1),
                durationNanoseconds: 250_000_000
            )
        ))
        await settleCoordinator()
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.cancel()
    }

    func testStartCompletionCannotOverrideAudioRecovery() async throws {
        let audio = FakeAudioCapture()
        audio.holdsStarts = true
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "")
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: target)
        let start = Task { try await coordinator.begin() }
        await waitForAudioStart(audio, count: 1)
        let id = try XCTUnwrap(audio.lastSessionID)
        audio.emit(.init(sessionID: id, kind: .interrupted(previousFormat: nil)))
        await settleCoordinator()
        audio.releaseNextStart()
        try await start.value
        XCTAssertEqual(coordinator.state, .recovering)
        asr.emit(.init(text: "切换前的尾句", isFinal: true, sequence: 0))
        await settleCoordinator()
        XCTAssertEqual(target.text, "切换前的尾句")
        audio.emit(.init(sessionID: id, kind: .recovered(
            format: .init(sampleRate: 24_000, channelCount: 1), durationNanoseconds: 600_000_000
        )))
        await settleCoordinator()
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.cancel()
    }

    func testAudioRecoversBeforeConnectionCompletes() async throws {
        let audio = FakeAudioCapture()
        audio.holdsStarts = true
        let coordinator = makeCoordinator(audio: audio, target: FakeTextTarget(text: ""))
        let start = Task { try await coordinator.begin() }
        await waitForAudioStart(audio, count: 1)
        let id = try XCTUnwrap(audio.lastSessionID)
        audio.emit(.init(sessionID: id, kind: .interrupted(previousFormat: nil)))
        await settleCoordinator()
        audio.emit(.init(sessionID: id, kind: .recovered(
            format: .init(sampleRate: 24_000, channelCount: 1), durationNanoseconds: 100_000_000
        )))
        await settleCoordinator()
        XCTAssertNotEqual(coordinator.state, .listening)
        audio.releaseNextStart()
        try await start.value
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.cancel()
    }

    func testStopDuringStartupRecoveryCancelsInsteadOfFinishing() async throws {
        let audio = FakeAudioCapture()
        audio.holdsStarts = true
        let asr = FakeRealtimeASRClient()
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: FakeTextTarget(text: ""))
        let start = Task { try await coordinator.begin() }
        await waitForAudioStart(audio, count: 1)
        let id = try XCTUnwrap(audio.lastSessionID)
        audio.emit(.init(sessionID: id, kind: .interrupted(previousFormat: nil)))
        await settleCoordinator()
        try await coordinator.end()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(asr.finishCallCount, 0)
        audio.releaseNextStart()
        try await start.value
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(asr.startedConfiguration)
    }

    func testAudioRecoveryFailureKeepsRecognizedTextAndEntersError() async throws {
        let audio = FakeAudioCapture()
        let target = FakeTextTarget(text: "")
        let asr = FakeRealtimeASRClient()
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: target)

        try await coordinator.begin()
        guard let sessionID = audio.lastSessionID else {
            return XCTFail("audio session ID was not captured")
        }
        asr.emit(.init(text: "切换前的文字", isFinal: false, sequence: 0))
        await settleCoordinator()

        audio.emit(AudioCaptureEvent(
            sessionID: sessionID,
            kind: .failed(.recoveryTimedOut)
        ))
        await settleCoordinator()

        XCTAssertEqual(coordinator.state, .error("麦克风设备切换后未能恢复"))
        XCTAssertEqual(target.text, "切换前的文字")
        XCTAssertEqual(asr.finishCallCount, 0)
    }

    func testLateCancelledStartCannotCleanUpTheNextSession() async throws {
        let audio = FakeAudioCapture()
        audio.holdsStarts = true
        let coordinator = makeCoordinator(audio: audio, target: FakeTextTarget(text: ""))

        let firstStart = Task { @MainActor in
            try? await coordinator.begin()
        }
        await waitForAudioStart(audio, count: 1)
        coordinator.cancel()

        let secondStart = Task { @MainActor in
            try? await coordinator.begin()
        }
        await waitForAudioStart(audio, count: 2)

        audio.releaseNextStart()
        await firstStart.value
        XCTAssertEqual(coordinator.state, .connecting)

        audio.releaseNextStart()
        await secondStart.value
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.cancel()
    }

    func testPauseFinalCommitsSentenceWhileSessionContinues() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "停顿前的这一句",
            phase: .partial
        ))
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "停顿前的这一句",
            phase: .final
        ))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(target.text, "停顿前的这一句")
        XCTAssertEqual(coordinator.state, .listening)

        asr.emit(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 1,
            segmentText: "继续说的下一句",
            phase: .partial,
            isNewSegment: true
        ))
        try await coordinator.end()

        XCTAssertEqual(target.text, "停顿前的这一句继续说的下一句")
        XCTAssertEqual(target.replaceCallCount, 0)
    }

    func testFinalRevisionDoesNotDisableFollowingSegment() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "我想吃苹果",
            phase: .partial
        ))
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "我想吃香蕉",
            phase: .partial
        ))
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 2,
            segmentText: "我要吃香蕉",
            phase: .final
        ))
        asr.emit(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 3,
            segmentText: "下一句",
            phase: .partial,
            isNewSegment: true
        ))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(target.text, "我要吃香蕉下一句")
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertNil(target.copiedText)

        coordinator.cancel()
    }

    func testStopFlushesLastAudioChunkBeforeSendingEndMarker() async throws {
        let asr = FakeRealtimeASRClient()
        asr.sendAudioDelayNanoseconds = 10_000_000
        let audio = FakeAudioCapture()
        audio.dataToEmitOnStop = Data([1, 2, 3])
        let coordinator = makeCoordinator(
            asr: asr, audio: audio, target: FakeTextTarget(text: ""),
            onStateChange: { state in
                guard state == .stopping else { return }
                XCTAssertEqual(audio.stopCallCount, 1, "Capture must stop before any state observer runs")
                audio.emit(Data([9, 9]))
            }
        )

        try await coordinator.begin()
        try await coordinator.end()

        XCTAssertEqual(asr.eventOrder, ["audio", "finish"])
        audio.emit(Data([4, 5, 6]))
        await settleCoordinator()
        XCTAssertEqual(asr.eventOrder, ["audio", "finish"], "Stopped capture must not submit more audio")
    }

    func testUploadFailurePreservesTextAndDoesNotSendEndMarker() async throws {
        let asr = FakeRealtimeASRClient()
        let audio = FakeAudioCapture()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: target)
        try await coordinator.begin()
        asr.emit(.init(text: "已有文字", isFinal: false, sequence: 0))
        await settleCoordinator()
        audio.dataToEmitOnStop = Data([1, 2])
        asr.sendAudioOperation = { throw TencentASRError.server(code: 500, message: "上传失败") }
        try await coordinator.end()
        guard case .error = coordinator.state else { return XCTFail("Upload failure must be incomplete") }
        XCTAssertEqual(target.text, "已有文字")
        XCTAssertEqual(asr.finishCallCount, 0)
    }

    func testUserCanEndWaitDuringHungUploadWithoutWaitingForSendCallback() async throws {
        let asr = FakeRealtimeASRClient()
        let audio = FakeAudioCapture()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: target)
        try await coordinator.begin()
        asr.emit(.init(text: "保留文字", isFinal: false, sequence: 0))
        await settleCoordinator()
        let suspension = SuspendedASROperation()
        asr.sendAudioOperation = { await suspension.wait() }
        audio.dataToEmitOnStop = Data([1, 2])
        let ended = expectation(description: "end without hung upload")
        let ending = Task { @MainActor in
            try? await coordinator.end()
            ended.fulfill()
        }
        for _ in 0..<200 where !suspension.isWaiting { await Task.yield() }
        XCTAssertTrue(suspension.isWaiting)
        coordinator.endFinalizationWaitPreservingText()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertTrue(suspension.isWaiting)
        XCTAssertEqual(target.text, "保留文字")
        XCTAssertEqual(asr.finishCallCount, 0)
        suspension.resume()
        await ending.value
    }

    func testFinalSignalWaitsForEndMarkerAcknowledgementAndRepeatedStopIsIdempotent() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let suspension = SuspendedASROperation()
        asr.finishOperation = { await suspension.wait() }
        let coordinator = makeCoordinator(asr: asr, target: FakeTextTarget(text: ""))
        try await coordinator.begin()
        let ending = Task { @MainActor in try? await coordinator.end() }
        for _ in 0..<200 where !suspension.isWaiting { await Task.yield() }
        asr.finishStream()
        await settleCoordinator()
        try await coordinator.end()
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertEqual(asr.finishCallCount, 1)
        suspension.resume()
        await ending.value
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testCancelledFinishCallbackCannotClearOrFailNextSession() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let suspension = SuspendedASROperation()
        asr.finishOperation = { await suspension.wait() }
        let coordinator = makeCoordinator(asr: asr, target: FakeTextTarget(text: ""))
        try await coordinator.begin()
        let ending = Task { @MainActor in try? await coordinator.end() }
        for _ in 0..<200 where !suspension.isWaiting { await Task.yield() }
        coordinator.cancel()
        await ending.value
        try await coordinator.begin()
        suspension.resume()
        await settleCoordinator()
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.cancel()
    }

    func testContinuousRecognitionProgressHasNoTotalDeadline() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let clock = ManualKeyboardPacingClock()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target, finalizationClock: clock)
        try await coordinator.begin()
        let ending = Task { @MainActor in try? await coordinator.end() }
        await settleCoordinator()
        for sequence in 1...10 {
            clock.advance(by: 20_000_000_000)
            asr.emit(.init(
                segmentID: 0, segmentOrder: 0, sequence: sequence,
                segmentText: "持续修订\(sequence)", phase: sequence == 10 ? .final : .partial
            ))
            await settleCoordinator()
            XCTAssertEqual(coordinator.state, .stopping)
        }
        asr.finishStream()
        await ending.value
        XCTAssertEqual(target.text, "持续修订10")
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testKeyboardSegmentsAreAppendedInOrder() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "第一句",
            phase: .partial
        ))
        asr.emit(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 1,
            segmentText: "第二句",
            phase: .partial
        ))
        asr.emit(ASRUpdate(
            segmentID: 2,
            segmentOrder: 1,
            sequence: 2,
            segmentText: "第二句完成",
            phase: .final,
            wireFinal: true
        ))
        try await coordinator.end()

        XCTAssertEqual(target.text, "第一句第二句完成")
        XCTAssertEqual(target.pastedTexts, ["第一句", "第二句", "完成"])
        XCTAssertEqual(target.replaceCallCount, 0)
    }

    func testKeyboardStreamEndCommitsLastPartialWithoutExplicitStop() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "自然结束前的 partial",
            phase: .partial
        ))
        asr.finishStream()
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(target.text, "自然结束前的 partial")
        XCTAssertEqual(target.pastedTexts, ["自然结束前的 partial"])

        coordinator.cancel()
    }

    func testCancelKeepsAlreadyVisibleKeyboardPartial() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "取消前已经上屏",
            phase: .partial
        ))
        try await Task.sleep(nanoseconds: 10_000_000)
        coordinator.cancel()

        XCTAssertEqual(target.text, "取消前已经上屏")
        XCTAssertEqual(target.pastedTexts, ["取消前已经上屏"])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testPartialThenFinalIsWrittenWithoutDuplication() async throws {
        let asr = FakeRealtimeASRClient()
        let audio = FakeAudioCapture()
        let target = FakeTextTarget(text: "")
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: target)

        try await coordinator.begin()
        asr.emit(.init(text: "你", isFinal: false, sequence: 0))
        asr.emit(.init(text: "你好", isFinal: false, sequence: 0))
        asr.emit(.init(text: "你好呀", isFinal: true, sequence: 0))
        try await coordinator.end()

        XCTAssertEqual(target.text, "你好呀")
        XCTAssertEqual(target.text.components(separatedBy: "你好呀").count - 1, 1)
        XCTAssertEqual(target.replaceCallCount, 3)
        XCTAssertEqual(asr.finishCallCount, 1)
    }

    func testStopBeforeFinalKeepsPartialAndAcceptsLateFinal() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "这是一句未完成",
            phase: .partial
        ))

        let ending = Task { @MainActor in
            try? await coordinator.end()
        }
        await Task.yield()
        XCTAssertEqual(coordinator.state, .stopping)

        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "这是一句未完成的话",
            phase: .final,
            wireFinal: true
        ))
        asr.finishStream()
        await ending.value

        XCTAssertEqual(target.text, "这是一句未完成的话")
        XCTAssertEqual(asr.finishCallCount, 1)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testStopBeforeFinalEmptyFinalKeepsCurrentText() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "这句还没讲完",
            phase: .partial
        ))

        let ending = Task { @MainActor in
            try? await coordinator.end()
        }
        await Task.yield()

        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "",
            phase: .final,
            wireFinal: true
        ))
        asr.finishStream()
        await ending.value

        XCTAssertEqual(target.text, "这句还没讲完")
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testStopTimeoutFreezesLastSafeProjection() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FakeTextTarget(text: "已有文字", supportsAXReplacement: false)
        let warningClock = ManualKeyboardPacingClock()
        let coordinator = makeCoordinator(
            asr: asr,
            target: target,
            finalizationClock: warningClock
        )

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "收尾中的文字",
            phase: .partial
        ))
        let ending = Task { @MainActor in try? await coordinator.end() }
        await settleCoordinator()
        warningClock.advance(by: 30_000_000_000)
        await settleCoordinator()

        XCTAssertEqual(target.text, "已有文字收尾中的文字")
        XCTAssertEqual(coordinator.state, .stoppingUnresponsive)
        XCTAssertEqual(coordinator.recordingDisplaySnapshot().isCapturing, false)

        coordinator.endFinalizationWaitPreservingText()
        await ending.value

        XCTAssertEqual(target.text, "已有文字收尾中的文字")
        guard case .error = coordinator.state else {
            return XCTFail("主动结束等待必须标记收尾未完成")
        }
    }

    func testStopWaitsPastThreeSecondsForTheFinalRecognitionRevision() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let warningClock = ManualKeyboardPacingClock()
        let coordinator = makeCoordinator(asr: asr, target: target, finalizationClock: warningClock)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "最后一句还没",
            phase: .partial
        ))
        await settleCoordinator()
        let ending = Task { @MainActor in try? await coordinator.end() }
        await settleCoordinator()

        warningClock.advance(by: 31_000_000_000)
        await settleCoordinator()
        XCTAssertEqual(coordinator.state, .stoppingUnresponsive)
        XCTAssertFalse(coordinator.recordingDisplaySnapshot().isCapturing)
        XCTAssertEqual(target.text, "最后一句还没")

        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "最后一句已经识别完毕",
            phase: .final,
            wireFinal: true
        ))
        asr.finishStream()
        await ending.value

        XCTAssertEqual(target.text, "最后一句已经识别完毕")
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testRepeatedRecognitionRevisionDoesNotResetNoProgressWarning() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let warningClock = ManualKeyboardPacingClock()
        let coordinator = makeCoordinator(
            asr: asr,
            target: FakeTextTarget(text: "", supportsAXReplacement: false),
            finalizationClock: warningClock
        )

        try await coordinator.begin()
        let partial = ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "识别进行中",
            phase: .partial
        )
        asr.emit(partial)
        await settleCoordinator()
        let ending = Task { @MainActor in try? await coordinator.end() }
        await settleCoordinator()

        warningClock.advance(by: 15_000_000_000)
        await settleCoordinator()
        asr.emit(partial)
        await settleCoordinator()
        warningClock.advance(by: 15_000_000_000)
        await settleCoordinator()

        XCTAssertEqual(coordinator.state, .stoppingUnresponsive)
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 1,
            segmentText: "识别进行中的最终修订",
            phase: .final,
            wireFinal: true
        ))
        await settleCoordinator()
        XCTAssertEqual(coordinator.state, .stopping)
        asr.finishStream()
        await ending.value
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testASRReceiveErrorDuringFinalizationIsNotReportedAsSuccess() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "已收到的安全文字",
            phase: .partial
        ))
        await settleCoordinator()
        let ending = Task { @MainActor in try? await coordinator.end() }
        await settleCoordinator()

        asr.fail(TencentASRError.server(code: 500, message: "测试错误"))
        await ending.value

        guard case .error = coordinator.state else {
            return XCTFail("接收错误不能把收尾会话标记为正常完成")
        }
        XCTAssertEqual(target.text, "已收到的安全文字")
    }

    func testStreamClosingWithoutFinalSignalMarksFinalizationIncomplete() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "连接关闭前的安全文字",
            phase: .partial
        ))
        await settleCoordinator()
        let ending = Task { @MainActor in try? await coordinator.end() }
        await settleCoordinator()

        asr.closeStreamWithoutFinalSignal()
        await ending.value

        guard case .error = coordinator.state else {
            return XCTFail("没有整段完成信号的正常关闭必须标记收尾未完成")
        }
        XCTAssertEqual(target.text, "连接关闭前的安全文字")
    }

    func testEndMarkerSendErrorIsNotDiscardedDuringFinalization() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        asr.finishError = TencentASRError.server(code: 500, message: "结束标记发送失败")
        let logger = SessionLogger(enabled: { false })
        let coordinator = SessionCoordinator(
            asr: asr,
            audio: FakeAudioCapture(),
            textTarget: FakeTextTarget(text: "", supportsAXReplacement: false),
            settingsStore: UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
            credentialStore: InMemoryCredentialStore(
                TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
            ),
            logger: logger,
            onStateChange: { _ in }
        )

        try await coordinator.begin()
        let ending = Task { @MainActor in try? await coordinator.end() }
        await ending.value

        guard case .error = coordinator.state else {
            return XCTFail("结束标记发送失败不能被吞掉并报告为正常完成")
        }
        XCTAssertNotNil(logger.recentEntries().first { $0.event == "asr_finalization_error" })
    }

    func testASRErrorFinalizesLastSafeProjectionWithoutDeletingIt() async throws {
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "已有文字", supportsAXReplacement: false)
        let coordinator = makeCoordinator(asr: asr, target: target)

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "错误前的文字",
            phase: .partial
        ))
        asr.fail(TencentASRError.server(code: 500, message: "测试错误"))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(target.text, "已有文字错误前的文字")
        if case .error = coordinator.state {
            // The session is ended, while the error remains visible to the user.
        } else {
            XCTFail("expected an error state")
        }
    }

    func testCredentialFailureDoesNotTouchTarget() async throws {
        let target = FakeTextTarget(text: "原文")
        let coordinator = makeCoordinator(target: target, credentials: nil)
        await assertThrowsAsync { try await coordinator.begin() }
        XCTAssertEqual(target.text, "原文")
    }

    func testEnabledSafeCopyWritesThroughAndCopiesThroughSettingsStore() async throws {
        let settingsStore = UserDefaultsSettingsStore(
            suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"
        )
        settingsStore.save(AppSettings(alwaysSaveVoiceContent: true))
        let asr = FakeRealtimeASRClient()
        let target = FakeTextTarget(text: "原文", supportsAXReplacement: false)
        let coordinator = makeCoordinator(
            asr: asr,
            target: target,
            settingsStore: settingsStore
        )

        try await coordinator.begin()
        asr.emit(ASRUpdate(text: "安全复制结果", isFinal: true, sequence: 0))
        await settleCoordinator()
        XCTAssertTrue(target.copiedTexts.isEmpty)
        try await coordinator.end()

        XCTAssertEqual(target.copiedTexts, ["安全复制结果"])
        XCTAssertEqual(target.text, "原文安全复制结果")
        XCTAssertEqual(target.copiedText, "安全复制结果")
    }

    func testInputDiagnosticsFlowFromASRThroughLoggerIntoReport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-InputDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let asr = FakeRealtimeASRClient()
        let logger = SessionLogger(
            enabled: { true },
            applicationSupportDirectoryURL: directory
        )
        let coordinator = SessionCoordinator(
            asr: asr,
            audio: FakeAudioCapture(),
            textTarget: FakeTextTarget(text: "", supportsAXReplacement: false),
            settingsStore: UserDefaultsSettingsStore(
                suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"
            ),
            credentialStore: InMemoryCredentialStore(
                TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
            ),
            logger: logger,
            keyboardSmoothing: .immediate,
            onStateChange: { _ in }
        )

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 87,
            segmentText: "旧候选",
            phase: .partial
        ))
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 88,
            segmentText: "新候选",
            phase: .partial
        ))
        await settleCoordinator()
        coordinator.cancel()

        let entries = logger.allPersistedEntries()
        let operation = try XCTUnwrap(entries.first {
            $0.event == "input_operation" && $0.revision == 2
        })
        XCTAssertEqual(operation.segmentID, 1)
        XCTAssertEqual(operation.revision, 2)
        XCTAssertEqual(operation.metadata["operationID"], "2")
        XCTAssertEqual(operation.metadata["operationType"], "tail_replacement")
        XCTAssertNotNil(operation.metadata["sourceAppPath"])
        XCTAssertNotNil(operation.metadata["sourceBuild"])

        let report = DiagnosticReport(
            app: DiagnosticAppInfo(
                displayName: "Rime Voice",
                bundleIdentifier: "local.tencent-voice-mvp",
                shortVersion: "0.2.3",
                build: "test",
                bundlePath: "/tmp/Rime Voice.app",
                executablePath: "/tmp/Rime Voice.app/Contents/MacOS/TencentVoiceMVP",
                bundleModificationDate: nil,
                processIdentifier: 1,
                processLaunchDate: nil,
                currentUser: "test",
                operatingSystem: "test",
                machineArchitecture: "arm64",
                signatureVerified: true,
                signatureDetails: "test"
            ),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "configured"),
            settings: DiagnosticSettingsInfo(
                shortcut: "test", engineModelType: "test", persistentSessionLogEnabled: true
            ),
            events: entries,
            logDirectoryPath: directory.path
        )
        XCTAssertTrue(report.events.contains { $0.event == "input_operation" })
        XCTAssertTrue(report.findings.contains { $0.code == "input_operation_trace" })
        XCTAssertTrue(report.renderedText().contains("operationType=tail_replacement"))
    }
}

@MainActor
private func makeCoordinator(
    asr: RealtimeASRClient = FakeRealtimeASRClient(),
    audio: AudioCapture = FakeAudioCapture(),
    target: TextTarget,
    credentials: TencentCredentials? = TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
    settingsStore: SettingsStore? = nil,
    finalizationWarningNanoseconds: UInt64 = 30_000_000_000,
    keyboardSmoothing: KeyboardSmoothingConfiguration = .immediate,
    pacingClock: KeyboardPacingClock? = nil,
    finalizationClock: KeyboardPacingClock? = nil,
    onStateChange: @escaping (SessionState) -> Void = { _ in }
) -> SessionCoordinator {
    SessionCoordinator(
        asr: asr,
        audio: audio,
        textTarget: target,
        settingsStore: settingsStore
            ?? UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
        credentialStore: InMemoryCredentialStore(credentials),
        finalizationWarningNanoseconds: finalizationWarningNanoseconds,
        keyboardSmoothing: keyboardSmoothing,
        pacingClock: pacingClock,
        finalizationClock: finalizationClock,
        onStateChange: onStateChange
    )
}

@MainActor
private func settleCoordinator() async {
    for _ in 0..<10 {
        await Task.yield()
    }
}

@MainActor
private func waitForAudioStart(_ audio: FakeAudioCapture, count: Int) async {
    for _ in 0..<100 {
        if audio.startCallCount >= count { return }
        await Task.yield()
    }
    XCTFail("audio start did not reach call (count)")
}

private func assertThrowsAsync<T>(_ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected an error")
    } catch {
        // Expected path.
    }
}
