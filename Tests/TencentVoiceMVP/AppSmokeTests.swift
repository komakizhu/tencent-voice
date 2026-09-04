import XCTest
@testable import TencentVoiceMVP

@MainActor
final class AppSmokeTests: XCTestCase {
    func testStatusMenuControllerCanBeCreated() {
        let controller = StatusMenuController()
        XCTAssertEqual(controller.statusText, "就绪")
    }
}
