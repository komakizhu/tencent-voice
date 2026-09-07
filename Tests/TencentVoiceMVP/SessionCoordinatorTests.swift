import Foundation
import XCTest
@testable import TencentVoiceMVP

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    func testStopFlushesPendingKeyboardSmoothingCharacters() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(
            asr: asr,
            target: target,
            finishTimeoutNanoseconds: 10_000_000,
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

    func testStoppingStartsPacingFlushBeforeASRWaitCompletes() async throws {
        let asr = FakeRealtimeASRClient()
        asr.finishCompletesStream = false
        let clock = ManualKeyboardPacingClock()
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let coordinator = makeCoordinator(
            asr: asr,
            target: target,
            finishTimeoutNanoseconds: 3_000_000_000,
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
        XCTAssertEqual(target.text, "甲乙")

        clock.advance(by: 120_000_000)
        await settleCoordinator()
        XCTAssertEqual(target.text, "甲乙丙丁戊")

        asr.finishStream()
        await ending.value
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
            finishTimeoutNanoseconds: 3_000_000_000,
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

        XCTAssertEqual(target.text, "这是一句未完成的话")
        asr.finishStream()
        await ending.value
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
        let coordinator = makeCoordinator(asr: asr, audio: audio, target: FakeTextTarget(text: ""))

        try await coordinator.begin()
        try await coordinator.end()

        XCTAssertEqual(asr.eventOrder, ["audio", "finish"])
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
        let coordinator = makeCoordinator(
            asr: asr,
            target: target,
            finishTimeoutNanoseconds: 10_000_000
        )

        try await coordinator.begin()
        asr.emit(ASRUpdate(
            segmentID: 1,
            segmentOrder: 0,
            sequence: 0,
            segmentText: "收尾中的文字",
            phase: .partial
        ))
        try await coordinator.end()

        XCTAssertEqual(target.text, "已有文字收尾中的文字")
        XCTAssertEqual(coordinator.state, .idle)
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
        settingsStore.save(AppSettings(safeCopyEnabled: true))
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
        try await coordinator.end()

        XCTAssertEqual(target.text, "原文安全复制结果")
        XCTAssertEqual(target.copiedText, "安全复制结果")
    }
}

@MainActor
private func makeCoordinator(
    asr: RealtimeASRClient = FakeRealtimeASRClient(),
    audio: AudioCapture = FakeAudioCapture(),
    target: TextTarget,
    credentials: TencentCredentials? = TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
    settingsStore: SettingsStore? = nil,
    finishTimeoutNanoseconds: UInt64 = 3_000_000_000,
    keyboardSmoothing: KeyboardSmoothingConfiguration = .immediate,
    pacingClock: KeyboardPacingClock? = nil
) -> SessionCoordinator {
    SessionCoordinator(
        asr: asr,
        audio: audio,
        textTarget: target,
        settingsStore: settingsStore
            ?? UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
        credentialStore: InMemoryCredentialStore(credentials),
        finishTimeoutNanoseconds: finishTimeoutNanoseconds,
        keyboardSmoothing: keyboardSmoothing,
        pacingClock: pacingClock,
        onStateChange: { _ in }
    )
}

@MainActor
private func settleCoordinator() async {
    for _ in 0..<10 {
        await Task.yield()
    }
}

private func assertThrowsAsync<T>(_ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected an error")
    } catch {
        // Expected path.
    }
}
