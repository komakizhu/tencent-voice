import Foundation
import XCTest
@testable import TencentVoiceMVP

final class TencentASRClientTests: XCTestCase {
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
