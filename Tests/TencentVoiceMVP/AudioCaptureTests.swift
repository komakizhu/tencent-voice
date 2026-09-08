import AVFoundation
import Foundation
import XCTest
@testable import TencentVoiceMVP

final class AudioCaptureTests: XCTestCase {
    func testInitialCaptureUsesNilTapAndConverts24KHz() async throws {
        let first = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let factory = AudioEngineFactoryBox(adapters: [first])
        let scheduler = ManualAudioRecoveryScheduler()
        let capture = SystemAudioCapture(
            engineFactory: { factory.next() },
            scheduler: scheduler
        )
        let chunks = LockedDataBox()

        try await capture.start(
            sessionID: UUID(),
            onChunk: { chunks.append($0) },
            onEvent: { _ in XCTFail("initial capture should not emit recovery events") }
        )
        XCTAssertNil(first.installedTapFormat)

        first.emitBuffer(frameCount: 4_800)
        await settleAudioCapture()
        capture.stop()

        XCTAssertGreaterThan(chunks.totalCount, 0)
        XCTAssertEqual(first.startCallCount, 1)
        XCTAssertEqual(first.removeTapCallCount, 1)
    }

    func testConfigurationChangeRebuildsTapForBothSampleRateDirections() async throws {
        let first = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let second = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 48_000))
        let factory = AudioEngineFactoryBox(adapters: [first, second])
        let scheduler = ManualAudioRecoveryScheduler()
        let events = LockedEventBox()
        let capture = SystemAudioCapture(
            engineFactory: { factory.next() },
            scheduler: scheduler
        )

        try await capture.start(
            sessionID: UUID(),
            onChunk: { _ in },
            onEvent: { events.append($0) }
        )
        first.emitBuffer(frameCount: 4_800)
        await settleAudioCapture()
        first.notifyConfigurationChange()
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()

        XCTAssertNil(first.installedTapFormat)
        XCTAssertNil(second.installedTapFormat)
        XCTAssertEqual(second.startCallCount, 1)

        second.emitBuffer(frameCount: 9_600)
        await settleAudioCapture()
        capture.stop()

        XCTAssertTrue(events.contains { event in
            if case .interrupted = event.kind { return true }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case let .recovered(format, _) = event.kind {
                return format == AudioCaptureFormat(sampleRate: 48_000, channelCount: 1)
            }
            return false
        })
    }

    func testConfigurationChangeAlsoRebuildsFrom48KHzTo24KHzAndTracksChannels() async throws {
        let first = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 48_000))
        let second = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000, channels: 2))
        let factory = AudioEngineFactoryBox(adapters: [first, second])
        let scheduler = ManualAudioRecoveryScheduler()
        let events = LockedEventBox()
        let capture = SystemAudioCapture(
            engineFactory: { factory.next() },
            scheduler: scheduler
        )

        try await capture.start(
            sessionID: UUID(),
            onChunk: { _ in },
            onEvent: { events.append($0) }
        )
        first.notifyConfigurationChange()
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()
        second.emitBuffer(frameCount: 4_800)
        await settleAudioCapture()
        capture.stop()

        XCTAssertTrue(events.contains { event in
            if case let .recovered(format, _) = event.kind {
                return format == AudioCaptureFormat(sampleRate: 24_000, channelCount: 2)
            }
            return false
        })
    }

    func testStaleBufferFromOldEngineCannotReachNewSessionGeneration() async throws {
        let first = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let second = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 48_000))
        let factory = AudioEngineFactoryBox(adapters: [first, second])
        let scheduler = ManualAudioRecoveryScheduler()
        let chunks = LockedDataBox()
        let capture = SystemAudioCapture(
            engineFactory: { factory.next() },
            scheduler: scheduler
        )

        try await capture.start(
            sessionID: UUID(),
            onChunk: { chunks.append($0) },
            onEvent: { _ in }
        )
        first.notifyConfigurationChange()
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()

        first.emitStaleBuffer(frameCount: 9_600)
        second.emitBuffer(frameCount: 9_600)
        await settleAudioCapture()
        capture.stop()

        XCTAssertGreaterThan(chunks.totalCount, 0)
        XCTAssertLessThan(chunks.totalCount, 10_000)
    }

    func testRecoveryTimesOutWithoutAValidAudioBuffer() async throws {
        let first = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let second = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 48_000))
        let factory = AudioEngineFactoryBox(adapters: [first, second])
        let scheduler = ManualAudioRecoveryScheduler()
        let events = LockedEventBox()
        let capture = SystemAudioCapture(
            engineFactory: { factory.next() },
            scheduler: scheduler,
            recoveryRetryNanoseconds: 250,
            recoveryTimeoutNanoseconds: 1_000
        )

        try await capture.start(
            sessionID: UUID(),
            onChunk: { _ in },
            onEvent: { events.append($0) }
        )
        first.notifyConfigurationChange()
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()
        scheduler.advance(by: 1_000)
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()

        XCTAssertTrue(events.contains { event in
            if case .failed(.recoveryTimedOut) = event.kind { return true }
            return false
        })
        capture.stop()
    }

    func testRecoveryRetriesAfterEngineStartFailure() async throws {
        let first = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let failed = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 48_000))
        failed.startError = AudioEngineTestError.startFailed
        let recovered = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 48_000))
        let factory = AudioEngineFactoryBox(adapters: [first, failed, recovered])
        let scheduler = ManualAudioRecoveryScheduler()
        let events = LockedEventBox()
        let capture = SystemAudioCapture(
            engineFactory: { factory.next() },
            scheduler: scheduler,
            recoveryRetryNanoseconds: 250,
            recoveryTimeoutNanoseconds: 3_000
        )

        try await capture.start(
            sessionID: UUID(),
            onChunk: { _ in },
            onEvent: { events.append($0) }
        )
        first.notifyConfigurationChange()
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()
        XCTAssertEqual(failed.startCallCount, 1)

        scheduler.advance(by: 250)
        await settleAudioCapture()
        recovered.emitBuffer(frameCount: 4_800)
        await settleAudioCapture()

        XCTAssertTrue(events.contains { event in
            if case let .recovered(format, _) = event.kind {
                return format == AudioCaptureFormat(sampleRate: 48_000, channelCount: 1)
            }
            return false
        })
        capture.stop()
    }

    func testRecoveryKeepsStartedEngineWhileFirstBufferIsDelayed() async throws {
        let first = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let second = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 48_000))
        let factory = AudioEngineFactoryBox(adapters: [first, second])
        let scheduler = ManualAudioRecoveryScheduler()
        let events = LockedEventBox()
        let capture = SystemAudioCapture(engineFactory: { factory.next() }, scheduler: scheduler)
        try await capture.start(sessionID: UUID(), onChunk: { _ in }, onEvent: { events.append($0) })
        first.notifyConfigurationChange()
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()
        scheduler.advance(by: 600_000_000)
        await settleAudioCapture()
        XCTAssertEqual(second.startCallCount, 1)
        XCTAssertEqual(second.removeTapCallCount, 0)
        second.emitBuffer(frameCount: 9_600)
        await settleAudioCapture()
        XCTAssertTrue(events.contains { if case .recovered = $0.kind { return true }; return false })
        capture.stop()
    }

    func testNormalStartDoesNotWaitForRecoveryClock() async throws {
        let engine = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let scheduler = ManualAudioRecoveryScheduler()
        let chunks = LockedDataBox()
        let capture = SystemAudioCapture(engineFactory: { engine }, scheduler: scheduler)
        try await capture.start(sessionID: UUID(), onChunk: { chunks.append($0) }, onEvent: { _ in
            XCTFail("normal start must not enter recovery")
        })
        engine.emitBuffer(frameCount: 9_600)
        await settleAudioCapture()
        engine.onConfigurationChange?()
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()
        XCTAssertGreaterThan(chunks.totalCount, 0)
        XCTAssertEqual(engine.startCallCount, 1)
        XCTAssertEqual(scheduler.nowNanoseconds(), 0)
        capture.stop()
    }

    func testStopAndRestartCancelsOldRecoveryDeadline() async throws {
        let first = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let recovering = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 48_000))
        let restarted = FakeAudioEngineAdapter(format: makeFormat(sampleRate: 24_000))
        let factory = AudioEngineFactoryBox(adapters: [first, recovering, restarted])
        let scheduler = ManualAudioRecoveryScheduler()
        let capture = SystemAudioCapture(engineFactory: { factory.next() }, scheduler: scheduler)
        try await capture.start(sessionID: UUID(), onChunk: { _ in }, onEvent: { _ in })
        first.notifyConfigurationChange()
        await settleAudioCapture()
        scheduler.runDue()
        await settleAudioCapture()
        capture.stop()
        let chunks = LockedDataBox()
        try await capture.start(sessionID: UUID(), onChunk: { chunks.append($0) }, onEvent: { _ in
            XCTFail("old recovery must not affect the next session")
        })
        scheduler.advance(by: 4_000_000_000)
        await settleAudioCapture()
        recovering.emitStaleBuffer(frameCount: 9_600)
        restarted.emitBuffer(frameCount: 9_600)
        await settleAudioCapture()
        XCTAssertEqual(restarted.startCallCount, 1)
        XCTAssertEqual(restarted.removeTapCallCount, 0)
        XCTAssertGreaterThan(chunks.totalCount, 0)
        capture.stop()
    }

    private func makeFormat(sampleRate: Double, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }
}

