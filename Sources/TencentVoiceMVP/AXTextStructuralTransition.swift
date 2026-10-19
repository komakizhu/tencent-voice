import Foundation

/// A possible post-write representation produced by a structural AX
/// transition. The model deliberately knows nothing about a target
/// application, event sender, or insertion anchor; it only carries the
/// document observation that the shared receipt checker must distinguish.
struct AXTextStructuralTransitionCandidate: Equatable, Sendable {
    let document: AXTextDocumentState
    let rawOperationRange: TextRange?
    let rawInsertionSeparatorLength: Int

    init(
        document: AXTextDocumentState,
        rawOperationRange: TextRange?,
        rawInsertionSeparatorLength: Int = 0
    ) {
        self.document = document
        self.rawOperationRange = rawOperationRange
        self.rawInsertionSeparatorLength = rawInsertionSeparatorLength
    }
}

/// Builds the finite set of raw/coordinate representations that can arise
/// when an editor publishes an empty paragraph marker around a write. The
/// same rules cover leading, interior, and trailing runs; the caller does
/// not select a case by position or by editor name.
enum AXTextStructuralTransitionModel {
    static func candidates(
        document: String,
        range: TextRange,
        text: String,
        rawDocument: String,
        rawRanges: [TextRange],
        mapping: AXTextCoordinateMapping
    ) -> [AXTextStructuralTransitionCandidate] {
        let terminalCandidates = rawRanges.compactMap {
            terminalCandidate(
                document: document,
                range: range,
                text: text,
                rawDocument: rawDocument,
                rawRange: $0,
                mapping: mapping
            )
        }
        if !terminalCandidates.isEmpty {
            return terminalCandidates
        }

        guard !text.isEmpty,
              !AXTextStructural.containsStructuralSeparator(in: text),
              range.length == 0,
              !document.isEmpty,
              mapping.source == .axStringForRange,
              mapping.coordinateDocumentLength == document.utf16.count,
              mapping.rawDocumentLength == rawDocument.utf16.count,
              range.location >= 0,
              range.location < document.utf16.count,
              !rawRanges.isEmpty,
              AXTextStructural.structuralUnitRange(
                  startingAt: range.location,
                  in: document
              ) != nil else {
            return []
        }

        guard let documentRun = structuralRun(containing: range.location, in: document),
              let documentRegion = region(
                  for: documentRun,
                  documentLength: document.utf16.count
              ) else {
            return []
        }

        let alternateSelection = TextRange(
            location: range.location + text.utf16.count,
            length: 0
        )
        let alternateCoordinate = NSMutableString(string: document)
        alternateCoordinate.replaceCharacters(
            in: NSRange(location: range.location, length: 0),
            with: text
        )
        let insertedTextEnd = range.location + text.utf16.count
        guard let coordinateUnit = AXTextStructural.structuralUnitRange(
            startingAt: insertedTextEnd,
            in: alternateCoordinate as String
        ) else {
            return []
        }
        alternateCoordinate.deleteCharacters(
            in: NSRange(location: coordinateUnit.location, length: coordinateUnit.length)
        )
        let alternateText = alternateCoordinate as String

        var result: [AXTextStructuralTransitionCandidate] = []
        for rawRange in rawRanges {
            guard rawRange.length == 0,
                  rawRange.location >= 0,
                  rawRange.location < rawDocument.utf16.count,
                  let rawRun = structuralRun(containing: rawRange.location, in: rawDocument),
                  documentRegion == region(
                      for: rawRun,
                      documentLength: rawDocument.utf16.count
                  ),
                  let rawUnit = AXTextStructural.structuralUnitRange(
                      startingAt: rawRange.location,
                      in: rawDocument
                  ) else {
                continue
            }

            var rawCandidates: [(text: String, range: TextRange, separatorLength: Int)] = []

        // Keep the selected structural unit as a finite marker run after the
        // inserted payload. A copy count of zero is the old "replace the
        // separator" representation; one is the ordinary retained-marker
        // representation; two and three cover empty-paragraph markers that
        // the editor can publish around the same logical insertion. The
        // suffix preserves every other unit in the original run, so no
        // invisible character is globally deleted or normalized.
        let rawPrefix = (rawDocument as NSString).substring(
            with: NSRange(location: 0, length: rawRange.location)
        )
        let rawSuffix = (rawDocument as NSString).substring(
            with: NSRange(
                location: rawRange.location + rawUnit.length,
                length: rawDocument.utf16.count - rawRange.location - rawUnit.length
            )
        )
        let separatorText = (rawDocument as NSString).substring(
            with: NSRange(location: rawUnit.location, length: rawUnit.length)
        )
        for copyCount in 0...AXTextStructural.maxLocalMarkerCopies {
            let marker = String(repeating: separatorText, count: copyCount)
            rawCandidates.append(
                (
                    rawPrefix + text + marker + rawSuffix,
                    TextRange(location: rawRange.location, length: 0),
                    marker.utf16.count
                )
            )
        }

        // A trailing run also admits an insertion after the selected unit.
        // Retain this path because it represents a different raw boundary,
        // not another count of the same marker candidate.
        if documentRegion == .trailing
            || (documentRegion == .leading && documentRun.count > 1) {
            let insertionOffset = rawRange.location + rawUnit.length
            guard insertionOffset <= rawDocument.utf16.count else { continue }
            let retainedSeparatorRaw = NSMutableString(string: rawDocument)
            retainedSeparatorRaw.replaceCharacters(
                in: NSRange(location: insertionOffset, length: 0),
                with: text
            )
            rawCandidates.append(
                (
                    retainedSeparatorRaw as String,
                    TextRange(location: insertionOffset, length: 0),
                    0
                )
            )
        }

            for rawCandidate in rawCandidates {
            let rawText = rawCandidate.text
            let probe = AXTextCoordinateProbe { requestedRange in
                guard requestedRange.location >= 0,
                      requestedRange.length >= 0,
                      requestedRange.location <= alternateText.utf16.count,
                      requestedRange.length <= alternateText.utf16.count - requestedRange.location else {
                    return nil
                }
                return (alternateText as NSString).substring(
                    with: NSRange(
                        location: requestedRange.location,
                        length: requestedRange.length
                    )
                )
            }
            guard let resolved = try? AXTextDocumentResolver.resolve(
                rawText: rawText,
                selection: alternateSelection,
                placeholderEvidence: .init(),
                probe: probe
            ),
            resolved.rawText == rawText,
            resolved.text == alternateText,
            resolved.selection == alternateSelection,
            AXTextDocumentResolver.isValidCoordinateMapping(
                resolved.mapping,
                rawText: resolved.rawText,
                coordinateText: resolved.text
            ),
            !resolved.mapping.rawRangeCandidates(for: alternateSelection).isEmpty else {
                continue
            }

            let candidate = AXTextStructuralTransitionCandidate(
                document: resolved,
                rawOperationRange: rawCandidate.range,
                rawInsertionSeparatorLength: rawCandidate.separatorLength
            )
                guard result.allSatisfy({ $0 != candidate }) else { continue }
                result.append(candidate)
            }
        }

        return result
    }

