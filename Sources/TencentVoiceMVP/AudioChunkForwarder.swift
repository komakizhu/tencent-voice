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
    private let drainGate: DrainGate
    private var accepting = true

    init() {
        let drainGate = DrainGate()
        self.drainGate = drainGate
        var streamContinuation: AsyncStream<(@Sendable () async -> Void)>.Continuation?
        let stream = AsyncStream<(@Sendable () async -> Void)> { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation!
        worker = Task {
            for await operation in stream {
                if Task.isCancelled { break }
                await operation()
            }
            drainGate.resolve()
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
        await drainGate.wait()
    }

    func cancel() {
        lock.lock()
        accepting = false
        continuation.finish()
        worker.cancel()
        lock.unlock()
        drainGate.resolve()
    }
}

private final class DrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isResolved {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func resolve() {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
