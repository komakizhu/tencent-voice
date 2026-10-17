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
}
