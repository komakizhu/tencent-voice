import Foundation

enum AXTextCoordinateSource: String, Equatable, Sendable {
    case axStringForRange
    case axValueAfterPlaceholderTransition
    case pendingReceiptExactAXValue
    case pendingReceiptStructuralAugmentation
    case placeholder
}

/// Structural separators are contextual rather than a character whitelist.
/// A CRLF pair is one raw caret unit, while an AX coordinate provider may
/// normalize either code unit; a standalone CR is正文. Keeping this rule in
/// one place prevents the coordinate mapper, diff classifier, and keyboard
/// receipt builder from silently deleting the same invisible body character
/// in different ways.
enum AXTextStructural {
    /// Finite local bound for a newly published marker run. Larger runs are
    /// not inferred from text alone and must remain unconfirmed until a real
    /// editor-specific observation expands the calibrated universe.
    static let maxLocalMarkerCopies = 3

    static func isStructuralSeparator(
        at scalarIndex: Int,
        in scalars: [UnicodeScalar]
    ) -> Bool {
        guard scalarIndex >= 0, scalarIndex < scalars.count else { return false }
        switch scalars[scalarIndex].value {
        case 0x0A, 0x2028, 0x2029:
            return true
        case 0x0D:
            return scalarIndex + 1 < scalars.count
                && scalars[scalarIndex + 1].value == 0x0A
        default:
            return false
        }
    }

    static func containsStructuralSeparator(in text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.indices.contains {
            isStructuralSeparator(at: $0, in: scalars)
        }
    }

    static func isCRLFInteriorBoundary(_ offset: Int, in text: String) -> Bool {
        guard offset > 0, offset < text.utf16.count else { return false }
        let units = Array(text.utf16)
        return units[offset - 1] == 0x0D && units[offset] == 0x0A
    }

    static func structuralUnitRange(startingAt location: Int, in text: String) -> TextRange? {
        let units = Array(text.utf16)
        guard location >= 0, location < units.count else { return nil }
        switch units[location] {
        case 0x0D:
            guard location + 1 < units.count, units[location + 1] == 0x0A else {
                return nil
            }
            return TextRange(location: location, length: 2)
        case 0x0A:
            guard location == 0 || units[location - 1] != 0x0D else {
                return nil
            }
            return TextRange(location: location, length: 1)
        case 0x2028, 0x2029:
            return TextRange(location: location, length: 1)
        default:
            return nil
        }
    }

    static func isStructuralSeparator(atUTF16Offset offset: Int, in text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var currentOffset = 0
        for (index, scalar) in scalars.enumerated() {
            if currentOffset == offset {
                return isStructuralSeparator(at: index, in: scalars)
            }
            currentOffset += scalar.utf16.count
        }
        return false
    }
}

/// The complete set of raw/coordinate alignments that can be explained by
/// omitting only structural separators. A single coordinate caret can sit at
/// several raw offsets when the accessibility tree contains empty paragraph
/// markers that AXStringForRange does not expose.
struct AXTextCoordinateAlignment: Equatable, Sendable {
    struct Node: Hashable, Sendable {
        let rawOffset: Int
        let coordinateOffset: Int
    }

    struct Edge: Equatable, Sendable {
        let from: Node
        let to: Node
    }

    let rawScalarCount: Int
    let coordinateScalarCount: Int
    let rawScalarValues: [UInt32]
    let coordinateScalarValues: [UInt32]
    let rawBoundaryCandidates: [[Int]]
    let edges: [Edge]

