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
}
