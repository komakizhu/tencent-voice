import Foundation
import XCTest
@testable import TencentVoiceMVP

final class TencentSignerTests: XCTestCase {
    func testHMACSHA1UsesRFC2202Vector() throws {
        let key = Data(repeating: 0x0b, count: 20)
        let digest = TencentSigner.hmacSHA1Base64(message: Data("Hi There".utf8), key: key)
        XCTAssertEqual(digest, "thcxhlUFcmTii8C2+zeMjvFGvgA=")
    }

    func testSignedURLContainsPercentEncodedSignatureAndNoSecretKey() throws {
        let configuration = TencentSessionConfiguration(
            appID: "1250000000",
            secretID: "secret-id",
            secretKey: "secret-key",
            engineModelType: "16k_zh_en_2.0",
            voiceID: "voice-1"
        )
        let url = try TencentSigner.makeURL(
            configuration: configuration,
            timestamp: 1_700_000_000,
            expired: 1_700_000_600,
            nonce: 123
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertTrue(url.absoluteString.contains("signature="))
        XCTAssertFalse(url.absoluteString.contains("secret-key"))
    }
}