    static func build(rawText: String, coordinateText: String) -> AXTextCoordinateAlignment? {
        let rawScalars = Array(rawText.unicodeScalars)
        let coordinateScalars = Array(coordinateText.unicodeScalars)
        let rawOffsets = scalarOffsets(rawScalars)
        let coordinateOffsets = scalarOffsets(coordinateScalars)

        struct IndexedEdge: Equatable {
            let rawIndex: Int
            let fromCoordinateIndex: Int
            let toCoordinateIndex: Int
        }

        var reachable = Array(
            repeating: Set<Int>(),
            count: rawScalars.count + 1
        )
        reachable[0] = [0]
        var indexedEdgesByRawIndex = Array(
            repeating: [IndexedEdge](),
            count: rawScalars.count
        )

        for rawIndex in rawScalars.indices {
            let scalar = rawScalars[rawIndex]
            for coordinateIndex in reachable[rawIndex] {
                if coordinateIndex < coordinateScalars.count,
                   scalar == coordinateScalars[coordinateIndex] {
                    indexedEdgesByRawIndex[rawIndex].append(
                        IndexedEdge(
                            rawIndex: rawIndex,
                            fromCoordinateIndex: coordinateIndex,
                            toCoordinateIndex: coordinateIndex + 1
                        )
                    )
                    reachable[rawIndex + 1].insert(coordinateIndex + 1)
                }
                if AXTextStructural.isStructuralSeparator(
                    at: rawIndex,
                    in: rawScalars
                ) {
                    indexedEdgesByRawIndex[rawIndex].append(
                        IndexedEdge(
                            rawIndex: rawIndex,
                            fromCoordinateIndex: coordinateIndex,
                            toCoordinateIndex: coordinateIndex
                        )
                    )
                    reachable[rawIndex + 1].insert(coordinateIndex)
                }
            }
        }

        guard reachable[rawScalars.count].contains(coordinateScalars.count) else {
            return nil
        }

        var canReachEnd = Array(
            repeating: Set<Int>(),
            count: rawScalars.count + 1
        )
        canReachEnd[rawScalars.count] = [coordinateScalars.count]
        for rawIndex in rawScalars.indices.reversed() {
            for edge in indexedEdgesByRawIndex[rawIndex] {
                guard reachable[rawIndex].contains(edge.fromCoordinateIndex),
                      canReachEnd[rawIndex + 1].contains(edge.toCoordinateIndex) else {
                    continue
                }
                canReachEnd[rawIndex].insert(edge.fromCoordinateIndex)
            }
        }

        var validNodes = Set<Node>()
        var edges: [Edge] = []
        for indexedEdges in indexedEdgesByRawIndex {
            for indexedEdge in indexedEdges where
                reachable[indexedEdge.rawIndex].contains(indexedEdge.fromCoordinateIndex)
                    && canReachEnd[indexedEdge.rawIndex + 1].contains(indexedEdge.toCoordinateIndex) {
                let edge = Edge(
                    from: Node(
                        rawOffset: rawOffsets[indexedEdge.rawIndex],
                        coordinateOffset: coordinateOffsets[indexedEdge.fromCoordinateIndex]
                    ),
                    to: Node(
                        rawOffset: rawOffsets[indexedEdge.rawIndex + 1],
                        coordinateOffset: coordinateOffsets[indexedEdge.toCoordinateIndex]
                    )
                )
                edges.append(edge)
                validNodes.insert(edge.from)
                validNodes.insert(edge.to)
            }
        }
        validNodes.insert(Node(rawOffset: 0, coordinateOffset: 0))
        validNodes.insert(
            Node(
                rawOffset: rawText.utf16.count,
                coordinateOffset: coordinateText.utf16.count
            )
        )

        var candidates = Array(
            repeating: [Int](),
            count: coordinateText.utf16.count + 1
        )
        for node in validNodes where node.coordinateOffset < candidates.count {
            candidates[node.coordinateOffset].append(node.rawOffset)
        }
        candidates = candidates.map { rawOffsets in
            Array(Set(rawOffsets)).sorted().filter {
                !AXTextStructural.isCRLFInteriorBoundary($0, in: rawText)
            }
        }
        guard coordinateOffsets.allSatisfy({
            $0 < candidates.count
                && (!candidates[$0].isEmpty
                    || AXTextStructural.isCRLFInteriorBoundary($0, in: coordinateText))
        }) else {
            return nil
        }

        edges.sort {
            if $0.from.rawOffset != $1.from.rawOffset {
                return $0.from.rawOffset < $1.from.rawOffset
            }
            if $0.from.coordinateOffset != $1.from.coordinateOffset {
                return $0.from.coordinateOffset < $1.from.coordinateOffset
            }
            if $0.to.rawOffset != $1.to.rawOffset {
                return $0.to.rawOffset < $1.to.rawOffset
            }
            return $0.to.coordinateOffset < $1.to.coordinateOffset
        }

        return AXTextCoordinateAlignment(
            rawScalarCount: rawScalars.count,
            coordinateScalarCount: coordinateScalars.count,
            rawScalarValues: rawScalars.map { $0.value },
            coordinateScalarValues: coordinateScalars.map { $0.value },
            rawBoundaryCandidates: candidates,
            edges: edges
        )
    }

    private static func scalarOffsets(_ scalars: [UnicodeScalar]) -> [Int] {
        var offsets = [0]
        offsets.reserveCapacity(scalars.count + 1)
        var offset = 0
        for scalar in scalars {
            offset += scalar.utf16.count
            offsets.append(offset)
        }
        return offsets
    }

