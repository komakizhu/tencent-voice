import XCTest
@testable import TencentVoiceMVP

final class AXKeyboardDiagnosticDiffTests: XCTestCase {
    private func state(
        _ axValue: String?,
        coordinate: String,
        selection: Int? = nil
    ) -> KeyboardDocumentState {
        KeyboardDocumentState(
            text: coordinate,
            selection: TextRange(location: selection ?? coordinate.utf16.count, length: 0),
            rawText: axValue
        )
    }

    private func operation(
        location: Int,
        length: Int = 0,
        inserted: String = "乙",
        generation: UInt64 = 1
    ) -> KeyboardDiagnosticDiffOperation {
        KeyboardDiagnosticDiffOperation(
            coordinateRange: TextRange(location: location, length: length),
            insertedLengthUTF16: inserted.utf16.count,
            inputText: inserted,
            operationGeneration: generation
        )
    }

    func testClassifiesEqualAndLocalStructuralDifference() {
        let expected = state("甲\n乙", coordinate: "甲乙")
        let equal = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: expected,
            operation: operation(location: 1),
            mappingValid: true
        )
        XCTAssertEqual(equal.classification, .equal)

        let observed = state("甲乙\n", coordinate: "甲乙")
        let local = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: operation(location: 1),
            mappingValid: true
        )
        XCTAssertEqual(local.classification, .structuralLocal)
        XCTAssertEqual(local.separatorDifferenceBoundaryCount, 2)
        XCTAssertEqual(local.separatorOutsideOperationCount, 0)
        XCTAssertEqual(local.separatorDeltaLF, 2)
        XCTAssertEqual(local.separatorFirstPositionUTF16, 1)
        XCTAssertEqual(local.separatorLastPositionUTF16, 2)
    }

    func testClassifiesOutsideStructuralDifferenceAndContentChange() {
        let expected = state("甲\n乙\n丁", coordinate: "甲乙丁")
        let observed = state("甲乙\n丁\n", coordinate: "甲乙丁")
        let outside = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: operation(location: 1),
            mappingValid: true
        )
        XCTAssertEqual(outside.classification, .structuralOutside)
        XCTAssertGreaterThan(outside.separatorOutsideOperationCount, 0)
        XCTAssertGreaterThan(outside.separatorLastDistanceFromOperationUTF16 ?? 0, 0)

        let contentChanged = KeyboardDiagnosticDiffCalculator.compare(
            expected: state("甲\n乙", coordinate: "甲乙"),
            observed: state("甲\n丙", coordinate: "甲丙"),
            operation: operation(location: 1),
            mappingValid: true
        )
        XCTAssertEqual(contentChanged.classification, .contentChanged)
        XCTAssertEqual(contentChanged.separatorDifferenceBoundaryCount, 0)

        let coordinateContentChanged = KeyboardDiagnosticDiffCalculator.compare(
            expected: state("甲\n乙", coordinate: "甲乙"),
            observed: state("甲\n乙", coordinate: "甲丙"),
            operation: operation(location: 1),
            mappingValid: true
        )
        XCTAssertEqual(coordinateContentChanged.classification, .contentChanged)
        XCTAssertFalse(
            KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
                expected: state("甲\n乙", coordinate: "甲乙", selection: 1),
                observed: state("甲\n\n乙", coordinate: "甲丙", selection: 1),
                operation: operation(location: 1),
                mappingValid: true
            )
        )
    }

    func testSharedConfirmationRejectsWrongCoordinateParagraphEvenWhenRawMarkersAreLocal() {
        let expected = state(
            "甲\n乙今丁",
            coordinate: "甲乙今丁",
            selection: 3
        )
        let observed = state(
            "甲乙\n今丁",
            coordinate: "甲今丁乙",
            selection: 3
        )
        let result = KeyboardWriteConfirmation.evaluate(
            expected: expected,
            observed: observed,
            operation: operation(location: 2, inserted: "今"),
            isCodexTarget: true,
            allowNewStructuralBoundary: true
        )

        XCTAssertFalse(result.matched)
        XCTAssertEqual(result.comparison, .documentMismatch)
    }

    func testStableStateComparisonRequiresTheCompleteCodexMapping() throws {
        let raw = "甲\n乙"
        let coordinate = "甲乙"
        let resolved = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinate.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: AXTextCoordinateProbe { range in
                guard range.location == 0, range.length <= coordinate.utf16.count else {
                    return nil
                }
                return (coordinate as NSString).substring(
                    with: NSRange(location: 0, length: range.length)
                )
            }
        )
        let expected = KeyboardDocumentState(
            text: resolved.text,
            selection: resolved.selection,
            rawText: resolved.rawText,
            mapping: resolved.mapping
        )
        let invalidMapping = AXTextCoordinateMapping(
            source: .axStringForRange,
            rawDocumentLength: raw.utf16.count,
            coordinateDocumentLength: coordinate.utf16.count,
            omittedStructuralSeparatorCount: 1,
            rawBoundaryOffsets: [0, 1, 3],
            rawPlaceholderRange: nil
        )
        let observed = KeyboardDocumentState(
            text: expected.text,
            selection: expected.selection,
            rawText: expected.rawText,
            mapping: invalidMapping
        )

        XCTAssertEqual(
            KeyboardWriteConfirmation.compareStableState(
                expected: expected,
                observed: observed,
                isCodexTarget: true
            ),
            .rawMappingUnavailable
        )
    }

    func testUserLineBreakInputCannotBeReclassifiedAsAStructuralMarker() {
        let expected = state(
            "甲A\nB\n乙",
            coordinate: "甲AB乙",
            selection: 4
        )
        let observed = state(
            "甲A\nB\n\n乙",
            coordinate: "甲AB乙",
            selection: 4
        )
        let result = KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
            expected: expected,
            observed: observed,
            operation: operation(location: 1, inserted: "A\nB"),
            mappingValid: true,
            allowNewStructuralBoundary: true
        )

        XCTAssertFalse(result)
    }

    func testHandlesCRLFEmojiAndCombiningCharacterWithUTF16Offsets() {
        let expected = state("😀e\u{301}\r\n乙", coordinate: "😀e\u{301}乙")
        let observed = state("😀e\u{301}乙\r\n", coordinate: "😀e\u{301}乙")
        let result = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: operation(location: "😀e\u{301}".utf16.count),
            mappingValid: true
        )
        XCTAssertEqual(result.classification, .structuralLocal)
        XCTAssertEqual(result.separatorDeltaCR, 2)
        XCTAssertEqual(result.separatorDeltaLF, 2)
        XCTAssertEqual(result.separatorDifferenceUnitCount, 4)
        XCTAssertEqual(result.operationStartUTF16, "😀e\u{301}".utf16.count)

        let standaloneCR = KeyboardDiagnosticDiffCalculator.compare(
            expected: state("甲\r乙", coordinate: "甲\r乙"),
            observed: state("甲\r乙", coordinate: "甲\r乙"),
            operation: operation(location: 1, inserted: ""),
            mappingValid: true
        )
        XCTAssertEqual(standaloneCR.classification, .equal)
    }

    func testRejectsOperationStartingInsideCRLF() {
        let expected = state("甲\r\n乙", coordinate: "甲\r\n乙")
        let result = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: expected,
            operation: operation(location: 2),
            mappingValid: true
        )

        XCTAssertEqual(result.classification, .unavailable)
        XCTAssertFalse(result.operationRangeAvailable)
    }

    func testMapsOperationBoundsAcrossCoordinateSeparators() {
        let expected = state("a\nXb", coordinate: "a\nXb")
        let observed = state("a\n\nXb", coordinate: "a\n\nXb")
        let result = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: operation(location: 2, inserted: "X"),
            mappingValid: true
        )

        XCTAssertEqual(result.classification, .structuralLocal)
        XCTAssertTrue(result.operationRangeAvailable)
        XCTAssertEqual(result.operationStartUTF16, 1)
        XCTAssertEqual(result.operationEndUTF16, 2)
        XCTAssertEqual(result.separatorFirstDistanceFromOperationUTF16, 0)
        XCTAssertEqual(result.separatorLastDistanceFromOperationUTF16, 0)
        XCTAssertEqual(result.separatorOutsideOperationCount, 0)
    }

    func testOperationBoundsCoverLongerReplacementThanInsertedText() {
        let expected = state("a\nXb\nc", coordinate: "aXbc")
        let observed = state("a\n\nXb\n\nc", coordinate: "aXbc")
        let result = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: operation(location: 1, length: 2, inserted: "Y"),
            mappingValid: true
        )

        XCTAssertEqual(result.classification, .structuralLocal)
        XCTAssertEqual(result.operationStartUTF16, 1)
        XCTAssertEqual(result.operationEndUTF16, 3)
        XCTAssertEqual(result.separatorOutsideOperationCount, 0)
    }

    func testTailShorteningReplacementClampsOperationToPostEditBoundary() {
        let expected = state("A", coordinate: "A", selection: 1)
        let result = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: expected,
            operation: operation(location: 1, length: 2, inserted: ""),
            mappingValid: true
        )

        XCTAssertEqual(result.classification, .equal)
        XCTAssertTrue(result.operationRangeAvailable)
        XCTAssertEqual(result.operationStartUTF16, 1)
        XCTAssertEqual(result.operationEndUTF16, 1)
    }

    func testReportsUnavailableAndBudgetExceededWithoutContent() {
        let expected = state(nil, coordinate: "甲")
        let observed = state("私密正文", coordinate: "甲")
        let unavailable = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: operation(location: 0),
            mappingValid: false
        )
        XCTAssertEqual(unavailable.classification, .unavailable)

        let longValue = String(repeating: "甲", count: KeyboardDiagnosticDiffSummary.maximumUTF16Length + 1)
        let budget = KeyboardDiagnosticDiffCalculator.compare(
            expected: state(longValue, coordinate: longValue),
            observed: state(longValue, coordinate: longValue),
            operation: operation(location: 0),
            mappingValid: true
        )
        XCTAssertEqual(budget.classification, .budgetExceeded)

        let longCoordinate = String(repeating: "乙", count: KeyboardDiagnosticDiffSummary.maximumUTF16Length + 1)
        let coordinateBudget = KeyboardDiagnosticDiffCalculator.compare(
            expected: state("甲", coordinate: longCoordinate),
            observed: state("甲", coordinate: longCoordinate),
            operation: operation(location: 0),
            mappingValid: true
        )
        XCTAssertEqual(coordinateBudget.classification, .budgetExceeded)

        let fields = DiagnosticLogSanitizer.fields(
            budget.fields(prefix: "ackDiffFinal0")
        )
        XCTAssertFalse(fields.values.contains { $0.contains("私密正文") })
        XCTAssertTrue(fields.keys.contains("ackDiffFinal0Classification"))
    }

    func testRejectsDoubleSeparatorObservationWhenMappingIsNotValid() {
        let expected = state("X\n\nABC", coordinate: "XABC", selection: 1)
        let observed = state("X\n\nABC", coordinate: "XABC", selection: 1)
        let result = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: operation(location: 0, inserted: "X"),
            mappingValid: false
        )

        XCTAssertEqual(result.classification, .unavailable)
        XCTAssertFalse(result.mappingValid)
    }

    func testAllowsOnlyLocalSeparatorAugmentationAtTheOperationBoundary() {
        let expected = state(
            "测试X\n看看",
            coordinate: "测试X\n看看",
            selection: 3
        )
        let observed = state(
            "测试X\n\n\n看看",
            coordinate: "测试X看看",
            selection: 3
        )
        XCTAssertTrue(
            KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
                expected: expected,
                observed: observed,
                operation: operation(location: 2, inserted: "X"),
                mappingValid: true
            )
        )

        let omittedInCoordinate = state(
            "甲X\n乙",
            coordinate: "甲X乙",
            selection: 2
        )
        let observedWithOneAdditionalMarker = state(
            "甲X\n\n乙",
            coordinate: "甲X乙",
            selection: 2
        )
        XCTAssertTrue(
            KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
                expected: omittedInCoordinate,
                observed: observedWithOneAdditionalMarker,
                operation: operation(location: 1, inserted: "X"),
                mappingValid: true
            )
        )

        let moved = state(
            "甲丙\n乙",
            coordinate: "甲丙乙",
            selection: 2
        )
        let expectedBeforeMove = state(
            "甲\n丙乙",
            coordinate: "甲丙乙",
            selection: 2
        )
        XCTAssertFalse(
            KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
                expected: expectedBeforeMove,
                observed: moved,
                operation: operation(location: 1, inserted: "丙"),
                mappingValid: true
            )
        )
    }

    func testAllowsNewStructuralBoundaryAtDocumentStartWhenCoordinateContentMatches() {
        let expected = state(
            "今甲",
            coordinate: "今甲",
            selection: 1
        )
        let observed = state(
            "今\n\n甲",
            coordinate: "今甲",
            selection: 1
        )

        XCTAssertTrue(
            KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
                expected: expected,
                observed: observed,
                operation: operation(location: 0, inserted: "今"),
                mappingValid: true,
                allowNewStructuralBoundary: true
            )
        )
    }

    func testNewStructuralBoundaryTreatsCRLFAsOneCompleteUnit() {
        let expected = state(
            "今甲",
            coordinate: "今甲",
            selection: 1
        )
        let observed = state(
            "今\r\n甲",
            coordinate: "今甲",
            selection: 1
        )

        XCTAssertTrue(
            KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
                expected: expected,
                observed: observed,
                operation: operation(location: 0, inserted: "今"),
                mappingValid: true,
                allowNewStructuralBoundary: true
            )
        )

        let standaloneCR = state(
            "今\r甲",
            coordinate: "今甲",
            selection: 1
        )
        XCTAssertFalse(
            KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
                expected: expected,
                observed: standaloneCR,
                operation: operation(location: 0, inserted: "今"),
                mappingValid: true,
                allowNewStructuralBoundary: true
            )
        )
    }
}