    private static func terminalCandidate(
        document: String,
        range: TextRange,
        text: String,
        rawDocument: String,
        rawRange: TextRange,
        mapping: AXTextCoordinateMapping
    ) -> AXTextStructuralTransitionCandidate? {
        guard let trailingUnit = trailingStructuralUnit(in: document),
              let trailingRun = structuralRun(
                  containing: trailingUnit.location,
                  in: document
              ) else {
            return nil
        }
        guard !text.isEmpty,
              !AXTextStructural.containsStructuralSeparator(in: text),
              range.length == 0,
              rawRange.length == 0,
              range.location == document.utf16.count,
              rawRange.location == rawDocument.utf16.count,
              !document.isEmpty,
              document == rawDocument,
              mapping.source == .axStringForRange,
              mapping.omittedStructuralSeparatorCount == 0,
              mapping.coordinateDocumentLength == document.utf16.count,
              mapping.rawDocumentLength == rawDocument.utf16.count,
              trailingRun.start > 0,
              !AXTextStructural.isStructuralSeparator(
                  atUTF16Offset: trailingRun.start - 1,
                  in: document
              ) else {
            return nil
        }

        let prefix = (document as NSString).substring(
            with: NSRange(location: 0, length: trailingUnit.location)
        )
        let expectedText = prefix + text
        let selection = TextRange(location: expectedText.utf16.count, length: 0)
        guard let resolved = resolve(
            rawText: expectedText,
            coordinateText: expectedText,
            selection: selection
        ) else {
            return nil
        }
        return AXTextStructuralTransitionCandidate(
            document: resolved,
            rawOperationRange: rawRange
        )
    }