    func rawRanges(for coordinateRange: TextRange) -> [TextRange] {
        guard coordinateRange.location >= 0,
              coordinateRange.length >= 0,
              coordinateRange.location < rawBoundaryCandidates.count,
              coordinateRange.location + coordinateRange.length < rawBoundaryCandidates.count else {
            return []
        }
        let startCandidates = rawBoundaryCandidates[coordinateRange.location]
        let endCandidates = rawBoundaryCandidates[coordinateRange.location + coordinateRange.length]
        guard !startCandidates.isEmpty, !endCandidates.isEmpty else { return [] }

        if coordinateRange.length == 0 {
            return startCandidates.map { TextRange(location: $0, length: 0) }
        }

        var adjacency: [Node: [Node]] = [:]
        for edge in edges {
            adjacency[edge.from, default: []].append(edge.to)
        }

        var result: [TextRange] = []
        for start in startCandidates {
            for end in endCandidates where end >= start {
                let startNode = Node(
                    rawOffset: start,
                    coordinateOffset: coordinateRange.location
                )
                let endNode = Node(
                    rawOffset: end,
                    coordinateOffset: coordinateRange.location + coordinateRange.length
                )
                guard hasPath(from: startNode, to: endNode, adjacency: adjacency) else { continue }
                result.append(TextRange(location: start, length: end - start))
            }
        }
        return result.sorted {
            if $0.location != $1.location { return $0.location < $1.location }
            return $0.length < $1.length
        }
    }

    private func hasPath(from start: Node, to end: Node, adjacency: [Node: [Node]]) -> Bool {
        guard start != end else { return true }
        var pending = [start]
        var visited: Set<Node> = [start]
        while let node = pending.popLast() {
            for next in adjacency[node, default: []] {
                if next == end { return true }
                if visited.insert(next).inserted {
                    pending.append(next)
                }
            }
        }
        return false
    }

}

struct AXTextCoordinateMapping: Equatable, Sendable {
    let source: AXTextCoordinateSource
    let rawDocumentLength: Int
    let coordinateDocumentLength: Int
    let omittedStructuralSeparatorCount: Int
    /// Every raw boundary that belongs to a complete raw/coordinate path.
    /// This is the source of truth for edits; no boundary is selected merely
    /// because it is leftmost or rightmost.
    let boundaryCandidates: [[Int]]
    let rawPlaceholderRange: TextRange?
    let alignment: AXTextCoordinateAlignment?

    /// Compatibility projection for diagnostics and legacy callers. A
    /// boundary is exposed only when it is unique; ambiguous boundaries are
    /// intentionally represented as -1 instead of being collapsed.
    var rawBoundaryOffsets: [Int] {
        rawBoundaryCandidates.map { $0.count == 1 ? $0[0] : -1 }
    }

    init(
        source: AXTextCoordinateSource,
        rawDocumentLength: Int,
        coordinateDocumentLength: Int,
        omittedStructuralSeparatorCount: Int,
        rawBoundaryOffsets: [Int],
        rawPlaceholderRange: TextRange?,
        alignment: AXTextCoordinateAlignment? = nil
    ) {
        self.init(
            source: source,
            rawDocumentLength: rawDocumentLength,
            coordinateDocumentLength: coordinateDocumentLength,
            omittedStructuralSeparatorCount: omittedStructuralSeparatorCount,
            rawBoundaryCandidates: rawBoundaryOffsets.map { $0 >= 0 ? [$0] : [] },
            rawPlaceholderRange: rawPlaceholderRange,
            alignment: alignment
        )
    }

    init(
        source: AXTextCoordinateSource,
        rawDocumentLength: Int,
        coordinateDocumentLength: Int,
        omittedStructuralSeparatorCount: Int,
        rawBoundaryCandidates: [[Int]],
        rawPlaceholderRange: TextRange?,
        alignment: AXTextCoordinateAlignment? = nil
    ) {
        self.source = source
        self.rawDocumentLength = rawDocumentLength
        self.coordinateDocumentLength = coordinateDocumentLength
        self.omittedStructuralSeparatorCount = omittedStructuralSeparatorCount
        self.boundaryCandidates = rawBoundaryCandidates
        self.rawPlaceholderRange = rawPlaceholderRange
        self.alignment = alignment
    }

