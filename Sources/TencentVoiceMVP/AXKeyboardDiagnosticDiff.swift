import Foundation

enum KeyboardDiagnosticDiffClassification: String, Equatable, Sendable {
    case equal
    case structuralLocal = "structural_local"
    case structuralOutside = "structural_outside"
    case contentChanged = "content_changed"
    case unavailable
    case budgetExceeded = "budget_exceeded"
}

struct KeyboardDiagnosticDiffOperation: Equatable, Sendable {
    let coordinateRange: TextRange
    let insertedLengthUTF16: Int
    let operationGeneration: UInt64
}

struct KeyboardDiagnosticDiffSummary: Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumUTF16Length = 65_536

    let classification: KeyboardDiagnosticDiffClassification
    let coordinateUnit: String
    let expectedAXValueLengthUTF16: Int?
    let observedAXValueLengthUTF16: Int?
    let expectedCoordinateLengthUTF16: Int?
    let observedCoordinateLengthUTF16: Int?
    let commonPrefixExpectedUTF16: Int?
    let commonPrefixObservedUTF16: Int?
    let commonSuffixExpectedUTF16: Int?
    let commonSuffixObservedUTF16: Int?
    let expectedChangeStartUTF16: Int?
    let expectedChangeEndUTF16: Int?
    let observedChangeStartUTF16: Int?
    let observedChangeEndUTF16: Int?
    let operationStartUTF16: Int?
    let operationEndUTF16: Int?
    let operationRangeAvailable: Bool
    let separatorDifferenceBoundaryCount: Int
    let separatorDifferenceUnitCount: Int
    let separatorDeltaLF: Int
    let separatorDeltaCR: Int
    let separatorDeltaLS: Int
    let separatorDeltaPS: Int
    let separatorFirstPositionUTF16: Int?
    let separatorLastPositionUTF16: Int?
    let separatorFirstDistanceFromOperationUTF16: Int?
    let separatorLastDistanceFromOperationUTF16: Int?
    let separatorOutsideOperationCount: Int
    let mappingValid: Bool

    static func unavailable(
        expected: KeyboardDocumentState,
        observed: KeyboardDocumentState,
        mappingValid: Bool,
        classification: KeyboardDiagnosticDiffClassification = .unavailable
    ) -> Self {
        Self(
            classification: classification,
            coordinateUnit: "UTF16",
            expectedAXValueLengthUTF16: expected.rawText?.utf16.count,
            observedAXValueLengthUTF16: observed.rawText?.utf16.count,
            expectedCoordinateLengthUTF16: expected.text.utf16.count,
            observedCoordinateLengthUTF16: observed.text.utf16.count,
            commonPrefixExpectedUTF16: nil,
            commonPrefixObservedUTF16: nil,
            commonSuffixExpectedUTF16: nil,
            commonSuffixObservedUTF16: nil,
            expectedChangeStartUTF16: nil,
            expectedChangeEndUTF16: nil,
            observedChangeStartUTF16: nil,
            observedChangeEndUTF16: nil,
            operationStartUTF16: nil,
            operationEndUTF16: nil,
            operationRangeAvailable: false,
            separatorDifferenceBoundaryCount: 0,
            separatorDifferenceUnitCount: 0,
            separatorDeltaLF: 0,
            separatorDeltaCR: 0,
            separatorDeltaLS: 0,
            separatorDeltaPS: 0,
            separatorFirstPositionUTF16: nil,
            separatorLastPositionUTF16: nil,
            separatorFirstDistanceFromOperationUTF16: nil,
            separatorLastDistanceFromOperationUTF16: nil,
            separatorOutsideOperationCount: 0,
            mappingValid: mappingValid
        )
    }

    func fields(prefix: String) -> [String: String] {
        var fields: [String: String] = [
            "\(prefix)SchemaVersion": String(Self.schemaVersion),
            "\(prefix)Classification": classification.rawValue,
            "\(prefix)CoordinateUnit": coordinateUnit,
            "\(prefix)OperationRangeAvailable": String(operationRangeAvailable),
            "\(prefix)MappingValid": String(mappingValid),
            "\(prefix)SeparatorDifferenceBoundaryCount": String(separatorDifferenceBoundaryCount),
            "\(prefix)SeparatorDifferenceUnitCount": String(separatorDifferenceUnitCount),
            "\(prefix)SeparatorDeltaLF": String(separatorDeltaLF),
            "\(prefix)SeparatorDeltaCR": String(separatorDeltaCR),
            "\(prefix)SeparatorDeltaLS": String(separatorDeltaLS),
            "\(prefix)SeparatorDeltaPS": String(separatorDeltaPS),
            "\(prefix)SeparatorOutsideOperationCount": String(separatorOutsideOperationCount)
        ]
        let values: [(String, Int?)] = [
            ("ExpectedAXValueLengthUTF16", expectedAXValueLengthUTF16),
            ("ObservedAXValueLengthUTF16", observedAXValueLengthUTF16),
            ("ExpectedCoordinateLengthUTF16", expectedCoordinateLengthUTF16),
            ("ObservedCoordinateLengthUTF16", observedCoordinateLengthUTF16),
            ("CommonPrefixExpectedUTF16", commonPrefixExpectedUTF16),
            ("CommonPrefixObservedUTF16", commonPrefixObservedUTF16),
            ("CommonSuffixExpectedUTF16", commonSuffixExpectedUTF16),
            ("CommonSuffixObservedUTF16", commonSuffixObservedUTF16),
            ("ExpectedChangeStartUTF16", expectedChangeStartUTF16),
            ("ExpectedChangeEndUTF16", expectedChangeEndUTF16),
            ("ObservedChangeStartUTF16", observedChangeStartUTF16),
            ("ObservedChangeEndUTF16", observedChangeEndUTF16),
            ("OperationStartUTF16", operationStartUTF16),
            ("OperationEndUTF16", operationEndUTF16),
            ("SeparatorFirstPositionUTF16", separatorFirstPositionUTF16),
            ("SeparatorLastPositionUTF16", separatorLastPositionUTF16),
            ("SeparatorFirstDistanceFromOperationUTF16", separatorFirstDistanceFromOperationUTF16),
            ("SeparatorLastDistanceFromOperationUTF16", separatorLastDistanceFromOperationUTF16)
        ]
        for (key, value) in values {
            if let value { fields["\(prefix)\(key)"] = String(value) }
        }
        return fields
    }
}