private final class AudioEngineFactoryBox: @unchecked Sendable {
    private var adapters: [FakeAudioEngineAdapter]
    private var index = 0

    init(adapters: [FakeAudioEngineAdapter]) {
        self.adapters = adapters
    }

    func next() -> AudioEngineAdapter {
        defer { index += 1 }
        return adapters[min(index, adapters.count - 1)]
    }
}

private final class FakeAudioEngineAdapter: AudioEngineAdapter {
    private(set) var isRunning = false
    let inputFormat: AVAudioFormat
    private var tapHandler: ((AVAudioPCMBuffer) -> Void)?
    private var staleTapHandler: ((AVAudioPCMBuffer) -> Void)?
    var onConfigurationChange: (() -> Void)?
    private(set) var installedTapFormat: AVAudioFormat?
    private(set) var startCallCount = 0
    private(set) var removeTapCallCount = 0
    var startError: Error?

    init(format: AVAudioFormat) {
        inputFormat = format
    }

    func installTap(
        format: AVAudioFormat?,
        bufferSize: AVAudioFrameCount,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        installedTapFormat = format
        tapHandler = handler
    }

    func removeTap() {
        removeTapCallCount += 1
        staleTapHandler = tapHandler
        tapHandler = nil
    }

    func prepare() {}

