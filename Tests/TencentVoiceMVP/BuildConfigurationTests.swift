import XCTest
@testable import TencentVoiceMVP

final class BuildConfigurationTests: XCTestCase {
    func testDefaultModelAndShortcutAreTheMVPDefaults() {
        XCTAssertEqual(AppSettings().engineModelType, "16k_zh")
        XCTAssertEqual(AppSettings().shortcut, .defaultF5)
        XCTAssertFalse(AppSettings().saveTextLogs)
    }
}
