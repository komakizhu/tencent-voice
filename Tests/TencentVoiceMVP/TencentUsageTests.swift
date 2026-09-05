import Foundation
import XCTest
@testable import TencentVoiceMVP

final class TencentUsageTests: XCTestCase {
    func testGeneralRealtimeEngineHasFiveHourFreeQuota() {
        XCTAssertEqual(TencentUsageQuota.freeQuotaSeconds(for: "16k_zh"), 18_000)
    }

    func testLargeModelHasNoFreeQuota() {
        XCTAssertEqual(TencentUsageQuota.freeQuotaSeconds(for: "16k_zh_en_2.0"), 0)
    }

    func testConfiguredPrepaidQuotaOverridesFreeQuota() {
        XCTAssertEqual(
            TencentUsageQuota.seconds(for: "16k_zh_en_2.0", prepaidHours: 60),
            216_000
        )
        XCTAssertEqual(
            TencentUsageQuota.seconds(for: "16k_zh", prepaidHours: nil),
            18_000
        )
    }

    func testPrepaidSummaryShowsPackagePercentage() {
        let summary = TencentUsageSummary(
            localUsedSeconds: 18_000,
            quotaSeconds: 60 * 3_600,
            engineModelType: "16k_zh_en_2.0",
            isPrepaid: true
        )

        XCTAssertEqual(summary.percentage, 8)
        XCTAssertEqual(
            summary.displayText,
            "本地套餐用量（16k_zh_en_2.0）：5小时0分 / 60小时（已用 8%）"
        )
    }

    func testUsagePercentageUsesTheLocallyRecordedValue() {
        let summary = TencentUsageSummary(
            localUsedSeconds: 120,
            quotaSeconds: 300,
            engineModelType: "16k_zh"
        )

        XCTAssertEqual(summary.usedSeconds, 120)
        XCTAssertEqual(summary.percentage, 40)
        XCTAssertEqual(summary.displayText, "本地本月用量（16k_zh）：2分0秒 / 5分0秒（已用 40%）")
    }