enum KeyboardDiagnosticDiffCalculator {
    private enum SeparatorKind: String, CaseIterable {
        case lf = "LF"
        case cr = "CR"
        case ls = "LS"
        case ps = "PS"

        init?(scalar: UnicodeScalar) {
            switch scalar.value {
            case 0x0A: self = .lf
            case 0x0D: self = .cr
            case 0x2028: self = .ls
            case 0x2029: self = .ps
            default: return nil
            }
        }
    }

    private struct ScalarUnit {
        let value: UInt32
        let offsetUTF16: Int
        let lengthUTF16: Int
        let separator: SeparatorKind?
    }

    private struct SeparatorEvent {
        let boundaryIndex: Int
        let kind: SeparatorKind
    }

    private struct SeparatorCounts: Equatable {
        var values: [SeparatorKind: Int] = [:]

        subscript(_ kind: SeparatorKind) -> Int {
            values[kind, default: 0]
        }

        var total: Int { values.values.reduce(0, +) }

        func delta(from other: Self) -> Int {
            SeparatorKind.allCases.reduce(0) { result, kind in
                result + abs(self[kind] - other[kind])
            }
        }
    }

    private struct ChangeRange {
        let commonPrefixExpectedUTF16: Int
        let commonPrefixObservedUTF16: Int
        let commonSuffixExpectedUTF16: Int
        let commonSuffixObservedUTF16: Int
        let expectedStartUTF16: Int
        let expectedEndUTF16: Int
        let observedStartUTF16: Int
        let observedEndUTF16: Int
    }

