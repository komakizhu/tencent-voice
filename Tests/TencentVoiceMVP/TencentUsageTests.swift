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

    func testUsagePercentageUsesTheLocallyRecordedValue() {
        let summary = TencentUsageSummary(
            localUsedSeconds: 120,
            quotaSeconds: 300
        )

        XCTAssertEqual(summary.usedSeconds, 120)
        XCTAssertEqual(summary.percentage, 40)
        XCTAssertEqual(summary.displayText, "本地本月用量：2分0秒 / 5分0秒（已用 40%）")
    }

    func testLocalUsageSessionIsLiveAndCommittedWhenItEnds() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalUsageStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)

        store.beginSession(at: start)
        store.touchSession(at: start.addingTimeInterval(37))

        XCTAssertEqual(store.currentSeconds(at: start.addingTimeInterval(37)), 37)
        XCTAssertEqual(store.endSession(at: start.addingTimeInterval(37)), 37)
        XCTAssertEqual(store.seconds(at: start.addingTimeInterval(37)), 37)
        XCTAssertFalse(store.hasActiveSession)
    }

    func testAbandonedLocalUsageSessionIsRecoveredOnNextLaunch() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalUsageStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 2_000_000)

        store.beginSession(at: start)
        store.touchSession(at: start.addingTimeInterval(12))
        XCTAssertEqual(store.recoverAbandonedSession(), 12)
        XCTAssertEqual(store.seconds(at: start.addingTimeInterval(12)), 12)
        XCTAssertFalse(store.hasActiveSession)
    }
}
