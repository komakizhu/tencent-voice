import Carbon.HIToolbox
import Foundation
import XCTest
@testable import TencentVoiceMVP

final class SettingsStoreTests: XCTestCase {
    func testDefaultsUseF5AndDisableTextLogs() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        let settings = store.load()
        XCTAssertEqual(settings.shortcut, .defaultF5)
        XCTAssertEqual(settings.engineModelType, "16k_zh")
        XCTAssertFalse(settings.saveTextLogs)
    }

    func testSettingsRoundTrip() {
        let suiteName = "TencentVoiceMVPTests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suiteName)
        let settings = AppSettings(
            shortcut: Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey)),
            engineModelType: "16k_zh_en_2.0",
            saveTextLogs: true
        )
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }
}