    private static func resolve(
        rawText: String,
        coordinateText: String,
        selection: TextRange
    ) -> AXTextDocumentState? {
        let probe = AXTextCoordinateProbe { requestedRange in
            guard requestedRange.location >= 0,
                  requestedRange.length >= 0,
                  requestedRange.location <= coordinateText.utf16.count,
                  requestedRange.length <= coordinateText.utf16.count - requestedRange.location else {
                return nil
            }
            return (coordinateText as NSString).substring(
                with: NSRange(
                    location: requestedRange.location,
                    length: requestedRange.length
                )
            )
        }
        guard let resolved = try? AXTextDocumentResolver.resolve(
            rawText: rawText,
            selection: selection,
            placeholderEvidence: .init(),
            probe: probe
        ),
        resolved.rawText == rawText,
        resolved.text == coordinateText,
        resolved.selection == selection,
        AXTextDocumentResolver.isValidCoordinateMapping(
            resolved.mapping,
            rawText: resolved.rawText,
            coordinateText: resolved.text
        ),
        !resolved.mapping.rawRangeCandidates(for: selection).isEmpty else {
            return nil
        }
        return resolved
    }

    private enum EmptyParagraphRegion: Equatable {
        case leading
        case interior
        case trailing
    }

    private struct StructuralRun: Equatable {
        let start: Int
        let end: Int
        let count: Int
    }

    private static func structuralRun(
        containing location: Int,
        in text: String
    ) -> StructuralRun? {
        let scalars = Array(text.unicodeScalars)
        var offsets = [0]
        offsets.reserveCapacity(scalars.count + 1)
        var offset = 0
        for scalar in scalars {
            offset += scalar.utf16.count
            offsets.append(offset)
        }
        guard let scalarIndex = offsets.firstIndex(of: location),
              scalarIndex < scalars.count,
              AXTextStructural.structuralUnitRange(
                  startingAt: location,
                  in: text
              ) != nil,
              AXTextStructural.isStructuralSeparator(
                  at: scalarIndex,
                  in: scalars
              ) else {
            return nil
        }

        var startIndex = scalarIndex
        while startIndex > 0,
              AXTextStructural.isStructuralSeparator(
                  at: startIndex - 1,
                  in: scalars
              ) {
            startIndex -= 1
        }
        var endIndex = scalarIndex + 1
        while endIndex < scalars.count,
              AXTextStructural.isStructuralSeparator(
                  at: endIndex,
                  in: scalars
              ) {
            endIndex += 1
        }
        let start = offsets[startIndex]
        let end = offsets[endIndex]
        let units = structuralUnitRanges(
            in: text,
            within: TextRange(location: start, length: end - start)
        )
        return StructuralRun(start: start, end: end, count: units.count)
    }

    private static func structuralUnitRanges(
        in text: String,
        within range: TextRange
    ) -> [TextRange] {
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= text.utf16.count else {
            return []
        }
        var result: [TextRange] = []
        var offset = range.location
        let end = range.location + range.length
        while offset < end {
            guard let unit = AXTextStructural.structuralUnitRange(
                startingAt: offset,
                in: text
            ),
            unit.location + unit.length <= end else {
                return []
            }
            result.append(unit)
            offset += unit.length
        }
        return result
    }

    private static func trailingStructuralUnit(in text: String) -> TextRange? {
        let scalars = Array(text.unicodeScalars)
        guard let lastScalar = scalars.indices.last,
              AXTextStructural.isStructuralSeparator(
                  at: lastScalar,
                  in: scalars
              ) else {
            return nil
        }
        var offsets = [0]
        offsets.reserveCapacity(scalars.count + 1)
        var offset = 0
        for scalar in scalars {
            offset += scalar.utf16.count
            offsets.append(offset)
        }
        let lastUnitStart: Int
        if scalars[lastScalar].value == 0x0A,
           lastScalar > 0,
           scalars[lastScalar - 1].value == 0x0D {
            lastUnitStart = offsets[lastScalar - 1]
        } else {
            lastUnitStart = offsets[lastScalar]
        }
        guard let run = structuralRun(containing: lastUnitStart, in: text),
              run.end == text.utf16.count else {
            return nil
        }
        return structuralUnitRanges(
            in: text,
            within: TextRange(location: run.start, length: run.end - run.start)
        ).last
    }

    private static func region(
        for run: StructuralRun,
        documentLength: Int
    ) -> EmptyParagraphRegion? {
        guard run.count > 0 else { return nil }
        if run.end == documentLength { return .trailing }
        if run.start == 0 { return .leading }
        return .interior
    }
}
