import Foundation
import XCTest
@testable import TencentVoiceMVP

final class TencentASRClientTests: XCTestCase {
    func testCancelledQueuedSendCannotUseCurrentConnection() async throws {
        let socket = ControlledTencentWebSocket()
        socket.deliver(.string("{\"code\":0,\"message\":\"success\"}"))
        let client = TencentASRClient { _ in socket }
        let stream = try await client.start(configuration: configuration)
        for sendsEndMarker in [false, true] {
            let suspension = SuspendedASROperation()
            let sending = Task {
                await suspension.wait()
                if sendsEndMarker { try await client.finish() }
                else { try await client.sendAudio(Data([1, 2])) }
            }
            for _ in 0..<200 where !suspension.isWaiting { await Task.yield() }
            XCTAssertTrue(suspension.isWaiting)
            sending.cancel()
            suspension.resume()
            do {
                try await sending.value
                XCTFail("Cancelled operations must not send into the current connection")
            } catch is CancellationError {
                // Expected.
            }
        }
        XCTAssertEqual(socket.sentMessageCount, 0)
        XCTAssertFalse(socket.didCancel)
        client.cancel()
        socket.deliver(.string("{\"code\":0,\"message\":\"success\",\"final\":1}"))
        _ = stream
    }

    func testSentenceFinalDoesNotEndStreamAndStreamFinalLeavesSocketForCallerCleanup() async throws {
        let socket = ControlledTencentWebSocket()
        socket.deliver(.string("{\"code\":0,\"message\":\"success\"}"))
        let client = TencentASRClient { _ in socket }
        let stream = try await client.start(configuration: configuration)
        let sentence = expectation(description: "sentence final")
        let complete = expectation(description: "whole stream final")
        let consumer = Task {
            for try await update in stream {
                if update.isStreamEnded { complete.fulfill() }
                else { sentence.fulfill() }
            }
        }
        socket.deliver(.string("{\"code\":0,\"message\":\"success\",\"final\":0,\"result\":{\"slice_type\":2,\"index\":0,\"voice_text_str\":\"句子\"}}"))
        await fulfillment(of: [sentence], timeout: 2)
        XCTAssertFalse(socket.didCancel)
        socket.deliver(.string("{\"code\":0,\"message\":\"success\",\"final\":1}"))
        await fulfillment(of: [complete], timeout: 2)
        try await consumer.value
        XCTAssertFalse(socket.didCancel, "Final delivery must not cancel an end-marker send still awaiting its callback")
        client.cancel()
        XCTAssertTrue(socket.didCancel)
    }

    func testCancelledReceiveCannotDeliverFinalOrCancelNewConnection() async throws {
        let oldSocket = ControlledTencentWebSocket()
        let newSocket = ControlledTencentWebSocket()
        oldSocket.deliver(.string("{\"code\":0,\"message\":\"success\"}"))
        newSocket.deliver(.string("{\"code\":0,\"message\":\"success\"}"))
        var sockets = [oldSocket, newSocket]
        let client = TencentASRClient { _ in sockets.removeFirst() }
        let oldStream = try await client.start(configuration: configuration)
        let oldWaiting = expectation(description: "old receive suspended")
        oldSocket.onReceiveWaiting = { oldWaiting.fulfill() }
        await fulfillment(of: [oldWaiting], timeout: 2)
        client.cancel()
        let newStream = try await client.start(configuration: configuration)
        let newResult = expectation(description: "new connection result")
        let consumer = Task { () throws -> [String] in
            var result: [String] = []
            for try await update in newStream {
                if !update.isStreamEnded {
                    result.append(update.text)
                    newResult.fulfill()
                }
            }
            return result
        }
        // Simulate a transport that returns one queued message despite task cancellation.
        oldSocket.deliver(.string("{\"code\":0,\"message\":\"success\",\"final\":1,\"result\":{\"slice_type\":2,\"index\":0,\"voice_text_str\":\"旧会话\"}}"))
        newSocket.deliver(.string("{\"code\":0,\"message\":\"success\",\"final\":1,\"result\":{\"slice_type\":2,\"index\":0,\"voice_text_str\":\"新会话\"}}"))
        await fulfillment(of: [newResult], timeout: 2)
        let result = try await consumer.value
        XCTAssertEqual(result, ["新会话"])
        _ = oldStream
        client.cancel()
    }

    func testConnectionCompletesAfterSuccessfulTencentHandshake() async throws {
        let socket = FakeTencentWebSocket(message: .string("{\"code\":0,\"message\":\"success\"}"))
        var requestedURL: URL?
        let client = TencentASRClient { url in
            requestedURL = url
            return socket
        }

        try await client.testConnection(configuration: configuration)

        XCTAssertTrue(socket.didResume)
        XCTAssertTrue(socket.didCancel)
        XCTAssertEqual(requestedURL?.host, "asr.cloud.tencent.com")
        XCTAssertTrue(requestedURL?.path.hasSuffix("/asr/v2/123") ?? false)
        XCTAssertFalse(requestedURL?.absoluteString.contains("secret-key") ?? true)
    }

    func testConnectionSurfacesTencentHandshakeError() async throws {
        let socket = FakeTencentWebSocket(message: .string("{\"code\":4002,\"message\":\"鉴权失败\"}"))
        let client = TencentASRClient { _ in socket }

        do {
            try await client.testConnection(configuration: configuration)
            XCTFail("expected handshake error")
        } catch let TencentASRError.server(code, message) {
            XCTAssertEqual(code, 4002)
            XCTAssertEqual(message, "鉴权失败")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(socket.didResume)
        XCTAssertTrue(socket.didCancel)
    }

    private var configuration: TencentSessionConfiguration {
        TencentSessionConfiguration(
            appID: "123",
            secretID: "secret-id",
            secretKey: "secret-key",
            engineModelType: "16k_zh"
        )
    }
}

private final class ControlledTencentWebSocket: TencentWebSocket {
    private let lock = NSLock()
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var cancelled = false
    private var sentCount = 0
    private var waitingObserver: (() -> Void)?
    var didCancel: Bool { lock.withLock { cancelled } }
    var sentMessageCount: Int { lock.withLock { sentCount } }
    var onReceiveWaiting: (() -> Void)? {
        get { lock.withLock { waitingObserver } }
        set {
            let notify = lock.withLock {
                waitingObserver = newValue
                return receiver != nil
            }
            if notify { newValue?() }
        }
    }
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { sentCount += 1 }
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { cancelled = true }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !messages.isEmpty {
                let message = messages.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else {
                receiver = continuation
                let observer = waitingObserver
                lock.unlock()
                observer?()
            }
        }
    }
    func deliver(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        let receiver = self.receiver
        self.receiver = nil
        if receiver == nil { messages.append(message) }
        lock.unlock()
        receiver?.resume(returning: message)
    }
}

private final class FakeTencentWebSocket: TencentWebSocket {
    let message: URLSessionWebSocketTask.Message
    private(set) var didResume = false
    private(set) var didCancel = false

    init(message: URLSessionWebSocketTask.Message) {
        self.message = message
    }

    func resume() {
        didResume = true
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        message
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        didCancel = true
    }
}
