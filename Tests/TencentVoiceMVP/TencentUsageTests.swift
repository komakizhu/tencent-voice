import Foundation
import XCTest
@testable import TencentVoiceMVP

final class TencentUsageTests: XCTestCase {
    func testUsageCorrectionInputValidatesWholeHoursAndMinutes() {
        XCTAssertEqual(UsageCorrectionInput.seconds(hours: "19", minutes: "00"), 68_400)
        XCTAssertEqual(UsageCorrectionInput.seconds(hours: " 7 ", minutes: "27"), 26_820)
        XCTAssertNil(UsageCorrectionInput.seconds(hours: "1.5", minutes: "0"))
        XCTAssertNil(UsageCorrectionInput.seconds(hours: "1", minutes: "60"))
        XCTAssertNil(UsageCorrectionInput.seconds(hours: "-1", minutes: "0"))
    }

    func testManualCorrectionPreservesRecordedSessionsAndAddsNewTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPSharedUsage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedUsageStore(fileURL: directory.appendingPathComponent("usage.json"))
        let credentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let otherCredentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "other")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let firstSession = try store.beginSession(for: credentials, engineModelType: "16k_zh_en_2.0", at: date)
        try store.endSession(firstSession, at: date.addingTimeInterval(100))
        try store.setDisplayedSeconds(68_400, for: credentials, engineModelType: "16k_zh_en_2.0",
                                      isPrepaid: true, at: date.addingTimeInterval(100))
        XCTAssertEqual(try store.currentTotalSeconds(for: credentials, engineModelType: "16k_zh_en_2.0",
                                                     at: date.addingTimeInterval(100)), 68_400)
        let nextSession = try store.beginSession(for: credentials, engineModelType: "16k_zh_en_2.0",
                                                 at: date.addingTimeInterval(200))
        try store.endSession(nextSession, at: date.addingTimeInterval(260))
        XCTAssertEqual(try store.currentTotalSeconds(for: credentials, engineModelType: "16k_zh_en_2.0",
                                                     at: date.addingTimeInterval(260)), 68_460)
        XCTAssertEqual(try store.currentTotalSeconds(for: otherCredentials, engineModelType: "16k_zh_en_2.0",
                                                     at: date.addingTimeInterval(260)), 0)
    }

    func testCloudPackageCalibrationSurvivesRestartAndKeepsAccumulating() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPCloudCalibration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("usage.json")
        let credentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let model = "16k_zh_en_2.0"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let firstRun = SharedUsageStore(fileURL: fileURL)
        try firstRun.setDisplayedSeconds(42_952, for: credentials, engineModelType: model,
                                         isPrepaid: true, prepaidQuotaHours: 60, at: date)

        let reopened = SharedUsageStore(fileURL: fileURL)
        XCTAssertEqual(try reopened.currentTotalSeconds(for: credentials, engineModelType: model, at: date), 42_952)
        XCTAssertEqual(try reopened.prepaidQuotaHours(for: credentials, engineModelType: model), 60)
        let session = try reopened.beginSession(for: credentials, engineModelType: model,
                                                at: date.addingTimeInterval(60))
        try reopened.endSession(session, at: date.addingTimeInterval(120))
        XCTAssertEqual(try reopened.currentTotalSeconds(for: credentials, engineModelType: model,
                                                        at: date.addingTimeInterval(120)), 43_012)
    }

    func testFreePackageCalibrationUsesCurrentMonthAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPFreeCalibration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("usage.json")
        let credentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let october = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
        let november = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        let store = SharedUsageStore(fileURL: fileURL)
        try store.setPrepaidQuotaHours(60, for: credentials, engineModelType: "16k_zh")
        try store.setDisplayedSeconds(16, for: credentials, engineModelType: "16k_zh",
                                      isPrepaid: false, prepaidQuotaHours: 0, at: october)

        let reopened = SharedUsageStore(fileURL: fileURL)
        let sharedHours = try reopened.prepaidQuotaHours(for: credentials, engineModelType: "16k_zh")
        XCTAssertEqual(sharedHours, 0)
        XCTAssertEqual(sharedHours ?? 60, 0)
        XCTAssertEqual(try reopened.currentSeconds(for: credentials, engineModelType: "16k_zh", at: october), 16)
        XCTAssertEqual(try reopened.currentSeconds(for: credentials, engineModelType: "16k_zh", at: november), 0)
        XCTAssertEqual(TencentUsageQuota.seconds(for: "16k_zh", prepaidHours: sharedHours), 18_000)
    }

    func testMonthlyCorrectionDoesNotCarryIntoNextMonth() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVPSharedUsage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedUsageStore(fileURL: directory.appendingPathComponent("usage.json"))
        let credentials = TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        let september = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
        let october = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
        try store.setDisplayedSeconds(3_600, for: credentials, engineModelType: "16k_zh",
                                      isPrepaid: false, at: september)
        XCTAssertEqual(try store.currentSeconds(for: credentials, engineModelType: "16k_zh", at: september), 3_600)
        XCTAssertEqual(try store.currentSeconds(for: credentials, engineModelType: "16k_zh", at: october), 0)
    }

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
            "模型：16k_zh_en_2.0\n本地套餐用量：5h / 60h（8%）"
        )
    }

    func testSharedPrepaidSummaryUsesShortUsageLabel() {
        let summary = TencentUsageSummary(
            localUsedSeconds: 18_000,
            quotaSeconds: 60 * 3_600,
            engineModelType: "16k_zh_en_2.0",
            isPrepaid: true,
            sharedAcrossUsers: true
        )

        XCTAssertEqual(
            summary.displayText,
            "模型：16k_zh_en_2.0\n用量：5h / 60h（8%）"
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
        XCTAssertEqual(summary.displayText, "模型：16k_zh\n本地本月用量：2min 0s / 5min 0s（40%）")
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
