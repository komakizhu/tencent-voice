import Carbon.HIToolbox
import Foundation
import AppKit
import XCTest
@testable import TencentVoiceMVP

final class ShortcutTests: XCTestCase {
    func testDefaultShortcutIsCommand0() {
        XCTAssertEqual(
            Shortcut.defaultCommand0,
            Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey))
        )
    }

    func testLegacyF5ShortcutRemainsAvailableForMigration() {
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

    func testMenuShortcutPresentationUsesConfiguredKeyAndModifiers() {
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey))

        XCTAssertEqual(ShortcutFormatter.menuKeyEquivalent(for: shortcut), "a")
        XCTAssertEqual(
            ShortcutFormatter.menuModifierFlags(for: shortcut),
            [.command, .option]
        )
    }

    func testMenuShortcutPresentationMapsFunctionKeys() {
        let shortcut = Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(shiftKey))

        XCTAssertEqual(
            ShortcutFormatter.menuKeyEquivalent(for: shortcut),
            String(UnicodeScalar(NSF5FunctionKey)!)
        )
        XCTAssertEqual(ShortcutFormatter.menuModifierFlags(for: shortcut), [.shift])
    }
}
