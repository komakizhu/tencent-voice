import Foundation
import XCTest
@testable import TencentVoiceMVP

final class PersistentCredentialStoreTests: XCTestCase {
    func testNormalLoadDoesNotTouchLegacyKeychain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let primary = LocalYAMLCredentialStore(fileURL: directory.appendingPathComponent("credentials.yaml"))
        let legacy = CountingCredentialStore(credentials: sampleCredentials)
        let store = PersistentCredentialStore(primary: primary, legacy: legacy)

        XCTAssertNil(try store.load())
        XCTAssertEqual(legacy.loadCallCount, 0)
    }

    func testLegacyMigrationWritesYAMLOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = LocalYAMLCredentialStore(fileURL: directory.appendingPathComponent("credentials.yaml"))
        let legacy = CountingCredentialStore(credentials: sampleCredentials)
        let store = PersistentCredentialStore(primary: primary, legacy: legacy)

        XCTAssertEqual(try store.migrateLegacyIfNeeded(), sampleCredentials)
        XCTAssertEqual(legacy.loadCallCount, 1)
        XCTAssertEqual(try store.load(), sampleCredentials)
        XCTAssertEqual(legacy.loadCallCount, 1)
    }

    private var sampleCredentials: TencentCredentials {
        TencentCredentials(appID: "123", secretID: "sid", secretKey: "key")
    }
}

private final class CountingCredentialStore: CredentialStore {
    let credentials: TencentCredentials?
    private(set) var loadCallCount = 0

    init(credentials: TencentCredentials?) {
        self.credentials = credentials
    }

    func load() throws -> TencentCredentials? {
        loadCallCount += 1
        return credentials
    }

    func save(_ credentials: TencentCredentials) throws {}
    func delete() throws {}
}
