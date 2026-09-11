import Foundation

enum AXTextCoordinateSource: String, Equatable, Sendable {
    case axStringForRange
    case axValueAfterPlaceholderTransition
    case placeholder
}

struct AXTextCoordinateMapping: Equatable, Sendable {
    let source: AXTextCoordinateSource
    let rawDocumentLength: Int
    let coordinateDocumentLength: Int
    let omittedStructuralSeparatorCount: Int
    let rawBoundaryOffsets: [Int]
    let rawPlaceholderRange: TextRange?

    func rawRange(for coordinateRange: TextRange) -> TextRange? {
        guard coordinateRange.location >= 0,
              coordinateRange.length >= 0,
              coordinateRange.location <= coordinateDocumentLength,
              coordinateRange.length <= coordinateDocumentLength - coordinateRange.location else {
            return nil
        }
        if source == .placeholder {
            guard coordinateRange.location == 0, coordinateRange.length == 0 else { return nil }
            return rawPlaceholderRange ?? TextRange(location: 0, length: rawDocumentLength)
        }
        guard rawBoundaryOffsets.count == coordinateDocumentLength + 1 else { return nil }
        let start = rawBoundaryOffsets[coordinateRange.location]
        let end = rawBoundaryOffsets[coordinateRange.location + coordinateRange.length]
        guard start >= 0, end >= start else { return nil }
        return TextRange(location: start, length: end - start)
    }
}

struct AXPlaceholderEvidence: Equatable, Sendable {
    let explicitPlaceholder: String?
    let markedTexts: [String]
    let unmarkedTexts: [String]

    init(
        explicitPlaceholder: String? = nil,
        markedTexts: [String] = [],
        unmarkedTexts: [String] = []
    ) {
        self.explicitPlaceholder = explicitPlaceholder
        self.markedTexts = markedTexts
        self.unmarkedTexts = unmarkedTexts
    }
}

struct AXTextCoordinateProbe {
    let read: (TextRange) throws -> String?

    init(read: @escaping (TextRange) throws -> String?) {
        self.read = read
    }
}

struct AXTextDocumentState: Equatable, Sendable {
    let rawText: String
    let text: String
    let selection: TextRange
    let placeholderNormalized: Bool
    let mapping: AXTextCoordinateMapping
}

enum AXTextDocumentResolutionError: Error, Equatable {
    case invalidSelection
    case coordinateReadUnavailable
    case coordinateLengthMismatch
    case coordinateTextMismatch
    case selectionOutOfBounds
    case selectedRangeUnavailable
}

enum AXTextDocumentResolver {
    // This is an observation of an in-flight edit, never a successful receipt.
    // Only an exactly preserved, previously acknowledged selection qualifies.
    static func readDuringReplacement(
        rawText: String,
        selection: TextRange,
        acknowledgedSelection: KeyboardDocumentState?,
        resolve: () throws -> AXTextDocumentState
    ) throws -> AXTextDocumentState {
        do {
            return try resolve()
        } catch let error as AXTextDocumentResolutionError {
            if (error == .coordinateReadUnavailable || error == .coordinateTextMismatch),
               let acknowledgedSelection,
               acknowledgedSelection.selection.length > 0,
               rawText == acknowledgedSelection.rawText,
               selection == acknowledgedSelection.selection {
                throw KeyboardWriteReadError.retryable
            }
            throw error
        }
    }

    static func isStaleAXValueBehindSelection(
        rawText: String,
        selection: TextRange,
        confirmedRawText: String?,
        expectedSelection: TextRange?
    ) -> Bool {
        guard let confirmedRawText,
              let expectedSelection,
              rawText == confirmedRawText,
              selection == expectedSelection,
              selection.length == 0,
              selection.location >= 0,
              selection.location > rawText.utf16.count else {
            return false
        }
        return true
    }

