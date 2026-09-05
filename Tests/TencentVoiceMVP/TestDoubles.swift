import Foundation
@testable import TencentVoiceMVP

@MainActor
final class FakeTextTarget: TextTarget {
    var text: String
    let supportsAXReplacement: Bool
    private(set) var copiedText: String?
    private(set) var replaceCallCount = 0
    private(set) var pastedTexts: [String] = []
    private(set) var trailingReplacementLengths: [Int] = []

    init(text: String, supportsAXReplacement: Bool = true) {
        self.text = text
        self.supportsAXReplacement = supportsAXReplacement
    }

    func capture() throws -> TextSnapshot {
        TextSnapshot(
            text: text,
            selection: TencentVoiceMVP.TextRange(location: text.utf16.count, length: 0),
            supportsAXReplacement: supportsAXReplacement
        )
    }

    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String, with replacement: String) throws -> TencentVoiceMVP.TextRange {
        guard text == expectedText else { throw TextTargetError.targetChanged }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
        text = mutable as String
        replaceCallCount += 1
        return TencentVoiceMVP.TextRange(location: range.location, length: replacement.utf16.count)
    }

    func paste(_ text: String) throws {
        pastedTexts.append(text)
        self.text.append(text)
    }

    func replaceTrailingText(_ previousText: String, with replacement: String) throws {
        guard text.hasSuffix(previousText) else { throw TextTargetError.targetChanged }
        trailingReplacementLengths.append(previousText.count)
        text.removeLast(previousText.count)
        text.append(replacement)
    }

    func copyToClipboard(_ text: String) throws {
        copiedText = text
    }
}

@MainActor
final class ManualKeyboardPacingClock: KeyboardPacingClock {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var nowNanoseconds: UInt64 = 0
    private var sleepers: [UUID: Sleeper] = [:]

    func sleep(nanoseconds: UInt64) async throws {
        let deadline = nowNanoseconds + nanoseconds
        guard deadline > nowNanoseconds else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let sleeper = self.sleepers.removeValue(forKey: id) else { return }
                sleeper.continuation.resume(throwing: CancellationError())
            }
        })
    }

    func advance(by nanoseconds: UInt64) {
        nowNanoseconds += nanoseconds
        let ready = sleepers.filter { $0.value.deadline <= nowNanoseconds }
        for (id, sleeper) in ready {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }
}

extension KeyboardPacingConfiguration {
    static let test = KeyboardPacingConfiguration(
        firstCharacterDelayNanoseconds: 0,
        reservoirDelayNanoseconds: 40_000_000,
        initialCharacterIntervalNanoseconds: 20_000_000,
        minimumCharacterIntervalNanoseconds: 20_000_000,
        maximumCharacterIntervalNanoseconds: 60_000_000,
        normalMaximumLagNanoseconds: 250_000_000,
        defaultPartialCadenceNanoseconds: 600_000_000,
        cadenceFillRatio: 0.75,
        velocityChangeLimit: 0.12,
        continuityMinimumNanoseconds: 250_000_000,
        continuityMaximumNanoseconds: 900_000_000,
        finalFlushMaximumDurationNanoseconds: 120_000_000,
        frameIntervalNanoseconds: 16_000_000,
        ewmaAlpha: 0.25,
        easeOutExponent: 1.6
    )
}

final class FakeRealtimeASRClient: RealtimeASRClient {
    private var continuation: AsyncThrowingStream<ASRUpdate, Error>.Continuation?
    private(set) var finishCallCount = 0
    private(set) var startedConfiguration: TencentSessionConfiguration?
    private(set) var eventOrder: [String] = []
    var finishCompletesStream = true
    var sendAudioDelayNanoseconds: UInt64 = 0

    func start(configuration: TencentSessionConfiguration) async throws -> AsyncThrowingStream<ASRUpdate, Error> {
        startedConfiguration = configuration
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func sendAudio(_ data: Data) async throws {
        if sendAudioDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendAudioDelayNanoseconds)
        }
        eventOrder.append("audio")
    }

    func finish() async throws {
        finishCallCount += 1
        eventOrder.append("finish")
        if finishCompletesStream {
            finishStream()
        }
    }

    func cancel() {
        continuation?.finish()
    }

    func emit(_ update: ASRUpdate) {
        continuation?.yield(update)
    }

    func finishStream() {
        continuation?.yield(.streamEnded)
        continuation?.finish()
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
    }
}

final class FakeAudioCapture: AudioCapture {
    private var handler: (@Sendable (Data) -> Void)?
    private(set) var startCallCount = 0
    var dataToEmitOnStop: Data?

    func start(onChunk: @escaping @Sendable (Data) -> Void) async throws {
        handler = onChunk
        startCallCount += 1
    }

    func stop() {
        if let dataToEmitOnStop {
            handler?(dataToEmitOnStop)
        }
    }

    func emit(_ data: Data) {
        handler?(data)
    }
}

final class InMemoryCredentialStore: CredentialStore {
    var credentials: TencentCredentials?

    init(_ credentials: TencentCredentials?) {
        self.credentials = credentials
    }

    func load() throws -> TencentCredentials? { credentials }
    func save(_ credentials: TencentCredentials) throws { self.credentials = credentials }
    func delete() throws { credentials = nil }
}
