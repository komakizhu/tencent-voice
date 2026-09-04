import ApplicationServices
import XCTest
@testable import TencentVoiceMVP

final class TextTargetTests: XCTestCase {
    func testAppendingOnlySendsNewSuffix() {
        let delta = PastedTextDelta(previousText: "你好", newText: "你好世界")
        XCTAssertEqual(delta.backspaceCount, 0)
        XCTAssertEqual(delta.insertion, "世界")
    }

    func testCorrectionOnlyReplacesChangedSuffix() {
        let delta = PastedTextDelta(previousText: "你好世", newText: "你好是")
        XCTAssertEqual(delta.backspaceCount, 1)
        XCTAssertEqual(delta.insertion, "是")
    }

    func testAXReplacementOnlyChangesUnstableMiddle() {
        let delta = TextReplacementDelta(previousText: "你好世", newText: "你好是")
        XCTAssertEqual(delta.prefixUTF16Length, 2)
        XCTAssertEqual(delta.previousMiddleUTF16Length, 1)
        XCTAssertEqual(delta.insertion, "是")
    }

    func testAXReplacementAppendsWithoutRewritingExistingText() {
        let delta = TextReplacementDelta(previousText: "你好", newText: "你好世界")
        XCTAssertEqual(delta.prefixUTF16Length, 2)
        XCTAssertEqual(delta.previousMiddleUTF16Length, 0)
        XCTAssertEqual(delta.insertion, "世界")
    }

    func testSyntheticKeyboardEventsNeverCarryPhysicalModifiers() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let backspace = try XCTUnwrap(
            SyntheticKeyboardEventFactory.keyEvent(
                source: source,
                keyCode: 0x33,
                keyDown: true
            )
        )
        let unicode = try XCTUnwrap(
            SyntheticKeyboardEventFactory.unicodeEvent(
                source: source,
                text: "测试",
                keyDown: true
            )
        )

        let modifiers: CGEventFlags = [
            .maskCommand,
            .maskControl,
            .maskAlternate,
            .maskShift,
            .maskSecondaryFn
        ]
        XCTAssertTrue(backspace.flags.intersection(modifiers).isEmpty)
        XCTAssertTrue(unicode.flags.intersection(modifiers).isEmpty)
    }
}