    static func resolve(
        rawText: String,
        selection: TextRange,
        placeholderEvidence: AXPlaceholderEvidence,
        probe: AXTextCoordinateProbe
    ) throws -> AXTextDocumentState {
        let rawLength = rawText.utf16.count
        guard selection.location >= 0,
              selection.length >= 0,
              selection.location <= rawLength,
              selection.length <= rawLength - selection.location else {
            throw AXTextDocumentResolutionError.invalidSelection
        }

        if selection.length == 0,
           let placeholderRange = placeholderRange(rawText: rawText, evidence: placeholderEvidence) {
            return AXTextDocumentState(
                rawText: rawText,
                text: "",
                selection: .init(location: 0, length: 0),
                placeholderNormalized: true,
                mapping: AXTextCoordinateMapping(
                    source: .placeholder,
                    rawDocumentLength: rawLength,
                    coordinateDocumentLength: 0,
                    omittedStructuralSeparatorCount: 0,
                    rawBoundaryOffsets: [0],
                    rawPlaceholderRange: placeholderRange
                )
            )
        }

        guard let coordinate = try readCoordinateText(rawText: rawText, probe: probe) else {
            throw AXTextDocumentResolutionError.coordinateReadUnavailable
        }
        guard coordinate.text.utf16.count == coordinate.length else {
            throw AXTextDocumentResolutionError.coordinateLengthMismatch
        }
        guard selection.location <= coordinate.length,
              selection.length <= coordinate.length - selection.location else {
            throw AXTextDocumentResolutionError.selectionOutOfBounds
        }
        if selection.length > 0, try probe.read(selection) == nil {
            throw AXTextDocumentResolutionError.selectedRangeUnavailable
        }

        guard let boundaryMapping = rawBoundaryMapping(
            rawText: rawText,
            coordinateText: coordinate.text
        ) else {
            throw AXTextDocumentResolutionError.coordinateTextMismatch
        }

        return AXTextDocumentState(
            rawText: rawText,
            text: coordinate.text,
            selection: selection,
            placeholderNormalized: false,
            mapping: AXTextCoordinateMapping(
                source: .axStringForRange,
                rawDocumentLength: rawLength,
                coordinateDocumentLength: coordinate.length,
                omittedStructuralSeparatorCount: boundaryMapping.omittedSeparatorCount,
                rawBoundaryOffsets: boundaryMapping.rawBoundaryOffsets,
                rawPlaceholderRange: nil
            )
        )
    }

    static func resolveUsingValidatedAXValueAfterPlaceholder(
        rawText: String,
        selection: TextRange,
        previousState: AXTextDocumentState,
        continuationAllowed: Bool = false
    ) throws -> AXTextDocumentState {
        let rawLength = rawText.utf16.count
        guard selection.location >= 0,
              selection.length >= 0,
              selection.location <= rawLength,
              selection.length <= rawLength - selection.location else {
            throw AXTextDocumentResolutionError.invalidSelection
        }
        guard selection.length == 0,
              selection.location == rawLength,
              !rawText.unicodeScalars.contains(where: isStructuralSeparator) else {
            throw AXTextDocumentResolutionError.coordinateTextMismatch
        }
        if previousState.placeholderNormalized {
            guard rawText != previousState.rawText else {
                throw AXTextDocumentResolutionError.coordinateTextMismatch
            }
        } else {
            guard continuationAllowed else {
                throw AXTextDocumentResolutionError.coordinateReadUnavailable
            }
        }
        guard let boundaryMapping = rawBoundaryMapping(
            rawText: rawText,
            coordinateText: rawText
        ) else {
            throw AXTextDocumentResolutionError.coordinateTextMismatch
        }
        return AXTextDocumentState(
            rawText: rawText,
            text: rawText,
            selection: selection,
            placeholderNormalized: false,
            mapping: AXTextCoordinateMapping(
                source: .axValueAfterPlaceholderTransition,
                rawDocumentLength: rawLength,
                coordinateDocumentLength: rawLength,
                omittedStructuralSeparatorCount: boundaryMapping.omittedSeparatorCount,
                rawBoundaryOffsets: boundaryMapping.rawBoundaryOffsets,
                rawPlaceholderRange: nil
            )
        )
    }

