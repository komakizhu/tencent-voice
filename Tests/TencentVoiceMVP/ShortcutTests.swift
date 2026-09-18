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

    func testShortcutPresetsContainRequestedKeysWithoutDelete() {
        XCTAssertEqual(
            ShortcutPreset.allCases.map(\.shortcut),
            [
                Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0),
                Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0),
                Shortcut(keyCode: UInt32(kVK_Home), modifiers: 0),
                Shortcut(keyCode: UInt32(kVK_PageUp), modifiers: 0),
                Shortcut(keyCode: UInt32(kVK_PageDown), modifiers: 0)
            ]
        )
        XCTAssertEqual(
            ShortcutPreset.allCases.map(\.displayName),
            ["F5（屏蔽 macOS 听写）", "Esc", "Home", "Page Up", "Page Down"]
        )
        XCTAssertFalse(ShortcutPreset.allCases.map(\.displayName).contains { $0.localizedCaseInsensitiveContains("delete") })
    }

    func testPresetSpecialKeysAreAllowedWithoutModifiers() {
        XCTAssertTrue(ShortcutPreset.allCases.allSatisfy { ShortcutValidator.isAllowed($0.shortcut) })
    }

    func testShortcutFormatterNamesPresetSpecialKeys() {
        XCTAssertEqual(ShortcutFormatter.string(for: ShortcutPreset.f5.shortcut), "F5")
        XCTAssertEqual(ShortcutFormatter.string(for: ShortcutPreset.escape.shortcut), "Esc")
        XCTAssertEqual(ShortcutFormatter.string(for: ShortcutPreset.home.shortcut), "Home")
        XCTAssertEqual(ShortcutFormatter.string(for: ShortcutPreset.pageUp.shortcut), "Page Up")
        XCTAssertEqual(ShortcutFormatter.string(for: ShortcutPreset.pageDown.shortcut), "Page Down")
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
