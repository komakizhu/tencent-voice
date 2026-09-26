import XCTest
@testable import TencentVoiceMVP

final class AppVersionTests: XCTestCase {
    func testDisplayTextNeverShowsBuildNumber() {
        XCTAssertEqual(
            AppVersion.displayText(for: [
                "CFBundleShortVersionString": "0.1.1",
                "CFBundleVersion": "97",
                "RimeVoiceShowBuild": true
            ]),
            "当前版本：0.1.1"
        )
    }

    func testDisplayTextFallsBackWhenBuildIsMissing() {
        XCTAssertEqual(
            AppVersion.displayText(for: ["CFBundleShortVersionString": "0.1.1"]),
            "当前版本：0.1.1"
        )
    }

}
