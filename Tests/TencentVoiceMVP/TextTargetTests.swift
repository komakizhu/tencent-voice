import ApplicationServices
import XCTest
@testable import TencentVoiceMVP

final class TextTargetTests: XCTestCase {
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

    func testAXReplacementHandlesEmojiAndCombiningCharacters() {
        let delta = TextReplacementDelta(previousText: "😀 e\u{301}尾", newText: "😀 a\u{301}尾")
        XCTAssertEqual(delta.prefixUTF16Length, 3)
        XCTAssertEqual(delta.previousMiddleUTF16Length, 2)
        XCTAssertEqual(delta.insertion, "a\u{301}")
    }

    func testSyntheticKeyboardEventsNeverCarryPhysicalModifiers() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let key = try XCTUnwrap(
            SyntheticKeyboardEventFactory.keyEvent(
                source: source,
                keyCode: 0,
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
        XCTAssertTrue(key.flags.intersection(modifiers).isEmpty)
        XCTAssertTrue(unicode.flags.intersection(modifiers).isEmpty)
    }

    func testSyntheticKeyboardSelectionEventCarriesOnlyRequestedShift() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(
            SyntheticKeyboardEventFactory.keyEvent(
                source: source,
                keyCode: 123,
                keyDown: true,
                flags: .maskShift
            )
        )
        let physicalModifiers: CGEventFlags = [
            .maskCommand,
            .maskControl,
            .maskAlternate,
            .maskShift,
            .maskSecondaryFn
        ]

        XCTAssertEqual(event.flags.intersection(physicalModifiers), .maskShift)
    }
}
