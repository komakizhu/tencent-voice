import XCTest
@testable import TencentVoiceMVP

final class BuildConfigurationTests: XCTestCase {
    func testDefaultModelAndShortcutAreTheMVPDefaults() {
        XCTAssertEqual(AppSettings().engineModelType, "16k_zh")
        XCTAssertEqual(AppSettings().shortcut, .defaultCommand0)
        XCTAssertFalse(AppSettings().saveTextLogs)
        XCTAssertFalse(AppSettings().safeCopyEnabled)
    }

    func testPacingPreviewPresetsStayWithinTheLiveSafetyBounds() {
        XCTAssertEqual(KeyboardPacingConfiguration.live, .balanced)
        XCTAssertEqual(KeyboardPacingConfiguration.previewPresets.count, 4)
        XCTAssertEqual(
            Set(KeyboardPacingConfiguration.previewPresets.map(\.reservoirDelayNanoseconds)).count,
            4
        )
        XCTAssertEqual(
            Set(KeyboardPacingConfiguration.previewPresets.map(\.velocityChangeLimit)).count,
            3
        )
        XCTAssertEqual(KeyboardPacingConfiguration.trialPresets.count, 6)
        XCTAssertEqual(KeyboardPacingConfiguration.blindPresets.count, 3)
        XCTAssertEqual(
            Set(KeyboardPacingConfiguration.trialPresets.map(\.reservoirDelayNanoseconds)).count,
            5
        )
        XCTAssertEqual(
            Set(KeyboardPacingConfiguration.trialPresets.map(\.cadenceFillRatio)).count,
            4
        )

        for preset in KeyboardPacingConfiguration.previewPresets {
            XCTAssertEqual(preset.firstCharacterDelayNanoseconds, 0)
            XCTAssertGreaterThanOrEqual(preset.minimumCharacterIntervalNanoseconds, 16_000_000)
            XCTAssertLessThanOrEqual(preset.maximumCharacterIntervalNanoseconds, 60_000_000)
            XCTAssertLessThanOrEqual(preset.velocityChangeLimit, 0.12)
            XCTAssertLessThanOrEqual(preset.normalMaximumLagNanoseconds, 250_000_000)
            XCTAssertLessThanOrEqual(preset.finalFlushMaximumDurationNanoseconds, 120_000_000)
            XCTAssertTrue(preset.isEnabled)
        }

        for preset in KeyboardPacingConfiguration.trialPresets {
            XCTAssertEqual(preset.firstCharacterDelayNanoseconds, 0)
            XCTAssertGreaterThanOrEqual(preset.minimumCharacterIntervalNanoseconds, 16_000_000)
            XCTAssertLessThanOrEqual(preset.maximumCharacterIntervalNanoseconds, 60_000_000)
            XCTAssertLessThanOrEqual(preset.velocityChangeLimit, 0.12)
            XCTAssertLessThanOrEqual(preset.normalMaximumLagNanoseconds, 250_000_000)
            XCTAssertLessThanOrEqual(preset.finalFlushMaximumDurationNanoseconds, 120_000_000)
            XCTAssertTrue(preset.isEnabled)
        }

        for preset in KeyboardPacingConfiguration.blindPresets {
            XCTAssertEqual(preset.firstCharacterDelayNanoseconds, 0)
            XCTAssertGreaterThanOrEqual(preset.minimumCharacterIntervalNanoseconds, 16_000_000)
            XCTAssertLessThanOrEqual(preset.maximumCharacterIntervalNanoseconds, 60_000_000)
            XCTAssertLessThanOrEqual(preset.velocityChangeLimit, 0.12)
            XCTAssertLessThanOrEqual(preset.normalMaximumLagNanoseconds, 250_000_000)
            XCTAssertLessThanOrEqual(preset.finalFlushMaximumDurationNanoseconds, 120_000_000)
            XCTAssertTrue(preset.isEnabled)
        }
    }
}
