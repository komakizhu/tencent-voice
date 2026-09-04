import Foundation

/// Serializes audio callbacks that were scheduled by the capture queue.
///
/// Audio capture delivers chunks through a synchronous callback, while the
/// ASR client is async. A single worker preserves capture order and gives
/// stop() a reliable barrier: the end marker is sent only after the final
/// captured chunk has reached the ASR client.
final class AudioChunkForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<(@Sendable () async -> Void)>.Continuation
    private let worker: Task<Void, Never>
    private var accepting = true

    init() {
        var streamContinuation: AsyncStream<(@Sendable () async -> Void)>.Continuation?
        let stream = AsyncStream<(@Sendable () async -> Void)> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation!
        worker = Task {
            for await operation in stream {
                await operation()
            }
        }
    }

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        continuation.yield(operation)
        lock.unlock()
    }

    func stopAccepting() {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        accepting = false
        continuation.finish()
        lock.unlock()
    }

    func drain() async {
        await worker.value
    }

    func cancel() {
        lock.lock()
        accepting = false
        continuation.finish()
        worker.cancel()
        lock.unlock()
    }
}
