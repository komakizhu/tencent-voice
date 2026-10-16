import XCTest
@testable import TencentVoiceMVP

@MainActor
final class InputReplayArgumentTests: XCTestCase {
    func testTargetBundleArgumentRequiresValue() {
        XCTAssertThrowsError(try InputReplay.targetBundleArgument(from: ["--target-bundle"])) { error in
            XCTAssertEqual(error as? InputReplay.ArgumentError, .missingTargetBundle)
        }
        XCTAssertThrowsError(try InputReplay.targetBundleArgument(from: ["--target-bundle", "--inspect-target"])) { error in
            XCTAssertEqual(error as? InputReplay.ArgumentError, .missingTargetBundle)
        }
    }

    func testTargetBundleArgumentReturnsOptionalBundle() throws {
        XCTAssertNil(try InputReplay.targetBundleArgument(from: ["--target-pid", "123"]))
        XCTAssertEqual(
            try InputReplay.targetBundleArgument(from: ["--target-bundle", "com.google.Chrome"]),
            "com.google.Chrome"
        )
    }
}