    func testLocalUsageSessionIsLiveAndCommittedWhenItEnds() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalUsageStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)

        store.beginSession(for: "16k_zh_en_2.0", at: start)
        store.touchSession(at: start.addingTimeInterval(37))

        XCTAssertEqual(store.currentSeconds(for: "16k_zh_en_2.0", at: start.addingTimeInterval(37)), 37)
        XCTAssertEqual(store.currentSeconds(for: "16k_zh", at: start.addingTimeInterval(37)), 0)
        XCTAssertEqual(store.endSession(at: start.addingTimeInterval(37)), 37)
        XCTAssertEqual(store.seconds(for: "16k_zh_en_2.0", at: start.addingTimeInterval(37)), 37)
        XCTAssertEqual(store.seconds(for: "16k_zh", at: start.addingTimeInterval(37)), 0)
        XCTAssertFalse(store.hasActiveSession)
    }

    func testUsageIsTrackedSeparatelyForEachEngine() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalUsageStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_000_000)

        store.add(seconds: 12, for: "16k_zh", at: date)
        store.add(seconds: 34, for: "16k_zh_en_2.0", at: date)

        XCTAssertEqual(store.seconds(for: "16k_zh", at: date), 12)
        XCTAssertEqual(store.seconds(for: "16k_zh_en_2.0", at: date), 34)
    }

    func testTotalSecondsSpansMonthsForAQuotaPackage() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalUsageStore(defaults: defaults)
        let january = Date(timeIntervalSince1970: 1_000_000)
        let february = january.addingTimeInterval(31 * 24 * 3_600)

        store.add(seconds: 12, for: "16k_zh_en_2.0", at: january)
        store.add(seconds: 34, for: "16k_zh_en_2.0", at: february)

        XCTAssertEqual(store.totalSeconds(for: "16k_zh_en_2.0"), 46)
    }

    func testLegacyUnscopedUsageDoesNotLeakIntoAnEngineBucket() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalUsageStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_000_000)

        defaults.set(99, forKey: "localUsageSeconds.1970-01")

        XCTAssertEqual(store.seconds(for: "16k_zh_en_2.0", at: date), 0)
    }

    func testLegacyUnscopedUsageMigratesToThePreviousDefaultEngineOnlyOnce() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalUsageStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_000_000)

        defaults.set(99, forKey: "localUsageSeconds.1970-01")

        store.migrateLegacyUnscopedUsage(to: "16k_zh")
        store.migrateLegacyUnscopedUsage(to: "16k_zh")

        XCTAssertEqual(store.seconds(for: "16k_zh", at: date), 99)
        XCTAssertEqual(store.seconds(for: "16k_zh_en_2.0", at: date), 0)
        XCTAssertEqual(defaults.integer(forKey: "localUsageSeconds.1970-01"), 99)
    }

    func testAbandonedLocalUsageSessionIsRecoveredOnNextLaunch() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalUsageStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 2_000_000)

        store.beginSession(for: "16k_zh", at: start)
        store.touchSession(at: start.addingTimeInterval(12))
        XCTAssertEqual(store.recoverAbandonedSession(), 12)
        XCTAssertEqual(store.seconds(for: "16k_zh", at: start.addingTimeInterval(12)), 12)
        XCTAssertFalse(store.hasActiveSession)
    }

    func testSharedUsageIsVisibleToAnotherMacOSAccountForTheSameCredentials() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPSharedUsage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("usage.json")
        let credentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let alice = SharedUsageStore(fileURL: fileURL, ownerID: "alice", processID: 1)
        let bob = SharedUsageStore(fileURL: fileURL, ownerID: "bob", processID: 2)
        let start = Date(timeIntervalSince1970: 1_000_000)

        let sessionID = try alice.beginSession(
            for: credentials,
            engineModelType: "16k_zh",
            at: start
        )
        XCTAssertEqual(
            try bob.currentSeconds(
                for: credentials,
                engineModelType: "16k_zh",
                at: start.addingTimeInterval(37)
            ),
            37
        )
        XCTAssertEqual(try alice.endSession(sessionID, at: start.addingTimeInterval(37)), 37)
        XCTAssertEqual(
            try bob.currentSeconds(
                for: credentials,
                engineModelType: "16k_zh",
                at: start.addingTimeInterval(37)
            ),
            37
        )
    }

    func testSharedUsageSeparatesDifferentCredentialIdentities() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPSharedUsage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("usage.json")
        let firstCredentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let secondCredentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "other-key")
        let store = SharedUsageStore(fileURL: fileURL, ownerID: "alice", processID: 1)
        let start = Date(timeIntervalSince1970: 1_000_000)

        let sessionID = try store.beginSession(
            for: firstCredentials,
            engineModelType: "16k_zh",
            at: start
        )
        _ = try store.endSession(sessionID, at: start.addingTimeInterval(12))

        XCTAssertEqual(
            try store.currentSeconds(
                for: firstCredentials,
                engineModelType: "16k_zh",
                at: start.addingTimeInterval(12)
            ),
            12
        )
        XCTAssertEqual(
            try store.currentSeconds(
                for: secondCredentials,
                engineModelType: "16k_zh",
                at: start.addingTimeInterval(12)
            ),
            0
        )
    }

    func testExistingPerUserUsageMigratesToSharedCredentialBucketOnce() throws {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localStore = LocalUsageStore(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPSharedUsage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedStore = SharedUsageStore(
            fileURL: directory.appendingPathComponent("usage.json"),
            ownerID: "alice",
            processID: 1
        )
        let credentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let date = Date(timeIntervalSince1970: 1_000_000)
        localStore.add(seconds: 19, for: "16k_zh", at: date)

        try sharedStore.migrateLocalUsageIfNeeded(from: localStore, for: credentials)
        try sharedStore.migrateLocalUsageIfNeeded(from: localStore, for: credentials)

        XCTAssertEqual(
            try sharedStore.currentSeconds(
                for: credentials,
                engineModelType: "16k_zh",
                at: date
            ),
            19
        )
        let content = try String(contentsOf: directory.appendingPathComponent("usage.json"))
        XCTAssertFalse(content.contains(credentials.secretKey))
    }

    func testPrepaidQuotaIsSharedForTheSameCredentials() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPSharedUsage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let alice = SharedUsageStore(
            fileURL: directory.appendingPathComponent("usage.json"),
            ownerID: "alice",
            processID: 1
        )
        let bob = SharedUsageStore(
            fileURL: directory.appendingPathComponent("usage.json"),
            ownerID: "bob",
            processID: 2
        )

        try alice.setPrepaidQuotaHours(60, for: credentials, engineModelType: "16k_zh_en_2.0")

        XCTAssertEqual(
            try bob.prepaidQuotaHours(for: credentials, engineModelType: "16k_zh_en_2.0"),
            60
        )
    }

    func testLegacyLocalUsageIsNotCopiedAgainWhenTheUserChangesCredentials() throws {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localStore = LocalUsageStore(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPSharedUsage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedStore = SharedUsageStore(
            fileURL: directory.appendingPathComponent("usage.json"),
            ownerID: "alice",
            processID: 1
        )
        let firstCredentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let secondCredentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "other-key")
        let date = Date(timeIntervalSince1970: 1_000_000)
        localStore.add(seconds: 19, for: "16k_zh", at: date)

        try sharedStore.migrateLocalUsageIfNeeded(from: localStore, for: firstCredentials)
        try sharedStore.migrateLocalUsageIfNeeded(from: localStore, for: secondCredentials)

        XCTAssertEqual(
            try sharedStore.currentSeconds(
                for: firstCredentials,
                engineModelType: "16k_zh",
                at: date
            ),
            19
        )
        XCTAssertEqual(
            try sharedStore.currentSeconds(
                for: secondCredentials,
                engineModelType: "16k_zh",
                at: date
            ),
            0
        )
    }
}
