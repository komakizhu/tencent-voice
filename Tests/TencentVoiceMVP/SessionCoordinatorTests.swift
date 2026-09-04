import Foundation
import XCTest
@testable import TencentVoiceMVP

@MainActor
final class SessionCoordinatorTests: XCTestCase {
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
        let target = FakeTextTarget(text: "")
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
        let target = FakeTextTarget(text: "")
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
        let target = FakeTextTarget(text: "已有文字")
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
        let target = FakeTextTarget(text: "已有文字")
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
}

@MainActor
private func makeCoordinator(
    asr: RealtimeASRClient = FakeRealtimeASRClient(),
    audio: AudioCapture = FakeAudioCapture(),
    target: TextTarget,
    credentials: TencentCredentials? = TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
    finishTimeoutNanoseconds: UInt64 = 3_000_000_000
) -> SessionCoordinator {
    SessionCoordinator(
        asr: asr,
        audio: audio,
        textTarget: target,
        settingsStore: UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"),
        credentialStore: InMemoryCredentialStore(credentials),
        finishTimeoutNanoseconds: finishTimeoutNanoseconds,
        onStateChange: { _ in }
    )
}

private func assertThrowsAsync<T>(_ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected an error")
    } catch {
        // Expected path.
    }
}
