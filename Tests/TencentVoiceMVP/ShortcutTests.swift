import Carbon.HIToolbox
import Foundation
import XCTest
@testable import TencentVoiceMVP

final class ShortcutTests: XCTestCase {
    func testDefaultShortcutIsF5WithoutModifiers() {
        XCTAssertEqual(Shortcut.defaultF5, Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0))
    }

    func testShortcutRoundTripsThroughJSON() throws {
        let shortcut = Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey))
        let data = try JSONEncoder().encode(shortcut)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), shortcut)
    }

    func testBareLetterIsRejectedButModifiedLetterIsAccepted() {
        XCTAssertFalse(ShortcutValidator.isAllowed(Shortcut(keyCode: 0, modifiers: 0)))
        XCTAssertTrue(ShortcutValidator.isAllowed(Shortcut(keyCode: 0, modifiers: UInt32(optionKey))))
        XCTAssertTrue(ShortcutValidator.isAllowed(Shortcut.defaultF5))
    }
}
