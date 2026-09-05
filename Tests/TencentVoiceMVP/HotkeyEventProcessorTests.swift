import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import TencentVoiceMVP

final class HotkeyEventProcessorTests: XCTestCase {
    private let shortcut = Shortcut(
        keyCode: UInt32(kVK_ANSI_0),
        modifiers: UInt32(cmdKey)
    )

    func testMatchingKeyDownAndKeyUpAreConsumedAndTriggerOnce() {
        var processor = HotkeyEventProcessor(shortcut: shortcut)

        XCTAssertEqual(
            processor.process(
                type: .keyDown,
                keyCode: shortcut.keyCode,
                flags: .maskCommand
            ),
            .press
        )
        XCTAssertEqual(
            processor.process(
                type: .keyUp,
                keyCode: shortcut.keyCode,
                flags: []
            ),
            .release
        )
    }

    func testRepeatedKeyDownIsConsumedWithoutAnotherPress() {
        var processor = HotkeyEventProcessor(shortcut: shortcut)

        XCTAssertEqual(
            processor.process(
                type: .keyDown,
                keyCode: shortcut.keyCode,
                flags: .maskCommand
            ),
            .press
        )
        XCTAssertEqual(
            processor.process(
                type: .keyDown,
                keyCode: shortcut.keyCode,
                flags: .maskCommand
            ),
            .consume
        )
    }

    func testKeyUpWithoutCommandModifierStillReleases() {
        var processor = HotkeyEventProcessor(shortcut: shortcut)
        _ = processor.process(type: .keyDown, keyCode: shortcut.keyCode, flags: .maskCommand)

        XCTAssertEqual(
            processor.process(type: .keyUp, keyCode: shortcut.keyCode, flags: []),
            .release
        )
        XCTAssertFalse(processor.isPressed)
    }

    func testUnmatchedKeyAndModifierPassThrough() {
        var processor = HotkeyEventProcessor(shortcut: shortcut)

        XCTAssertEqual(
            processor.process(type: .keyDown, keyCode: UInt32(kVK_ANSI_A), flags: .maskCommand),
            .pass
        )
        XCTAssertEqual(
            processor.process(type: .keyDown, keyCode: shortcut.keyCode, flags: .maskShift),
            .pass
        )
        XCTAssertEqual(
            processor.process(type: .keyUp, keyCode: shortcut.keyCode, flags: []),
            .pass
        )
    }

    func testUpdatingOrResettingProcessorStopsOldShortcutFromBeingConsumed() {
        var processor = HotkeyEventProcessor(shortcut: shortcut)
        _ = processor.process(type: .keyDown, keyCode: shortcut.keyCode, flags: .maskCommand)

        let newShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        processor.update(shortcut: newShortcut)
        XCTAssertEqual(
            processor.process(type: .keyDown, keyCode: shortcut.keyCode, flags: .maskCommand),
            .pass
        )

        processor.reset()
        XCTAssertEqual(
            processor.process(type: .keyDown, keyCode: newShortcut.keyCode, flags: .maskAlternate),
            .press
        )
    }
}
