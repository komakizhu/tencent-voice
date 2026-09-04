import Carbon.HIToolbox
import Foundation
import XCTest
@testable import TencentVoiceMVP

final class SettingsStoreTests: XCTestCase {
    func testEnginePresetsContainTheThreeSupportedModels() {
        XCTAssertEqual(
            TencentEnginePreset.allCases.map(\.rawValue),
            ["16k_zh", "16k_zh_en", "16k_zh_en_2.0"]
        )
        XCTAssertEqual(
            TencentEnginePreset(persistedModelType: "16k_zh_en_2.0"),
            .largeV2
        )
    }

    func testUnknownPersistedEngineFallsBackToStandardPreset() {
        XCTAssertEqual(
            TencentEnginePreset(persistedModelType: "legacy-custom-model"),
            .standard
        )
    }

    func testDefaultsUseF5AndDisableTextLogs() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        let settings = store.load()
        XCTAssertEqual(settings.shortcut, .defaultF5)
        XCTAssertEqual(settings.engineModelType, "16k_zh")
        XCTAssertFalse(settings.saveTextLogs)
        XCTAssertTrue(settings.prepaidQuotaHoursByModel.isEmpty)
    }

    func testSettingsRoundTrip() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        let settings = AppSettings(
            shortcut: Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey)),
            engineModelType: "16k_zh_en_2.0",
            saveTextLogs: true,
            prepaidQuotaHoursByModel: ["16k_zh_en_2.0": 60]
        )
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testOlderSettingsWithoutPrepaidQuotaDecodeWithEmptyQuota() throws {
        let data = try JSONEncoder().encode(
            LegacySettingsFixture(
                shortcut: LegacyShortcutFixture(keyCode: UInt32(kVK_F5), modifiers: 0),
                engineModelType: "16k_zh",
                saveTextLogs: false
            )
        )

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(settings.prepaidQuotaHoursByModel.isEmpty)
    }
}

private struct LegacySettingsFixture: Encodable {
    let shortcut: LegacyShortcutFixture
    let engineModelType: String
    let saveTextLogs: Bool
}

private struct LegacyShortcutFixture: Encodable {
    let keyCode: UInt32
    let modifiers: UInt32
}
