import XCTest
@testable import TencentVoiceMVP

final class KeychainCredentialStoreTests: XCTestCase {
    func testCredentialsRoundTripThroughKeychain() throws {
        let store = KeychainCredentialStore(service: "local.tencent.voice.mvp.tests.\(UUID().uuidString)")
        try? store.delete()
        defer { try? store.delete() }

        let credentials = TencentCredentials(appID: "test-app-id", secretID: "test-secret-id", secretKey: "test-secret-key")
        try store.save(credentials)
        XCTAssertEqual(try store.load(), credentials)
    }
}