    static func compare(
        expected: KeyboardDocumentState,
        observed: KeyboardDocumentState,
        operation: KeyboardDiagnosticDiffOperation?,
        mappingValid: Bool,
        maximumUTF16Length: Int = KeyboardDiagnosticDiffSummary.maximumUTF16Length
    ) -> KeyboardDiagnosticDiffSummary {
        guard let expectedAXValue = expected.rawText,
              let observedAXValue = observed.rawText,
              let operation else {
            return .unavailable(expected: expected, observed: observed, mappingValid: mappingValid)
        }

        let expectedLength = expectedAXValue.utf16.count
        let observedLength = observedAXValue.utf16.count
        let expectedCoordinateLength = expected.text.utf16.count
        let observedCoordinateLength = observed.text.utf16.count
        guard expectedLength <= maximumUTF16Length,
              observedLength <= maximumUTF16Length,
              expectedCoordinateLength <= maximumUTF16Length,
              observedCoordinateLength <= maximumUTF16Length else {
            return .unavailable(
                expected: expected,
                observed: observed,
                mappingValid: mappingValid,
                classification: .budgetExceeded
            )
        }
        guard mappingValid,
              operation.insertedLengthUTF16 >= 0 else {
            return .unavailable(expected: expected, observed: observed, mappingValid: mappingValid)
        }

        let expectedUnits = scalarUnits(expectedAXValue)
        let observedUnits = scalarUnits(observedAXValue)
        let change = changeRange(expected: expectedUnits, observed: observedUnits)
        let expectedContent = expectedUnits.filter { $0.separator == nil }.map(\.value)
        let observedContent = observedUnits.filter { $0.separator == nil }.map(\.value)
        let coordinateUnits = scalarUnits(expected.text)
        let coordinateContent = coordinateUnits.filter { $0.separator == nil }.map(\.value)
        let operationStart = operation.coordinateRange.location
        // Cover both the consumed range and the inserted content. This keeps
        // the two boundaries of an insertion local while retaining the full
        // replaced span for deletion and shorter revisions.
        let operationWidth = max(
            operation.coordinateRange.length,
            operation.insertedLengthUTF16
        )
        guard operationStart >= 0,
              operation.coordinateRange.length >= 0,
              operationWidth >= 0,
              operationStart <= expectedCoordinateLength,
              coordinateContent == expectedContent,
              let operationStartBoundary = contentBoundaryIndex(
                  utf16Offset: operationStart,
                  in: coordinateUnits
              ),
              // The operation is expressed in the pre-edit coordinate space.
              // A tail deletion can consume more units than remain in the
              // post-edit expected text, so stop at its final boundary rather
              // than turning an otherwise useful summary into unavailable.
              let operationEndBoundary = contentBoundaryIndex(
                  utf16Offset: operationStart + min(
                      operationWidth,
                      expectedCoordinateLength - operationStart
                  ),
                  in: coordinateUnits
              ),
              operationEndBoundary >= operationStartBoundary else {
            return .unavailable(expected: expected, observed: observed, mappingValid: mappingValid)
        }
        let coordinateBoundaryOffsets = contentBoundaryUTF16Offsets(in: coordinateUnits)
        let operationStartCoordinate = coordinateBoundaryOffsets[operationStartBoundary]
        let operationEndCoordinate = coordinateBoundaryOffsets[operationEndBoundary]

        guard expectedContent == observedContent else {
            return makeSummary(
                classification: .contentChanged,
                expected: expected,
                observed: observed,
                change: change,
                operationStart: operationStartCoordinate,
                operationEnd: operationEndCoordinate,
                separatorBoundaryCount: 0,
                separatorUnitCount: 0,
                separatorDeltas: [:],
                separatorPositions: [],
                outsideCount: 0,
                mappingValid: mappingValid
            )
        }

        let expectedSeparators = separatorEvents(expectedUnits)
        let observedSeparators = separatorEvents(observedUnits)
        let expectedByBoundary = groupedSeparators(expectedSeparators)
        let observedByBoundary = groupedSeparators(observedSeparators)
        let maximumBoundary = max(expectedContent.count, observedContent.count)
        var changedBoundaries = [Int]()
        var separatorUnitCount = 0
        var separatorDeltas: [SeparatorKind: Int] = [:]
        for boundary in 0...maximumBoundary {
            let expectedAtBoundary = expectedByBoundary[boundary] ?? []
            let observedAtBoundary = observedByBoundary[boundary] ?? []
            let expectedCounts = counts(expectedAtBoundary)
            let observedCounts = counts(observedAtBoundary)
            let countDelta = expectedCounts.delta(from: observedCounts)
            let orderChanged = expectedAtBoundary.map(\.kind) != observedAtBoundary.map(\.kind)
                && expectedCounts == observedCounts
            guard countDelta > 0 || orderChanged else { continue }
            changedBoundaries.append(boundary)
            separatorUnitCount += countDelta > 0 ? countDelta : max(expectedAtBoundary.count, 1)
            for kind in SeparatorKind.allCases {
                separatorDeltas[kind, default: 0] += abs(expectedCounts[kind] - observedCounts[kind])
            }
        }

        let positions = changedBoundaries.map { coordinateBoundaryOffsets[$0] }
        let outsideCount = changedBoundaries.reduce(into: 0) { count, boundary in
            if boundary < operationStartBoundary || boundary > operationEndBoundary { count += 1 }
        }
        let classification: KeyboardDiagnosticDiffClassification
        if changedBoundaries.isEmpty {
            classification = expectedUnits.map(\.value) == observedUnits.map(\.value) ? .equal : .unavailable
        } else {
            classification = outsideCount == 0 ? .structuralLocal : .structuralOutside
        }
        let firstDistance = positions.first.map {
            distanceFromOperation(
                position: $0,
                start: operationStartCoordinate,
                end: operationEndCoordinate
            )
        }
        let lastDistance = positions.last.map {
            distanceFromOperation(
                position: $0,
                start: operationStartCoordinate,
                end: operationEndCoordinate
            )
        }
        return makeSummary(
            classification: classification,
            expected: expected,
            observed: observed,
            change: change,
            operationStart: operationStartCoordinate,
            operationEnd: operationEndCoordinate,
            separatorBoundaryCount: changedBoundaries.count,
            separatorUnitCount: separatorUnitCount,
            separatorDeltas: separatorDeltas,
            separatorPositions: positions,
            outsideCount: outsideCount,
            firstDistance: firstDistance,
            lastDistance: lastDistance,
            mappingValid: mappingValid
        )
    }

