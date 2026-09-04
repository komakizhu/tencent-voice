import XCTest
@testable import TencentVoiceMVP

final class BuildConfigurationTests: XCTestCase {
    func testDefaultModelAndShortcutAreTheMVPDefaults() {
        XCTAssertEqual(AppSettings().engineModelType, "16k_zh")
        XCTAssertEqual(AppSettings().shortcut, .defaultCommand0)
        XCTAssertFalse(AppSettings().saveTextLogs)
    }
}
