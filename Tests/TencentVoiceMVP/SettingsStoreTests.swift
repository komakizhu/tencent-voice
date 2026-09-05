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

    func testDefaultsUseCommand0AndDisableTextLogs() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        let settings = store.load()
        XCTAssertEqual(settings.shortcut, .defaultCommand0)
        XCTAssertEqual(settings.engineModelType, "16k_zh")
        XCTAssertFalse(settings.saveTextLogs)
        XCTAssertTrue(settings.prepaidQuotaHoursByModel.isEmpty)
    }

    func testLegacyF5MigratesToCommand0OnlyOnce() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        let legacyData = try! JSONEncoder().encode(AppSettings(shortcut: .defaultF5))
        UserDefaults(suiteName: suiteName)?.set(legacyData, forKey: "appSettings")

        XCTAssertEqual(store.load().shortcut, .defaultCommand0)

        store.save(AppSettings(shortcut: .defaultF5))
        XCTAssertEqual(store.load().shortcut, .defaultF5)
    }

    func testCustomShortcutsAreNotMigrated() throws {
        let modifierSets = [
            UInt32(optionKey),
            UInt32(controlKey),
            UInt32(shiftKey),
            UInt32(cmdKey)
        ]

        for modifiers in modifierSets {
            let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
            let store = UserDefaultsSettingsStore(suiteName: suiteName)
            let customShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: modifiers)
            let data = try JSONEncoder().encode(AppSettings(shortcut: customShortcut))
            UserDefaults(suiteName: suiteName)?.set(data, forKey: "appSettings")

            XCTAssertEqual(store.load().shortcut, customShortcut)
        }
    }

    func testManuallySavingF5AfterMigrationKeepsF5() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        _ = store.load()

        store.save(AppSettings(shortcut: .defaultF5))

        XCTAssertEqual(store.load().shortcut, .defaultF5)
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
