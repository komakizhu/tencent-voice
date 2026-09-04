import Foundation
@testable import TencentVoiceMVP

@MainActor
final class FakeTextTarget: TextTarget {
    var text: String
    private(set) var copiedText: String?
    private(set) var replaceCallCount = 0

    init(text: String) {
        self.text = text
    }

    func capture() throws -> TextSnapshot {
        TextSnapshot(text: text, selection: TencentVoiceMVP.TextRange(location: text.utf16.count, length: 0))
    }

    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String, with replacement: String) throws -> TencentVoiceMVP.TextRange {
        guard text == expectedText else { throw TextTargetError.targetChanged }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
        text = mutable as String
        replaceCallCount += 1
        return TencentVoiceMVP.TextRange(location: range.location, length: replacement.utf16.count)
    }

    func replacePastedText(previousText: String, with text: String) throws {
        guard previousText.isEmpty || self.text.hasSuffix(previousText) else {
            throw TextTargetError.targetChanged
        }
        let delta = PastedTextDelta(previousText: previousText, newText: text)
        if delta.backspaceCount > 0 {
            self.text.removeLast(delta.backspaceCount)
        }
        self.text.append(delta.insertion)
    }

    func paste(_ text: String) throws {
        copiedText = text
    }

    func copyToClipboard(_ text: String) throws {
        copiedText = text
    }
}

final class FakeRealtimeASRClient: RealtimeASRClient {
    private var continuation: AsyncThrowingStream<ASRUpdate, Error>.Continuation?
    private(set) var finishCallCount = 0
    var finishCompletesStream = true

    func start(configuration: TencentSessionConfiguration) async throws -> AsyncThrowingStream<ASRUpdate, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func sendAudio(_ data: Data) async throws {}

    func finish() async throws {
        finishCallCount += 1
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

    func start(onChunk: @escaping @Sendable (Data) -> Void) async throws {
        handler = onChunk
        startCallCount += 1
    }

    func stop() {}

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