    private static func makeSummary(
        classification: KeyboardDiagnosticDiffClassification,
        expected: KeyboardDocumentState,
        observed: KeyboardDocumentState,
        change: ChangeRange,
        operationStart: Int,
        operationEnd: Int,
        separatorBoundaryCount: Int,
        separatorUnitCount: Int,
        separatorDeltas: [SeparatorKind: Int],
        separatorPositions: [Int],
        outsideCount: Int,
        firstDistance: Int? = nil,
        lastDistance: Int? = nil,
        mappingValid: Bool
    ) -> KeyboardDiagnosticDiffSummary {
        return KeyboardDiagnosticDiffSummary(
            classification: classification,
            coordinateUnit: "UTF16",
            expectedAXValueLengthUTF16: expected.rawText?.utf16.count,
            observedAXValueLengthUTF16: observed.rawText?.utf16.count,
            expectedCoordinateLengthUTF16: expected.text.utf16.count,
            observedCoordinateLengthUTF16: observed.text.utf16.count,
            commonPrefixExpectedUTF16: change.commonPrefixExpectedUTF16,
            commonPrefixObservedUTF16: change.commonPrefixObservedUTF16,
            commonSuffixExpectedUTF16: change.commonSuffixExpectedUTF16,
            commonSuffixObservedUTF16: change.commonSuffixObservedUTF16,
            expectedChangeStartUTF16: change.expectedStartUTF16,
            expectedChangeEndUTF16: change.expectedEndUTF16,
            observedChangeStartUTF16: change.observedStartUTF16,
            observedChangeEndUTF16: change.observedEndUTF16,
            operationStartUTF16: operationStart,
            operationEndUTF16: operationEnd,
            operationRangeAvailable: true,
            separatorDifferenceBoundaryCount: separatorBoundaryCount,
            separatorDifferenceUnitCount: separatorUnitCount,
            separatorDeltaLF: separatorDeltas[.lf, default: 0],
            separatorDeltaCR: separatorDeltas[.cr, default: 0],
            separatorDeltaLS: separatorDeltas[.ls, default: 0],
            separatorDeltaPS: separatorDeltas[.ps, default: 0],
            separatorFirstPositionUTF16: separatorPositions.first,
            separatorLastPositionUTF16: separatorPositions.last,
            separatorFirstDistanceFromOperationUTF16: firstDistance,
            separatorLastDistanceFromOperationUTF16: lastDistance,
            separatorOutsideOperationCount: outsideCount,
            mappingValid: mappingValid
        )
    }

