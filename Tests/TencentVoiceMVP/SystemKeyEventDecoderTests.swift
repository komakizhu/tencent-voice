import Carbon.HIToolbox
import XCTest
@testable import TencentVoiceMVP

final class SystemKeyEventDecoderTests: XCTestCase {
    func testDecodesBuiltInF5WhenMacPostsItAsSystemDefined() {
        let data1 = Int64((22 << 16) | (10 << 8))

        XCTAssertEqual(
            SystemKeyEventDecoder.decode(
                subtype: 8,
                data1: data1,
                timestampNanoseconds: 105_000_000,
                eventTag: 0
            ),
            SystemKeyEvent(
                keyCode: UInt32(kVK_F5),
                isDown: true,
                isRepeat: false,
                timestampNanoseconds: 105_000_000,
                eventTag: 0
            )
        )
    }

    func testDecodesBuiltInF5KeyUpAndRepeatState() {
        let data1 = Int64((22 << 16) | (11 << 8) | 1)

        XCTAssertEqual(
            SystemKeyEventDecoder.decode(
                subtype: 8,
                data1: data1,
                timestampNanoseconds: 205_000_000,
                eventTag: 0
            ),
            SystemKeyEvent(
                keyCode: UInt32(kVK_F5),
                isDown: false,
                isRepeat: true,
                timestampNanoseconds: 205_000_000,
                eventTag: 0
            )
        )
    }

    func testIgnoresOtherSystemDefinedEvents() {
        XCTAssertNil(
            SystemKeyEventDecoder.decode(
                subtype: 8,
                data1: Int64((3 << 16) | (10 << 8)),
                timestampNanoseconds: 105_000_000,
                eventTag: 0
            )
        )
        XCTAssertNil(
            SystemKeyEventDecoder.decode(
                subtype: 1,
                data1: Int64((22 << 16) | (10 << 8)),
                timestampNanoseconds: 105_000_000,
                eventTag: 0
            )
        )
    }
}
