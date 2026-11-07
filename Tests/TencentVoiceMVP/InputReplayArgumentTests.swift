import XCTest
@testable import TencentVoiceMVP

private typealias ReplayTextRange = TencentVoiceMVP.TextRange

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

    func testQuoteTestFixtureRequiresExactCherryDraftAndCaret() throws {
        let arguments = ["--quote-test-fixture", "--allow-test-input"]
        XCTAssertNoThrow(try InputReplay.validateQuoteTestFixture(
            args: arguments,
            targetBundle: InputReplay.quoteFixtureBundleIdentifier,
            role: "AXTextArea",
            rawValue: InputReplay.quoteFixtureInitialText,
            selection: .init(location: 3, length: 0),
            fullRangeText: InputReplay.quoteFixtureInitialText
        ))

        let unsafeStates: [(String?, String?, ReplayTextRange?, String?)] = [
            ("com.example.editor", "AXTextArea", .init(location: 3, length: 0), "引用 "),
            (InputReplay.quoteFixtureBundleIdentifier, "AXTextField", .init(location: 3, length: 0), "引用 "),
            (InputReplay.quoteFixtureBundleIdentifier, "AXTextArea", .init(location: 2, length: 0), "引用 "),
            (InputReplay.quoteFixtureBundleIdentifier, "AXTextArea", .init(location: 3, length: 0), "引用 用户草稿"),
            (InputReplay.quoteFixtureBundleIdentifier, "AXTextArea", .init(location: 3, length: 0), nil)
        ]
        for (bundle, role, selection, rangeText) in unsafeStates {
            XCTAssertThrowsError(try InputReplay.validateQuoteTestFixture(
                args: arguments,
                targetBundle: bundle,
                role: role,
                rawValue: InputReplay.quoteFixtureInitialText,
                selection: selection,
                fullRangeText: rangeText
            ))
        }

        XCTAssertThrowsError(try InputReplay.validateQuoteTestFixture(
            args: ["--quote-test-fixture"],
            targetBundle: InputReplay.quoteFixtureBundleIdentifier,
            role: "AXTextArea",
            rawValue: InputReplay.quoteFixtureInitialText,
            selection: .init(location: 3, length: 0),
            fullRangeText: InputReplay.quoteFixtureInitialText
        )) { error in
            XCTAssertEqual(error as? InputReplay.QuoteFixtureError, .requiresExplicitTestInput)
        }
    }
}