    private static func scalarUnits(_ value: String) -> [ScalarUnit] {
        var offset = 0
        return value.unicodeScalars.map { scalar in
            let length = scalar.utf16.count
            defer { offset += length }
            return ScalarUnit(
                value: scalar.value,
                offsetUTF16: offset,
                lengthUTF16: length,
                separator: SeparatorKind(scalar: scalar)
            )
        }
    }

    private static func changeRange(expected: [ScalarUnit], observed: [ScalarUnit]) -> ChangeRange {
        var prefixCount = 0
        while prefixCount < expected.count,
              prefixCount < observed.count,
              expected[prefixCount].value == observed[prefixCount].value {
            prefixCount += 1
        }
        var suffixCount = 0
        while suffixCount < expected.count - prefixCount,
              suffixCount < observed.count - prefixCount,
              expected[expected.count - suffixCount - 1].value
                == observed[observed.count - suffixCount - 1].value {
            suffixCount += 1
        }
        let expectedStart = prefixCount < expected.count ? expected[prefixCount].offsetUTF16 : expected.reduce(0) { $0 + $1.lengthUTF16 }
        let observedStart = prefixCount < observed.count ? observed[prefixCount].offsetUTF16 : observed.reduce(0) { $0 + $1.lengthUTF16 }
        let expectedEnd = suffixCount < expected.count
            ? expected[expected.count - suffixCount - 1].offsetUTF16 + expected[expected.count - suffixCount - 1].lengthUTF16
            : expectedStart
        let observedEnd = suffixCount < observed.count
            ? observed[observed.count - suffixCount - 1].offsetUTF16 + observed[observed.count - suffixCount - 1].lengthUTF16
            : observedStart
        return ChangeRange(
            commonPrefixExpectedUTF16: expectedStart,
            commonPrefixObservedUTF16: observedStart,
            commonSuffixExpectedUTF16: expected.reduce(0) { $0 + $1.lengthUTF16 } - expectedEnd,
            commonSuffixObservedUTF16: observed.reduce(0) { $0 + $1.lengthUTF16 } - observedEnd,
            expectedStartUTF16: expectedStart,
            expectedEndUTF16: expectedEnd,
            observedStartUTF16: observedStart,
            observedEndUTF16: observedEnd
        )
    }

    private static func separatorEvents(_ units: [ScalarUnit]) -> [SeparatorEvent] {
        var boundary = 0
        var events = [SeparatorEvent]()
        for unit in units {
            if let separator = unit.separator {
                events.append(SeparatorEvent(boundaryIndex: boundary, kind: separator))
            } else {
                boundary += 1
            }
        }
        return events
    }

    private static func groupedSeparators(_ events: [SeparatorEvent]) -> [Int: [SeparatorEvent]] {
        events.reduce(into: [:]) { result, event in
            result[event.boundaryIndex, default: []].append(event)
        }
    }

    private static func counts(_ events: [SeparatorEvent]) -> SeparatorCounts {
        events.reduce(into: SeparatorCounts()) { result, event in
            result.values[event.kind, default: 0] += 1
        }
    }

    private static func contentBoundaryIndex(utf16Offset: Int, in units: [ScalarUnit]) -> Int? {
        guard utf16Offset >= 0 else { return nil }
        var documentOffset = 0
        var boundary = 0
        for unit in units {
            if documentOffset == utf16Offset { return boundary }
            let endOffset = documentOffset + unit.lengthUTF16
            guard utf16Offset >= endOffset else {
                // A UTF-16 offset in the middle of a scalar is not a valid
                // operation boundary. Separators are single UTF-16 units, so
                // their start and end offsets are handled by the next loop.
                return nil
            }
            documentOffset = endOffset
            if unit.separator == nil { boundary += 1 }
        }
        return documentOffset == utf16Offset ? boundary : nil
    }

    private static func contentBoundaryUTF16Offsets(in units: [ScalarUnit]) -> [Int] {
        var offsets = [0]
        offsets.reserveCapacity(units.count + 1)
        var offset = 0
        for unit in units where unit.separator == nil {
            offset += unit.lengthUTF16
            offsets.append(offset)
        }
        return offsets
    }

    private static func distanceFromOperation(position: Int, start: Int, end: Int) -> Int {
        if position < start { return start - position }
        if position > end { return position - end }
        return 0
    }
}