    private static func placeholderRange(
        rawText: String,
        evidence: AXPlaceholderEvidence
    ) -> TextRange? {
        guard evidence.unmarkedTexts.allSatisfy({ $0.isEmpty }) else {
            return nil
        }

        let candidates = ([evidence.explicitPlaceholder] + evidence.markedTexts.map(Optional.some))
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        let rawScalars = Array(rawText.unicodeScalars)
        var start = 0
        var end = rawScalars.count
        while start < end, isStructuralSeparator(rawScalars[start]) {
            start += 1
        }
        while end > start, isStructuralSeparator(rawScalars[end - 1]) {
            end -= 1
        }
        let trimmedRaw = String(String.UnicodeScalarView(rawScalars[start..<end]))
        guard candidates.contains(where: { trimBoundarySeparators($0) == trimmedRaw }) else {
            return nil
        }

        // The separators surrounding a marked placeholder are part of the
        // accessibility representation, not user-owned draft text. Replace
        // the complete representation when the logical document is empty so
        // the receipt matches the post-insertion AXValue after the marker
        // disappears.
        return TextRange(location: 0, length: rawText.utf16.count)
    }

    private static func trimBoundarySeparators(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, isStructuralSeparator(scalars[start]) {
            start += 1
        }
        while end > start, isStructuralSeparator(scalars[end - 1]) {
            end -= 1
        }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    private static func isStructuralSeparator(_ scalar: UnicodeScalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    private static func readCoordinateText(
        rawText: String,
        probe: AXTextCoordinateProbe
    ) throws -> (length: Int, text: String)? {
        guard let empty = try probe.read(.init(location: 0, length: 0)), empty.isEmpty else {
            return nil
        }

        let rawLength = rawText.utf16.count
        let separatorLength = rawText.unicodeScalars.reduce(into: 0) { result, scalar in
            if isStructuralSeparator(scalar) {
                result += scalar.utf16.count
            }
        }

        // A failed probe can be caused by an invalid UTF-16 split inside an
        // emoji, so a binary search over every integer is not safe. The only
        // valid length reduction we accept is the number of line-separator
        // units present in AXValue; try those candidates from longest to
        // shortest and require the returned text to have the requested size.
        for omittedLength in 0...separatorLength {
            let candidate = rawLength - omittedLength
            guard let text = try probe.read(.init(location: 0, length: candidate)),
                  text.utf16.count == candidate else {
                continue
            }
            return (candidate, text)
        }
        return nil
    }

    private static func rawBoundaryMapping(
        rawText: String,
        coordinateText: String
    ) -> (omittedSeparatorCount: Int, rawBoundaryOffsets: [Int])? {
        let coordinateScalars = Array(coordinateText.unicodeScalars)
        var coordinateIndex = 0
        var coordinateOffset = 0
        var rawOffset = 0
        var omittedCount = 0
        var rawBoundaryOffsets = Array(
            repeating: -1,
            count: coordinateText.utf16.count + 1
        )
        rawBoundaryOffsets[0] = 0

        for scalar in rawText.unicodeScalars {
            if coordinateIndex < coordinateScalars.count,
               scalar == coordinateScalars[coordinateIndex] {
                let scalarLength = scalar.utf16.count
                rawOffset += scalarLength
                coordinateOffset += scalarLength
                guard coordinateOffset < rawBoundaryOffsets.count else { return nil }
                rawBoundaryOffsets[coordinateOffset] = rawOffset
                coordinateIndex += 1
            } else if isStructuralSeparator(scalar) {
                rawOffset += scalar.utf16.count
                rawBoundaryOffsets[coordinateOffset] = rawOffset
                omittedCount += 1
            } else {
                return nil
            }
        }

        guard coordinateIndex == coordinateScalars.count,
              rawOffset == rawText.utf16.count,
              rawBoundaryOffsets[coordinateText.utf16.count] >= 0 else {
            return nil
        }
        return (omittedCount, rawBoundaryOffsets)
    }
}
