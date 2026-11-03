import Foundation
import XCTest
@testable import TencentVoiceMVP

final class AudioChunkForwarderTests: XCTestCase {
    func testCancelUnblocksDrainWhileCurrentSendIsStillSuspended() async {
        let forwarder = AudioChunkForwarder()
        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let suspension = ForwarderSendSuspension()

        forwarder.submit {
            await suspension.pause(started: startedContinuation)
        }
        forwarder.stopAccepting()

        for await _ in startedStream {
            break
        }

        let drainTask = Task { await forwarder.drain() }
        await Task.yield()
        forwarder.cancel()
        await drainTask.value

        suspension.resume()
        await Task.yield()
    }
}

private final class ForwarderSendSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func pause(started: AsyncStream<Void>.Continuation) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            started.yield()
        }
    }

    func resume() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