    func start() throws {
        startCallCount += 1
        if let startError {
            throw startError
        }
        isRunning = true
    }

    func stop() { isRunning = false }

    func notifyConfigurationChange() {
        isRunning = false
        onConfigurationChange?()
    }

    func emitBuffer(frameCount: AVAudioFrameCount) {
        emitBuffer(frameCount: frameCount, using: tapHandler)
    }

    func emitStaleBuffer(frameCount: AVAudioFrameCount) {
        emitBuffer(frameCount: frameCount, using: staleTapHandler)
    }

    private func emitBuffer(
        frameCount: AVAudioFrameCount,
        using handler: ((AVAudioPCMBuffer) -> Void)?
    ) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            XCTFail("test audio buffer could not be allocated")
            return
        }
        buffer.frameLength = frameCount
        handler?(buffer)
    }
}

private enum AudioEngineTestError: Error {
    case startFailed
}

private final class ManualAudioRecoveryScheduler: AudioRecoveryScheduler, @unchecked Sendable {
    private final class Entry: AudioRecoverySchedule {
        let deadline: UInt64
        let operation: @Sendable () -> Void
        var isCancelled = false

        init(deadline: UInt64, operation: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.operation = operation
        }

        func cancel() {
            isCancelled = true
        }
    }

    private var now: UInt64 = 0
    private var entries: [Entry] = []
    private let lock = NSLock()

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    @discardableResult
    func schedule(
        afterNanoseconds: UInt64,
        _ operation: @escaping @Sendable () -> Void
    ) -> AudioRecoverySchedule {
        lock.lock()
        let entry = Entry(deadline: now + afterNanoseconds, operation: operation)
        entries.append(entry)
        lock.unlock()
        return entry
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        now += nanoseconds
        let due = entries.filter { !$0.isCancelled && $0.deadline <= now }
        entries.removeAll { $0.deadline <= now || $0.isCancelled }
        lock.unlock()
        due.forEach { $0.operation() }
    }

    func runDue() {
        advance(by: 0)
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }

    func append(_ value: Data) {
        lock.lock()
        data.append(value)
        lock.unlock()
    }
}

private final class LockedEventBox: @unchecked Sendable {
    private var events: [AudioCaptureEvent] = []
    private let lock = NSLock()

    func append(_ event: AudioCaptureEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func contains(where predicate: (AudioCaptureEvent) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains(where: predicate)
    }
}

private func settleAudioCapture() async {
    try? await Task.sleep(nanoseconds: 10_000_000)
    for _ in 0..<20 {
        await Task.yield()
    }
}
