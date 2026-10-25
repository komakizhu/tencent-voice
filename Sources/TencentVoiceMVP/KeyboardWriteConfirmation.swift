import Foundation

struct KeyboardWriteConfirmationResult: Equatable {
    let matched: Bool
    let comparison: KeyboardDocumentComparison

    static func confirmed() -> Self {
        Self(matched: true, comparison: .matched)
    }

    static func rejected(_ comparison: KeyboardDocumentComparison) -> Self {
        Self(matched: false, comparison: comparison)
    }
}

struct KeyboardWriteCandidateConfirmation: Equatable {
    let matchedIndexes: [Int]
    let comparisons: [KeyboardDocumentComparison]
    let comparison: KeyboardDocumentComparison

    var matched: Bool {
        matchedIndexes.count == 1
    }

    var matchedIndex: Int? {
        matchedIndexes.count == 1 ? matchedIndexes[0] : nil
    }
}

/// The single receipt predicate used by Codex writes and deterministic replay.
/// It deliberately separates a valid coordinate mapping from a matching
/// document: a caret or a local structural difference is not a receipt unless
/// the complete observation still explains the intended edit.
enum KeyboardWriteConfirmation {
    /// Compare two observations that are expected to be the same state before
    /// a new operation. No operation context means a structural transition
    /// cannot be attributed to a just-sent write; raw text and the complete
    /// coordinate mapping must therefore remain stable.
    static func compareStableState(
        expected: KeyboardDocumentState,
        observed: KeyboardDocumentState,
        isCodexTarget: Bool
    ) -> KeyboardDocumentComparison {
        let result = evaluate(
            expected: expected,
            observed: observed,
            operation: nil,
            isCodexTarget: isCodexTarget
        )
        return result.matched ? .matched : result.comparison
    }

    static func evaluate(
        expected: KeyboardDocumentState,
        observed: KeyboardDocumentState,
        operation: KeyboardDiagnosticDiffOperation?,
        isCodexTarget: Bool,
        allowNewStructuralBoundary: Bool = false,
        allowStructuralAugmentation: Bool = true
    ) -> KeyboardWriteConfirmationResult {
        let comparison = observed.compare(
            to: expected,
            allowingStructuralRawDifference: isCodexTarget
        )

        guard observed.selection == expected.selection else {
            return .rejected(comparison)
        }

        // A valid raw/coordinate alignment is necessary but not sufficient:
        // the coordinate document is the editor's logical paragraph view.
        // Check it before accepting a raw-only structural transition so a
        // paragraph move cannot be mistaken for a harmless AXValue marker.
        guard observed.text == expected.text else {
            return .rejected(comparison)
        }

        if allowStructuralAugmentation,
           isCodexTarget,
           mappingIsValid(observed, isCodexTarget: true),
           KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
               expected: expected,
               observed: observed,
               operation: operation,
               mappingValid: true,
               allowNewStructuralBoundary: allowNewStructuralBoundary
           ) {
            return .confirmed()
        }

        if isCodexTarget {
            guard let expectedRawText = expected.rawText,
                  observed.rawText == expectedRawText,
                  mappingIsValid(observed, isCodexTarget: true),
                  observed.matchesExpectedMapping(of: expected) else {
                let failure: KeyboardDocumentComparison = observed.rawText == expected.rawText
                    ? .rawMappingUnavailable
                    : .rawTextMismatch
                return .rejected(failure)
            }
            return .confirmed()
        }

        return observed.rawText == expected.rawText
            ? .confirmed()
            : .rejected(comparison)
    }

    /// Evaluate the complete candidate set for one observation. A receipt is
    /// usable only when exactly one candidate explains the document,
    /// selection, raw representation, and mapping. If multiple candidates
    /// explain it, the state is intentionally left unconfirmed rather than
    /// choosing the first or the canonical/rightmost boundary.
    static func evaluateCandidates(
        expectedCandidates: [KeyboardDocumentState],
        observed: KeyboardDocumentState,
        operation: KeyboardDiagnosticDiffOperation?,
        isCodexTarget: Bool,
        allowNewStructuralBoundary: Bool = false
    ) -> KeyboardWriteCandidateConfirmation {
        // A complete raw/coordinate/mapping match is stronger evidence than
        // a structural fallback. Evaluate that tier first so a fallback-only
        // explanation cannot make an otherwise exact receipt look ambiguous.
        let strictResults = expectedCandidates.map { expected in
            evaluate(
                expected: expected,
                observed: observed,
                operation: operation,
                isCodexTarget: isCodexTarget,
                allowNewStructuralBoundary: allowNewStructuralBoundary,
                allowStructuralAugmentation: false
            )
        }
        let strictMatches = strictResults.indices.filter { strictResults[$0].matched }
        if !strictMatches.isEmpty {
            return makeCandidateConfirmation(
                results: strictResults,
                matchedIndexes: strictMatches
            )
        }

        let results = expectedCandidates.map { expected in
            evaluate(
                expected: expected,
                observed: observed,
                operation: operation,
                isCodexTarget: isCodexTarget,
                allowNewStructuralBoundary: allowNewStructuralBoundary,
                allowStructuralAugmentation: true
            )
        }
        let matchedIndexes = results.indices.filter { results[$0].matched }
        return makeCandidateConfirmation(
            results: results,
            matchedIndexes: matchedIndexes
        )
    }

    private static func makeCandidateConfirmation(
        results: [KeyboardWriteConfirmationResult],
        matchedIndexes: [Int]
    ) -> KeyboardWriteCandidateConfirmation {
        let comparisons = results.map(\.comparison)
        let comparison: KeyboardDocumentComparison
        switch matchedIndexes.count {
        case 1:
            comparison = .matched
        case 2...:
            comparison = .ambiguousReceipt
        default:
            comparison = comparisons.last ?? .documentMismatch
        }
        return KeyboardWriteCandidateConfirmation(
            matchedIndexes: matchedIndexes,
            comparisons: comparisons,
            comparison: comparison
        )
    }

    static func mappingIsValid(
        _ state: KeyboardDocumentState,
        isCodexTarget: Bool
    ) -> Bool {
        guard isCodexTarget else { return true }
        guard let rawText = state.rawText,
              let mapping = state.mapping else {
            return false
        }
        if mapping.source == .placeholder {
            return state.text.isEmpty
                && state.selection == TextRange(location: 0, length: 0)
                && mapping.coordinateDocumentLength == 0
                && mapping.rawDocumentLength == rawText.utf16.count
                && mapping.rawBoundaryOffsets == [0]
                && mapping.rawPlaceholderRange == TextRange(
                    location: 0,
                    length: mapping.rawDocumentLength
                )
        }
        return AXTextDocumentResolver.isValidCoordinateMapping(
            mapping,
            rawText: rawText,
            coordinateText: state.text
        )
    }
}
