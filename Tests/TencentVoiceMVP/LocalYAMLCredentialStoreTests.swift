import Foundation
import XCTest
@testable import TencentVoiceMVP

final class LocalYAMLCredentialStoreTests: XCTestCase {
    func testCredentialsRoundTripThroughLocalYAML() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("credentials.yaml")
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentials = TencentCredentials(
            appID: "1250000000",
            secretID: "secret-id",
            secretKey: "secret-key"
        )
        let store = LocalYAMLCredentialStore(fileURL: fileURL)

        try store.save(credentials)

        XCTAssertEqual(try store.load(), credentials)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
