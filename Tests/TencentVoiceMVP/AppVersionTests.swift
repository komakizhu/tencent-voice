import XCTest
@testable import TencentVoiceMVP

final class AppVersionTests: XCTestCase {
    func testDisplayTextIncludesVersionAndBuild() {
        XCTAssertEqual(
            AppVersion.displayText(for: [
                "CFBundleShortVersionString": "0.1.1",
                "CFBundleVersion": "2"
            ]),
            "当前版本：0.1.1（build 2）"
        )
    }

    func testDisplayTextFallsBackWhenBuildIsMissing() {
        XCTAssertEqual(
            AppVersion.displayText(for: ["CFBundleShortVersionString": "0.1.1"]),
            "当前版本：0.1.1"
        )
    }

    func testDisplayTextOmitsBuildForPublicRelease() {
        XCTAssertEqual(
            AppVersion.displayText(for: [
                "CFBundleShortVersionString": "0.1.1",
                "CFBundleVersion": "2",
                "RimeVoiceShowBuild": false
            ]),
            "当前版本：0.1.1"
        )
    }
}