    var rawBoundaryCandidates: [[Int]] {
        alignment?.rawBoundaryCandidates
            ?? boundaryCandidates
    }

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
        if let alignment {
            // A single range is safe only when the complete alignment graph
            // has exactly one explanation. Do not collapse several valid raw
            // boundaries to a canonical/rightmost choice: callers that can
            // resolve the ambiguity must use rawRangeCandidates(for:) and
            // confirm the observed post-write state.
            let ranges = alignment.rawRanges(for: coordinateRange)
            return ranges.count == 1 ? ranges[0] : nil
        }
        let ranges = rawRangeCandidates(for: coordinateRange)
        return ranges.count == 1 ? ranges[0] : nil
    }

    func rawRangeCandidates(for coordinateRange: TextRange) -> [TextRange] {
        guard coordinateRange.location >= 0,
              coordinateRange.length >= 0,
              coordinateRange.location <= coordinateDocumentLength,
              coordinateRange.length <= coordinateDocumentLength - coordinateRange.location else {
            return []
        }
        if source == .placeholder {
            guard coordinateRange.location == 0, coordinateRange.length == 0 else { return [] }
            return [rawPlaceholderRange ?? TextRange(location: 0, length: rawDocumentLength)]
        }
        if let alignment {
            return alignment.rawRanges(for: coordinateRange)
        }
        guard boundaryCandidates.count == coordinateDocumentLength + 1 else { return [] }
        let starts = boundaryCandidates[coordinateRange.location]
        let ends = boundaryCandidates[coordinateRange.location + coordinateRange.length]
        guard !starts.isEmpty, !ends.isEmpty else { return [] }
        if coordinateRange.length == 0 {
            return starts.map { TextRange(location: $0, length: 0) }
        }
        // Without the alignment graph, independently combining two
        // ambiguous endpoints would recreate the old invalid-range bug.
        guard starts.count == 1, ends.count == 1, ends[0] >= starts[0] else {
            return []
        }
        return [TextRange(location: starts[0], length: ends[0] - starts[0])]
    }

    func withSource(_ source: AXTextCoordinateSource) -> Self {
        AXTextCoordinateMapping(
            source: source,
            rawDocumentLength: rawDocumentLength,
            coordinateDocumentLength: coordinateDocumentLength,
            omittedStructuralSeparatorCount: omittedStructuralSeparatorCount,
            rawBoundaryCandidates: rawBoundaryCandidates,
            rawPlaceholderRange: rawPlaceholderRange,
            alignment: alignment
        )
    }

    func isEquivalentIgnoringSource(to other: Self) -> Bool {
        rawDocumentLength == other.rawDocumentLength
            && coordinateDocumentLength == other.coordinateDocumentLength
            && omittedStructuralSeparatorCount == other.omittedStructuralSeparatorCount
            && rawBoundaryCandidates == other.rawBoundaryCandidates
            && rawPlaceholderRange == other.rawPlaceholderRange
            && alignment == other.alignment
    }

    var isPendingReceiptFallback: Bool {
        source == .pendingReceiptExactAXValue
            || source == .pendingReceiptStructuralAugmentation
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
                    rawPlaceholderRange: placeholderRange,
                    alignment: nil
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
              selection.length <= coordinate.length - selection.location,
              isUTF16ScalarBoundary(selection.location, in: coordinate.text),
              isUTF16ScalarBoundary(selection.location + selection.length, in: coordinate.text),
              !AXTextStructural.isCRLFInteriorBoundary(selection.location, in: coordinate.text),
              !AXTextStructural.isCRLFInteriorBoundary(
                  selection.location + selection.length,
                  in: coordinate.text
              ) else {
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
                rawBoundaryCandidates: boundaryMapping.rawBoundaryCandidates,
                rawPlaceholderRange: nil,
                alignment: boundaryMapping.alignment
            )
        )
    }

    static func isValidCoordinateMapping(
        _ mapping: AXTextCoordinateMapping,
        rawText: String,
        coordinateText: String
    ) -> Bool {
        guard mapping.source != .placeholder,
              mapping.rawPlaceholderRange == nil,
              mapping.rawDocumentLength == rawText.utf16.count,
              mapping.coordinateDocumentLength == coordinateText.utf16.count else {
            return false
        }

        // Resolved observations carry the complete alignment graph. Its
        // internal shape is sufficient for repeated acknowledgement reads;
        // rebuilding the graph for every polling sample made a large editor
        // document compete with the existing acknowledgement deadline.
        if let alignment = mapping.alignment {
            guard alignment.rawScalarValues == rawText.unicodeScalars.map({ $0.value }),
                  alignment.coordinateScalarValues == coordinateText.unicodeScalars.map({ $0.value }) else {
                return false
            }
            return alignment.rawBoundaryCandidates.count == coordinateText.utf16.count + 1
                && alignment.rawBoundaryCandidates == mapping.rawBoundaryCandidates
                && mapping.omittedStructuralSeparatorCount
                    == alignment.rawScalarCount - alignment.coordinateScalarCount
                && !(mapping.rawBoundaryCandidates.first ?? []).isEmpty
                && !(mapping.rawBoundaryCandidates.last ?? []).isEmpty
        }

        guard let expected = rawBoundaryMapping(
            rawText: rawText,
            coordinateText: coordinateText
        ) else {
            return false
        }
        return mapping.omittedStructuralSeparatorCount == expected.omittedSeparatorCount
            && mapping.rawBoundaryCandidates == expected.rawBoundaryCandidates
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
              !AXTextStructural.containsStructuralSeparator(in: rawText) else {
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
                rawBoundaryCandidates: boundaryMapping.rawBoundaryCandidates,
                rawPlaceholderRange: nil,
                alignment: boundaryMapping.alignment
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
        while start < end,
              AXTextStructural.isStructuralSeparator(at: start, in: rawScalars) {
            start += 1
        }
        while end > start,
              AXTextStructural.isStructuralSeparator(at: end - 1, in: rawScalars) {
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
        while start < end,
              AXTextStructural.isStructuralSeparator(at: start, in: scalars) {
            start += 1
        }
        while end > start,
              AXTextStructural.isStructuralSeparator(at: end - 1, in: scalars) {
            end -= 1
        }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    private static func isUTF16ScalarBoundary(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf16.count else { return false }
        guard offset > 0, offset < text.utf16.count else { return true }
        let units = Array(text.utf16)
        let previous = units[offset - 1]
        let current = units[offset]
        let isHighSurrogate = (0xD800...0xDBFF).contains(previous)
        let isLowSurrogate = (0xDC00...0xDFFF).contains(current)
        return !(isHighSurrogate && isLowSurrogate)
    }

    private static func readCoordinateText(
        rawText: String,
        probe: AXTextCoordinateProbe
    ) throws -> (length: Int, text: String)? {
        guard let empty = try probe.read(.init(location: 0, length: 0)), empty.isEmpty else {
            return nil
        }

        let rawLength = rawText.utf16.count
        let rawScalars = Array(rawText.unicodeScalars)
        var separatorLength = 0
        var rawOffset = 0
        for (index, scalar) in rawScalars.enumerated() {
            if AXTextStructural.isStructuralSeparator(at: index, in: rawScalars),
               let structuralRange = AXTextStructural.structuralUnitRange(
                   startingAt: rawOffset,
                   in: rawText
               ) {
                // A CRLF is one structural unit but occupies two UTF-16
                // positions in the raw AXValue. The read probe is addressed
                // in UTF-16, so its candidate lengths must remove both code
                // units even though the alignment graph has one logical
                // separator edge.
                separatorLength += structuralRange.length
            }
            rawOffset += scalar.utf16.count
        }

        // A failed probe can be caused by an invalid UTF-16 split inside an
        // emoji, so a binary search over every integer is not safe. The only
        // valid length reduction we accept is the number of line-separator
        // units present in AXValue; try those candidates from longest to
        // shortest and require both the requested size and a complete
        // raw/coordinate alignment. The latter rejects a transient prefix
        // that ends inside a still-updating CRLF or before the body suffix.
        var firstSizedText: (length: Int, text: String)?
        for omittedLength in 0...separatorLength {
            let candidate = rawLength - omittedLength
            guard let text = try probe.read(.init(location: 0, length: candidate)),
                  text.utf16.count == candidate else {
                continue
            }
            firstSizedText = firstSizedText ?? (candidate, text)
            if rawBoundaryMapping(rawText: rawText, coordinateText: text) != nil {
                return (candidate, text)
            }
        }
        return firstSizedText
    }

    private static func rawBoundaryMapping(
        rawText: String,
        coordinateText: String
    ) -> (
        omittedSeparatorCount: Int,
        rawBoundaryCandidates: [[Int]],
        alignment: AXTextCoordinateAlignment
    )? {
        guard let alignment = AXTextCoordinateAlignment.build(
            rawText: rawText,
            coordinateText: coordinateText
        ) else {
            return nil
        }
        guard alignment.rawBoundaryCandidates.count == coordinateText.utf16.count + 1,
              !(alignment.rawBoundaryCandidates.first ?? []).isEmpty,
              !(alignment.rawBoundaryCandidates.last ?? []).isEmpty else {
            return nil
        }
        return (
            omittedSeparatorCount: max(
                0,
                rawText.unicodeScalars.count - coordinateText.unicodeScalars.count
            ),
            rawBoundaryCandidates: alignment.rawBoundaryCandidates,
            alignment: alignment
        )
    }
}
