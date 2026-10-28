import ApplicationServices
import AppKit
import Foundation

func boundedContinuityDiagnosticFields(_ fields: [String: String], byteLimit: Int = 8_192) -> [String: String] {
    var result: [String: String] = [:]
    var truncated = false

    func encodedSize(_ fields: [String: String]) -> Int {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            return Int.max
        }
        return data.count
    }

    for key in fields.keys.sorted() {
        guard key != "diagnosticSummaryTruncated" else { continue }
        guard let value = fields[key] else { continue }
        var candidate = result
        candidate[key] = value
        guard encodedSize(candidate) <= byteLimit else {
            truncated = true
            continue
        }
        result = candidate
    }
    if truncated {
        let marker = "diagnosticSummaryTruncated"
        var candidate = result
        candidate[marker] = "true"
        while encodedSize(candidate) > byteLimit, let key = result.keys.sorted().last {
            result.removeValue(forKey: key)
            candidate = result
            candidate[marker] = "true"
        }
        if encodedSize(candidate) <= byteLimit { result = candidate }
    }
    return result
}

struct AXAttributeReadFailure: Error {
    let attribute: String
    let status: Int32
}

private enum KeyboardDocumentStateReadError: Error {
    case retryable
    case unavailable
}

private enum KeyboardReceiptRepresentation {
    static let trailingNewlineCollapsed = "trailing_newline_collapsed"
    static let emptyParagraphMarkerCollapsed = "empty_paragraph_marker_collapsed"
}

private struct PendingKeyboardReplacement {
    let selected: KeyboardDocumentState
    let insertion: String
    let originalSelection: TextRange
    let sessionGeneration: UInt64
    let operationGeneration: UInt64
}

private struct KeyboardRawInsertionRegion: Equatable {
    let sessionGeneration: UInt64
    let operationGeneration: UInt64
    let coordinateRange: TextRange
    let rawRange: TextRange
    let separatorLength: Int
}

private struct KeyboardRawInsertionUpdate {
    let rawRange: TextRange
    let nextRegion: KeyboardRawInsertionRegion?
}

private struct KeyboardRepresentationCandidate {
    let state: KeyboardDocumentState
    let rawOperationRange: TextRange?
    let rawInsertionRegion: KeyboardRawInsertionRegion?
}

private func sameKeyboardRepresentationCandidate(
    _ lhs: KeyboardRepresentationCandidate,
    _ rhs: KeyboardRepresentationCandidate
) -> Bool {
    // The visible strings and caret are not a sufficient identity. Two
    // candidates can expose the same text while retaining different raw
    // alignments, and an anchored replacement region can lead the next edit
    // to a different raw boundary. Keep both hypotheses until the receipt
    // checker proves one of them.
    lhs.state == rhs.state
        && lhs.rawOperationRange == rhs.rawOperationRange
        && lhs.rawInsertionRegion == rhs.rawInsertionRegion
}

private struct PendingKeyboardRepresentationTransition {
    let alternates: [KeyboardRepresentationCandidate]
    let representation: String
    let insertionPositionClass: String
    let sessionGeneration: UInt64
    let operationGeneration: UInt64
}

private struct KeyboardDiagnosticDiffRecord {
    let candidateIndex: Int
    let candidateMatched: Bool
    let comparison: KeyboardDocumentComparison
    let sampleIndex: Int
    let elapsedMilliseconds: UInt64
    let phase: String
    let operationGeneration: UInt64?
    let summary: KeyboardDiagnosticDiffSummary

    func fields(prefix: String) -> [String: String] {
        var fields = summary.fields(prefix: prefix)
        fields["\(prefix)CandidateIndex"] = String(candidateIndex)
        fields["\(prefix)CandidateMatched"] = String(candidateMatched)
        fields["\(prefix)Comparison"] = comparison.rawValue
        fields["\(prefix)SampleIndex"] = String(sampleIndex)
        fields["\(prefix)ElapsedMilliseconds"] = String(elapsedMilliseconds)
        fields["\(prefix)Phase"] = phase
        if let operationGeneration {
            fields["\(prefix)OperationGeneration"] = String(operationGeneration)
        }
        return fields
    }
}

private struct KeyboardDiagnosticComparisonSnapshot {
    let observed: KeyboardDocumentState
    let expectedCandidates: [KeyboardDocumentState]
    let candidateMatches: [Bool]
    let candidateComparisons: [KeyboardDocumentComparison]
    let sampleIndex: Int
    let elapsedMilliseconds: UInt64
}

private struct KeyboardStateEvidence {
    let coordinateLengthUTF16: Int
    let axValueLengthUTF16: Int
    let selectionLocation: Int
    let selectionLength: Int
    let coordinateTrailingNewlineCount: Int
    let axValueTrailingNewlineCount: Int
    let mappingValid: Bool
}

private struct AXWriteStateEvidence {
    let axValueLengthUTF16: Int
    let selectionLocation: Int
    let selectionLength: Int
    let targetIdentityMatches: Bool
}

private struct AXWritePhaseTrace {
    private(set) var readAttempts = 0
    private(set) var firstReadable: AXWriteStateEvidence?
    private(set) var firstChanged: AXWriteStateEvidence?
    private(set) var firstChangedCandidateMatches = false
    private(set) var lastCandidateMatches = false
    private(set) var firstReadErrorCode: String?
    private(set) var firstReadErrorElapsedMilliseconds: UInt64?

    mutating func recordRead(_ evidence: AXWriteStateEvidence, matches: Bool) {
        readAttempts += 1
        if firstReadable == nil { firstReadable = evidence }
        lastCandidateMatches = matches
        if firstChanged == nil, !matches {
            firstChanged = evidence
            firstChangedCandidateMatches = false
        }
    }

    mutating func recordReadError(_ code: String, elapsedMilliseconds: UInt64) {
        readAttempts += 1
        guard firstReadErrorCode == nil else { return }
        firstReadErrorCode = code
        firstReadErrorElapsedMilliseconds = elapsedMilliseconds
    }

}

private struct AXWriteAcknowledgementTrace {
    private var preflight = AXWritePhaseTrace()
    private var postDispatch = AXWritePhaseTrace()
    private var isPostDispatch = false

    mutating func beginPostDispatch() {
        isPostDispatch = true
        postDispatch = AXWritePhaseTrace()
    }

    mutating func recordRead(_ evidence: AXWriteStateEvidence, matches: Bool) {
        if isPostDispatch {
            postDispatch.recordRead(evidence, matches: matches)
        } else {
            preflight.recordRead(evidence, matches: matches)
        }
    }

    mutating func recordReadError(_ code: String, elapsedMilliseconds: UInt64) {
        if isPostDispatch {
            postDispatch.recordReadError(code, elapsedMilliseconds: elapsedMilliseconds)
        } else {
            preflight.recordReadError(code, elapsedMilliseconds: elapsedMilliseconds)
        }
    }

    func fields(final: AXWriteStateEvidence?, finalMatches: Bool, elapsedMilliseconds: UInt64) -> [String: String] {
        let phase = postDispatch
        var result: [String: String] = [
            "axReadAttempts": String(phase.readAttempts),
            "axPreflightReadAttempts": String(preflight.readAttempts),
            "axElapsedMilliseconds": String(elapsedMilliseconds),
            "axFinalCandidateMatches": String(finalMatches),
            "axFirstChangedCandidateMatches": String(phase.firstChangedCandidateMatches)
        ]
        if let firstReadable = phase.firstReadable {
            result.merge(firstReadable.fields(prefix: "axFirstReadable")) { _, new in new }
        }
        if let firstChanged = phase.firstChanged {
            result.merge(firstChanged.fields(prefix: "axFirstChanged")) { _, new in new }
        }
        if let firstReadErrorCode = phase.firstReadErrorCode {
            result["axFirstReadErrorCode"] = firstReadErrorCode
            result["axFirstReadErrorElapsedMilliseconds"] = String(phase.firstReadErrorElapsedMilliseconds ?? 0)
        }
        if let firstReadable = preflight.firstReadable {
            result.merge(firstReadable.fields(prefix: "axPreflightFirstReadable")) { _, new in new }
        }
        if let firstChanged = preflight.firstChanged {
            result.merge(firstChanged.fields(prefix: "axPreflightFirstChanged")) { _, new in new }
        }
        if let firstReadErrorCode = preflight.firstReadErrorCode {
            result["axPreflightFirstReadErrorCode"] = firstReadErrorCode
            result["axPreflightFirstReadErrorElapsedMilliseconds"] = String(preflight.firstReadErrorElapsedMilliseconds ?? 0)
        }
        if let final {
            result.merge(final.fields(prefix: "axFinal")) { _, new in new }
        }
        return result
    }
}

private extension AXWriteStateEvidence {
    func fields(prefix: String) -> [String: String] {
        [
            "\(prefix)AXValueLengthUTF16": String(axValueLengthUTF16),
            "\(prefix)SelectionLocation": String(selectionLocation),
            "\(prefix)SelectionLength": String(selectionLength),
            "\(prefix)TargetIdentityMatches": String(targetIdentityMatches)
        ]
    }
}

private struct AXWritableState {
    let text: String
    let selection: TextRange
}

private struct KeyboardAcknowledgementTrace {
    let insertionPositionClass: String
    private(set) var readAttempts = 0
    private(set) var firstReadable: KeyboardStateEvidence?
    private(set) var firstChanged: KeyboardStateEvidence?
    private(set) var firstChangedComparison: KeyboardDocumentComparison?
    private(set) var firstChangedCandidateMatches: [Bool]?
    private(set) var lastCandidateMatches: [Bool] = []
    private(set) var firstReadErrorCode: String?
    private(set) var firstReadErrorElapsedMilliseconds: UInt64?
    private(set) var earlyDiffRecords: [KeyboardDiagnosticDiffRecord] = []
    private(set) var finalDiffRecords: [KeyboardDiagnosticDiffRecord] = []
    private(set) var earlyDiffCandidateOmittedCount = 0
    private(set) var finalDiffCandidateOmittedCount = 0
    private var comparisonSequence = 0
    private var lastComparisonSnapshot: KeyboardDiagnosticComparisonSnapshot?
    private var phase = "pre_dispatch"

    init(
        insertionPositionClass: String = "not_applicable",
        phase: String = "post_dispatch"
    ) {
        self.insertionPositionClass = insertionPositionClass
        self.phase = phase
    }

    mutating func recordRead(_ evidence: KeyboardStateEvidence) {
        readAttempts += 1
        if firstReadable == nil { firstReadable = evidence }
    }

    mutating func recordReadError(_ code: String, elapsedMilliseconds: UInt64) {
        readAttempts += 1
        guard firstReadErrorCode == nil else { return }
        firstReadErrorCode = code
        firstReadErrorElapsedMilliseconds = elapsedMilliseconds
    }

    mutating func beginPostDispatch() {
        phase = "post_dispatch"
        comparisonSequence = 0
        lastCandidateMatches.removeAll(keepingCapacity: true)
        earlyDiffRecords.removeAll(keepingCapacity: true)
        finalDiffRecords.removeAll(keepingCapacity: true)
        earlyDiffCandidateOmittedCount = 0
        finalDiffCandidateOmittedCount = 0
        lastComparisonSnapshot = nil
    }

    mutating func recordComparison(
        evidence: KeyboardStateEvidence,
        comparison: KeyboardDocumentComparison,
        candidateMatches: [Bool],
        observed: KeyboardDocumentState,
        expectedCandidates: [KeyboardDocumentState],
        candidateComparisons: [KeyboardDocumentComparison],
        operation: KeyboardDiagnosticDiffOperation?,
        mappingValid: Bool,
        elapsedMilliseconds: UInt64
    ) {
        lastCandidateMatches = candidateMatches
        comparisonSequence += 1
        let snapshot = KeyboardDiagnosticComparisonSnapshot(
            observed: observed,
            expectedCandidates: expectedCandidates,
            candidateMatches: candidateMatches,
            candidateComparisons: candidateComparisons,
            sampleIndex: comparisonSequence,
            elapsedMilliseconds: elapsedMilliseconds
        )
        lastComparisonSnapshot = snapshot
        if earlyDiffRecords.isEmpty {
            let earlyIndexes = expectedCandidates.indices.filter { index in
                guard index < candidateMatches.count,
                      index < candidateComparisons.count,
                      !candidateMatches[index],
                      observed.text == expectedCandidates[index].text,
                      observed.selection == expectedCandidates[index].selection,
                      candidateComparisons[index] == .rawTextMismatch
                        || candidateComparisons[index] == .rawMappingUnavailable else {
                    return false
                }
                return true
            }
            if !earlyIndexes.isEmpty {
                earlyDiffCandidateOmittedCount = max(0, earlyIndexes.count - 8)
                earlyDiffRecords = makeDiffRecords(
                    indexes: earlyIndexes,
                    snapshot: snapshot,
                    operation: operation,
                    mappingValid: mappingValid
                )
            }
        }
        guard firstChanged == nil, !candidateMatches.contains(true) else { return }
        firstChanged = evidence
        firstChangedComparison = comparison
        firstChangedCandidateMatches = candidateMatches
    }

    mutating func finalizeDiff(
        operation: KeyboardDiagnosticDiffOperation?,
        mappingValid: Bool
    ) {
        guard let snapshot = lastComparisonSnapshot else { return }
        // Keep the terminal observation for every candidate, including an
        // accepted primary candidate. This makes a successful write explicit
        // (`equal`) while preserving the same per-candidate evidence on
        // failures and representation transitions.
        let indexes = Array(snapshot.expectedCandidates.indices)
        finalDiffRecords = makeDiffRecords(
            indexes: indexes,
            snapshot: snapshot,
            operation: operation,
            mappingValid: mappingValid
        )
        finalDiffCandidateOmittedCount = max(0, indexes.count - 8)
    }

    private func makeDiffRecords(
        indexes: [Int],
        snapshot: KeyboardDiagnosticComparisonSnapshot,
        operation: KeyboardDiagnosticDiffOperation?,
        mappingValid: Bool
    ) -> [KeyboardDiagnosticDiffRecord] {
        let limitedIndexes = Array(indexes.prefix(8))
        let observedMappingValid = mappingValid
        return limitedIndexes.map { index in
            let expected = snapshot.expectedCandidates[index]
            let comparison = index < snapshot.candidateComparisons.count
                ? snapshot.candidateComparisons[index]
                : .documentMismatch
            let summary = KeyboardDiagnosticDiffCalculator.compare(
                expected: expected,
                observed: snapshot.observed,
                operation: operation,
                mappingValid: observedMappingValid
            )
            return KeyboardDiagnosticDiffRecord(
                candidateIndex: index,
                candidateMatched: index < snapshot.candidateMatches.count
                    ? snapshot.candidateMatches[index]
                    : false,
                comparison: comparison,
                sampleIndex: snapshot.sampleIndex,
                elapsedMilliseconds: snapshot.elapsedMilliseconds,
                phase: phase,
                operationGeneration: operation?.operationGeneration,
                summary: summary
            )
        }
    }

    func fields(
        final: KeyboardStateEvidence?,
        finalComparison: KeyboardDocumentComparison?,
        candidateCount: Int,
        insertionPositionClass overrideInsertionPositionClass: String? = nil
    ) -> [String: String] {
        var result: [String: String] = [
            "ackCandidateCount": String(candidateCount),
            "ackInsertionPositionClass": overrideInsertionPositionClass ?? insertionPositionClass,
            "ackFinalCandidateMatches": lastCandidateMatches.map { $0 ? "true" : "false" }.joined(separator: ","),
            "ackReadAttempts": String(readAttempts)
        ]
        if let firstReadable {
            result.merge(firstReadable.fields(prefix: "ackFirstReadable")) { _, new in new }
        }
        if let firstChanged {
            result.merge(firstChanged.fields(prefix: "ackFirstChanged")) { _, new in new }
            result["ackFirstChangedComparison"] = firstChangedComparison?.rawValue ?? "unknown"
            result["ackFirstChangedCandidateMatches"] = (firstChangedCandidateMatches ?? [])
                .map { $0 ? "true" : "false" }.joined(separator: ",")
        }
        if let firstReadErrorCode {
            result["ackFirstReadErrorCode"] = firstReadErrorCode
            result["ackFirstReadErrorElapsedMilliseconds"] = String(firstReadErrorElapsedMilliseconds ?? 0)
        }
        if let final {
            result.merge(final.fields(prefix: "ackFinal")) { _, new in new }
        }
        if let finalComparison {
            result["ackFinalComparison"] = finalComparison.rawValue
        }
        let maxBytesPerSample = 8_192
        func mergeDiffRecords(
            _ records: [KeyboardDiagnosticDiffRecord],
            prefix: String,
            candidateOmittedCount: Int
        ) -> Int {
            guard !records.isEmpty else {
                if candidateOmittedCount > 0 {
                    result["\(prefix)CandidateOmittedCount"] = String(candidateOmittedCount)
                }
                return candidateOmittedCount
            }
            var bytes = 0
            var included = 0
            var sizeOmittedCount = 0
            for (index, record) in records.enumerated() {
                let fields = record.fields(prefix: "\(prefix)\(index)")
                let recordBytes = fields.reduce(0) { total, field in
                    total + field.key.utf8.count + field.value.utf8.count + 2
                }
                guard bytes + recordBytes <= maxBytesPerSample else {
                    sizeOmittedCount = records.count - index
                    break
                }
                bytes += recordBytes
                included += 1
                result.merge(fields) { _, new in new }
            }
            result["\(prefix)CandidateCount"] = String(included)
            let omitted = candidateOmittedCount + sizeOmittedCount
            if omitted > 0 {
                result["\(prefix)CandidateOmittedCount"] = String(omitted)
            }
            return omitted
        }
        let earlyOmitted = mergeDiffRecords(
            earlyDiffRecords,
            prefix: "ackDiffEarly",
            candidateOmittedCount: earlyDiffCandidateOmittedCount
        )
        let finalOmitted = mergeDiffRecords(
            finalDiffRecords,
            prefix: "ackDiffFinal",
            candidateOmittedCount: finalDiffCandidateOmittedCount
        )
        let omitted = earlyOmitted + finalOmitted
        if omitted > 0 {
            result["ackDiffCandidateOmittedCount"] = String(omitted)
        }
        return result
    }
}

private extension KeyboardStateEvidence {
    func fields(prefix: String) -> [String: String] {
        [
            "\(prefix)CoordinateLengthUTF16": String(coordinateLengthUTF16),
            "\(prefix)AXValueLengthUTF16": String(axValueLengthUTF16),
            "\(prefix)SelectionLocation": String(selectionLocation),
            "\(prefix)SelectionLength": String(selectionLength),
            "\(prefix)CoordinateTrailingNewlineCount": String(coordinateTrailingNewlineCount),
            "\(prefix)AXValueTrailingNewlineCount": String(axValueTrailingNewlineCount),
            "\(prefix)MappingValid": String(mappingValid)
        ]
    }
}

@MainActor
protocol AXTextTargetAccess {
    func requestInputPermissions() throws
    func currentApplication() -> TextTargetApplication?
    func focusedElement() throws -> AXUIElement
    func processIdentifier(of element: AXUIElement) -> pid_t?
    func elementValidity(_ element: AXUIElement) -> AXTextElementValidity
    func editorContinuityEvidence(for element: AXUIElement) -> AXTextEditorContinuityEvidence?
    func lastContinuityScanObservationID() -> String?
    func lastContinuityScanSummary() -> [String: String]?
    func setContinuityScanObjectGeneration(_ generation: String?)
    func setContinuityScanBudgetNanoseconds(_ budget: UInt64?)
    func editorContinuityEvidence(
        for element: AXUIElement,
        anchoredAt previous: AXTextEditorContinuityEvidence
    ) -> AXTextEditorContinuityEvidence?
    func textInputContext(for element: AXUIElement) -> AXTextInputTargetContext?
    func text(in element: AXUIElement) throws -> String?
    func selection(in element: AXUIElement) throws -> TextRange?
    func coordinateText(for range: TextRange, in element: AXUIElement) throws -> String?
    func placeholderEvidence(in element: AXUIElement) -> AXPlaceholderEvidence
    func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool
    func isProseMirrorEditor(_ element: AXUIElement) -> Bool
    func setSelection(_ range: TextRange, on element: AXUIElement) throws -> Int32
    func setSelectedText(_ text: String, on element: AXUIElement) throws -> Int32
    func setValue(_ text: String, on element: AXUIElement) throws -> Int32
    func drainReadDiagnostics() -> [TextInputDiagnostic]
    func setContinuityDiagnosticsEnabled(_ enabled: Bool)
}

extension AXTextTargetAccess {
    func textInputContext(for element: AXUIElement) -> AXTextInputTargetContext? { nil }
    func isProseMirrorEditor(_ element: AXUIElement) -> Bool { false }
    func elementValidity(_ element: AXUIElement) -> AXTextElementValidity { .unavailable }
    func editorContinuityEvidence(for element: AXUIElement) -> AXTextEditorContinuityEvidence? { nil }
    func lastContinuityScanObservationID() -> String? { nil }
    func lastContinuityScanSummary() -> [String: String]? { nil }
    func setContinuityScanObjectGeneration(_ generation: String?) {}
    func setContinuityScanBudgetNanoseconds(_ budget: UInt64?) {}
    func editorContinuityEvidence(
        for element: AXUIElement,
        anchoredAt previous: AXTextEditorContinuityEvidence
    ) -> AXTextEditorContinuityEvidence? { nil }
    func drainReadDiagnostics() -> [TextInputDiagnostic] { [] }
    func setContinuityDiagnosticsEnabled(_ enabled: Bool) {}
}

enum AXTextElementValidity: Equatable {
    case valid
    case invalid
    case unavailable
}

struct AXTextEditorContinuityEvidence {
    let webArea: AXUIElement
    let window: AXUIElement?
    let editorAnchor: AXUIElement
    let editorAnchorRole: String
    let rolesFromEditorToAnchor: [String]
    let identifiersFromEditorToAnchor: [String?]
    let editableEditorCount: Int
    let scanComplete: Bool
}

enum AXEditorIdentityValidationResult {
    case confirmed(
        evidence: AXTextEditorContinuityEvidence,
        route: String,
        processID: pid_t,
        identityOutcome: String,
        diagnosticFields: [String: String]
    )
    case temporarilyUnavailable(reason: String, diagnosticFields: [String: String]? = nil)
    case rejected(reason: String, diagnosticFields: [String: String]? = nil)
}

struct AXTextEditorContinuityComparison {
    let matches: Bool
    let structurallyMatches: Bool
    let hasMissingIdentifiers: Bool
    let hasIdentifierConflict: Bool
    let identityOutcome: String
    let firstMismatch: String?
    let fields: [String: String]

    var canConfirmFromCapturedAnchor: Bool {
        structurallyMatches && hasMissingIdentifiers && !hasIdentifierConflict
    }
}

struct AXKeyboardDocumentObservation {
    let state: KeyboardDocumentState
    let objectGeneration: String
    let requestedAt: Date
    let readStartedAt: Date
    let readFinishedAt: Date
    let monotonicReadStartedMilliseconds: UInt64

    var coordinateMapping: AXTextCoordinateMapping? { state.mapping }
}

struct AXAnchoredEditorScanResult {
    let editableEditorCount: Int
    let targetFound: Bool
    let rolesFromEditorToAnchor: [String]?
    let identifiersFromEditorToAnchor: [String?]?
    let visitedNodeCount: Int

    init(
        editableEditorCount: Int,
        targetFound: Bool,
        rolesFromEditorToAnchor: [String]?,
        identifiersFromEditorToAnchor: [String?]?,
        visitedNodeCount: Int = 0
    ) {
        self.editableEditorCount = editableEditorCount
        self.targetFound = targetFound
        self.rolesFromEditorToAnchor = rolesFromEditorToAnchor
        self.identifiersFromEditorToAnchor = identifiersFromEditorToAnchor
        self.visitedNodeCount = visitedNodeCount
    }
}

struct AXAnchoredEditorScanFailure: Error {
    let attribute: String
    let status: Int32
    let reason: String
}

@MainActor
enum AXAnchoredEditorScanner {
    static func isDescendant<Node>(
        _ element: Node,
        of ancestor: Node,
        equals: (Node, Node) -> Bool,
        parent: (Node) throws -> Node?,
        nodeLimit: Int = 64
    ) throws -> Bool {
        var current = element
        var visited: [Node] = []
        for _ in 0..<nodeLimit {
            if equals(current, ancestor) { return true }
            guard !visited.contains(where: { equals($0, current) }) else {
                throw AXAnchoredEditorScanFailure(attribute: "AXParent", status: 0, reason: "parent_cycle")
            }
            visited.append(current)
            guard let next = try parent(current) else { return false }
            current = next
        }
        throw AXAnchoredEditorScanFailure(attribute: "AXParent", status: 0, reason: "parent_depth_limit")
    }

    static func scan<Node>(
        anchor: Node,
        target: Node,
        anchorRole: String,
        equals: (Node, Node) -> Bool,
        role: (Node) throws -> String,
        identifier: (Node) throws -> String?,
        subrole: (Node) throws -> String?,
        readOnly: (Node) throws -> Bool?,
        children: (Node) throws -> [Node],
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        timeLimitNanoseconds: UInt64 = 250_000_000,
        nodeLimit: Int = 160
    ) throws -> AXAnchoredEditorScanResult {
        let deadline = now() &+ timeLimitNanoseconds
        guard try role(anchor) == anchorRole else {
            return .init(editableEditorCount: 0, targetFound: false,
                rolesFromEditorToAnchor: nil, identifiersFromEditorToAnchor: nil,
                visitedNodeCount: 1)
        }
        var pending: [(node: Node, roles: [String], identifiers: [String?])] = []
        for child in try children(anchor) {
            pending.append((child, [], []))
        }
        var visited: [Node] = [anchor]
        var editableCount = 0
        var targetPath: ([String], [String?])?
        while !pending.isEmpty {
            guard now() < deadline else {
                throw AXAnchoredEditorScanFailure(attribute: "deadline", status: 0, reason: "deadline_exceeded")
            }
            guard visited.count < nodeLimit else {
                throw AXAnchoredEditorScanFailure(attribute: "AXChildren", status: 0, reason: "node_limit_reached")
            }
            let item = pending.removeLast()
            guard !visited.contains(where: { equals($0, item.node) }) else { continue }
            visited.append(item.node)
            let nodeRole = try role(item.node)
            let nodeIdentifier = try identifier(item.node)
            let pathRoles = item.roles + [nodeRole]
            let pathIdentifiers = item.identifiers + [nodeIdentifier]
            if ["AXTextArea", "AXTextField", "AXSearchField"].contains(nodeRole) {
                guard try subrole(item.node) != "AXSecureTextField",
                      let isReadOnly = try readOnly(item.node) else {
                    throw AXAnchoredEditorScanFailure(
                        attribute: "AXReadOnly", status: 0, reason: "editor_writability_unavailable"
                    )
                }
                if !isReadOnly {
                    editableCount += 1
                    if equals(item.node, target) {
                        targetPath = (pathRoles, pathIdentifiers)
                    }
                }
            }
            for child in try children(item.node) {
                pending.append((child, pathRoles, pathIdentifiers))
            }
        }
        guard let targetPath else {
            return .init(editableEditorCount: editableCount, targetFound: false,
                rolesFromEditorToAnchor: nil, identifiersFromEditorToAnchor: nil,
                visitedNodeCount: visited.count)
        }
        return .init(
            editableEditorCount: editableCount,
            targetFound: true,
            rolesFromEditorToAnchor: Array(targetPath.0.reversed()),
            identifiersFromEditorToAnchor: Array(targetPath.1.reversed()),
            visitedNodeCount: visited.count
        )
    }
}

enum AXTextEditorContinuityScanDiagnostic {
    static let event = "editor_continuity_scan_diagnostic"

    static func fields(
        stage: String,
        reason: String,
        attribute: String? = nil,
        status: Int32? = nil,
        depth: Int? = nil,
        visitedNodes: Int? = nil,
        candidateIndex: Int? = nil,
        candidateCount: Int? = nil,
        candidateEditableCounts: [Int]? = nil,
        editableEditorCount: Int? = nil,
        elapsedMilliseconds: UInt64? = nil
    ) -> [String: String] {
        var fields = ["scanStage": stage, "reason": reason]
        if let attribute { fields["axAttribute"] = attribute }
        if let status { fields["axStatus"] = String(status) }
        if let depth { fields["depth"] = String(depth) }
        if let visitedNodes { fields["visitedNodes"] = String(visitedNodes) }
        if let candidateIndex { fields["candidateIndex"] = String(candidateIndex) }
        if let candidateCount { fields["candidateCount"] = String(candidateCount) }
        if let candidateEditableCounts {
            fields["candidateEditableCounts"] = candidateEditableCounts.map { String($0) }.joined(separator: ",")
        }
        if let editableEditorCount { fields["editableEditorCount"] = String(editableEditorCount) }
        if let elapsedMilliseconds { fields["elapsedMilliseconds"] = String(elapsedMilliseconds) }
        return fields
    }
}

enum AXTextEditorContinuity {
    static func captureOutcome(
        continuityApplicable: Bool,
        continuityTargetApplication: Bool,
        focusedElementAvailable: Bool,
        evidenceSaved: Bool,
        scanSummary: [String: String]?
    ) -> String {
        if !focusedElementAvailable && continuityTargetApplication { return "focused_element_missing" }
        guard continuityApplicable else { return "not_applicable" }
        if evidenceSaved { return "saved" }
        if scanSummary?["stopReason"] == "no_unique_editable_editor" { return "candidate_not_unique" }
        if ["deadline_exceeded", "node_limit_reached", "web_area_not_found_before_depth_limit"]
            .contains(scanSummary?["stopReason"] ?? "") {
            return "scan_incomplete"
        }
        if let scanSummary {
            return scanSummary["failureAttribute"] != nil || scanSummary["stopReason"] != nil
                ? "scan_failed" : "scan_incomplete"
        }
        return "scan_unavailable"
    }

    static func compare(
        _ previous: AXTextEditorContinuityEvidence,
        _ current: AXTextEditorContinuityEvidence
    ) -> AXTextEditorContinuityComparison {
        var fields: [String: String] = [:]
        func state(_ equal: Bool) -> String { equal ? "equal" : "different" }

        let previousLeafIdentifier = previous.identifiersFromEditorToAnchor.first ?? nil
        let currentLeafIdentifier = current.identifiersFromEditorToAnchor.first ?? nil
        fields["leafIdentifierPresence"] = previousLeafIdentifier != nil && currentLeafIdentifier != nil
            ? "present" : "missing"
        fields["leafIdentifierComparison"] = if let previousLeafIdentifier, let currentLeafIdentifier {
            state(previousLeafIdentifier == currentLeafIdentifier)
        } else { "unavailable" }
        fields["scanCompleteness"] = state(previous.scanComplete && current.scanComplete)
        fields["editableEditorCount"] = previous.editableEditorCount == 1 && current.editableEditorCount == 1
            ? "equal" : "different"
        fields["anchorRoleComparison"] = state(previous.editorAnchorRole == current.editorAnchorRole)
        fields["anchorRoleAllowed"] = ["AXGroup", "AXContainer"].contains(current.editorAnchorRole)
            ? "yes" : "no"
        fields["webAreaComparison"] = state(CFEqual(previous.webArea, current.webArea))
        fields["windowPresence"] = previous.window != nil && current.window != nil ? "present" : "missing"
        fields["windowComparison"] = if let oldWindow = previous.window, let newWindow = current.window {
            state(CFEqual(oldWindow, newWindow))
        } else { "unavailable" }
        fields["containerComparison"] = state(CFEqual(previous.editorAnchor, current.editorAnchor))
        fields["rolePathComparison"] = state(previous.rolesFromEditorToAnchor == current.rolesFromEditorToAnchor)
        fields["identifierPathDepth"] = previous.identifiersFromEditorToAnchor.count == current.identifiersFromEditorToAnchor.count
            ? "equal" : "different"
        fields["rolePathDepthPrevious"] = String(previous.rolesFromEditorToAnchor.count)
        fields["rolePathDepthCurrent"] = String(current.rolesFromEditorToAnchor.count)
        fields["identifierPathDepthPrevious"] = String(previous.identifiersFromEditorToAnchor.count)
        fields["identifierPathDepthCurrent"] = String(current.identifiersFromEditorToAnchor.count)
        var identifierComparisons: [String] = []
        for index in previous.identifiersFromEditorToAnchor.indices {
            let oldIdentifier = previous.identifiersFromEditorToAnchor[index]
            guard current.identifiersFromEditorToAnchor.indices.contains(index) else { break }
            let newIdentifier = current.identifiersFromEditorToAnchor[index]
            identifierComparisons.append(oldIdentifier == nil || newIdentifier == nil
                ? "\(index):unavailable"
                : "\(index):\(oldIdentifier == newIdentifier ? "equal" : "different")")
        }
        fields["identifierPathComparisons"] = identifierComparisons.joined(separator: ",")

        let pathDepthMatches = previous.identifiersFromEditorToAnchor.count
            == current.identifiersFromEditorToAnchor.count
        var missingIdentifierIndexes: [Int] = []
        var conflictingIdentifierIndex: Int?
        if pathDepthMatches {
            for index in previous.identifiersFromEditorToAnchor.indices {
                let oldIdentifier = previous.identifiersFromEditorToAnchor[index]
                let newIdentifier = current.identifiersFromEditorToAnchor[index]
                if oldIdentifier == nil || newIdentifier == nil {
                    missingIdentifierIndexes.append(index)
                } else if oldIdentifier != newIdentifier, conflictingIdentifierIndex == nil {
                    conflictingIdentifierIndex = index
                }
            }
        }
        let scanComplete = previous.scanComplete && current.scanComplete
        let editorCountMatches = previous.editableEditorCount == 1 && current.editableEditorCount == 1
        let anchorRoleMatches = previous.editorAnchorRole == current.editorAnchorRole
        let anchorRoleAllowed = ["AXGroup", "AXContainer"].contains(current.editorAnchorRole)
        let webAreaMatches = CFEqual(previous.webArea, current.webArea)
        let windowAvailable = previous.window != nil && current.window != nil
        let windowMatches = previous.window.map { old in current.window.map { CFEqual(old, $0) } ?? false } ?? false
        let containerMatches = CFEqual(previous.editorAnchor, current.editorAnchor)
        let rolePathMatches = previous.rolesFromEditorToAnchor == current.rolesFromEditorToAnchor
        let structureChecks: [(Bool, String)] = [
            (scanComplete, "scan_incomplete"),
            (editorCountMatches, "editor_count"),
            (anchorRoleMatches, "container_role"),
            (anchorRoleAllowed, "container_role_unsupported"),
            (webAreaMatches, "web_area"),
            (windowAvailable, "window_missing"),
            (windowMatches, "window"),
            (containerMatches, "container"),
            (rolePathMatches, "role_path"),
            (pathDepthMatches, "identifier_path_depth")
        ]
        let structuralFailure = structureChecks.first(where: { !$0.0 })?.1
        let structurallyMatches = structuralFailure == nil
        // The leaf identifier is the editor's stable identifier. Missing
        // identifiers on both sides of an ancestor path were already allowed
        // by the previous matcher and do not weaken an equal leaf identity.
        let hasMissingIdentifiers = previousLeafIdentifier == nil || currentLeafIdentifier == nil
        let hasIdentifierConflict = conflictingIdentifierIndex != nil
        let identifiersMatch = previousLeafIdentifier != nil
            && previousLeafIdentifier == currentLeafIdentifier
            && !hasIdentifierConflict
            && pathDepthMatches

        var firstMismatch = structuralFailure
        if firstMismatch == nil, hasIdentifierConflict {
            if let conflictingIdentifierIndex {
                firstMismatch = conflictingIdentifierIndex == 0
                    ? "leaf_identifier"
                    : "identifier_path_\(conflictingIdentifierIndex)"
            }
        } else if firstMismatch == nil, hasMissingIdentifiers {
            firstMismatch = missingIdentifierIndexes.first == 0 ? "leaf_identifier" : "identifier_missing"
        }
        let identityOutcome: String
        if !scanComplete || !windowAvailable {
            identityOutcome = "temporarily_unavailable"
        } else if !structurallyMatches || hasIdentifierConflict {
            identityOutcome = "identity_conflict"
        } else if identifiersMatch {
            identityOutcome = "identifier_match"
        } else {
            identityOutcome = "identifier_missing_requires_captured_anchor_scan"
        }
        fields["firstMismatch"] = firstMismatch ?? "none"
        fields["identityOutcome"] = identityOutcome
        fields["missingIdentifierIndexes"] = missingIdentifierIndexes.map(String.init).joined(separator: ",")
        fields["identifierConflictIndex"] = conflictingIdentifierIndex.map(String.init) ?? "none"
        fields["structuralComparison"] = structurallyMatches ? "equal" : "different"
        return AXTextEditorContinuityComparison(
            matches: structurallyMatches && identifiersMatch,
            structurallyMatches: structurallyMatches,
            hasMissingIdentifiers: hasMissingIdentifiers,
            hasIdentifierConflict: hasIdentifierConflict,
            identityOutcome: identityOutcome,
            firstMismatch: firstMismatch,
            fields: boundedContinuityDiagnosticFields(fields)
        )
    }

    static func matches(
        _ previous: AXTextEditorContinuityEvidence,
        _ current: AXTextEditorContinuityEvidence
    ) -> Bool {
        compare(previous, current).matches
    }
}

@MainActor
protocol AXTextTargetKeyboardEventSending: AnyObject {
    func selectTrailingText(_ previousText: String, processID: pid_t?) throws
    func replaceSelection(with text: String, processID: pid_t?) throws
    func send(_ text: String, processID: pid_t?) throws
    func replaceTrailingText(_ previousText: String, with text: String, processID: pid_t?) throws
    func advanceCaretRight(processID: pid_t?) throws
}

struct AXTextTargetWriteTiming {
    let now: () -> UInt64
    let sleep: (UInt64) async throws -> Void

    init(
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }
}

@MainActor
final class AXTextTarget: KeyboardAcknowledgingTarget, AXAcknowledgingTarget {
    private(set) var requiresKeyboardAcknowledgement = false
    private var confirmedKeyboardDocument: String?
    private var confirmedKeyboardState: KeyboardDocumentState?
    private var pendingKeyboardWrite: KeyboardDocumentState?
    private var pendingKeyboardDiagnosticOperation: KeyboardDiagnosticDiffOperation?
    private var pendingKeyboardRepresentationTransition: PendingKeyboardRepresentationTransition?
    private var pendingKeyboardReplacement: PendingKeyboardReplacement?
    private var confirmedKeyboardRawInsertionRegion: KeyboardRawInsertionRegion?
    private var pendingKeyboardRawInsertionRegion: KeyboardRawInsertionRegion?
    private var replacementWasSent = false
    private var confirmedKeyboardRawText: String?
    private var confirmedKeyboardMapping: AXTextCoordinateMapping?
    private var lastResolvedCodexDocument: AXTextDocumentState?
    private var codexPlaceholderEvidence: AXPlaceholderEvidence?
    private var codexAXValueFallbackAllowed = false
    private var keyboardGeneration: UInt64 = 0
    private var keyboardOperationGeneration: UInt64 = 0
    private var axWriteGeneration: UInt64 = 0
    private var isCodexTarget = false
    private var isObsidianTarget = false
    private var isSafariWebEditor = false
    private var safariStrategyRetryDiagnosticRecorded = false
    private var safariStrategyRetryIsPending = false
    private var safariStrategyMismatchStartedAt: UInt64?
    private var keyboardTargetReacquireRetryDiagnosticRecorded = false
    private var keyboardTargetReacquireRetryIsPending = false
    private let safariStrategyRetryWindowNanoseconds: UInt64 = 500_000_000
    private var usesKeyboardOwnedSelection: Bool {
        activeInputStrategy.prefersAcknowledgedKeyboard
            || (isSafariWebEditor && requiresKeyboardAcknowledgement)
    }
    private var targetElement: AXUIElement?
    private var editorContinuity: AXTextEditorContinuityEvidence?
    private var continuityCaptureSummary: [String: String] = [:]
    private var firstContinuityRejectionDiagnostic: TextInputDiagnostic?
    private var targetProcessID: pid_t?
    private var targetApplicationProcessID: pid_t?
    private var targetApplicationBundleIdentifier: String?
    private var targetElementObservationID: String?
    private var lastKeyboardObservationTiming: (requested: Date, started: Date, finished: Date, monotonicMilliseconds: UInt64)?
    private var activeInputStrategy: AXTextInputStrategy = .accessibility
    private var expectedKeyboardSelection: TextRange?
    private let access: any AXTextTargetAccess
    private let keyboardEventSender: any AXTextTargetKeyboardEventSending
    private let writeTiming: AXTextTargetWriteTiming
    private let preflightTimeoutNanoseconds: UInt64
    private let acknowledgementTimeoutNanoseconds: UInt64
    private let enableExperimentalCodexCaretRecovery: Bool
    private let diagnosticCollectionEnabled: () -> Bool
    private let evidenceObserver: ((TextInputDiagnostic, AXUIElement?, pid_t?) -> Void)?
    private var diagnostics: [TextInputDiagnostic] = []
    private var diagnosticBytes = 0
    private var droppedDiagnosticCount = 0
    private var diagnosticOperationContext: TextInputDiagnosticContext?
    private var previousDiagnosticOperationContext: TextInputDiagnosticContext?
    private var lastKeyboardDispatch: UInt64?
    private var lastAXWriteStatus: Int32?
    private var lastAXWriteKind = "none"
    private var lastCoordinateDiagnosticKey: String?
    private var lastKeyboardReadUsedStructuralFallback = false

    init(
        operationObserver: ((String) -> Void)? = nil,
        evidenceObserver: ((TextInputDiagnostic, AXUIElement?, pid_t?) -> Void)? = nil,
        access: (any AXTextTargetAccess)? = nil,
        keyboardEventSender: (any AXTextTargetKeyboardEventSending)? = nil,
        writeTiming: AXTextTargetWriteTiming = .init(),
        preflightTimeoutNanoseconds: UInt64 = 5_000_000_000,
        acknowledgementTimeoutNanoseconds: UInt64 = 5_000_000_000,
        enableExperimentalCodexCaretRecovery: Bool = false,
        diagnosticCollectionEnabled: @escaping () -> Bool = { true }
    ) {
        self.evidenceObserver = evidenceObserver
        self.diagnosticCollectionEnabled = diagnosticCollectionEnabled
        self.access = access ?? SystemAXTextTargetAccess()
        self.keyboardEventSender = keyboardEventSender
            ?? KeyboardEventSender(stageObserver: operationObserver)
        self.writeTiming = writeTiming
        self.preflightTimeoutNanoseconds = preflightTimeoutNanoseconds
        self.acknowledgementTimeoutNanoseconds = acknowledgementTimeoutNanoseconds
        self.enableExperimentalCodexCaretRecovery = enableExperimentalCodexCaretRecovery
    }

    func drainDiagnostics() -> [TextInputDiagnostic] {
        _ = refreshDiagnosticCollectionState()
        for diagnostic in access.drainReadDiagnostics() {
            recordDiagnostic(
                diagnostic.event,
                diagnostic.fields,
                context: diagnosticOperationContext ?? previousDiagnosticOperationContext,
                timestamp: diagnostic.timestamp,
                monotonicTimestampNanoseconds: diagnostic.monotonicTimestampNanoseconds
            )
        }
        defer { diagnostics.removeAll(keepingCapacity: true); diagnosticBytes = 0 }
        var result = diagnostics
        if droppedDiagnosticCount > 0 {
            result.append(TextInputDiagnostic(
                timestamp: Date(),
                event: "target_diagnostics_truncated",
                fields: ["droppedEventCount": String(droppedDiagnosticCount),
                    "reason": "target_event_count_or_byte_capacity", "byteLimit": String(16 * 1024 * 1024)]
            ))
            droppedDiagnosticCount = 0
        }
        return result
    }

    func setDiagnosticOperation(_ context: TextInputDiagnosticContext?) {
        if context == nil {
            previousDiagnosticOperationContext = diagnosticOperationContext
        }
        diagnosticOperationContext = context
    }

    private func recordDiagnostic(
        _ event: String,
        _ fields: [String: String] = [:],
        context: TextInputDiagnosticContext? = nil,
        textEvidence: [DiagnosticTextEvidence] = [],
        timestamp: Date = Date(),
        monotonicTimestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let diagnosticsEnabled = refreshDiagnosticCollectionState()
        if !diagnosticsEnabled && Self.continuityDiagnosticOnlyEvents.contains(event) {
            return
        }
        var merged = (context ?? diagnosticOperationContext)?.fields ?? [:]
        merged.merge(fields) { _, new in new }
        if !diagnosticsEnabled {
            merged = merged.filter { !Self.isContinuityDiagnosticField($0.key) }
        }
        merged["inputSessionGeneration"] = String(keyboardGeneration)
        merged["keyboardOperationGeneration"] = String(keyboardOperationGeneration)
        if diagnosticsEnabled,
           ["keyboard_editor_continuity_captured", "keyboard_target_reacquire_rejected"].contains(event) {
            merged = boundedContinuityDiagnosticFields(merged)
        }
        let diagnostic = TextInputDiagnostic(
            timestamp: timestamp,
            monotonicTimestampNanoseconds: monotonicTimestampNanoseconds,
            event: event,
            fields: merged,
            textEvidence: textEvidence
        )
        if diagnosticsEnabled, event == "keyboard_target_reacquire_rejected",
           firstContinuityRejectionDiagnostic == nil {
            firstContinuityRejectionDiagnostic = diagnostic
        }
        evidenceObserver?(diagnostic, targetElement, targetApplicationProcessID ?? targetProcessID)
        diagnostics.append(diagnostic)
        diagnosticBytes += diagnostic.estimatedDiagnosticBytes
        while diagnostics.count > 4096 || diagnosticBytes > 16 * 1024 * 1024 {
            droppedDiagnosticCount += 1
            // Keep terminal outcomes even when read sampling fills the buffer.
            let removable = diagnostics.firstIndex {
                $0.eventID != firstContinuityRejectionDiagnostic?.eventID
                    && ["keyboard_document_observed", "ax_text_attribute_read"].contains($0.event)
            }
            let fallback = removable ?? diagnostics.firstIndex {
                $0.eventID != firstContinuityRejectionDiagnostic?.eventID
            }
            guard let fallback else { break }
            diagnosticBytes -= diagnostics.remove(at: fallback).estimatedDiagnosticBytes
        }
    }

    private func refreshDiagnosticCollectionState() -> Bool {
        let enabled = diagnosticCollectionEnabled()
        access.setContinuityDiagnosticsEnabled(enabled)
        guard !enabled else { return true }
        continuityCaptureSummary.removeAll(keepingCapacity: false)
        firstContinuityRejectionDiagnostic = nil
        diagnostics = diagnostics.compactMap { diagnostic in
            if Self.continuityDiagnosticOnlyEvents.contains(diagnostic.event) {
                return nil
            }
            let fields = diagnostic.fields.filter { !Self.isContinuityDiagnosticField($0.key) }
            guard fields != diagnostic.fields else { return diagnostic }
            return TextInputDiagnostic(
                eventID: diagnostic.eventID,
                timestamp: diagnostic.timestamp,
                monotonicTimestampNanoseconds: diagnostic.monotonicTimestampNanoseconds,
                event: diagnostic.event,
                fields: fields,
                textEvidence: diagnostic.textEvidence
            )
        }
        diagnosticBytes = diagnostics.reduce(0) { $0 + $1.estimatedDiagnosticBytes }
        return false
    }

    func refreshDiagnosticCollectionSettings() {
        _ = refreshDiagnosticCollectionState()
    }

    private static func isContinuityDiagnosticField(_ key: String) -> Bool {
        key.hasPrefix("continuity") || key.hasPrefix("captureScan_") || key.hasPrefix("scan_")
            || key.hasSuffix("ObjectGeneration")
            || ["firstMismatch", "fallbackRoute", "currentEvidenceSource", "previousEvidence",
                "ancestorScanOutcome", "ancestorScanID", "currentScanID", "identifierPathComparisons",
                "leafIdentifierPresence", "leafIdentifierComparison", "scanCompleteness",
                "editableEditorCount", "anchorRoleComparison", "anchorRoleAllowed",
                "webAreaComparison", "windowPresence", "windowComparison", "containerComparison",
                "rolePathComparison", "identifierPathDepth", "rolePathDepthPrevious",
                "rolePathDepthCurrent", "identifierPathDepthPrevious", "identifierPathDepthCurrent",
                "diagnosticSummaryTruncated", "objectGeneration", "scanID", "scanPath", "scanComplete",
                "outcome", "candidateCount", "elapsedMilliseconds", "visitedNodes", "stopStage",
                "stopReason", "failureAttribute", "failureStatus", "rolePathDepth", "identifierPresence",
                "capturedApplication", "capturedProcessID", "targetElementObservationID",
                "identityFailure", "applicationComparison", "processComparison", "candidateProcessComparison",
                "previousHandleValidity", "captureOutcome", "captureContinuityApplicable",
                "captureTargetApplication", "captureFocusedElementAvailable", "capturedContinuityEvidence",
                "capturedContinuityScanID", "readStartedAt", "readFinishedAt",
                "readStartedMonotonicMilliseconds", "sendState", "confirmationResult"].contains(key)
    }

    private static let continuityDiagnosticOnlyEvents: Set<String> = [
        "keyboard_editor_continuity_captured", "editor_continuity_scan_summary",
        "editor_continuity_scan_diagnostic", "ax_read_diagnostic_queue_summary",
        "keyboard_document_observation_discarded"
    ]

    func currentApplication() -> TextTargetApplication? {
        access.currentApplication()
    }

    // A successful dispatch call is not proof of what the editor displayed.
    // Record its exact payload here, never reconstruct it in an onFinish callback.
    private func recordDispatchedText(_ text: String, expectedDocument: String?,
                                      replacementRange: TextRange? = nil,
                                      context: TextInputDiagnosticContext? = nil) {
        let operation = context ?? diagnosticOperationContext
        let now = Date()
        func evidence(_ kind: DiagnosticTextEvidenceKind, _ source: DiagnosticEvidenceSource,
                      _ value: String) -> DiagnosticTextEvidence {
            DiagnosticTextEvidence(kind: kind, source: source, text: value,
                revision: UInt64(operation?.fields["revision"] ?? ""),
                operationID: operation.map { String($0.operationID) },
                targetApplicationBundleIdentifier: targetApplicationBundleIdentifier,
                targetApplicationProcessID: targetApplicationProcessID,
                editorIdentity: targetElementObservationID,
                selectionLocationUTF16: replacementRange?.location,
                selectionLengthUTF16: replacementRange?.length, observedAt: now,
                monotonicMilliseconds: writeTiming.now() / 1_000_000)
        }
        var texts = [evidence(.sentText, .observed, text)]
        if let expectedDocument { texts.append(evidence(.expectedDocument, .expected, expectedDocument)) }
        recordDiagnostic("text_dispatch_returned", ["result": "submission_returned_without_error",
            "selectionMeaning": "requested_replacement_range_not_post_write_caret",
            "displayResult": "not_yet_confirmed", "editorIdentityMeaning": "captured_handle_not_stable_editor_identity"],
            context: operation, textEvidence: texts)
    }

    private func documentEvidence(_ state: KeyboardDocumentState, requested: Date,
                                  started: Date, monotonic: UInt64) -> [DiagnosticTextEvidence] {
        let finished = Date()
        let context = diagnosticOperationContext ?? previousDiagnosticOperationContext
        var values: [(DiagnosticTextEvidenceKind, String)] = []
        if let raw = state.rawText { values.append((.axValue, raw)) }
        if state.mapping?.source == .axStringForRange { values.append((.axStringForRange, state.text)) }
        return values.map { kind, text in
            DiagnosticTextEvidence(kind: kind, source: .observed, text: text,
                revision: UInt64(context?.fields["revision"] ?? ""),
                operationID: context.map { String($0.operationID) },
                targetApplicationBundleIdentifier: targetApplicationBundleIdentifier,
                targetApplicationProcessID: targetApplicationProcessID,
                editorIdentity: targetElementObservationID,
                selectionLocationUTF16: state.selection.location,
                selectionLengthUTF16: state.selection.length,
                requestedAt: requested, readStartedAt: started, readFinishedAt: finished,
                observedAt: finished, monotonicMilliseconds: monotonic)
        }
    }

    private var lastAXObservationEvidence: [DiagnosticTextEvidence] = []

    private func readTextEvidence(_ kind: DiagnosticTextEvidenceKind,
                                  fields: [String: String] = [:],
                                  read: () throws -> String?) throws -> String? {
        let start = Date()
        let monotonic = writeTiming.now() / 1_000_000
        let context = diagnosticOperationContext ?? previousDiagnosticOperationContext
        do {
            let text = try read()
            let end = Date()
            let evidence = text.map { text in
                DiagnosticTextEvidence(kind: kind, source: .observed, text: text,
                    revision: UInt64(context?.fields["revision"] ?? ""),
                    operationID: context.map { String($0.operationID) },
                    targetApplicationBundleIdentifier: targetApplicationBundleIdentifier,
                    targetApplicationProcessID: targetApplicationProcessID,
                    editorIdentity: targetElementObservationID,
                    requestedAt: start, readStartedAt: start, readFinishedAt: end,
                    observedAt: end, monotonicMilliseconds: monotonic)
            }
            recordDiagnostic("ax_text_attribute_read", fields.merging([
                "attribute": kind.rawValue, "result": text == nil ? "unavailable" : "observed",
                "selectionRelation": "separate_non_atomic_read",
                "editorIdentityMeaning": "captured_handle_not_stable_editor_identity"
            ]) { _, new in new }, context: context, textEvidence: evidence.map { [$0] } ?? [])
            return text
        } catch {
            recordDiagnostic("ax_text_attribute_read", fields.merging([
                "attribute": kind.rawValue, "result": "failed", "code": axReadDiagnosticCode(for: error),
                "requestedAt": start.ISO8601Format(), "finishedAt": Date().ISO8601Format(),
                "readStartedMonotonicMilliseconds": String(monotonic)
            ]) { _, new in new }, context: context)
            throw error
        }
    }

    func capture() throws -> TextSnapshot {
        _ = refreshDiagnosticCollectionState()
        _ = access.drainReadDiagnostics()
        keyboardGeneration &+= 1
        keyboardOperationGeneration = 0
        axWriteGeneration &+= 1
        pendingKeyboardWrite = nil
        pendingKeyboardDiagnosticOperation = nil
        pendingKeyboardRepresentationTransition = nil
        pendingKeyboardReplacement = nil
        confirmedKeyboardRawInsertionRegion = nil
        pendingKeyboardRawInsertionRegion = nil
        replacementWasSent = false
        confirmedKeyboardRawText = nil
        confirmedKeyboardMapping = nil
        lastResolvedCodexDocument = nil
        codexPlaceholderEvidence = nil
        codexAXValueFallbackAllowed = false
        confirmedKeyboardDocument = nil
        confirmedKeyboardState = nil
        requiresKeyboardAcknowledgement = false
        diagnostics.removeAll(keepingCapacity: true)
        diagnosticBytes = 0
        droppedDiagnosticCount = 0
        firstContinuityRejectionDiagnostic = nil
        diagnosticOperationContext = nil
        previousDiagnosticOperationContext = nil
        lastKeyboardDispatch = nil
        lastAXWriteStatus = nil
        lastAXWriteKind = "none"
        lastCoordinateDiagnosticKey = nil
        lastKeyboardReadUsedStructuralFallback = false
        try access.requestInputPermissions()
        targetElement = nil
        editorContinuity = nil
        continuityCaptureSummary = [:]
        targetProcessID = nil
        targetApplicationBundleIdentifier = nil
        targetElementObservationID = nil
        lastKeyboardObservationTiming = nil
        expectedKeyboardSelection = nil
        activeInputStrategy = .accessibility
        let targetApplication = currentApplication()
        targetApplicationProcessID = targetApplication.map { pid_t($0.processIdentifier) }
        targetApplicationBundleIdentifier = targetApplication?.bundleIdentifier
        isCodexTarget = targetApplication?.bundleIdentifier == "com.openai.codex"
        isObsidianTarget = targetApplication?.bundleIdentifier == "md.obsidian"
        isSafariWebEditor = false

        // Some Electron/WebKit controls expose neither a stable AX value nor
        // a stable focused AX element while the DOM is being rebuilt. That is
        // still a valid keyboard target as long as a frontmost application is
        // known; the keyboard append path only owns the text it sends.
        let element = try? focusedElement()
        targetElement = element
        if let element {
            targetProcessID = access.processIdentifier(of: element) ?? targetApplicationProcessID
            targetElementObservationID = UUID().uuidString
        } else {
            targetProcessID = targetApplicationProcessID
            targetElementObservationID = nil
        }
        guard targetProcessID != nil else {
            throw TextTargetError.unsupported
        }

        // Electron/web content controls do not always expose kAXValueAttribute,
        // even though they still accept Unicode keyboard events. Keep the
        // focused element as a keyboard target instead of falling all the way
        // back to append-only mode. When Codex exposes readable text, however,
        // its AXValue and selection coordinates must be interpreted together.
        let inputContext = element.flatMap { access.textInputContext(for: $0) }
        // Safari web editors can advertise writable AX attributes even when
        // those writes do not update the page. Use the acknowledged keyboard
        // path for positively identified editable web text areas; retain the
        // explicit ProseMirror marker as the legacy fallback when ancestry is
        // unavailable.
        isSafariWebEditor = element.map {
            isEligibleSafariWebEditor($0, application: targetApplication, context: inputContext)
        } ?? false
        let continuityApplicable = isSafariWebEditor || (isCodexTarget && inputContext?.ancestorScanStatus == .webArea)
        let continuityTargetApplication = targetApplicationBundleIdentifier == "com.apple.Safari" || isCodexTarget
        access.setContinuityScanObjectGeneration(targetElementObservationID)
        editorContinuity = continuityApplicable
            ? element.flatMap { access.editorContinuityEvidence(for: $0) }
                .flatMap { $0.scanComplete && $0.editableEditorCount == 1 ? $0 : nil }
            : nil
        access.setContinuityScanObjectGeneration(nil)
        let captureScanID = continuityApplicable ? access.lastContinuityScanObservationID() : nil
        let captureScanSummary = continuityApplicable ? access.lastContinuityScanSummary() : nil
        let captureOutcome = AXTextEditorContinuity.captureOutcome(
            continuityApplicable: continuityApplicable,
            continuityTargetApplication: continuityTargetApplication,
            focusedElementAvailable: element != nil,
            evidenceSaved: editorContinuity != nil,
            scanSummary: captureScanSummary
        )
        var captureFields = [
            "continuityApplicable": String(continuityApplicable),
            "continuityTargetApplication": String(continuityTargetApplication),
            "continuityEvidenceSaved": String(editorContinuity != nil),
            "captureOutcome": captureOutcome,
            "targetElementObservationID": targetElementObservationID ?? "unknown",
            "continuityScanID": captureScanID ?? "not_run",
            "capturedApplication": targetApplicationBundleIdentifier ?? "unknown",
            "capturedProcessID": targetApplicationProcessID.map(String.init) ?? "unknown"
        ]
        continuityCaptureSummary = [
            "capturedContinuityEvidence": editorContinuity == nil ? "missing" : "saved",
            "capturedContinuityScanID": captureScanID ?? "not_run",
            "captureOutcome": captureOutcome,
            "captureContinuityApplicable": String(continuityApplicable),
            "captureTargetApplication": String(continuityTargetApplication),
            "captureFocusedElementAvailable": String(element != nil)
        ]
        for (key, value) in captureScanSummary ?? [:] {
            captureFields["scan_\(key)"] = value
            continuityCaptureSummary["captureScan_\(key)"] = value
        }
        recordDiagnostic("keyboard_editor_continuity_captured", boundedContinuityDiagnosticFields(captureFields))
        continuityCaptureSummary = boundedContinuityDiagnosticFields(continuityCaptureSummary)
        let rawText = try element.flatMap { element in
            try captureReadableText(in: element, context: inputContext)
        }
        let readableKeyboardSelection = try element.flatMap { element in
            try captureReadableSelection(in: element, context: inputContext)
        }
        let hasReadableAXTextState = if let rawText, let readableKeyboardSelection {
            isValidTextRange(readableKeyboardSelection, in: rawText)
        } else {
            false
        }
        let rawSelection = readableKeyboardSelection
            ?? TextRange(location: rawText?.utf16.count ?? 0, length: 0)
        let inputStrategy = AXTextInputStrategy.select(
            application: targetApplication,
            context: inputContext,
            hasReadableTextState: hasReadableAXTextState
        )
        activeInputStrategy = inputStrategy
        var codexState: AXTextDocumentState?
        if isCodexTarget, let element, let rawText, let readableKeyboardSelection {
            let evidence = placeholderEvidence(in: element)
            codexPlaceholderEvidence = evidence
            do {
                let state = try readCodexTextDocument(
                    rawText: rawText,
                    selection: readableKeyboardSelection,
                    evidence: evidence,
                    element: element
                )
                codexState = state
                lastResolvedCodexDocument = state
                recordCoordinateResolution(state: state, evidence: evidence)
            } catch let error as AXTextDocumentResolutionError {
                recordCoordinateResolutionFailure(
                    error,
                    rawText: rawText,
                    selection: readableKeyboardSelection,
                    evidence: evidence
                )
            } catch let error as TextTargetError {
                throw error
            } catch {
                recordCoordinateResolutionFailure(
                    .coordinateReadUnavailable,
                    rawText: rawText,
                    selection: readableKeyboardSelection,
                    evidence: evidence
                )
            }
        }
        let text = codexState?.text ?? rawText ?? ""
        let selection = codexState?.selection ?? rawSelection
        expectedKeyboardSelection = selection
        requiresKeyboardAcknowledgement = hasReadableAXTextState || inputStrategy.prefersAcknowledgedKeyboard
        confirmedKeyboardDocument = if let codexState {
            codexState.text
        } else if !isCodexTarget, let rawText {
            rawText
        } else {
            nil
        }
        confirmedKeyboardRawText = codexState?.rawText
        confirmedKeyboardMapping = codexState?.mapping
        confirmedKeyboardState = if let codexState {
            KeyboardDocumentState(
                text: codexState.text,
                selection: codexState.selection,
                rawText: codexState.rawText,
                mapping: codexState.mapping
            )
        } else if !isCodexTarget, let rawText, let readableKeyboardSelection {
            KeyboardDocumentState(text: rawText, selection: readableKeyboardSelection)
        } else {
            nil
        }
        recordDiagnostic("input_target_captured", [
            "hasElement": String(element != nil), "hasReadableState": String(hasReadableAXTextState),
            "targetElementObservationID": targetElementObservationID ?? "unknown",
            "targetElementObservationMeaning": "captured_AX_handle_not_stable_editor_identity",
            "selectedSettable": String(element.map { selectedTextIsSettable(on: $0) } ?? false),
            "selectedRangeSettable": String(element.map { selectedTextRangeIsSettable(on: $0) } ?? false),
            "valueSettable": String(element.map { valueIsSettable(on: $0) } ?? false),
            "documentLength": String(text.utf16.count),
            "axValueLengthUTF16": String(rawText?.utf16.count ?? 0),
            "axCoordinateLengthUTF16": String(codexState?.text.utf16.count ?? text.utf16.count),
            "selectionLocation": String(selection.location), "selectionLength": String(selection.length),
            "keyboardCompatibility": String(
                isCodexTarget || isSafariWebEditor || inputStrategy.prefersAcknowledgedKeyboard
            ),
            "safariWebEditor": String(isSafariWebEditor),
            "inputStrategy": inputStrategy.diagnosticName,
            "inputStrategyReason": inputStrategy.diagnosticReason,
            "inputStrategyHasReadableState": String(hasReadableAXTextState),
            "inputRole": inputContext?.role ?? "unknown",
            "inputReadOnly": inputContext.flatMap { $0.isReadOnly }.map { String($0) } ?? "unknown",
            "inputSecure": inputContext.flatMap { $0.isSecure }.map { String($0) } ?? "unknown",
            "ancestorScanStatus": inputContext.map { $0.ancestorScanStatus.rawValue } ?? "unavailable",
            "webAreaDepth": inputContext.flatMap { $0.webAreaDepth }.map(String.init) ?? "unknown"
        ])
        return TextSnapshot(
            element: element,
            text: text,
            selection: selection,
            supportsAXReplacement: !inputStrategy.suppressesAXReplacement
                && !inputStrategy.requiresSafeStop
                && !isSafariWebEditor && !isObsidianTarget && hasReadableAXTextState && (element.map {
                selectedTextIsSettable(on: $0) || valueIsSettable(on: $0)
            } ?? false),
            targetApplication: targetApplication,
            rawText: rawText ?? text,
            coordinateText: codexState?.text ?? text,
            placeholderNormalized: codexState?.placeholderNormalized ?? false,
            coordinateMapping: codexState?.mapping,
            preferredInputStrategy: inputStrategy
        )
    }

    func replace(snapshot: TextSnapshot, range: TextRange, expectedText: String, with text: String) throws -> TextRange {
        guard snapshot.supportsAXReplacement else { throw TextTargetError.unsupported }
        guard let expectedElement = snapshot.element else { throw TextTargetError.unsupported }
        let element = try focusedElement()
        guard CFEqual(element, expectedElement) else {
            recordDiagnostic("ax_focus_changed")
            throw TextTargetError.targetChanged
        }
        guard let currentText = readableText(in: element) else {
            recordDiagnostic("ax_value_unreadable")
            throw TextTargetError.targetChanged
        }
        guard currentText == expectedText else {
            recordDiagnostic("ax_document_mismatch", [
                "expectedDocumentLength": String(expectedText.utf16.count),
                "actualDocumentLength": String(currentText.utf16.count), "documentMatches": "false",
                "lastAXStatus": lastAXWriteStatus.map(String.init) ?? "none", "lastAXWriteKind": lastAXWriteKind
            ])
            throw TextTargetError.targetChanged
        }
        guard let currentSelection = readableSelection(in: element),
              currentSelection.location == range.location + range.length,
              range.location >= 0,
              range.length >= 0,
              range.location + range.length <= currentText.utf16.count else {
            recordDiagnostic("ax_selection_mismatch", [
                "expectedLocation": String(range.location + range.length),
                "actualLocation": String(readableSelection(in: element)?.location ?? -1),
                "actualLength": String(readableSelection(in: element)?.length ?? -1)
            ])
            throw TextTargetError.targetChanged
        }

        if selectedTextIsSettable(on: element) {
            let previousText = (currentText as NSString).substring(
                with: NSRange(location: range.location, length: range.length)
            )
            let delta = TextReplacementDelta(previousText: previousText, newText: text)
            let replacementRange = TextRange(
                location: range.location + delta.prefixUTF16Length,
                length: delta.previousMiddleUTF16Length
            )
            try setSelection(replacementRange, on: element)
            let status = try access.setSelectedText(delta.insertion, on: element)
            lastAXWriteStatus = status
            lastAXWriteKind = "selected"
            guard status == AXError.success.rawValue else {
                recordDiagnostic("ax_write_failed", ["status": String(status), "writeKind": "selected"])
                throw TextTargetError.writeFailed
            }
        } else {
            guard valueIsSettable(on: element) else { throw TextTargetError.writeFailed }
            let document = NSMutableString(string: currentText)
            document.replaceCharacters(
                in: NSRange(location: range.location, length: range.length),
                with: text
            )
            let status = try access.setValue(document as String, on: element)
            lastAXWriteStatus = status
            lastAXWriteKind = "value"
            guard status == AXError.success.rawValue else {
                recordDiagnostic("ax_write_failed", ["status": String(status), "writeKind": "value"])
                throw TextTargetError.writeFailed
            }
        }

        let newRange = TextRange(location: range.location, length: text.utf16.count)
        try setSelection(TextRange(location: newRange.location + newRange.length, length: 0), on: element)
        return newRange
    }

    func writeAXText(
        snapshot: TextSnapshot,
        range: TextRange,
        expectedText: String,
        with text: String
    ) async throws -> AXTextWriteReceipt {
        guard snapshot.supportsAXReplacement else { throw TextTargetError.unsupported }
        guard let expectedElement = snapshot.element else { throw TextTargetError.unsupported }
        let generation = axWriteGeneration
        keyboardOperationGeneration &+= 1
        let operationGeneration = keyboardOperationGeneration
        let start = writeTiming.now()
        var trace = AXWriteAcknowledgementTrace()
        var submitted = false
        var writeKind = "none"
        var lastObserved: AXWritableState?
        var expectedDocumentLengthUTF16 = expectedText.utf16.count

        do {
            try checkAXWriteIdentity(expectedElement, generation: generation)
            let element = try focusedElement()
            let collapsedEnd = TextRange(
                location: range.location + range.length,
                length: 0
            )
            let original = try await waitForAXPreflightState(
                expectedElement: expectedElement,
                element: element,
                expectedDocument: expectedText,
                range: range,
                allowedSelections: [range, collapsedEnd],
                generation: generation,
                operationGeneration: operationGeneration,
                trace: &trace,
                lastObserved: &lastObserved,
                start: start
            )
            guard range.location >= 0,
                  range.length >= 0,
                  range.location + range.length <= original.text.utf16.count else {
                throw TextTargetError.targetChanged
            }

            let document = NSMutableString(string: expectedText)
            document.replaceCharacters(
                in: NSRange(location: range.location, length: range.length),
                with: text
            )
            let expectedDocument = document as String
            expectedDocumentLengthUTF16 = expectedDocument.utf16.count
            let writtenRange = TextRange(location: range.location, length: text.utf16.count)
            let targetSelection = TextRange(location: writtenRange.location + writtenRange.length, length: 0)
            var allowedPostDispatchSelections = [
                range,
                TextRange(location: range.location + range.length, length: 0),
                targetSelection
            ]

            var dispatchedPayload = text
            var dispatchedRange = range
            if selectedTextIsSettable(on: element) {
                writeKind = "selected"
                let previousText = (expectedText as NSString).substring(
                    with: NSRange(location: range.location, length: range.length)
                )
                let delta = TextReplacementDelta(previousText: previousText, newText: text)
                dispatchedPayload = delta.insertion
                let replacementRange = TextRange(
                    location: range.location + delta.prefixUTF16Length,
                    length: delta.previousMiddleUTF16Length
                )
                dispatchedRange = replacementRange
                try setSelection(replacementRange, on: element)
                allowedPostDispatchSelections.append(replacementRange)
                _ = try await waitForAXWriteState(
                    expectedElement: expectedElement,
                    element: element,
                    expectedDocument: expectedText,
                    requiredSelection: replacementRange,
                    allowedDocuments: [expectedText],
                    allowedSelections: [
                        range,
                        TextRange(location: range.location + range.length, length: 0),
                        replacementRange
                    ],
                    phase: "selection_preparation",
                    generation: generation,
                    operationGeneration: operationGeneration,
                    trace: &trace,
                    lastObserved: &lastObserved,
                    start: start
                )
                let status = try access.setSelectedText(delta.insertion, on: element)
                lastAXWriteStatus = status
                lastAXWriteKind = writeKind
                guard status == AXError.success.rawValue else {
                    recordDiagnostic("ax_write_failed", [
                        "status": String(status),
                        "writeKind": writeKind,
                        "failureStage": "text_submission",
                        "axOperationGeneration": String(operationGeneration)
                    ])
                    throw TextTargetError.writeFailed
                }
            } else {
                guard valueIsSettable(on: element) else { throw TextTargetError.writeFailed }
                writeKind = "value"
                dispatchedPayload = expectedDocument
                dispatchedRange = TextRange(location: 0, length: expectedText.utf16.count)
                let status = try access.setValue(expectedDocument, on: element)
                lastAXWriteStatus = status
                lastAXWriteKind = writeKind
                guard status == AXError.success.rawValue else {
                    recordDiagnostic("ax_write_failed", [
                        "status": String(status),
                        "writeKind": writeKind,
                        "failureStage": "text_submission",
                        "axOperationGeneration": String(operationGeneration)
                    ])
                    throw TextTargetError.writeFailed
                }
            }

            submitted = true
            recordDispatchedText(dispatchedPayload, expectedDocument: expectedDocument, replacementRange: dispatchedRange)
            trace.beginPostDispatch()
            recordDiagnostic("ax_write_submitted", [
                "axWriteStatus": String(lastAXWriteStatus ?? AXError.success.rawValue),
                "axWriteKind": writeKind,
                "axExpectedValueLengthUTF16": String(expectedDocument.utf16.count),
                "axExpectedSelectionLocation": String(targetSelection.location),
                "axExpectedSelectionLength": String(targetSelection.length),
                "axOperationGeneration": String(operationGeneration),
                "failureStage": "post_submission"
            ])

            try setSelection(targetSelection, on: element)
            recordDiagnostic("ax_write_waiting", [
                "axWriteKind": writeKind,
                "axExpectedValueLengthUTF16": String(expectedDocument.utf16.count),
                "axExpectedSelectionLocation": String(targetSelection.location),
                "axExpectedSelectionLength": String(targetSelection.length),
                "axOperationGeneration": String(operationGeneration),
                "failureStage": "readback"
            ])
            let acknowledged = try await waitForAXWriteState(
                expectedElement: expectedElement,
                element: element,
                expectedDocument: expectedDocument,
                requiredSelection: targetSelection,
                allowedDocuments: [expectedText, expectedDocument],
                allowedSelections: allowedPostDispatchSelections,
                phase: "post_submission",
                generation: generation,
                operationGeneration: operationGeneration,
                trace: &trace,
                lastObserved: &lastObserved,
                start: start
            )
            lastObserved = acknowledged
            let elapsed = (writeTiming.now() &- start) / 1_000_000
            var fields = trace.fields(
                final: AXWriteStateEvidence(
                    axValueLengthUTF16: acknowledged.text.utf16.count,
                    selectionLocation: acknowledged.selection.location,
                    selectionLength: acknowledged.selection.length,
                    targetIdentityMatches: true
                ),
                finalMatches: true,
                elapsedMilliseconds: elapsed
            )
            fields.merge([
                "axWriteStatus": String(lastAXWriteStatus ?? AXError.success.rawValue),
                "axWriteKind": writeKind,
                "axExpectedValueLengthUTF16": String(expectedDocument.utf16.count),
                "axExpectedSelectionLocation": String(targetSelection.location),
                "axExpectedSelectionLength": String(targetSelection.length),
                "axOperationGeneration": String(operationGeneration),
                "failureStage": "acknowledged"
            ]) { _, new in new }
            recordDiagnostic("ax_write_acknowledged", fields, textEvidence: lastAXObservationEvidence)
            return AXTextWriteReceipt(
                text: acknowledged.text,
                selection: acknowledged.selection,
                writtenRange: writtenRange
            )
        } catch {
            if submitted {
                let elapsed = (writeTiming.now() &- start) / 1_000_000
                var fields = trace.fields(
                    final: lastObserved.map {
                        AXWriteStateEvidence(
                            axValueLengthUTF16: $0.text.utf16.count,
                            selectionLocation: $0.selection.location,
                            selectionLength: $0.selection.length,
                            targetIdentityMatches: true
                        )
                    },
                    finalMatches: false,
                    elapsedMilliseconds: elapsed
                )
                fields.merge([
                    "axWriteStatus": String(lastAXWriteStatus ?? AXError.success.rawValue),
                    "axWriteKind": writeKind,
                    "axExpectedValueLengthUTF16": String(expectedDocumentLengthUTF16),
                    "axFailureCode": axReadDiagnosticCode(for: error),
                    "axOperationGeneration": String(operationGeneration),
                    "failureStage": "readback"
                ]) { _, new in new }
                recordDiagnostic("ax_write_unconfirmed", fields)
            }
            throw error
        }
    }

    func cancelAXWrite() {
        axWriteGeneration &+= 1
        // A cancelled voice operation must never let a later operation reuse
        // the raw insertion anchor captured for this one.
        invalidateKeyboardRawInsertionRegion()
    }

    private func checkAXWriteIdentity(_ expectedElement: AXUIElement, generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == axWriteGeneration else { throw CancellationError() }
        try ensureTargetApplicationIsFrontmost()
        let focused = try focusedElement()
        guard CFEqual(focused, expectedElement) else {
            recordDiagnostic("ax_focus_changed", ["failureStage": "identity_check"])
            throw TextTargetError.targetChanged
        }
        if let expectedPID = targetProcessID,
           let actualPID = access.processIdentifier(of: focused),
           expectedPID != actualPID {
            recordDiagnostic("ax_focus_changed", [
                "failureStage": "identity_check",
                "targetElementProcessID": String(expectedPID),
                "actualElementProcessID": String(actualPID)
            ])
            throw TextTargetError.targetChanged
        }
    }

    private func readAXWritableState(in element: AXUIElement) throws -> AXWritableState {
        lastAXObservationEvidence = []
        let start = Date()
        let monotonic = writeTiming.now() / 1_000_000
        guard let text = try readTextEvidence(.axValue, read: { try access.text(in: element) }),
              let selection = try access.selection(in: element) else {
            throw KeyboardWriteReadError.retryable
        }
        lastAXObservationEvidence = documentEvidence(
            KeyboardDocumentState(text: text, selection: selection, rawText: text),
            requested: start, started: start, monotonic: monotonic)
        return AXWritableState(text: text, selection: selection)
    }

    private func waitForAXPreflightState(
        expectedElement: AXUIElement,
        element: AXUIElement,
        expectedDocument: String,
        range: TextRange,
        allowedSelections: [TextRange],
        generation: UInt64,
        operationGeneration: UInt64,
        trace: inout AXWriteAcknowledgementTrace,
        lastObserved: inout AXWritableState?,
        start: UInt64
    ) async throws -> AXWritableState {
        let deadline = start &+ acknowledgementTimeoutNanoseconds
        while true {
            try Task.checkCancellation()
            guard generation == axWriteGeneration,
                  operationGeneration == keyboardOperationGeneration else {
                throw CancellationError()
            }
            try checkAXWriteIdentity(expectedElement, generation: generation)
            do {
                let observed = try readAXWritableState(in: element)
                lastObserved = observed
                try checkAXWriteIdentity(expectedElement, generation: generation)
                let matches = observed.text == expectedDocument && allowedSelections.contains(observed.selection)
                trace.recordRead(
                    AXWriteStateEvidence(
                        axValueLengthUTF16: observed.text.utf16.count,
                        selectionLocation: observed.selection.location,
                        selectionLength: observed.selection.length,
                        targetIdentityMatches: true
                    ),
                    matches: matches
                )
                guard writeTiming.now() < deadline else { throw TextTargetError.writeFailed }
                guard observed.text == expectedDocument else {
                    recordDiagnostic("ax_document_mismatch", [
                        "expectedDocumentLength": String(expectedDocument.utf16.count),
                        "actualDocumentLength": String(observed.text.utf16.count),
                        "documentMatches": "false",
                        "failureStage": "preflight",
                        "axOperationGeneration": String(operationGeneration)
                    ])
                    throw TextTargetError.targetChanged
                }
                guard observed.selection.location >= 0,
                      observed.selection.length >= 0,
                      observed.selection.location + observed.selection.length <= observed.text.utf16.count,
                      allowedSelections.contains(observed.selection) else {
                    recordDiagnostic("ax_selection_mismatch", [
                        "expectedLocation": String(range.location),
                        "expectedLength": String(range.length),
                        "actualLocation": String(observed.selection.location),
                        "actualLength": String(observed.selection.length),
                        "failureStage": "preflight"
                    ])
                    throw TextTargetError.targetChanged
                }
                return observed
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TextTargetError {
                throw error
            } catch {
                guard isTransientAXReadError(error) else { throw TextTargetError.writeFailed }
                trace.recordReadError(
                    axReadDiagnosticCode(for: error),
                    elapsedMilliseconds: (writeTiming.now() &- start) / 1_000_000
                )
            }
            let now = writeTiming.now()
            guard now < deadline else { throw TextTargetError.writeFailed }
            try await writeTiming.sleep(min(10_000_000, deadline &- now))
        }
    }

    private func waitForAXWriteState(
        expectedElement: AXUIElement,
        element: AXUIElement,
        expectedDocument: String,
        requiredSelection: TextRange,
        allowedDocuments: [String],
        allowedSelections: [TextRange],
        phase: String,
        generation: UInt64,
        operationGeneration: UInt64,
        trace: inout AXWriteAcknowledgementTrace,
        lastObserved: inout AXWritableState?,
        start: UInt64
    ) async throws -> AXWritableState {
        let deadline = start &+ acknowledgementTimeoutNanoseconds
        while true {
            try Task.checkCancellation()
            guard generation == axWriteGeneration,
                  operationGeneration == keyboardOperationGeneration else {
                throw CancellationError()
            }
            try checkAXWriteIdentity(expectedElement, generation: generation)
            do {
                let observed = try readAXWritableState(in: element)
                lastObserved = observed
                try checkAXWriteIdentity(expectedElement, generation: generation)
                let matches = observed.text == expectedDocument && observed.selection == requiredSelection
                trace.recordRead(
                    AXWriteStateEvidence(
                        axValueLengthUTF16: observed.text.utf16.count,
                        selectionLocation: observed.selection.location,
                        selectionLength: observed.selection.length,
                        targetIdentityMatches: true
                    ),
                    matches: matches
                )
                guard writeTiming.now() < deadline else { throw TextTargetError.writeFailed }
                if matches { return observed }
                guard allowedDocuments.contains(observed.text),
                      allowedSelections.contains(observed.selection) else {
                    recordDiagnostic("ax_selection_mismatch", [
                        "failureStage": phase,
                        "expectedLocation": String(requiredSelection.location),
                        "expectedLength": String(requiredSelection.length),
                        "actualLocation": String(observed.selection.location),
                        "actualLength": String(observed.selection.length),
                        "axValueLengthUTF16": String(observed.text.utf16.count)
                    ])
                    throw TextTargetError.targetChanged
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TextTargetError {
                throw error
            } catch {
                guard isTransientAXReadError(error) else { throw TextTargetError.writeFailed }
                trace.recordReadError(
                    axReadDiagnosticCode(for: error),
                    elapsedMilliseconds: (writeTiming.now() &- start) / 1_000_000
                )
            }
            let now = writeTiming.now()
            guard now < deadline else { throw TextTargetError.writeFailed }
            try await writeTiming.sleep(min(10_000_000, deadline &- now))
        }
    }

    private func isTransientAXReadError(_ error: Error) -> Bool {
        if let error = error as? KeyboardWriteReadError, error == .retryable { return true }
        if let error = error as? AXAttributeReadFailure {
            return error.status == AXError.cannotComplete.rawValue
        }
        return false
    }

    private func axReadDiagnosticCode(for error: Error) -> String {
        if error is KeyboardWriteReadError { return "ax_read_retryable" }
        return DiagnosticErrorFormatter.code(for: error)
    }

    func writeKeyboardText(previousText: String, with text: String) async throws {
        safariStrategyRetryDiagnosticRecorded = false
        safariStrategyRetryIsPending = false
        safariStrategyMismatchStartedAt = nil
        keyboardTargetReacquireRetryDiagnosticRecorded = false
        keyboardTargetReacquireRetryIsPending = false
        guard requiresKeyboardAcknowledgement else {
            if previousText.isEmpty {
                try paste(text)
            } else {
                try replaceTrailingText(previousText, with: text)
            }
            return
        }

        let generation = keyboardGeneration
        try await waitForConfirmedKeyboardState(generation: generation)
        try Task.checkCancellation()
        guard generation == keyboardGeneration else { throw CancellationError() }
        try await waitForSafeKeyboardTargetIdentity(generation: generation)
        try Task.checkCancellation()
        guard generation == keyboardGeneration else { throw CancellationError() }
        try await waitForKeyboardSelectionStabilization(generation: generation)
        try Task.checkCancellation()
        guard generation == keyboardGeneration else { throw CancellationError() }
        if previousText.isEmpty {
            try submitPaste(text, selectionAlreadyStabilized: true)
        } else {
            try submitTrailingReplacement(previousText, with: text, selectionAlreadyStabilized: true)
        }
        try await acknowledgeKeyboardWrite()
    }

    private func waitForKeyboardSelectionStabilization(generation: UInt64) async throws {
        let start = writeTiming.now()
        while true {
            try Task.checkCancellation()
            guard generation == keyboardGeneration else { throw CancellationError() }
            do {
                try stabilizeKeyboardSelectionBeforeDispatch()
                return
            } catch KeyboardWriteReadError.retryable, KeyboardDocumentStateReadError.retryable {
                if !safariStrategyRetryIsPending {
                    recordDiagnostic("keyboard_state_read_retryable", ["phase": "selection_stabilization"])
                }
                safariStrategyRetryIsPending = false
            }

            let elapsed = writeTiming.now() &- start
            guard elapsed < preflightTimeoutNanoseconds else {
                throw TextTargetError.writeFailed
            }
            try await writeTiming.sleep(min(10_000_000, preflightTimeoutNanoseconds - elapsed))
        }
    }

    /// A readable AX caret is not necessarily the caret that the web editor
    /// will use for the next synthetic keyboard event.  This is observable
    /// at a paragraph boundary: the selection read before dispatch can be
    /// stable while the insertion is applied on the other side of the
    /// separator.  For native targets with a writable AX range, reseat that
    /// already-confirmed caret and read the complete state back before
    /// creating the receipt. Web editors use keyboard-owned selection instead
    /// because an AX range write may not move the page's actual caret.
    private func stabilizeKeyboardSelectionBeforeDispatch() throws {
        if usesKeyboardOwnedSelection {
            // Web editors may report an AX range write as successful without
            // moving the page's actual selection. The acknowledged preflight
            // already checked the observed document and caret; avoid changing
            // selection through AX and let keyboard events establish ranges
            // that are verified before replacement.
            try ensureKeyboardTargetIdentityIsSafe()
            recordDiagnostic("keyboard_selection_stabilization_skipped", [
                "reason": "web_selection_is_keyboard_owned"
            ])
            return
        }
        guard requiresKeyboardAcknowledgement,
              let targetElement,
              selectedTextRangeIsSettable(on: targetElement),
              let expected = currentConfirmedKeyboardState() else {
            return
        }

        try ensureKeyboardTargetIdentityIsSafe()
        let before = try keyboardDocumentState(in: targetElement, confirming: true)
        guard before.compare(to: expected, allowingStructuralRawDifference: false) == .matched else {
            invalidateKeyboardRawInsertionRegion()
            recordDiagnostic("keyboard_selection_stabilization_failed", [
                "phase": "before_set",
                "comparison": before.compare(to: expected, allowingStructuralRawDifference: false).rawValue
            ])
            throw TextTargetError.targetChanged
        }

        let axSelectionRequestID = try setSelection(expected.selection, on: targetElement)
        let after = try keyboardDocumentState(in: targetElement, confirming: true)
        let comparison = after.compare(to: expected, allowingStructuralRawDifference: false)
        guard comparison == .matched else {
            invalidateKeyboardRawInsertionRegion()
            recordDiagnostic("keyboard_selection_stabilization_failed", [
                "phase": "after_set",
                "axSelectionRequestID": axSelectionRequestID,
                "comparison": comparison.rawValue,
                "expectedSelectionLocation": String(expected.selection.location),
                "actualSelectionLocation": String(after.selection.location),
                "actualSelectionLength": String(after.selection.length)
            ])
            throw TextTargetError.targetChanged
        }

        commitConfirmedKeyboardState(after)
        recordDiagnostic("keyboard_selection_stabilized", [
            "route": "ax_range",
            "axSelectionRequestID": axSelectionRequestID,
            "nextKeyboardOperationGeneration": String(keyboardOperationGeneration &+ 1),
            "axReadbackMonotonicNanoseconds": String(DispatchTime.now().uptimeNanoseconds),
            "selectionEffectObservation": "ax_readback_only_not_editor_internal_state",
            "selectionLocation": String(after.selection.location),
            "selectionLength": String(after.selection.length)
        ])
    }

    func paste(_ text: String) throws {
        try ensureKeyboardTargetIsSafe()
        try submitPaste(text)
    }

    private func submitPaste(_ text: String, selectionAlreadyStabilized: Bool = false) throws {
        if !selectionAlreadyStabilized {
            try stabilizeKeyboardSelectionBeforeDispatch()
        }
        keyboardOperationGeneration &+= 1
        let operationGeneration = keyboardOperationGeneration
        pendingKeyboardDiagnosticOperation = nil
        let operationRange = expectedKeyboardSelection
        let receipt: KeyboardDocumentState?
        do {
            receipt = try keyboardReceipt(
                replacing: operationRange,
                with: text,
                operationGeneration: operationGeneration
            )
        } catch {
            invalidateKeyboardRawInsertionRegion()
            throw error
        }
        do {
            try keyboardEventSender.send(text, processID: eventProcessID)
            recordDispatchedText(text, expectedDocument: receipt?.text, replacementRange: operationRange)
        } catch {
            pendingKeyboardRepresentationTransition = nil
            pendingKeyboardDiagnosticOperation = nil
            pendingKeyboardRawInsertionRegion = nil
            confirmedKeyboardRawInsertionRegion = nil
            throw error
        }
        lastKeyboardDispatch = writeTiming.now()
        if let receipt {
            pendingKeyboardWrite = receipt
            if let operationRange {
                pendingKeyboardDiagnosticOperation = KeyboardDiagnosticDiffOperation(
                    coordinateRange: operationRange,
                    insertedLengthUTF16: coordinateLength(forKeyboardText: text),
                    inputText: text,
                    operationGeneration: operationGeneration
                )
            }
            let fields = [
                "expectedLocation": String(receipt.selection.location),
                "expectedDocumentLength": String(receipt.text.utf16.count),
                "receiptRepresentationTransition": pendingKeyboardRepresentationTransition != nil
                    ? pendingKeyboardRepresentationTransition?.representation ?? "none"
                    : "none"
            ]
            recordDiagnostic("keyboard_write_submitted", fields)
            return
        }
        if let selection = expectedKeyboardSelection {
            expectedKeyboardSelection = TextRange(
                location: selection.location + text.utf16.count,
                length: 0
            )
        }
    }

    func replaceTrailingText(_ previousText: String, with text: String) throws {
        try ensureKeyboardTargetIsSafe()
        try submitTrailingReplacement(previousText, with: text)
    }

    private func submitTrailingReplacement(
        _ previousText: String,
        with text: String,
        selectionAlreadyStabilized: Bool = false
    ) throws {
        if !selectionAlreadyStabilized {
            try stabilizeKeyboardSelectionBeforeDispatch()
        }
        var completed = false
        defer {
            if !completed {
                invalidateKeyboardRawInsertionRegion()
            }
        }
        let previousCoordinateText = coordinateTextForConfirmedReplacement(previousText)
        let previousCoordinateLength = previousCoordinateText.utf16.count
        let insertionCoordinateLength = coordinateLength(forKeyboardText: text)
        let updatedSelection: TextRange?
        if let selection = expectedKeyboardSelection {
            guard selection.length == 0,
                  selection.location >= previousCoordinateLength else {
                throw TextTargetError.targetChanged
            }
            updatedSelection = TextRange(
                location: selection.location - previousCoordinateLength + insertionCoordinateLength,
                length: 0
            )
        } else {
            updatedSelection = nil
        }
        let replacementRange = expectedKeyboardSelection.map {
            TextRange(location: $0.location - previousCoordinateLength, length: previousCoordinateLength)
        }
        pendingKeyboardDiagnosticOperation = nil
        let operationGeneration = keyboardOperationGeneration &+ 1
        let receipt = try keyboardReceipt(
            replacing: replacementRange,
            with: text,
            previousText: previousText,
            operationGeneration: operationGeneration
        )
        if let receipt, let replacementRange, let document = confirmedKeyboardDocument {
            let selected = KeyboardDocumentState(
                text: document,
                selection: replacementRange,
                rawText: confirmedKeyboardRawText,
                mapping: confirmedKeyboardMapping
            )
            let originalSelection = expectedKeyboardSelection ?? TextRange(
                location: replacementRange.location + replacementRange.length,
                length: 0
            )
            keyboardOperationGeneration = operationGeneration
            let usesAXSelection = !usesKeyboardOwnedSelection && (targetElement.map {
                selectedTextRangeIsSettable(on: $0)
            } ?? false)
            if usesAXSelection, let targetElement {
                // The selected input strategy owns selection changes. Keyboard
                // routes must establish replacements with keyboard events and
                // confirm the selection before inserting text.
                try setSelection(replacementRange, on: targetElement)
            } else {
                try keyboardEventSender.selectTrailingText(previousText, processID: eventProcessID)
            }
            pendingKeyboardReplacement = PendingKeyboardReplacement(
                selected: selected,
                insertion: text,
                originalSelection: originalSelection,
                sessionGeneration: keyboardGeneration,
                operationGeneration: operationGeneration
            )
            pendingKeyboardWrite = receipt
            pendingKeyboardDiagnosticOperation = KeyboardDiagnosticDiffOperation(
                coordinateRange: replacementRange,
                insertedLengthUTF16: insertionCoordinateLength,
                inputText: text,
                operationGeneration: operationGeneration
            )
            recordDiagnostic("keyboard_selection_submitted", [
                "route": usesAXSelection ? "ax_range" : "keyboard",
                "expectedLocation": String(replacementRange.location),
                "expectedLength": String(replacementRange.length)
            ])
            completed = true
            return
        }
        try keyboardEventSender.replaceTrailingText(
            previousText,
            with: text,
            processID: eventProcessID
        )
        recordDispatchedText(text, expectedDocument: receipt?.text, replacementRange: replacementRange)
        lastKeyboardDispatch = writeTiming.now()
        if let receipt {
            pendingKeyboardWrite = receipt
            if let replacementRange {
                pendingKeyboardDiagnosticOperation = KeyboardDiagnosticDiffOperation(
                    coordinateRange: replacementRange,
                    insertedLengthUTF16: insertionCoordinateLength,
                    inputText: text,
                    operationGeneration: keyboardOperationGeneration
                )
            }
            recordDiagnostic("keyboard_write_submitted", ["expectedLocation": String(receipt.selection.location),
                "expectedDocumentLength": String(receipt.text.utf16.count), "replacementCharacters": String(previousText.count)])
            completed = true
            return
        }
        expectedKeyboardSelection = updatedSelection
        completed = true
    }

    private func waitForConfirmedKeyboardState(generation: UInt64) async throws {
        guard let expected = confirmedKeyboardState else {
            recordDiagnostic("keyboard_confirmed_state_unavailable")
            throw TextTargetError.writeFailed
        }
        _ = try await KeyboardWriteAcknowledgement.wait(
            for: expected,
            timeoutNanoseconds: preflightTimeoutNanoseconds,
            now: writeTiming.now,
            sleep: writeTiming.sleep
        ) {
            let observed = try self.readKeyboardDocumentObservation(
                generation: generation,
                phase: "preflight"
            )
            guard observed.state == expected else {
                self.recordDiagnostic("keyboard_confirmed_state_changed", [
                    "expectedDocumentLength": String(expected.text.utf16.count),
                    "actualDocumentLength": String(observed.state.text.utf16.count),
                    "expectedSelectionLocation": String(expected.selection.location),
                    "actualSelectionLocation": String(observed.state.selection.location)
                ])
                self.invalidateKeyboardRawInsertionRegion()
                throw TextTargetError.targetChanged
            }
            return observed.state
        }
    }

    private func readKeyboardDocumentObservation(
        generation: UInt64,
        phase: String
    ) throws -> AXKeyboardDocumentObservation {
        let requestedAt = Date()
        guard generation == keyboardGeneration else { throw CancellationError() }
        try ensureTargetApplicationIsFrontmost()
        let element = try focusedElement()
        if let targetElement, !CFEqual(element, targetElement) {
            guard isSafariWebEditor || isCodexTarget else {
                invalidateKeyboardRawInsertionRegion()
                throw TextTargetError.targetChanged
            }
            _ = try acceptKeyboardTargetRebuild(element, phase: "\(phase)_before_read")
            // Never use a snapshot produced by the previous handle after
            // accepting its replacement. The next bounded read starts with
            // the newly captured target identity.
            throw KeyboardWriteReadError.retryable
        } else if targetElement == nil {
            invalidateKeyboardRawInsertionRegion()
            throw TextTargetError.targetChanged
        }
        guard let targetElement, CFEqual(element, targetElement) else {
            invalidateKeyboardRawInsertionRegion()
            throw TextTargetError.targetChanged
        }
        guard let objectGeneration = targetElementObservationID else {
            invalidateKeyboardRawInsertionRegion()
            throw TextTargetError.targetChanged
        }
        let readStartedAt = Date()
        let readStartedMonotonic = writeTiming.now() / 1_000_000
        do {
            let state = try KeyboardWriteAcknowledgement.readObservation {
                try self.keyboardDocumentState(in: element, confirming: true)
            }
            try ensureTargetApplicationIsFrontmost()
            let afterElement = try focusedElement()
            if !CFEqual(afterElement, targetElement) {
                guard isSafariWebEditor || isCodexTarget else {
                    invalidateKeyboardRawInsertionRegion()
                    throw TextTargetError.targetChanged
                }
                let readFinishedAt = Date()
                let candidateGeneration = UUID().uuidString
                do {
                    _ = try acceptKeyboardTargetRebuild(
                        afterElement,
                        phase: "\(phase)_after_read",
                        candidateGeneration: candidateGeneration
                    )
                } catch {
                    let recoveryResult: String
                    if error is KeyboardWriteReadError {
                        recoveryResult = "temporarily_unavailable"
                    } else if let targetError = error as? TextTargetError, targetError == .targetChanged {
                        recoveryResult = "rejected"
                    } else {
                        recoveryResult = "failed"
                    }
                    recordDiagnostic("keyboard_document_observation_discarded", [
                        "phase": phase,
                        "reason": "focused_object_changed_during_read",
                        "readStartedObjectGeneration": objectGeneration,
                        "readFinishedObjectGeneration": candidateGeneration,
                        "readStartedAt": readStartedAt.ISO8601Format(),
                        "readFinishedAt": readFinishedAt.ISO8601Format(),
                        "readStartedMonotonicMilliseconds": String(readStartedMonotonic),
                        "sendState": pendingKeyboardWrite == nil ? "not_in_flight" : "sent_unconfirmed",
                        "confirmationResult": "discarded_old_object_snapshot",
                        "reacquireResult": recoveryResult
                    ])
                    throw error
                }
                recordDiagnostic("keyboard_document_observation_discarded", [
                    "phase": phase,
                    "reason": "focused_object_changed_during_read",
                    "readStartedObjectGeneration": objectGeneration,
                    "readFinishedObjectGeneration": candidateGeneration,
                    "readStartedAt": readStartedAt.ISO8601Format(),
                    "readFinishedAt": readFinishedAt.ISO8601Format(),
                    "readStartedMonotonicMilliseconds": String(readStartedMonotonic),
                    "sendState": pendingKeyboardWrite == nil ? "not_in_flight" : "sent_unconfirmed",
                    "confirmationResult": "discarded_old_object_snapshot",
                    "reacquireResult": "confirmed"
                ])
                // The text and caret above belong to the old element. Discard
                // both and re-read only after the replacement is installed.
                throw KeyboardWriteReadError.retryable
            }
            guard targetElementObservationID == objectGeneration else {
                // A generation changed while AX was being read. Do not let a
                // snapshot cross that boundary even when AX equality happens
                // to report the same handle again.
                let readFinishedAt = Date()
                recordDiagnostic("keyboard_document_observation_discarded", [
                    "phase": phase,
                    "reason": "object_generation_changed_during_read",
                    "readStartedObjectGeneration": objectGeneration,
                    "readFinishedObjectGeneration": targetElementObservationID ?? "unknown",
                    "readStartedAt": readStartedAt.ISO8601Format(),
                    "readFinishedAt": readFinishedAt.ISO8601Format(),
                    "readStartedMonotonicMilliseconds": String(readStartedMonotonic),
                    "sendState": pendingKeyboardWrite == nil ? "not_in_flight" : "sent_unconfirmed",
                    "confirmationResult": "discarded_old_object_snapshot"
                ])
                throw KeyboardWriteReadError.retryable
            }
            let readFinishedAt = Date()
            lastKeyboardObservationTiming = (
                requested: requestedAt,
                started: readStartedAt,
                finished: readFinishedAt,
                monotonicMilliseconds: readStartedMonotonic
            )
            let observation = AXKeyboardDocumentObservation(
                state: state,
                objectGeneration: objectGeneration,
                requestedAt: requestedAt,
                readStartedAt: readStartedAt,
                readFinishedAt: readFinishedAt,
                monotonicReadStartedMilliseconds: readStartedMonotonic
            )
            recordDiagnostic("keyboard_document_observed", [
                "phase": phase,
                "editorIdentityMeaning": "captured_handle_not_stable_editor_identity",
                "objectGeneration": objectGeneration,
                "readStartedObjectGeneration": objectGeneration,
                "readFinishedObjectGeneration": targetElementObservationID ?? "unknown",
                "requestedAt": requestedAt.ISO8601Format(),
                "readStartedAt": readStartedAt.ISO8601Format(),
                "readFinishedAt": readFinishedAt.ISO8601Format(),
                "readStartedMonotonicMilliseconds": String(readStartedMonotonic),
                "sendState": pendingKeyboardWrite == nil ? "not_in_flight" : "sent_unconfirmed",
                "confirmationResult": "observed_for_comparison",
                "coordinateMappingSource": state.mapping.map { String(describing: $0.source) } ?? "unavailable",
                "coordinateDocumentLengthUTF16": String(state.text.utf16.count),
                "rawDocumentLengthUTF16": String(state.rawText?.utf16.count ?? 0)
            ],
                textEvidence: documentEvidence(state, requested: requestedAt,
                    started: readStartedAt, monotonic: readStartedMonotonic))
            return observation
        } catch KeyboardWriteReadError.retryable {
            if !keyboardTargetReacquireRetryIsPending {
                recordDiagnostic("keyboard_state_read_retryable", [
                    "phase": phase,
                    "readStartedObjectGeneration": objectGeneration,
                    "readFinishedObjectGeneration": targetElementObservationID ?? "unknown",
                    "readStartedAt": readStartedAt.ISO8601Format(),
                    "readFinishedAt": Date().ISO8601Format(),
                    "readStartedMonotonicMilliseconds": String(readStartedMonotonic),
                    "sendState": pendingKeyboardWrite == nil ? "not_in_flight" : "sent_unconfirmed",
                    "confirmationResult": "not_confirmed"
                ])
            }
            keyboardTargetReacquireRetryIsPending = false
            throw KeyboardWriteReadError.retryable
        } catch KeyboardDocumentStateReadError.retryable,
                KeyboardDocumentStateReadError.unavailable {
            recordDiagnostic("keyboard_state_read_retryable", [
                "phase": phase,
                "readStartedObjectGeneration": objectGeneration,
                "readFinishedObjectGeneration": targetElementObservationID ?? "unknown",
                "readStartedAt": readStartedAt.ISO8601Format(),
                "readFinishedAt": Date().ISO8601Format(),
                "readStartedMonotonicMilliseconds": String(readStartedMonotonic),
                "sendState": pendingKeyboardWrite == nil ? "not_in_flight" : "sent_unconfirmed",
                "confirmationResult": "read_unavailable"
            ])
            throw KeyboardWriteReadError.retryable
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TextTargetError {
            throw error
        } catch {
            throw TextTargetError.targetChanged
        }
    }

    func acknowledgeKeyboardWrite() async throws {
        guard let receipt = pendingKeyboardWrite else { return }
        let generation = keyboardGeneration
        let operationGeneration = keyboardOperationGeneration
        let start = writeTiming.now()
        let pendingRepresentationTransition = pendingKeyboardRepresentationTransition
        let pendingRawInsertionRegion = pendingKeyboardRawInsertionRegion
        let diagnosticOperation = pendingKeyboardDiagnosticOperation
        let preWriteConfirmedState = confirmedKeyboardState
        var pendingInitialInsertionCalibration: (position: Int, state: KeyboardDocumentState)?
        var lastObservedObjectGeneration: String?
        var calibratedInitialInsertion = false
        var lastObservedState: KeyboardDocumentState?
        var lastComparison: KeyboardDocumentComparison?
        var usedRepresentationTransition = false
        var matchedRawInsertionRegion: KeyboardRawInsertionRegion?
        var matchedCandidateRegionWasResolved = false
        var attemptedAppendCaretRecovery = false
        let acknowledgementContext = diagnosticOperationContext ?? previousDiagnosticOperationContext
        var acknowledgementTrace = KeyboardAcknowledgementTrace(
            insertionPositionClass: pendingRepresentationTransition?.insertionPositionClass ?? "not_applicable",
            phase: pendingKeyboardReplacement == nil ? "post_dispatch" : "pre_dispatch"
        )
        let candidateCount = 1 + (pendingRepresentationTransition?.alternates.count ?? 0)
        let read = { () throws -> KeyboardDocumentState in
            do {
                let observation = try self.readKeyboardDocumentObservation(
                    generation: generation,
                    phase: "acknowledgement"
                )
                let observed = observation.state
                acknowledgementTrace.recordRead(self.keyboardStateEvidence(observed))
                lastObservedState = observed
                lastObservedObjectGeneration = observation.objectGeneration
                if self.enableExperimentalCodexCaretRecovery,
                   !attemptedAppendCaretRecovery,
                   self.shouldRecoverUnadvancedCodexAppendCaret(
                    expected: receipt,
                    observed: observed,
                    operation: diagnosticOperation
                   ) {
                    attemptedAppendCaretRecovery = true
                    try self.ensureKeyboardTargetIdentityIsSafe()
                    try self.keyboardEventSender.advanceCaretRight(processID: self.eventProcessID)
                    self.recordDiagnostic("keyboard_caret_recovery_submitted", [
                        "route": "right_arrow",
                        "reason": "exact_single_character_append_caret_did_not_advance",
                        "fromLocation": String(observed.selection.location),
                        "toLocation": String(receipt.selection.location)
                    ], context: acknowledgementContext)
                }
                guard self.targetElementObservationID == observation.objectGeneration else {
                    lastObservedObjectGeneration = nil
                    throw KeyboardWriteReadError.retryable
                }
                return observed
            } catch {
                acknowledgementTrace.recordReadError(
                    DiagnosticErrorFormatter.code(for: error),
                    elapsedMilliseconds: (self.writeTiming.now() - start) / 1_000_000
                )
                throw error
            }
        }
        let matches: (KeyboardDocumentState, KeyboardDocumentState) -> Bool = { expected, observed in
            matchedRawInsertionRegion = nil
            matchedCandidateRegionWasResolved = false
            var candidateStates = [expected]
            var candidateRegions: [KeyboardRawInsertionRegion?] = [pendingRawInsertionRegion]
            if let transition = pendingRepresentationTransition,
               transition.sessionGeneration == generation,
               transition.operationGeneration == operationGeneration {
                candidateStates.append(contentsOf: transition.alternates.map(\.state))
                candidateRegions.append(contentsOf: transition.alternates.map { $0.rawInsertionRegion })
            }
            let evaluated = KeyboardWriteConfirmation.evaluateCandidates(
                expectedCandidates: candidateStates,
                observed: observed,
                operation: diagnosticOperation,
                isCodexTarget: self.isCodexTarget,
                allowNewStructuralBoundary: self.lastKeyboardReadUsedStructuralFallback
            )
            var confirmedByInitialCalibration = false
            if !evaluated.matched,
               !calibratedInitialInsertion,
               let operation = diagnosticOperation,
               operation.operationGeneration == 1,
               operation.coordinateRange.length == 0,
               operation.inputText?.isEmpty == false,
               let before = preWriteConfirmedState,
               before.selection.length == 0,
               self.pendingKeyboardReplacement == nil,
               lastObservedObjectGeneration == self.targetElementObservationID,
               self.keyboardDiagnosticMappingIsValid(before),
               self.keyboardDiagnosticMappingIsValid(observed),
               let payload = operation.inputText,
               let position = self.uniqueInsertionPosition(
                   before: before.text,
                   inserting: payload,
                   observed: observed.text
               ),
               self.initialInsertionPreservesRawDocument(
                    baseline: before,
                    observed: observed,
                    coordinatePosition: position,
                    inserting: payload
               ),
               observed.selection == TextRange(
                   location: position + payload.utf16.count,
                   length: 0
               ) {
                if let pending = pendingInitialInsertionCalibration,
                   pending.position == position,
                   pending.state == observed {
                    calibratedInitialInsertion = true
                    confirmedByInitialCalibration = true
                    pendingInitialInsertionCalibration = nil
                    self.recordDiagnostic("keyboard_initial_insertion_position_calibrated", [
                        "positionUTF16": String(position),
                        "payloadLengthUTF16": String(payload.utf16.count),
                        "consecutiveMatchingReads": "2",
                        "reason": "unique_document_insertion_and_matching_caret",
                        "editorIdentityContinuous": "true"
                    ], context: acknowledgementContext)
                } else {
                    pendingInitialInsertionCalibration = (position, observed)
                }
            } else {
                pendingInitialInsertionCalibration = nil
            }
            let candidateMatches = candidateStates.indices.map {
                evaluated.matchedIndexes.contains($0)
            }
            lastComparison = confirmedByInitialCalibration ? .matched : evaluated.comparison
            if evaluated.matched, let matchedIndex = evaluated.matchedIndex {
                lastComparison = .matched
                matchedCandidateRegionWasResolved = true
                if matchedIndex > 0 {
                    usedRepresentationTransition = true
                    matchedRawInsertionRegion = candidateRegions[matchedIndex]
                } else {
                    // The primary state owns the pending anchor. An
                    // alternate may intentionally have no anchor; retaining
                    // the primary one in that case would steer the next
                    // write back to the wrong raw boundary.
                    matchedRawInsertionRegion = pendingRawInsertionRegion
                }
            }
            acknowledgementTrace.recordComparison(
                evidence: self.keyboardStateEvidence(observed),
                comparison: evaluated.comparison,
                candidateMatches: candidateMatches,
                observed: observed,
                expectedCandidates: candidateStates,
                candidateComparisons: evaluated.comparisons,
                operation: diagnosticOperation,
                mappingValid: self.keyboardDiagnosticMappingIsValid(observed),
                elapsedMilliseconds: (self.writeTiming.now() - start) / 1_000_000
            )
            return evaluated.matched || confirmedByInitialCalibration
        }
        do {
            let acknowledgedState: KeyboardDocumentState
            if let replacement = pendingKeyboardReplacement {
                acknowledgedState = try await KeyboardWriteAcknowledgement.replaceSelection(
                    selected: replacement.selected,
                    result: receipt,
                    matches: matches,
                    timeoutNanoseconds: acknowledgementTimeoutNanoseconds,
                    now: writeTiming.now,
                    sleep: writeTiming.sleep,
                    read: read
                ) {
                    acknowledgementTrace.beginPostDispatch()
                    lastObservedState = nil
                    lastComparison = nil
                    self.recordDiagnostic(
                        "keyboard_selection_acknowledged",
                        context: acknowledgementContext
                    )
                    try self.keyboardEventSender.replaceSelection(with: replacement.insertion, processID: self.eventProcessID)
                    self.recordDispatchedText(replacement.insertion, expectedDocument: receipt.text,
                                              replacementRange: replacement.selected.selection,
                                              context: acknowledgementContext)
                    self.replacementWasSent = true
                    self.lastKeyboardDispatch = self.writeTiming.now()
                    self.recordDiagnostic(
                        "keyboard_replacement_submitted",
                        context: acknowledgementContext
                    )
                }
            } else {
                acknowledgedState = try await KeyboardWriteAcknowledgement.wait(
                    for: receipt,
                    matches: matches,
                    timeoutNanoseconds: acknowledgementTimeoutNanoseconds,
                    now: writeTiming.now,
                    sleep: writeTiming.sleep,
                    read: read
                )
            }
            guard generation == keyboardGeneration else { throw CancellationError() }
            confirmedKeyboardDocument = acknowledgedState.text
            expectedKeyboardSelection = acknowledgedState.selection
            confirmedKeyboardRawText = acknowledgedState.rawText
            confirmedKeyboardMapping = acknowledgedState.mapping
            confirmedKeyboardState = acknowledgedState
            confirmedKeyboardRawInsertionRegion = matchedCandidateRegionWasResolved
                ? matchedRawInsertionRegion
                : pendingRawInsertionRegion
            pendingKeyboardWrite = nil
            pendingKeyboardDiagnosticOperation = nil
            pendingKeyboardRepresentationTransition = nil
            pendingKeyboardReplacement = nil
            pendingKeyboardRawInsertionRegion = nil
            replacementWasSent = false
            let acknowledgementFields = [
                "elapsedMilliseconds": String((writeTiming.now() - start) / 1_000_000),
                "documentMatches": "true", "selectionMatches": "true",
                "comparison": lastComparison?.rawValue ?? "matched",
                "observedLengthUTF16": String(acknowledgedState.text.utf16.count),
                "observedAXValueLengthUTF16": String(acknowledgedState.rawText?.utf16.count ?? 0),
                "receiptRepresentationTransition": usedRepresentationTransition
                    ? pendingRepresentationTransition?.representation ?? "none"
                    : "none"
            ]
            acknowledgementTrace.finalizeDiff(
                operation: diagnosticOperation,
                mappingValid: self.keyboardDiagnosticMappingIsValid(acknowledgedState)
            )
            let acknowledgementEvidence = acknowledgementTrace.fields(
                final: self.keyboardStateEvidence(acknowledgedState),
                finalComparison: lastComparison,
                candidateCount: candidateCount,
                insertionPositionClass: usedRepresentationTransition
                    ? pendingRepresentationTransition?.insertionPositionClass ?? "not_applicable"
                    : "not_applicable"
            )
            let mergedAcknowledgementFields = acknowledgementFields.merging(acknowledgementEvidence) { _, new in new }
            let timing = lastKeyboardObservationTiming
            let observedAt = timing?.finished ?? Date()
            var textEvidence: [DiagnosticTextEvidence] = []
            if let rawText = acknowledgedState.rawText {
                textEvidence.append(DiagnosticTextEvidence(
                    kind: .axValue, source: .observed, text: rawText,
                    revision: UInt64(acknowledgementContext?.fields["revision"] ?? ""),
                    operationID: acknowledgementContext.map { String($0.operationID) },
                    targetApplicationBundleIdentifier: targetApplicationBundleIdentifier,
                    targetApplicationProcessID: targetApplicationProcessID.map { Int32($0) },
                    editorIdentity: targetElementObservationID,
                    selectionLocationUTF16: acknowledgedState.selection.location,
                    selectionLengthUTF16: acknowledgedState.selection.length,
                    requestedAt: timing?.requested, readStartedAt: timing?.started, readFinishedAt: timing?.finished,
                    observedAt: observedAt,
                    monotonicMilliseconds: timing?.monotonicMilliseconds
                ))
            }
            if acknowledgedState.mapping?.source == .axStringForRange {
                textEvidence.append(DiagnosticTextEvidence(
                    kind: .axStringForRange, source: .observed, text: acknowledgedState.text,
                    revision: UInt64(acknowledgementContext?.fields["revision"] ?? ""),
                    operationID: acknowledgementContext.map { String($0.operationID) },
                    targetApplicationBundleIdentifier: targetApplicationBundleIdentifier,
                    targetApplicationProcessID: targetApplicationProcessID.map { Int32($0) },
                    editorIdentity: targetElementObservationID,
                    selectionLocationUTF16: acknowledgedState.selection.location,
                    selectionLengthUTF16: acknowledgedState.selection.length,
                    requestedAt: timing?.requested, readStartedAt: timing?.started, readFinishedAt: timing?.finished,
                    observedAt: observedAt,
                    monotonicMilliseconds: timing?.monotonicMilliseconds
                ))
            }
            recordDiagnostic("keyboard_write_acknowledged", mergedAcknowledgementFields,
                context: acknowledgementContext, textEvidence: textEvidence)
        } catch {
            let evidence: [String: String] = [
                "elapsedMilliseconds": String((writeTiming.now() - start) / 1_000_000),
                "readAttempts": String(acknowledgementTrace.readAttempts),
                "expectedDocumentLength": String(receipt.text.utf16.count),
                "expectedSelectionLocation": String(receipt.selection.location),
                "expectedSelectionLength": String(receipt.selection.length),
                "actualSelectionLocation": String(lastObservedState?.selection.location ?? -1),
                "actualSelectionLength": String(lastObservedState?.selection.length ?? -1)
            ]
            let failureFields = [
                "code": DiagnosticErrorFormatter.code(for: error),
                "comparison": lastComparison?.rawValue ?? "unreadable",
                "observedLengthUTF16": String(lastObservedState?.text.utf16.count ?? 0),
                "observedAXValueLengthUTF16": String(lastObservedState?.rawText?.utf16.count ?? 0),
                "receiptRepresentationTransition": pendingRepresentationTransition != nil
                    ? pendingRepresentationTransition?.representation ?? "none"
                    : "none"
            ]
            acknowledgementTrace.finalizeDiff(
                operation: diagnosticOperation,
                mappingValid: lastObservedState.map(self.keyboardDiagnosticMappingIsValid) ?? false
            )
            let failureEvidence = acknowledgementTrace.fields(
                final: lastObservedState.map(self.keyboardStateEvidence),
                finalComparison: lastComparison,
                candidateCount: candidateCount
            )
            let mergedFailureFields = evidence
                .merging(failureFields) { _, new in new }
                .merging(failureEvidence) { _, new in new }
            let textEvidence = lastObservedState.flatMap { observed -> [DiagnosticTextEvidence]? in
                guard let rawText = observed.rawText else { return nil }
                return [DiagnosticTextEvidence(
                    kind: .axValue, source: .observed, text: rawText,
                    revision: UInt64(acknowledgementContext?.fields["revision"] ?? ""),
                    operationID: acknowledgementContext.map { String($0.operationID) },
                    targetApplicationBundleIdentifier: targetApplicationBundleIdentifier,
                    targetApplicationProcessID: targetApplicationProcessID.map { Int32($0) },
                    editorIdentity: targetElementObservationID,
                    selectionLocationUTF16: observed.selection.location,
                    selectionLengthUTF16: observed.selection.length,
                    requestedAt: lastKeyboardObservationTiming?.requested,
                    readStartedAt: lastKeyboardObservationTiming?.started,
                    readFinishedAt: lastKeyboardObservationTiming?.finished,
                    observedAt: lastKeyboardObservationTiming?.finished,
                    monotonicMilliseconds: lastKeyboardObservationTiming?.monotonicMilliseconds
                )]
            } ?? []
            recordDiagnostic("keyboard_write_unconfirmed", mergedFailureFields,
                context: acknowledgementContext, textEvidence: textEvidence)
            pendingKeyboardDiagnosticOperation = nil
            pendingKeyboardRepresentationTransition = nil
            pendingKeyboardRawInsertionRegion = nil
            confirmedKeyboardRawInsertionRegion = nil
            recoverPendingSelectionIfSafe(generation: generation)
            throw error
        }
    }

    private func keyboardReceipt(replacing range: TextRange?, with text: String,
                                 previousText: String? = nil,
                                 operationGeneration: UInt64? = nil) throws -> KeyboardDocumentState? {
        pendingKeyboardRepresentationTransition = nil
        pendingKeyboardRawInsertionRegion = nil
        guard requiresKeyboardAcknowledgement else { return nil }
        guard let range, let document = confirmedKeyboardDocument,
              range.location >= 0, range.length >= 0,
              range.location <= document.utf16.count,
              range.length <= document.utf16.count - range.location else { throw TextTargetError.targetChanged }
        let nsRange = NSRange(location: range.location, length: range.length)
        let previousCoordinateTexts = isCodexTarget
            ? coordinateTextCandidates(forKeyboardText: previousText ?? "")
            : [coordinateText(forKeyboardText: previousText ?? "")]
        if previousText != nil,
           !previousCoordinateTexts.contains(where: {
               (document as NSString).substring(with: nsRange) == $0
           }) {
            throw TextTargetError.targetChanged
        }
        let coordinateTexts = isCodexTarget
            ? coordinateTextCandidates(forKeyboardText: text)
            : [coordinateText(forKeyboardText: text)]
        var rawDocumentForTransition: String?
        var rawRangesForTransition: [TextRange]?
        var mappingForTransition: AXTextCoordinateMapping?
        var anchoredReplacement: KeyboardRawInsertionUpdate?
        var candidateStates: [KeyboardRepresentationCandidate] = []
        if isCodexTarget {
            guard let rawDocument = confirmedKeyboardRawText,
                  let mapping = confirmedKeyboardMapping else {
                throw TextTargetError.targetChanged
            }
            anchoredReplacement = anchoredRawReplacement(
                in: rawDocument,
                range: range,
                with: text,
                operationGeneration: operationGeneration ?? keyboardOperationGeneration
            )
            let rawRanges: [TextRange]
            let compatibleRanges = mapping.rawRangeCandidates(for: range)
            guard !compatibleRanges.isEmpty else { throw TextTargetError.targetChanged }
            if let anchoredReplacement {
                // A previously confirmed insertion region is the only
                // permitted primary anchor. Every other range remains in the
                // same complete alignment graph so the post-write
                // observation, rather than a rightmost heuristic, selects it.
                rawRanges = [anchoredReplacement.rawRange]
                    + compatibleRanges.filter { $0 != anchoredReplacement.rawRange }
            } else {
                // No boundary has been confirmed yet. Preserve the complete
                // set in graph order; confirmation must find exactly one
                // matching candidate before it can become the next anchor.
                rawRanges = compatibleRanges
            }
            guard !rawRanges.isEmpty else { throw TextTargetError.targetChanged }

            for coordinateText in coordinateTexts {
                let result = NSMutableString(string: document)
                result.replaceCharacters(in: nsRange, with: coordinateText)
                for rawRange in rawRanges {
                    guard rawRange.location >= 0,
                          rawRange.length >= 0,
                          rawRange.location <= rawDocument.utf16.count,
                          rawRange.length <= rawDocument.utf16.count - rawRange.location else {
                        continue
                    }
                    let raw = NSMutableString(string: rawDocument)
                    raw.replaceCharacters(
                        in: NSRange(location: rawRange.location, length: rawRange.length),
                        with: text
                    )
                    let rawText = raw as String
                    let selection = TextRange(
                        location: range.location + coordinateText.utf16.count,
                        length: 0
                    )
                    guard let candidateMapping = expectedKeyboardMapping(
                        rawText: rawText,
                        coordinateText: result as String,
                        selection: selection
                    ) else {
                        continue
                    }
                    let insertionRegion: KeyboardRawInsertionRegion?
                    if let anchoredReplacement,
                       rawRange == anchoredReplacement.rawRange {
                        insertionRegion = anchoredReplacement.nextRegion
                    } else {
                        insertionRegion = derivedRawInsertionRegion(
                            rawText: rawText,
                            rawRange: rawRange,
                            coordinateRange: range,
                            selection: selection,
                            inputText: text,
                            operationGeneration: operationGeneration ?? keyboardOperationGeneration
                        )
                    }
                    let candidate = KeyboardRepresentationCandidate(
                        state: KeyboardDocumentState(
                            text: result as String,
                            selection: selection,
                            rawText: rawText,
                            mapping: candidateMapping
                        ),
                        rawOperationRange: rawRange,
                        rawInsertionRegion: insertionRegion
                    )
                    guard candidateStates.allSatisfy({
                        !sameKeyboardRepresentationCandidate($0, candidate)
                    }) else {
                        continue
                    }
                    candidateStates.append(candidate)
                }
            }
            guard !candidateStates.isEmpty else { throw TextTargetError.targetChanged }

            // Keep the old deterministic choice for diagnostics and for code
            // that only consumes the primary receipt. The acknowledgement
            // path also receives every other compatible raw representation.
            if let anchoredReplacement,
               let index = candidateStates.firstIndex(where: {
                   $0.state.rawText == {
                       let raw = NSMutableString(string: rawDocument)
                       raw.replaceCharacters(
                           in: NSRange(
                               location: anchoredReplacement.rawRange.location,
                               length: anchoredReplacement.rawRange.length
                           ),
                           with: text
                       )
                       return raw as String
                   }()
               }) {
                candidateStates.insert(candidateStates.remove(at: index), at: 0)
            }
            rawDocumentForTransition = rawDocument
            let transitionRanges = mapping.rawRangeCandidates(for: range)
            rawRangesForTransition = anchoredReplacement.map { [$0.rawRange] } ?? transitionRanges
            mappingForTransition = mapping
        } else {
            rawDocumentForTransition = nil
            rawRangesForTransition = nil
            mappingForTransition = nil
        }

        let primary: KeyboardDocumentState
        if isCodexTarget {
            guard let first = candidateStates.first else { throw TextTargetError.targetChanged }
            primary = first.state
        } else {
            let coordinateText = coordinateText(forKeyboardText: text)
            let result = NSMutableString(string: document)
            result.replaceCharacters(in: nsRange, with: coordinateText)
            primary = KeyboardDocumentState(
                text: result as String,
                selection: TextRange(
                    location: range.location + coordinateText.utf16.count,
                    length: 0
                ),
                rawText: nil,
                mapping: nil
            )
        }

        var alternates = isCodexTarget
            ? Array(candidateStates.dropFirst())
            : []
        if previousText == nil,
           let rawDocumentForTransition,
           let rawRangesForTransition,
           let mappingForTransition {
            let structuralAlternates = AXTextStructuralTransitionModel.candidates(
                document: document,
                range: range,
                text: text,
                rawDocument: rawDocumentForTransition,
                rawRanges: rawRangesForTransition,
                mapping: mappingForTransition
            )
            for alternate in structuralAlternates {
                let structuralInsertionRegion: KeyboardRawInsertionRegion?
                if alternate.rawInsertionSeparatorLength > 0,
                   let rawOperationRange = alternate.rawOperationRange {
                    let generation = operationGeneration ?? keyboardOperationGeneration
                    structuralInsertionRegion = KeyboardRawInsertionRegion(
                        sessionGeneration: keyboardGeneration,
                        operationGeneration: generation,
                        coordinateRange: TextRange(
                            location: range.location,
                            length: text.utf16.count
                        ),
                        rawRange: TextRange(
                            location: rawOperationRange.location,
                            length: text.utf16.count
                        ),
                        separatorLength: alternate.rawInsertionSeparatorLength
                    )
                } else {
                    structuralInsertionRegion = nil
                }
                let candidate = KeyboardRepresentationCandidate(
                    state: KeyboardDocumentState(
                        text: alternate.document.text,
                        selection: alternate.document.selection,
                        rawText: alternate.document.rawText,
                        mapping: alternate.document.mapping
                    ),
                    rawOperationRange: alternate.rawOperationRange,
                    rawInsertionRegion: structuralInsertionRegion
                )
                guard candidateStates.allSatisfy({
                    !sameKeyboardRepresentationCandidate($0, candidate)
                }),
                alternates.allSatisfy({
                    !sameKeyboardRepresentationCandidate($0, candidate)
                }) else { continue }
                alternates.append(candidate)
            }
        }
        if isCodexTarget {
            let generation = operationGeneration ?? keyboardOperationGeneration
            func attachInsertionRegion(
                _ candidate: KeyboardRepresentationCandidate
            ) -> KeyboardRepresentationCandidate {
                guard candidate.rawInsertionRegion == nil,
                      candidate.rawOperationRange != anchoredReplacement?.rawRange,
                      let rawOperationRange = candidate.rawOperationRange,
                      let rawText = candidate.state.rawText,
                      let region = derivedRawInsertionRegion(
                          rawText: rawText,
                          rawRange: rawOperationRange,
                          coordinateRange: range,
                          selection: candidate.state.selection,
                          inputText: text,
                          operationGeneration: generation
                      ) else {
                    return candidate
                }
                return KeyboardRepresentationCandidate(
                    state: candidate.state,
                    rawOperationRange: candidate.rawOperationRange,
                    rawInsertionRegion: region
                )
            }
            candidateStates = candidateStates.map(attachInsertionRegion)
            alternates = alternates.map(attachInsertionRegion)
            pendingKeyboardRawInsertionRegion = candidateStates.first?.rawInsertionRegion
        }
        if !alternates.isEmpty {
            let hasGenericBoundaryAmbiguity = candidateStates.count > 1
            pendingKeyboardRepresentationTransition = PendingKeyboardRepresentationTransition(
                alternates: alternates,
                representation: hasGenericBoundaryAmbiguity
                    ? "raw_boundary_candidates"
                    : structuralRepresentationKind(
                        document: document,
                        range: range
                    ),
                insertionPositionClass: hasGenericBoundaryAmbiguity
                    ? "ambiguous_raw_boundary"
                    : structuralInsertionPositionClass(
                        document: document,
                        range: range
                    ),
                sessionGeneration: keyboardGeneration,
                operationGeneration: operationGeneration ?? keyboardOperationGeneration
            )
        }
        return primary
    }

    private func shouldRecoverUnadvancedCodexAppendCaret(
        expected: KeyboardDocumentState,
        observed: KeyboardDocumentState,
        operation: KeyboardDiagnosticDiffOperation?
    ) -> Bool {
        guard isCodexTarget,
              let operation,
              let inputText = operation.inputText,
              inputText.count == 1,
              inputText.utf16.count == 1,
              operation.coordinateRange.length == 0,
              expected.text == observed.text,
              expected.rawText == observed.rawText,
              expected.selection.length == 0,
              expected.selection.location == expected.text.utf16.count,
              observed.selection.length == 0,
              observed.selection.location == operation.coordinateRange.location,
              expected.selection.location == observed.selection.location + 1,
              keyboardDiagnosticMappingIsValid(observed),
              observed.matchesExpectedMapping(of: expected) else {
            return false
        }
        return true
    }

    private func expectedKeyboardMapping(
        rawText: String,
        coordinateText: String,
        selection: TextRange
    ) -> AXTextCoordinateMapping? {
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
        resolved.text == coordinateText,
        resolved.selection == selection,
        AXTextDocumentResolver.isValidCoordinateMapping(
            resolved.mapping,
            rawText: rawText,
            coordinateText: coordinateText
        ) else {
            return nil
        }
        return resolved.mapping
    }

    private func derivedRawInsertionRegion(
        rawText: String,
        rawRange: TextRange,
        coordinateRange: TextRange,
        selection: TextRange,
        inputText: String,
        operationGeneration: UInt64
    ) -> KeyboardRawInsertionRegion? {
        guard !inputText.isEmpty,
              operationGeneration > 0,
              rawRange.location >= 0,
              rawRange.length >= 0,
              rawRange.location <= rawText.utf16.count,
              rawRange.length <= rawText.utf16.count - rawRange.location,
              coordinateRange.location >= 0,
              coordinateRange.length >= 0,
              selection.length == 0,
              selection.location >= coordinateRange.location else {
            return nil
        }

        let rawLength = inputText.utf16.count
        guard rawRange.location + rawLength <= rawText.utf16.count else {
            return nil
        }
        let insertedRawText = (rawText as NSString).substring(
            with: NSRange(location: rawRange.location, length: rawLength)
        )
        guard insertedRawText == inputText else { return nil }

        return KeyboardRawInsertionRegion(
            sessionGeneration: keyboardGeneration,
            operationGeneration: operationGeneration,
            coordinateRange: TextRange(
                location: coordinateRange.location,
                length: selection.location - coordinateRange.location
            ),
            rawRange: TextRange(location: rawRange.location, length: rawLength),
            separatorLength: 0
        )
    }

    private func anchoredRawReplacement(
        in rawDocument: String,
        range: TextRange,
        with text: String,
        operationGeneration: UInt64
    ) -> KeyboardRawInsertionUpdate? {
        guard let region = confirmedKeyboardRawInsertionRegion,
              region.sessionGeneration == keyboardGeneration,
              region.operationGeneration > 0,
              region.operationGeneration <= keyboardOperationGeneration,
              !AXTextStructural.containsStructuralSeparator(in: text),
              region.coordinateRange.location >= 0,
              region.coordinateRange.length >= 0,
              region.rawRange.location >= 0,
              region.rawRange.length == region.coordinateRange.length,
              range.location >= region.coordinateRange.location,
              range.length >= 0,
              range.location <= region.coordinateRange.location + region.coordinateRange.length,
              range.length <= region.coordinateRange.location + region.coordinateRange.length - range.location,
              isUTF16ScalarBoundary(range.location, in: confirmedKeyboardDocument ?? ""),
              isUTF16ScalarBoundary(range.location + range.length, in: confirmedKeyboardDocument ?? "") else {
            return nil
        }
        if region.separatorLength > 0,
           structuralMarker(
               in: rawDocument,
               after: region.rawRange,
               length: region.separatorLength
           ) == nil {
            return nil
        }

        let relativeLocation = range.location - region.coordinateRange.location
        let rawRange = TextRange(
            location: region.rawRange.location + relativeLocation,
            length: range.length
        )
        guard rawRange.location >= region.rawRange.location,
              rawRange.location + rawRange.length <= region.rawRange.location + region.rawRange.length else {
            return nil
        }

        let nextCoordinateLength = region.coordinateRange.length - range.length + text.utf16.count
        let nextRawLength = region.rawRange.length - range.length + text.utf16.count
        let nextRegion: KeyboardRawInsertionRegion? = nextRawLength > 0
            ? KeyboardRawInsertionRegion(
                sessionGeneration: region.sessionGeneration,
                operationGeneration: operationGeneration,
                coordinateRange: TextRange(
                    location: region.coordinateRange.location,
                    length: nextCoordinateLength
                ),
                rawRange: TextRange(
                    location: region.rawRange.location,
                    length: nextRawLength
                ),
                separatorLength: region.separatorLength
            )
            : nil
        return KeyboardRawInsertionUpdate(rawRange: rawRange, nextRegion: nextRegion)
    }

    private func structuralMarker(
        in rawDocument: String,
        after rawRange: TextRange,
        length: Int
    ) -> String? {
        guard length > 0,
              rawRange.location >= 0,
              rawRange.length >= 0,
              rawRange.location + rawRange.length + length <= rawDocument.utf16.count else {
            return nil
        }
        let markerRange = TextRange(
            location: rawRange.location + rawRange.length,
            length: length
        )
        let units = structuralUnitRanges(in: rawDocument, within: markerRange)
        guard units.count >= 2,
              let first = units.first else {
            return nil
        }
        let firstText = (rawDocument as NSString).substring(
            with: NSRange(location: first.location, length: first.length)
        )
        guard units.dropFirst().allSatisfy({ unit in
            (rawDocument as NSString).substring(
                with: NSRange(location: unit.location, length: unit.length)
            ) == firstText
        }) else {
            return nil
        }
        return String(repeating: firstText, count: units.count)
    }

    private func structuralRepresentationKind(document: String, range: TextRange) -> String {
        if range.length == 0,
           range.location == document.utf16.count,
           trailingStructuralUnit(in: document) != nil {
            return KeyboardReceiptRepresentation.trailingNewlineCollapsed
        }
        guard let run = structuralRun(containing: range.location, in: document),
              let region = structuralRegion(for: run, documentLength: document.utf16.count) else {
            return KeyboardReceiptRepresentation.emptyParagraphMarkerCollapsed
        }
        return region == .trailing
            ? KeyboardReceiptRepresentation.trailingNewlineCollapsed
            : KeyboardReceiptRepresentation.emptyParagraphMarkerCollapsed
    }

    private func structuralInsertionPositionClass(document: String, range: TextRange) -> String {
        if range.length == 0,
           range.location == document.utf16.count,
           trailingStructuralUnit(in: document) != nil {
            return "terminal_after_trailing_newline"
        }
        guard let run = structuralRun(containing: range.location, in: document),
              let region = structuralRegion(for: run, documentLength: document.utf16.count) else {
            return "not_empty_paragraph"
        }
        switch region {
        case .trailing:
            return trailingNewlineInsertionPositionClass(document: document, range: range)
        case .leading:
            return "leading_empty_paragraph"
        case .interior:
            return "interior_empty_paragraph"
        }
    }

    private func trailingNewlineInsertionPositionClass(document: String, range: TextRange) -> String {
        guard range.length == 0,
              let run = structuralRun(containing: range.location, in: document),
              structuralRegion(for: run, documentLength: document.utf16.count) == .trailing else {
            return "not_trailing_newline"
        }
        let unitStarts = structuralUnitRanges(
            in: document,
            within: TextRange(location: run.start, length: run.end - run.start)
        ).map(\.location)
        guard let offset = unitStarts.firstIndex(of: range.location) else {
            return "not_trailing_newline"
        }
        if offset == 0 { return "first_trailing_newline" }
        if offset == unitStarts.count - 1 { return "last_trailing_newline" }
        if offset == unitStarts.count - 2 { return "second_last_trailing_newline" }
        return "middle_trailing_newline"
    }

    private enum EmptyParagraphRegion: Equatable {
        case leading
        case interior
        case trailing
    }

    private struct StructuralRun {
        let start: Int
        let end: Int
        let unitCount: Int

        var count: Int { unitCount }
    }

    private func structuralUnitRange(startingAt location: Int, in text: String) -> TextRange? {
        AXTextStructural.structuralUnitRange(startingAt: location, in: text)
    }

    private func structuralRun(containing location: Int, in text: String) -> StructuralRun? {
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
              structuralUnitRange(startingAt: location, in: text) != nil,
              AXTextStructural.isStructuralSeparator(at: scalarIndex, in: scalars) else {
            return nil
        }
        var startIndex = scalarIndex
        while startIndex > 0,
              AXTextStructural.isStructuralSeparator(at: startIndex - 1, in: scalars) {
            startIndex -= 1
        }
        var endIndex = scalarIndex + 1
        while endIndex < scalars.count,
              AXTextStructural.isStructuralSeparator(at: endIndex, in: scalars) {
            endIndex += 1
        }
        let run = TextRange(
            location: offsets[startIndex],
            length: offsets[endIndex] - offsets[startIndex]
        )
        return StructuralRun(
            start: run.location,
            end: run.location + run.length,
            unitCount: structuralUnitRanges(in: text, within: run).count
        )
    }

    private func structuralUnitRanges(in text: String, within range: TextRange) -> [TextRange] {
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= text.utf16.count else {
            return []
        }
        var result: [TextRange] = []
        var offset = range.location
        let end = range.location + range.length
        while offset < end {
            guard let unit = structuralUnitRange(startingAt: offset, in: text),
                  unit.location + unit.length <= end else {
                return []
            }
            result.append(unit)
            offset += unit.length
        }
        return result
    }

    private func trailingStructuralUnit(in text: String) -> TextRange? {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        var offsets = [0]
        offsets.reserveCapacity(scalars.count + 1)
        var offset = 0
        for scalar in scalars {
            offset += scalar.utf16.count
            offsets.append(offset)
        }
        guard let lastScalar = scalars.indices.last,
              AXTextStructural.isStructuralSeparator(at: lastScalar, in: scalars) else {
            return nil
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

    private func structuralRegion(
        for run: StructuralRun,
        documentLength: Int
    ) -> EmptyParagraphRegion? {
        guard run.count > 0 else { return nil }
        if run.end == documentLength {
            return .trailing
        }
        if run.start == 0 {
            return .leading
        }
        return .interior
    }

    private func isEligibleStructuralRun(
        _ run: StructuralRun,
        documentLength: Int
    ) -> Bool {
        guard let region = structuralRegion(for: run, documentLength: documentLength) else {
            return false
        }
        switch region {
        case .leading, .trailing:
            return run.count >= 1
        case .interior:
            // A single separator can become a multi-unit AX marker after a
            // write. The post-write alignment and local diff decide whether
            // the additional units are valid; do not reject the transition
            // merely because the pre-write run had one unit.
            return run.count >= 1
        }
    }

    private func keyboardStateEvidence(_ state: KeyboardDocumentState) -> KeyboardStateEvidence {
        let mappingValid = KeyboardWriteConfirmation.mappingIsValid(
            state,
            isCodexTarget: isCodexTarget
        )
        return KeyboardStateEvidence(
            coordinateLengthUTF16: state.text.utf16.count,
            axValueLengthUTF16: state.rawText?.utf16.count ?? 0,
            selectionLocation: state.selection.location,
            selectionLength: state.selection.length,
            coordinateTrailingNewlineCount: trailingNewlineCount(in: state.text),
            axValueTrailingNewlineCount: trailingNewlineCount(in: state.rawText ?? ""),
            mappingValid: mappingValid
        )
    }

    private func keyboardDiagnosticMappingIsValid(_ state: KeyboardDocumentState) -> Bool {
        KeyboardWriteConfirmation.mappingIsValid(
            state,
            isCodexTarget: isCodexTarget
        )
    }

    private func trailingNewlineCount(in text: String) -> Int {
        let units = Array(text.utf16)
        var count = 0
        for unit in units.reversed() {
            guard unit == 0x0A else { break }
            count += 1
        }
        return count
    }

    private func isUTF16ScalarBoundary(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf16.count else { return false }
        guard offset > 0, offset < text.utf16.count else { return true }
        let units = Array(text.utf16)
        let previous = units[offset - 1]
        let current = units[offset]
        let isHighSurrogate = (0xD800...0xDBFF).contains(previous)
        let isLowSurrogate = (0xDC00...0xDFFF).contains(current)
        return !(isHighSurrogate && isLowSurrogate)
    }

    private func coordinateLength(forKeyboardText text: String) -> Int {
        if isCodexTarget {
            return coordinateTextCandidates(forKeyboardText: text).first?.utf16.count
                ?? text.utf16.count
        }
        return coordinateText(forKeyboardText: text).utf16.count
    }

    private func coordinateTextForConfirmedReplacement(_ text: String) -> String {
        guard isCodexTarget else { return coordinateText(forKeyboardText: text) }
        guard let document = confirmedKeyboardDocument,
              let selection = expectedKeyboardSelection else {
            return coordinateText(forKeyboardText: text)
        }
        return coordinateTextCandidates(forKeyboardText: text).first { candidate in
            guard candidate.utf16.count <= selection.location else { return false }
            let range = NSRange(
                location: selection.location - candidate.utf16.count,
                length: candidate.utf16.count
            )
            return document.utf16.count >= range.location + range.length
                && (document as NSString).substring(with: range) == candidate
        } ?? coordinateText(forKeyboardText: text)
    }

    private func coordinateTextCandidates(forKeyboardText text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var structuralRuns: [(start: Int, end: Int)] = []
        var index = 0
        while index < scalars.count {
            guard AXTextStructural.isStructuralSeparator(at: index, in: scalars) else {
                index += 1
                continue
            }
            let start = index
            repeat { index += 1 } while index < scalars.count
                && AXTextStructural.isStructuralSeparator(at: index, in: scalars)
            structuralRuns.append((start, index))
        }
        guard !structuralRuns.isEmpty else { return [text] }

        // A payload normally has only a small number of line separators. For
        // that local universe retain every representation formed by keeping or
        // omitting complete structural runs. A very large payload is kept
        // bounded by also testing each complete run and the all-omitted form;
        // an unbounded candidate set is never allowed to turn a write into an
        // implicit guess. In particular, CRLF is never split into a guessed
        // lone CR or lone LF representation.
        var variants = [text]
        if structuralRuns.count <= 8 {
            for mask in 1..<(1 << structuralRuns.count) {
                let omittedRuns = structuralRuns.enumerated().compactMap { index, run in
                    (mask & (1 << index)) != 0 ? run : nil
                }
                let retained = scalars.enumerated().compactMap { index, scalar in
                    omittedRuns.contains(where: { index >= $0.start && index < $0.end })
                        ? nil
                        : scalar
                }
                variants.append(String(String.UnicodeScalarView(retained)))
            }
        } else {
            for run in structuralRuns {
                let omittedRun = scalars.enumerated().compactMap { itemIndex, scalar in
                    itemIndex >= run.start && itemIndex < run.end ? nil : scalar
                }
                variants.append(String(String.UnicodeScalarView(omittedRun)))
            }
            variants.append(String(String.UnicodeScalarView(
                scalars.enumerated().compactMap { index, scalar in
                    AXTextStructural.isStructuralSeparator(at: index, in: scalars)
                        ? nil
                        : scalar
                }
            )))
        }

        var result: [String] = []
        for variant in variants where !result.contains(variant) {
            result.append(variant)
        }
        return result
    }

    private func coordinateText(forKeyboardText text: String) -> String {
        // Structural omission belongs to the observed document mapping, not
        // to every future keyboard payload. Keep the payload literal until a
        // post-write snapshot proves a different coordinate representation.
        return text
    }

    private func keyboardDocumentState(in element: AXUIElement, confirming: Bool = false) throws -> KeyboardDocumentState {
        do {
            return try readKeyboardDocumentState(in: element, confirming: confirming)
        } catch let failure as AXAttributeReadFailure {
            // kAXErrorInvalidUIElement is -25202. A transient failure on the
            // same focused AX element can be retried. A newly created AX
            // element must re-establish editor identity before reusing the
            // previous position; matching text alone is not enough.
            if (isSafariWebEditor || isCodexTarget), failure.status == AXError.invalidUIElement.rawValue,
               [kAXValueAttribute as String, kAXSelectedTextRangeAttribute as String].contains(failure.attribute) {
                try ensureTargetApplicationIsFrontmost()
                let focused = try focusedElement()
                if !CFEqual(focused, element) {
                    try acceptKeyboardTargetRebuild(focused, phase: "invalid_element_read")
                }
                recordDiagnostic("keyboard_invalid_element_retry", [
                    "axAttribute": failure.attribute,
                    "axStatus": String(failure.status),
                    "elementSame": String(CFEqual(focused, element))
                ])
                throw KeyboardWriteReadError.retryable
            }
            throw TextTargetError.writeFailed
        }
    }

    private func readKeyboardDocumentState(in element: AXUIElement, confirming: Bool) throws -> KeyboardDocumentState {
        lastKeyboardReadUsedStructuralFallback = false
        guard let rawText = try readTextEvidence(.axValue, read: { try access.text(in: element) }),
              let selection = try access.selection(in: element) else {
            throw KeyboardDocumentStateReadError.unavailable
        }
        if isCodexTarget {
            if AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: rawText,
                selection: selection,
                confirmedRawText: confirmedKeyboardRawText,
                expectedSelection: pendingKeyboardWrite?.selection
            ) {
                let key = "retryable:\(rawText.utf16.count):\(selection.location)"
                if key != lastCoordinateDiagnosticKey {
                    lastCoordinateDiagnosticKey = key
                    recordDiagnostic("ax_coordinate_mapping_retryable", [
                        "reason": "ax_value_stale_behind_selection",
                        "axValueLengthUTF16": String(rawText.utf16.count),
                        "selectionLocation": String(selection.location),
                        "selectionLength": String(selection.length)
                    ])
                }
                throw KeyboardDocumentStateReadError.retryable
            }
            let evidence = codexPlaceholderEvidence ?? placeholderEvidence(in: element)
            do {
                let document = try AXTextDocumentResolver.readDuringReplacement(
                    rawText: rawText,
                    selection: selection,
                    acknowledgedSelection: replacementWasSent ? pendingKeyboardReplacement?.selected : nil
                ) {
                    try readCodexTextDocument(
                        rawText: rawText, selection: selection, evidence: evidence, element: element
                    )
                }
                lastResolvedCodexDocument = document
                return KeyboardDocumentState(
                    text: document.text,
                    selection: document.selection,
                    rawText: document.rawText,
                    mapping: document.mapping
                )
            } catch KeyboardWriteReadError.retryable {
                if let fallback = exactPendingReceiptState(
                    rawText: rawText,
                    selection: selection,
                    evidence: evidence
                ) {
                    return fallback
                }
                if let fallback = structuralPendingReceiptState(
                    rawText: rawText,
                    selection: selection,
                    evidence: evidence
                ) {
                    return fallback
                }
                recordDiagnostic("ax_coordinate_mapping_retryable", [
                    "reason": "replacement_previous_selection_still_visible",
                    "axValueLengthUTF16": String(rawText.utf16.count),
                    "selectionLocation": String(selection.location),
                    "selectionLength": String(selection.length)
                ])
                throw KeyboardDocumentStateReadError.retryable
            } catch let error as AXTextDocumentResolutionError {
                let pendingReceiptFallbackAllowed: Bool = switch error {
                case .coordinateReadUnavailable, .coordinateLengthMismatch,
                        .coordinateTextMismatch, .selectionOutOfBounds,
                        .selectedRangeUnavailable:
                    true
                default:
                    false
                }
                if pendingReceiptFallbackAllowed,
                   let fallback = exactPendingReceiptState(
                       rawText: rawText,
                       selection: selection,
                       evidence: evidence
                   ) {
                    return fallback
                }
                if pendingReceiptFallbackAllowed,
                   let fallback = structuralPendingReceiptState(
                       rawText: rawText,
                       selection: selection,
                       evidence: evidence
                   ) {
                    return fallback
                }
                if error == .coordinateReadUnavailable,
                   let previous = lastResolvedCodexDocument,
                   let document = try? AXTextDocumentResolver.resolveUsingValidatedAXValueAfterPlaceholder(
                       rawText: rawText,
                       selection: selection,
                       previousState: previous,
                       continuationAllowed: codexAXValueFallbackAllowed
                   ) {
                    codexAXValueFallbackAllowed = true
                    lastResolvedCodexDocument = document
                    recordCoordinateResolution(state: document, evidence: evidence)
                    return KeyboardDocumentState(
                        text: document.text,
                        selection: document.selection,
                        rawText: document.rawText,
                        mapping: document.mapping
                    )
                }
                recordCoordinateResolutionFailure(
                    error,
                    rawText: rawText,
                    selection: selection,
                    evidence: evidence,
                    confirming: confirming
                )
                throw error
            } catch let error as TextTargetError {
                throw error
            } catch {
                recordCoordinateResolutionFailure(
                    .coordinateReadUnavailable,
                    rawText: rawText,
                    selection: selection,
                    evidence: evidence
                )
                throw KeyboardDocumentStateReadError.unavailable
            }
        }
        return KeyboardDocumentState(text: rawText, selection: selection)
    }

    private func exactPendingReceiptFromAXValue(
        rawText: String,
        selection: TextRange
    ) -> AXTextDocumentState? {
        guard isCodexTarget,
              let pending = pendingKeyboardWrite,
              pending.text == rawText,
              pending.selection == selection,
              pending.rawText == rawText,
              let mapping = pending.mapping,
              AXTextDocumentResolver.isValidCoordinateMapping(
                  mapping,
                  rawText: rawText,
                  coordinateText: rawText
              ) else {
            return nil
        }

        return AXTextDocumentState(
            rawText: rawText,
            text: rawText,
            selection: selection,
            placeholderNormalized: false,
            mapping: mapping.withSource(.pendingReceiptExactAXValue)
        )
    }

    /// When AXStringForRange is temporarily unavailable, the AXValue can
    /// still be sufficient evidence if it contains exactly the expected
    /// coordinate document plus structural separators at the operation's
    /// local boundary. This is deliberately stricter than accepting a
    /// matching caret: the expected coordinate text is used to build a full
    /// alignment, content must remain identical, and exactly one receipt
    /// candidate must explain the observed AXValue.
    private func structuralPendingReceiptState(
        rawText: String,
        selection: TextRange,
        evidence: AXPlaceholderEvidence
    ) -> KeyboardDocumentState? {
        guard isCodexTarget,
              let pending = pendingKeyboardWrite,
              let operation = pendingKeyboardDiagnosticOperation,
              let targetElement,
              selectedTextIsSettable(on: targetElement) else {
            return nil
        }

        let candidates = [pending] + (pendingKeyboardRepresentationTransition?.alternates ?? [])
            .map(\.state)
        let matches = candidates.compactMap { expected -> KeyboardDocumentState? in
            guard expected.selection == selection,
                  expected.rawText != rawText,
                  let mapping = expectedKeyboardMapping(
                      rawText: rawText,
                      coordinateText: expected.text,
                      selection: selection
                  ) else {
                return nil
            }
            let observed = KeyboardDocumentState(
                text: expected.text,
                selection: selection,
                rawText: rawText,
                mapping: mapping
            )
            guard KeyboardDiagnosticDiffCalculator.allowsLocalStructuralAugmentation(
                expected: expected,
                observed: observed,
                operation: operation,
                mappingValid: true,
                allowNewStructuralBoundary: true
            ) else {
                return nil
            }
            return observed
        }
        guard matches.count == 1, let match = matches.first else {
            return nil
        }

        guard let mapping = match.mapping else { return nil }
        let resolved = AXTextDocumentState(
            rawText: rawText,
            text: match.text,
            selection: match.selection,
            placeholderNormalized: false,
            mapping: mapping.withSource(.pendingReceiptStructuralAugmentation)
        )
        lastResolvedCodexDocument = resolved
        lastKeyboardReadUsedStructuralFallback = true
        recordDiagnostic("ax_coordinate_mapping_fallback", [
            "reason": "pending_receipt_local_structural_augmentation",
            "selectionLocation": String(selection.location),
            "selectionLength": String(selection.length),
            "axValueLengthUTF16": String(rawText.utf16.count)
        ])
        recordCoordinateResolution(
            state: resolved,
            evidence: evidence
        )
        return match
    }

    private func exactPendingReceiptState(
        rawText: String,
        selection: TextRange,
        evidence: AXPlaceholderEvidence
    ) -> KeyboardDocumentState? {
        guard let fallback = exactPendingReceiptFromAXValue(
            rawText: rawText,
            selection: selection
        ) else {
            return nil
        }

        lastResolvedCodexDocument = fallback
        recordDiagnostic("ax_coordinate_mapping_fallback", [
            "reason": "exact_pending_receipt",
            "selectionLocation": String(selection.location),
            "selectionLength": String(selection.length),
            "axValueLengthUTF16": String(rawText.utf16.count)
        ])
        recordCoordinateResolution(state: fallback, evidence: evidence)
        return KeyboardDocumentState(
            text: fallback.text,
            selection: fallback.selection,
            rawText: fallback.rawText,
            mapping: fallback.mapping
        )
    }

    func copyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.clearContents()
            if let previousString {
                _ = pasteboard.setString(previousString, forType: .string)
            }
            throw TextTargetError.writeFailed
        }
    }

    @discardableResult
    private func setSelection(_ range: TextRange, on element: AXUIElement) throws -> String {
        let requestID = UUID().uuidString
        let requestMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        recordDiagnostic("ax_selected_text_range_set_requested", [
            "axSelectionRequestID": requestID,
            "requestedLocation": String(range.location),
            "requestedLength": String(range.length),
            "requestMonotonicNanoseconds": String(requestMonotonicNanoseconds)
        ])
        let status: Int32
        do {
            status = try access.setSelection(range, on: element)
        } catch {
            recordDiagnostic("ax_selected_text_range_set_threw", [
                "axSelectionRequestID": requestID,
                "requestedLocation": String(range.location),
                "requestedLength": String(range.length),
                "requestMonotonicNanoseconds": String(requestMonotonicNanoseconds),
                "returnMonotonicNanoseconds": String(DispatchTime.now().uptimeNanoseconds),
                "errorCode": DiagnosticErrorFormatter.code(for: error)
            ])
            throw error
        }
        let returnMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        recordDiagnostic("ax_selected_text_range_set_returned", [
            "axSelectionRequestID": requestID,
            "requestedLocation": String(range.location),
            "requestedLength": String(range.length),
            "requestMonotonicNanoseconds": String(requestMonotonicNanoseconds),
            "returnMonotonicNanoseconds": String(returnMonotonicNanoseconds),
            "callDurationNanoseconds": String(returnMonotonicNanoseconds - requestMonotonicNanoseconds),
            "apiStatus": String(status)
        ])
        guard status == AXError.success.rawValue else {
            recordDiagnostic("ax_write_failed", ["status": String(status), "writeKind": "selection"])
            throw TextTargetError.writeFailed
        }
        return requestID
    }

    private func selectedTextIsSettable(on element: AXUIElement) -> Bool {
        access.isAttributeSettable(kAXSelectedTextAttribute as String, on: element)
    }

    private func valueIsSettable(on element: AXUIElement) -> Bool {
        access.isAttributeSettable(kAXValueAttribute as String, on: element)
    }

    private func selectedTextRangeIsSettable(on element: AXUIElement) -> Bool {
        access.isAttributeSettable(kAXSelectedTextRangeAttribute as String, on: element)
    }

    private func ensureKeyboardTargetIdentityIsSafe() throws {
        try ensureTargetApplicationIsFrontmost()
        guard let targetElement else { return }
        let currentElement = try focusedElement()
        if !CFEqual(currentElement, targetElement) {
            if isSafariWebEditor || isCodexTarget {
                try acceptKeyboardTargetRebuild(currentElement, phase: "identity_check")
            } else {
                recordDiagnostic("keyboard_focus_changed")
                invalidateKeyboardRawInsertionRegion()
                throw TextTargetError.targetChanged
            }
        }
        try ensureActiveInputStrategyIsStillApplicable(for: currentElement)
    }

    private func ensureActiveInputStrategyIsStillApplicable(for element: AXUIElement) throws {
        guard activeInputStrategy.suppressesAXReplacement || isSafariWebEditor else { return }
        let application = access.currentApplication()
        let context = access.textInputContext(for: element)
        let currentStrategy = AXTextInputStrategy.select(application: application, context: context)
        if currentStrategy == .safeStop(reason: "web_ancestor_unclassified"),
           confirmSafariTargetUnderCapturedAnchor(element, application: application, context: context) {
            safariStrategyMismatchStartedAt = nil
            safariStrategyRetryDiagnosticRecorded = false
            safariStrategyRetryIsPending = false
            recordDiagnostic("keyboard_target_identity_confirmed", [
                "continuityRoute": "captured_anchor_subtree",
                "reason": "unique_focused_editor_under_captured_anchor",
                "ancestorScanStatus": context?.ancestorScanStatus.rawValue ?? "unavailable"
            ])
            return
        }
        if shouldRetrySafariStrategyMismatch(
            currentStrategy,
            application: application,
            context: context
        ) {
            let now = writeTiming.now()
            let mismatchStartedAt = safariStrategyMismatchStartedAt ?? now
            safariStrategyMismatchStartedAt = mismatchStartedAt
            let elapsed = now &- mismatchStartedAt
            if elapsed >= safariStrategyRetryWindowNanoseconds {
                recordDiagnostic("input_strategy_changed", [
                    "expectedStrategy": activeInputStrategy.diagnosticName,
                    "expectedReason": activeInputStrategy.diagnosticReason,
                    "actualStrategy": currentStrategy.diagnosticName,
                    "actualReason": currentStrategy.diagnosticReason,
                    "currentRole": context?.role ?? "unknown",
                    "ancestorScanStatus": context?.ancestorScanStatus.rawValue ?? "unavailable",
                    "strategyMismatchDurationMilliseconds": String(elapsed / 1_000_000),
                    "retryWindow": "expired"
                ])
                safariStrategyMismatchStartedAt = nil
                safariStrategyRetryIsPending = false
                invalidateKeyboardRawInsertionRegion()
                throw TextTargetError.targetChanged
            }
            if !safariStrategyRetryDiagnosticRecorded {
                recordDiagnostic("input_strategy_read_retryable", [
                    "expectedStrategy": activeInputStrategy.diagnosticName,
                    "expectedReason": activeInputStrategy.diagnosticReason,
                    "actualStrategy": currentStrategy.diagnosticName,
                    "actualReason": currentStrategy.diagnosticReason,
                    "currentRole": context?.role ?? "unknown",
                    "ancestorScanStatus": context?.ancestorScanStatus.rawValue ?? "unavailable",
                    "isReadOnly": context?.isReadOnly.map(String.init) ?? "unknown",
                    "isSecure": context?.isSecure.map(String.init) ?? "unknown",
                    "retryWindow": "existing_keyboard_preflight"
                ])
                safariStrategyRetryDiagnosticRecorded = true
            }
            safariStrategyRetryIsPending = true
            throw KeyboardWriteReadError.retryable
        }
        safariStrategyMismatchStartedAt = nil
        safariStrategyRetryIsPending = false
        guard currentStrategy == activeInputStrategy else {
            recordDiagnostic("input_strategy_changed", [
                "expectedStrategy": activeInputStrategy.diagnosticName,
                "expectedReason": activeInputStrategy.diagnosticReason,
                "actualStrategy": currentStrategy.diagnosticName,
                "actualReason": currentStrategy.diagnosticReason
            ])
            invalidateKeyboardRawInsertionRegion()
            throw TextTargetError.targetChanged
        }
    }

    private func confirmSafariTargetUnderCapturedAnchor(
        _ element: AXUIElement,
        application: TextTargetApplication?,
        context: AXTextInputTargetContext?
    ) -> Bool {
        guard isSafariWebEditor,
              activeInputStrategy.prefersAcknowledgedKeyboard,
              application?.bundleIdentifier == "com.apple.Safari",
              application?.processIdentifier == targetApplicationProcessID,
              let expectedTargetPID = targetProcessID,
              access.processIdentifier(of: element) == expectedTargetPID,
              let context,
              ["AXTextArea", "AXTextField"].contains(context.role ?? ""),
              context.isReadOnly != true,
              context.isSecure != true,
              [.readFailure, .truncated, .cycle].contains(context.ancestorScanStatus),
              isEligibleSafariWebEditor(
                element,
                application: application,
                context: context,
                allowCapturedAnchorFallback: true
              ),
              let previous = editorContinuity,
              let current = access.editorContinuityEvidence(for: element, anchoredAt: previous),
              Self.editorContinuityMatches(previous, current, capturedAnchorScan: true),
              let focusedAfterScan = try? access.focusedElement(),
              CFEqual(focusedAfterScan, element),
              access.currentApplication()?.processIdentifier == targetApplicationProcessID else {
            return false
        }
        editorContinuity = current
        return true
    }

    private func shouldRetrySafariStrategyMismatch(
        _ currentStrategy: AXTextInputStrategy,
        application: TextTargetApplication?,
        context: AXTextInputTargetContext?
    ) -> Bool {
        guard isSafariWebEditor,
              activeInputStrategy.prefersAcknowledgedKeyboard,
              application?.bundleIdentifier == "com.apple.Safari",
              application?.processIdentifier == targetApplicationProcessID,
              currentStrategy != activeInputStrategy,
              context?.isReadOnly != true,
              context?.isSecure != true else {
            return false
        }

        // Even a complete-looking mismatch may be a short WebKit tree rebuild.
        // Retry briefly, but never dispatch unless the captured web strategy
        // becomes confirmable again.
        return true
    }

    private func waitForSafeKeyboardTargetIdentity(generation: UInt64) async throws {
        let start = writeTiming.now()
        while true {
            try Task.checkCancellation()
            guard generation == keyboardGeneration else { throw CancellationError() }
            do {
                try ensureKeyboardTargetIdentityIsSafe()
                return
            } catch KeyboardWriteReadError.retryable {
                if !safariStrategyRetryIsPending && !keyboardTargetReacquireRetryIsPending {
                    recordDiagnostic("keyboard_state_read_retryable", ["phase": "identity_check"])
                }
                safariStrategyRetryIsPending = false
                keyboardTargetReacquireRetryIsPending = false
            }

            let elapsed = writeTiming.now() &- start
            guard elapsed < preflightTimeoutNanoseconds else {
                throw TextTargetError.writeFailed
            }
            try await writeTiming.sleep(min(10_000_000, preflightTimeoutNanoseconds - elapsed))
        }
    }

    @discardableResult
    private func acceptKeyboardTargetRebuild(
        _ element: AXUIElement,
        phase: String,
        candidateGeneration: String? = nil
    ) throws -> String {
        let candidateObjectGeneration = candidateGeneration ?? UUID().uuidString
        func reject(_ reason: String, additionalFields: [String: String] = [:]) throws -> Never {
            var fields = [
                "phase": phase,
                "reason": reason,
                "sameApplication": String(access.currentApplication()?.bundleIdentifier == targetApplicationBundleIdentifier),
                "targetApplication": targetApplicationBundleIdentifier ?? "unknown",
                "previousObjectGeneration": targetElementObservationID ?? "unknown",
                "candidateObjectGeneration": candidateObjectGeneration
            ]
            fields.merge(boundedContinuityDiagnosticFields(continuityCaptureSummary)) { _, new in new }
            fields.merge(additionalFields) { _, new in new }
            recordDiagnostic("keyboard_target_reacquire_rejected", fields)
            keyboardTargetReacquireRetryDiagnosticRecorded = false
            keyboardTargetReacquireRetryIsPending = false
            invalidateKeyboardRawInsertionRegion()
            throw TextTargetError.targetChanged
        }

        func retry(_ reason: String, additionalFields: [String: String] = [:]) throws -> Never {
            if !keyboardTargetReacquireRetryDiagnosticRecorded {
                var fields = [
                    "phase": phase,
                    "reason": reason,
                    "retryWindow": "existing_operation_deadline",
                    "previousObjectGeneration": targetElementObservationID ?? "unknown",
                    "candidateObjectGeneration": candidateObjectGeneration
                ]
                fields.merge(boundedContinuityDiagnosticFields(continuityCaptureSummary)) { _, new in new }
                fields.merge(additionalFields) { _, new in new }
                recordDiagnostic("keyboard_target_reacquire_retryable", fields)
                keyboardTargetReacquireRetryDiagnosticRecorded = true
            }
            keyboardTargetReacquireRetryIsPending = true
            throw KeyboardWriteReadError.retryable
        }

        let validation = validateKeyboardTargetRebuild(
            element,
            candidateObjectGeneration: candidateObjectGeneration
        )
        let current: AXTextEditorContinuityEvidence
        let continuityRoute: String
        let expectedPID: pid_t
        let identityOutcome: String
        let identityDiagnosticFields: [String: String]
        switch validation {
        case let .confirmed(evidence, route, processID, outcome, diagnosticFields):
            current = evidence
            continuityRoute = route
            expectedPID = processID
            identityOutcome = outcome
            identityDiagnosticFields = diagnosticFields
        case let .temporarilyUnavailable(reason, diagnosticFields):
            try retry(reason, additionalFields: diagnosticFields ?? [:])
        case let .rejected(reason, diagnosticFields):
            try reject(reason, additionalFields: diagnosticFields ?? [:])
        }

        let previousID = targetElementObservationID
        targetElement = element
        targetProcessID = expectedPID
        editorContinuity = current
        targetElementObservationID = candidateObjectGeneration
        keyboardTargetReacquireRetryDiagnosticRecorded = false
        keyboardTargetReacquireRetryIsPending = false
        var reacquireFields = [
            "phase": phase,
            "reason": continuityRoute == "captured_anchor_subtree"
                ? "unique_focused_editor_under_captured_anchor"
                : "same_web_area_unique_editor_anchor_and_expected_document",
            "continuityRoute": continuityRoute,
            "previousObjectGeneration": previousID ?? "unknown",
            "currentObjectGeneration": targetElementObservationID ?? "unknown",
            "editableEditorCount": String(current.editableEditorCount),
            "editorAnchorRole": current.editorAnchorRole,
            "rolePathDepth": String(current.rolesFromEditorToAnchor.count),
            "identityOutcome": identityOutcome,
            "leafIdentifierPresence": (current.identifiersFromEditorToAnchor.first ?? nil) == nil
                ? "missing" : "present"
        ]
        reacquireFields.merge(identityDiagnosticFields) { existing, _ in existing }
        if let comparisonOutcome = identityDiagnosticFields["identityOutcome"] {
            reacquireFields["identityComparisonOutcome"] = comparisonOutcome
        }
        reacquireFields["identityOutcome"] = identityOutcome
        recordDiagnostic("keyboard_target_reacquired", reacquireFields)
        return candidateObjectGeneration
    }

    private func validateKeyboardTargetRebuild(
        _ element: AXUIElement,
        candidateObjectGeneration: String
    ) -> AXEditorIdentityValidationResult {
        access.setContinuityScanObjectGeneration(targetElementObservationID)
        access.setContinuityScanBudgetNanoseconds(nil)
        defer {
            access.setContinuityScanObjectGeneration(nil)
            access.setContinuityScanBudgetNanoseconds(nil)
        }
        guard isSafariWebEditor || isCodexTarget else {
            return .rejected(reason: "old_handle_or_process_not_verified")
        }
        guard let currentApplication = access.currentApplication() else {
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "frontmost_application_unavailable",
                "applicationComparison": "unavailable"
            ])
        }
        guard currentApplication.bundleIdentifier == targetApplicationBundleIdentifier else {
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "application_changed",
                "applicationComparison": "different"
            ])
        }
        guard let expectedApplicationPID = targetApplicationProcessID else {
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "captured_process_unavailable",
                "processComparison": "unavailable"
            ])
        }
        guard currentApplication.processIdentifier == expectedApplicationPID else {
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "frontmost_process_changed",
                "processComparison": "different"
            ])
        }
        guard let capturedTargetPID = targetProcessID else {
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "captured_target_process_unavailable",
                "candidateCapturedTargetProcessComparison": "unavailable"
            ])
        }
        guard let candidatePID = access.processIdentifier(of: element) else {
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "candidate_process_unavailable",
                "candidateProcessComparison": "unavailable",
                "candidateCapturedTargetProcessComparison": "unavailable"
            ])
        }
        guard candidatePID == capturedTargetPID else {
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "candidate_process_changed",
                "candidateProcessComparison": candidatePID == expectedApplicationPID ? "equal" : "different",
                "candidateCapturedTargetProcessComparison": "different"
            ])
        }
        guard let previousElement = targetElement else {
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "previous_handle_missing",
                "previousHandleValidity": "unavailable"
            ])
        }
        let previousHandleValidity = access.elementValidity(previousElement)
        guard previousHandleValidity == .invalid else {
            let validity: String = switch previousHandleValidity {
            case .valid: "valid"
            case .unavailable: "unavailable"
            case .invalid: "invalid"
            }
            return .rejected(reason: "old_handle_or_process_not_verified", diagnosticFields: [
                "identityFailure": "previous_handle_not_invalidated",
                "previousHandleValidity": validity
            ])
        }
        guard let previous = editorContinuity else {
            return .rejected(reason: "stable_unique_editor_continuity_unverified", diagnosticFields: [
                "continuityFailure": "captured_evidence_missing",
                "previousEvidence": "missing",
                "fallbackRoute": "not_attempted_no_captured_anchor"
            ])
        }
        access.setContinuityScanBudgetNanoseconds(250_000_000)
        access.setContinuityScanObjectGeneration(candidateObjectGeneration)
        let scannedContinuity = access.editorContinuityEvidence(for: element)
        let ancestorScanID = access.lastContinuityScanObservationID()
        let ancestorComparison = scannedContinuity.map { AXTextEditorContinuity.compare(previous, $0) }
        let shouldUseCapturedAnchor = scannedContinuity == nil
            || ancestorComparison?.canConfirmFromCapturedAnchor == true
        if let ancestorComparison,
           !ancestorComparison.matches,
           !ancestorComparison.canConfirmFromCapturedAnchor {
            var fields = ancestorComparison.fields
            fields["continuityFailure"] = "evidence_mismatch"
            fields["fallbackRoute"] = "not_attempted_ancestor_evidence_conflicts_or_structure_differs"
            fields["currentEvidenceSource"] = "ancestor_scan"
            fields["ancestorScanID"] = ancestorScanID ?? "unknown"
            fields["currentScanID"] = ancestorScanID ?? "unknown"
            if ancestorComparison.identityOutcome == "temporarily_unavailable" {
                return .temporarilyUnavailable(
                    reason: "continuity_evidence_temporarily_unavailable",
                    diagnosticFields: fields
                )
            }
            return .rejected(
                reason: "stable_unique_editor_continuity_unverified",
                diagnosticFields: fields
            )
        }
        let current = shouldUseCapturedAnchor
            ? access.editorContinuityEvidence(for: element, anchoredAt: previous)
            : scannedContinuity
        let currentScanID = shouldUseCapturedAnchor
            ? access.lastContinuityScanObservationID()
            : ancestorScanID
        guard let current else {
            var unavailableFields = [
                "continuityFailure": "current_evidence_unavailable",
                "previousEvidence": "saved",
                "ancestorScanOutcome": scannedContinuity == nil ? "no_evidence" : "identifier_missing",
                "fallbackRoute": shouldUseCapturedAnchor
                    ? "attempted_captured_anchor_subtree"
                    : "not_attempted_identifier_match",
                "ancestorScanID": ancestorScanID ?? "unknown",
                "capturedAnchorScanID": currentScanID ?? "unknown"
            ]
            if let ancestorComparison {
                unavailableFields.merge(ancestorComparison.fields) { _, new in new }
            }
            return .temporarilyUnavailable(
                reason: "continuity_evidence_unavailable",
                diagnosticFields: unavailableFields
            )
        }
        let comparison = AXTextEditorContinuity.compare(previous, current)
        let confirmedWithoutIdentifier = shouldUseCapturedAnchor
            && comparison.canConfirmFromCapturedAnchor
        guard comparison.matches || confirmedWithoutIdentifier else {
            var fields = comparison.fields
            fields["continuityFailure"] = "evidence_mismatch"
            fields["fallbackRoute"] = shouldUseCapturedAnchor
                ? "attempted_captured_anchor_subtree"
                : "not_attempted_identifier_match"
            fields["currentEvidenceSource"] = shouldUseCapturedAnchor ? "captured_anchor_subtree" : "ancestor_scan"
            fields["ancestorScanID"] = ancestorScanID ?? "unknown"
            fields["currentScanID"] = currentScanID ?? "unknown"
            if comparison.identityOutcome == "temporarily_unavailable" {
                return .temporarilyUnavailable(
                    reason: "continuity_evidence_temporarily_unavailable",
                    diagnosticFields: fields
                )
            }
            return .rejected(
                reason: "stable_unique_editor_continuity_unverified",
                diagnosticFields: fields
            )
        }
        let continuityRoute = shouldUseCapturedAnchor ? "captured_anchor_subtree" : "ancestor_scan"
        let usedCapturedAnchorFallback = shouldUseCapturedAnchor
        guard let latestApplication = access.currentApplication() else {
            return .temporarilyUnavailable(reason: "frontmost_application_unavailable_after_scan")
        }
        guard latestApplication.bundleIdentifier == targetApplicationBundleIdentifier,
              latestApplication.processIdentifier == expectedApplicationPID else {
            return .rejected(reason: "application_or_process_changed_during_scan", diagnosticFields: [
                "applicationComparison": String(latestApplication.bundleIdentifier == targetApplicationBundleIdentifier),
                "processComparison": String(latestApplication.processIdentifier == expectedApplicationPID)
            ])
        }
        do {
            let focusedAfterScan = try access.focusedElement()
            guard CFEqual(focusedAfterScan, element) else {
                return .rejected(reason: "focused_editor_changed_during_scan", diagnosticFields: [
                    "focusedTargetComparison": "different",
                    "identityOutcome": "focus_changed_after_scan"
                ])
            }
        } catch {
            return .temporarilyUnavailable(reason: "focused_editor_unavailable_after_scan", diagnosticFields: [
                "focusedTargetComparison": "unavailable"
            ])
        }
        let context = access.textInputContext(for: element)
        if context?.isReadOnly == true || context?.isSecure == true {
            return .rejected(reason: "editor_is_not_writable")
        }
        if rebuildContextIsTemporarilyUnavailable(
            context,
            allowCapturedAnchorFallback: usedCapturedAnchorFallback
        ) {
            return .temporarilyUnavailable(reason: "target_context_temporarily_unavailable")
        }
        guard isEligibleRebuiltKeyboardEditor(
            element,
            application: latestApplication,
            context: context,
            allowCapturedAnchorFallback: usedCapturedAnchorFallback
        ) else {
            return .rejected(reason: "editor_is_no_longer_eligible")
        }
        return .confirmed(
            evidence: current,
            route: continuityRoute,
            processID: candidatePID,
            identityOutcome: confirmedWithoutIdentifier
                ? "confirmed_by_captured_anchor_without_identifier"
                : shouldUseCapturedAnchor
                    ? "confirmed_by_captured_anchor_with_identifier"
                    : "confirmed_by_matching_identifier",
            diagnosticFields: comparison.fields.merging([
                "fallbackRoute": shouldUseCapturedAnchor
                    ? "attempted_captured_anchor_subtree"
                    : "not_attempted_identifier_match",
                "currentEvidenceSource": shouldUseCapturedAnchor
                    ? "captured_anchor_subtree"
                    : "ancestor_scan",
                "ancestorScanID": ancestorScanID ?? "unknown",
                "currentScanID": currentScanID ?? "unknown",
                "focusedTargetComparison": "same",
                "applicationComparison": "equal",
                "processComparison": "equal",
                "candidateProcessComparison": candidatePID == expectedApplicationPID ? "equal" : "different",
                "candidateCapturedTargetProcessComparison": "equal"
            ]) { _, new in new }
        )
    }

    private func rebuildContextIsTemporarilyUnavailable(
        _ context: AXTextInputTargetContext?,
        allowCapturedAnchorFallback: Bool
    ) -> Bool {
        guard let context, let role = context.role else {
            return true
        }
        let capturedTextAreaProof = allowCapturedAnchorFallback && role == "AXTextArea"
        guard context.isReadOnly != nil || capturedTextAreaProof,
              context.isSecure != nil || capturedTextAreaProof else {
            return true
        }
        switch context.ancestorScanStatus {
        case .readFailure, .truncated, .cycle:
            return !allowCapturedAnchorFallback
        case .webArea, .completeWithoutWebArea:
            return false
        }
    }

    private static func editorContinuityMatches(
        _ previous: AXTextEditorContinuityEvidence,
        _ current: AXTextEditorContinuityEvidence,
        capturedAnchorScan: Bool = false
    ) -> Bool {
        let comparison = AXTextEditorContinuity.compare(previous, current)
        return comparison.matches
            || (capturedAnchorScan && comparison.canConfirmFromCapturedAnchor)
    }

    private func isEligibleRebuiltKeyboardEditor(
        _ element: AXUIElement,
        application: TextTargetApplication?,
        context: AXTextInputTargetContext?,
        allowCapturedAnchorFallback: Bool
    ) -> Bool {
        if isSafariWebEditor {
            return isEligibleSafariWebEditor(
                element,
                application: application,
                context: context,
                allowCapturedAnchorFallback: allowCapturedAnchorFallback
            )
        }
        let hasConfirmedWebArea = context?.ancestorScanStatus == .webArea
        let hasCapturedAnchorProof = allowCapturedAnchorFallback
            && (context?.ancestorScanStatus == .readFailure
                || context?.ancestorScanStatus == .truncated
                || context?.ancestorScanStatus == .cycle)
        let capturedTextAreaProof = allowCapturedAnchorFallback && context?.role == "AXTextArea"
        let writable = context?.isReadOnly == false
            || (capturedTextAreaProof && context?.isReadOnly == nil)
        let nonSecure = context?.isSecure == false
            || (capturedTextAreaProof && context?.isSecure == nil)
        guard isCodexTarget,
              application?.bundleIdentifier == "com.openai.codex",
              hasConfirmedWebArea || hasCapturedAnchorProof,
              ["AXTextArea", "AXTextField"].contains(context?.role ?? ""),
              writable,
              nonSecure else {
            return false
        }
        return true
    }

    private func isEligibleSafariWebEditor(
        _ element: AXUIElement,
        application: TextTargetApplication?,
        context: AXTextInputTargetContext?,
        allowCapturedAnchorFallback: Bool = false
    ) -> Bool {
        guard application?.bundleIdentifier == "com.apple.Safari" else { return false }
        guard context?.isReadOnly != true, context?.isSecure != true else { return false }
        if access.isProseMirrorEditor(element) { return true }
        let hasConfirmedWebArea = context?.ancestorScanStatus == .webArea
        let hasCapturedAnchorProof = allowCapturedAnchorFallback
            && (context?.ancestorScanStatus == .readFailure
                || context?.ancestorScanStatus == .truncated
                || context?.ancestorScanStatus == .cycle)
        let capturedTextAreaProof = allowCapturedAnchorFallback && context?.role == "AXTextArea"
        let writable = context?.isReadOnly == false
            || (capturedTextAreaProof && context?.isReadOnly == nil)
        let nonSecure = context?.isSecure == false
            || (capturedTextAreaProof && context?.isSecure == nil)
        guard let context,
              context.role == "AXTextArea",
              hasConfirmedWebArea || hasCapturedAnchorProof,
              writable,
              nonSecure else {
            return false
        }
        return true
    }

    private func ensureKeyboardTargetIsSafe() throws {
        try ensureKeyboardTargetIdentityIsSafe()
        guard let targetElement else { return }
        let currentElement = try focusedElement()
        if requiresKeyboardAcknowledgement {
            guard pendingKeyboardWrite == nil else { throw TextTargetError.writeFailed }
            guard let currentState = try? keyboardDocumentState(in: currentElement),
                  let expectedState = currentConfirmedKeyboardState() else {
                recordDiagnostic("keyboard_confirmed_state_changed", ["comparison": "unreadable"])
                throw TextTargetError.targetChanged
            }
            let comparison = keyboardStateComparison(currentState, expected: expectedState)
            guard comparison == .matched else {
                invalidateKeyboardRawInsertionRegion()
                recordDiagnostic(
                    "keyboard_confirmed_state_changed",
                    [
                        "comparison": comparison.rawValue,
                        "expectedDocumentLengthUTF16": String(expectedState.text.utf16.count),
                        "currentDocumentLengthUTF16": String(currentState.text.utf16.count),
                        "expectedSelectionLocation": String(expectedState.selection.location),
                        "expectedSelectionLength": String(expectedState.selection.length),
                        "currentSelectionLocation": String(currentState.selection.location),
                        "currentSelectionLength": String(currentState.selection.length)
                    ]
                )
                throw TextTargetError.targetChanged
            }
            guard confirmedRawInsertionRegionMatches(currentState) else {
                invalidateKeyboardRawInsertionRegion()
                recordDiagnostic("keyboard_confirmed_state_changed", [
                    "comparison": "raw_text_changed",
                    "expectedDocumentLengthUTF16": String(expectedState.text.utf16.count),
                    "currentDocumentLengthUTF16": String(currentState.text.utf16.count)
                ])
                throw TextTargetError.targetChanged
            }
            commitConfirmedKeyboardState(currentState)
            return
        }
        if let expectedKeyboardSelection {
            let actualSelection = readableSelection(in: currentElement)
            if actualSelection != expectedKeyboardSelection {
                let age = lastKeyboardDispatch.map {
                    Double(writeTiming.now() - $0) / 1_000_000
                } ?? -1
                let result = try KeyboardCaretSynchronizer.wait(
                    expected: expectedKeyboardSelection, initial: actualSelection,
                    canWait: age >= 0 && age <= 250
                ) {
                    try self.ensureTargetApplicationIsFrontmost()
                    let focused = try self.focusedElement()
                    guard CFEqual(focused, targetElement) else {
                        self.recordDiagnostic("keyboard_focus_changed")
                        throw TextTargetError.targetChanged
                    }
                    return self.readableSelection(in: focused)
                }
                let recovered = result.selection == expectedKeyboardSelection
                recordDiagnostic(recovered ? "keyboard_caret_recovered" : "keyboard_caret_timeout", [
                    "expectedLocation": String(expectedKeyboardSelection.location),
                    "expectedLength": String(expectedKeyboardSelection.length),
                    "initialLocation": String(actualSelection?.location ?? -1),
                    "initialLength": String(actualSelection?.length ?? -1),
                    "actualLocation": String(result.selection?.location ?? -1),
                    "actualLength": String(result.selection?.length ?? -1),
                    "millisecondsSinceDispatch": String(age), "waitMilliseconds": String(result.elapsedMilliseconds),
                    "polls": String(result.polls)
                ])
                guard recovered else { throw TextTargetError.targetChanged }
            }
        }
    }

    func reconcileKeyboardStateForUserEdit() throws -> KeyboardReconciliation {
        guard requiresKeyboardAcknowledgement, isCodexTarget else { return .matched }
        guard targetElement != nil else { return .matched }
        guard pendingKeyboardWrite == nil, pendingKeyboardReplacement == nil else {
            recordDiagnostic("own_write_in_flight", [
                "pendingReplacement": String(pendingKeyboardReplacement != nil),
                "keyboardGeneration": String(keyboardGeneration)
            ])
            return .ownWriteInFlight
        }
        let currentState: KeyboardDocumentState
        let requestedAt = Date()
        let monotonic = writeTiming.now() / 1_000_000
        do {
            currentState = try readKeyboardDocumentObservation(
                generation: keyboardGeneration,
                phase: "reconciliation"
            ).state
        } catch KeyboardDocumentStateReadError.retryable,
                KeyboardWriteReadError.retryable {
            // The atomic writer performs a fresh preflight with its existing
            // bounded retry loop. A changed AX handle or transient snapshot
            // must not be treated as an external edit or reused as evidence.
            recordDiagnostic("keyboard_state_read_retryable", ["phase": "reconciliation"])
            return .matched
        } catch {
            invalidateKeyboardRawInsertionRegion()
            recordDiagnostic("keyboard_user_edit_read_failed")
            throw TextTargetError.targetChanged
        }
        guard let expectedState = currentConfirmedKeyboardState() else {
            invalidateKeyboardRawInsertionRegion()
            recordDiagnostic("keyboard_user_edit_read_failed")
            throw TextTargetError.targetChanged
        }
        let comparison = keyboardStateComparison(currentState, expected: expectedState)
        if comparison != .matched {
            recordDiagnostic("keyboard_state_change_observed", [
                "comparison": comparison.rawValue,
                "cause": "unknown",
                "previousSelectionLocation": String(expectedState.selection.location),
                "currentSelectionLocation": String(currentState.selection.location),
                "productionClassification": "external_edit_inference_not_user_action_proof"
            ], textEvidence: documentEvidence(currentState, requested: requestedAt,
                                               started: requestedAt, monotonic: monotonic))
        }
        guard comparison != .rawMappingUnavailable else {
            invalidateKeyboardRawInsertionRegion()
            recordDiagnostic("keyboard_user_edit_ambiguous", ["reason": "mapping_unavailable"])
            throw TextTargetError.targetChanged
        }
        if comparison == .matched {
            guard confirmedRawInsertionRegionMatches(currentState) else {
                invalidateKeyboardRawInsertionRegion()
                recordDiagnostic("keyboard_user_edit_detected", [
                    "comparison": "raw_text_changed",
                    "previousDocumentLengthUTF16": String(expectedState.text.utf16.count),
                    "currentDocumentLengthUTF16": String(currentState.text.utf16.count)
                ])
                commitConfirmedKeyboardState(currentState)
                recordDiagnostic("keyboard_state_rebased_after_user_edit", [
                    "documentLengthUTF16": String(currentState.text.utf16.count),
                    "selectionLocation": String(currentState.selection.location),
                    "selectionLength": String(currentState.selection.length)
                ])
                return .externalEdit
            }
            commitConfirmedKeyboardState(currentState)
            return .matched
        }

        invalidateKeyboardRawInsertionRegion()

        recordDiagnostic("keyboard_user_edit_detected", [
            "comparison": comparison.rawValue,
            "previousDocumentLengthUTF16": String(expectedState.text.utf16.count),
            "currentDocumentLengthUTF16": String(currentState.text.utf16.count),
            "previousSelectionLocation": String(expectedState.selection.location),
            "previousSelectionLength": String(expectedState.selection.length),
            "currentSelectionLocation": String(currentState.selection.location),
            "currentSelectionLength": String(currentState.selection.length)
        ])
        commitConfirmedKeyboardState(currentState)
        recordDiagnostic("keyboard_state_rebased_after_user_edit", [
            "documentLengthUTF16": String(currentState.text.utf16.count),
            "selectionLocation": String(currentState.selection.location),
            "selectionLength": String(currentState.selection.length)
        ])
        return .externalEdit
    }

    private func recoverPendingSelectionIfSafe(generation: UInt64) {
        guard let pending = pendingKeyboardReplacement else { return }
        guard pending.sessionGeneration == generation,
              generation == keyboardGeneration,
              pending.operationGeneration == keyboardOperationGeneration else {
            recordDiagnostic("selection_recovery_skipped", ["reason": "operation_generation_changed"])
            return
        }
        guard !replacementWasSent else {
            recordDiagnostic("selection_recovery_skipped", ["reason": "replacement_already_sent"])
            return
        }
        guard let targetElement else {
            recordDiagnostic("selection_recovery_skipped", ["reason": "target_unavailable"])
            return
        }

        do {
            try ensureTargetApplicationIsFrontmost()
            let currentElement = try focusedElement()
            guard CFEqual(currentElement, targetElement) else {
                recordDiagnostic("selection_recovery_skipped", ["reason": "focus_changed"])
                return
            }
            guard let currentState = try? keyboardDocumentState(in: currentElement) else {
                recordDiagnostic("selection_recovery_skipped", ["reason": "read_failed"])
                return
            }
            let comparison = keyboardStateComparison(currentState, expected: pending.selected)
            guard comparison == .matched else {
                recordDiagnostic("selection_recovery_skipped", ["reason": comparison.rawValue])
                return
            }
            try setSelection(pending.originalSelection, on: currentElement)
            guard readableSelection(in: currentElement) == pending.originalSelection else {
                recordDiagnostic("selection_recovery_skipped", ["reason": "selection_not_restored"])
                return
            }
            expectedKeyboardSelection = pending.originalSelection
            pendingKeyboardReplacement = nil
            pendingKeyboardWrite = nil
            replacementWasSent = false
            recordDiagnostic("selection_recovery_succeeded", [
                "selectionLocation": String(pending.originalSelection.location),
                "selectionLength": String(pending.originalSelection.length)
            ])
        } catch {
            recordDiagnostic("selection_recovery_skipped", [
                "reason": DiagnosticErrorFormatter.code(for: error)
            ])
        }
    }

    private func currentConfirmedKeyboardState() -> KeyboardDocumentState? {
        guard let confirmedKeyboardDocument,
              let expectedKeyboardSelection else { return nil }
        return KeyboardDocumentState(
            text: confirmedKeyboardDocument,
            selection: expectedKeyboardSelection,
            rawText: confirmedKeyboardRawText,
            mapping: confirmedKeyboardMapping
        )
    }

    private func invalidateKeyboardRawInsertionRegion() {
        confirmedKeyboardRawInsertionRegion = nil
        pendingKeyboardRawInsertionRegion = nil
    }

    private func confirmedRawInsertionRegionMatches(_ state: KeyboardDocumentState) -> Bool {
        guard confirmedKeyboardRawInsertionRegion != nil else { return true }
        guard let confirmedKeyboardRawText,
              let confirmedKeyboardMapping else {
            return false
        }
        return state.rawText == confirmedKeyboardRawText
            && state.mapping == confirmedKeyboardMapping
    }

    private func keyboardStateComparison(
        _ current: KeyboardDocumentState,
        expected: KeyboardDocumentState
    ) -> KeyboardDocumentComparison {
        // A structural representation transition is only admissible as part
        // of the receipt for the write that caused it. Between writes, a
        // raw-only separator change or a different mapping is external state
        // (even when the coordinate text and caret still look identical), so
        // the confirmed position must be invalidated before any new keyboard
        // event is sent.
        KeyboardWriteConfirmation.compareStableState(
            expected: expected,
            observed: current,
            isCodexTarget: isCodexTarget
        )
    }

    private func uniqueInsertionPosition(before: String, inserting payload: String, observed: String) -> Int? {
        let originalUnits = Array(before.utf16)
        let observedUnits = Array(observed.utf16)
        let payloadUnits = Array(payload.utf16)
        guard !payloadUnits.isEmpty,
              observedUnits.count == originalUnits.count + payloadUnits.count else {
            return nil
        }

        var commonPrefix = 0
        while commonPrefix < originalUnits.count,
              originalUnits[commonPrefix] == observedUnits[commonPrefix] {
            commonPrefix += 1
        }
        var commonSuffix = 0
        while commonSuffix < originalUnits.count,
              originalUnits[originalUnits.count - commonSuffix - 1]
                == observedUnits[observedUnits.count - commonSuffix - 1] {
            commonSuffix += 1
        }

        let firstPossible = max(0, originalUnits.count - commonSuffix)
        let lastPossible = min(originalUnits.count, commonPrefix)
        guard firstPossible <= lastPossible else { return nil }
        var matches: [Int] = []
        for position in firstPossible...lastPossible {
            let end = position + payloadUnits.count
            guard end <= observedUnits.count,
                  Array(observedUnits[position..<end]) == payloadUnits,
                  isUTF16ScalarBoundary(position, in: before),
                  isUTF16ScalarBoundary(end, in: observed) else {
                continue
            }
            matches.append(position)
            if matches.count > 1 { return nil }
        }
        return matches.first
    }

    private func initialInsertionPreservesRawDocument(
        baseline: KeyboardDocumentState,
        observed: KeyboardDocumentState,
        coordinatePosition: Int,
        inserting payload: String
    ) -> Bool {
        guard let rawBefore = baseline.rawText,
              let rawAfter = observed.rawText,
              let mapping = baseline.mapping,
              coordinatePosition >= 0,
              coordinatePosition < mapping.rawBoundaryCandidates.count else {
            return false
        }
        let mappedRawBoundaries = mapping.rawBoundaryCandidates[coordinatePosition]
        guard !mappedRawBoundaries.isEmpty else { return false }

        var rawBeforeVariants = [rawBefore]
        if let trimmed = removingOneTerminalLineBreak(from: rawBefore) {
            rawBeforeVariants.append(trimmed)
        }
        let validPositions = Set(rawBeforeVariants.compactMap { rawVariant -> Int? in
            guard let rawPosition = uniqueInsertionPosition(
                before: rawVariant,
                inserting: payload,
                observed: rawAfter
            ), mappedRawBoundaries.contains(rawPosition) else {
                return nil
            }
            return rawPosition
        })
        return validPositions.count == 1
    }

    private func removingOneTerminalLineBreak(from text: String) -> String? {
        let units = Array(text.utf16)
        guard let last = units.last,
              [0x0A, 0x0D, 0x2028, 0x2029].contains(last) else {
            return nil
        }
        let count = last == 0x0A && units.count > 1 && units[units.count - 2] == 0x0D ? 2 : 1
        return String(decoding: units.dropLast(count), as: UTF16.self)
    }

    private func commitConfirmedKeyboardState(_ state: KeyboardDocumentState) {
        confirmedKeyboardDocument = state.text
        expectedKeyboardSelection = state.selection
        confirmedKeyboardRawText = state.rawText
        confirmedKeyboardMapping = state.mapping
        confirmedKeyboardState = state
    }

    private func ensureTargetApplicationIsFrontmost() throws {
        guard let targetApplicationProcessID else { return }
        let currentApplication = access.currentApplication()
        let applicationComparison: String
        if let currentBundle = currentApplication?.bundleIdentifier,
           let targetApplicationBundleIdentifier {
            applicationComparison = currentBundle == targetApplicationBundleIdentifier ? "equal" : "different"
        } else {
            applicationComparison = "unavailable"
        }
        let processComparison: String
        if let currentPID = currentApplication?.processIdentifier {
            processComparison = currentPID == Int32(targetApplicationProcessID) ? "equal" : "different"
        } else {
            processComparison = "unavailable"
        }
        guard processComparison == "equal" else {
            let identityFailure = currentApplication == nil
                ? "frontmost_application_unavailable"
                : (applicationComparison == "different" ? "application_changed" : "frontmost_process_changed")
            recordDiagnostic("input_application_changed", [
                "identityFailure": identityFailure,
                "applicationComparison": applicationComparison,
                "processComparison": processComparison
            ])
            invalidateKeyboardRawInsertionRegion()
            throw TextTargetError.targetChanged
        }
    }

    // AX may report an Electron/WebKit accessibility element owned by a
    // renderer process. Synthetic keyboard input must be delivered to the
    // frontmost application process so its normal event routing reaches the
    // focused web control.
    private var eventProcessID: pid_t? {
        targetApplicationProcessID ?? targetProcessID
    }

    private func focusedElement() throws -> AXUIElement {
        try access.focusedElement()
    }

    private func readableText(in element: AXUIElement) -> String? {
        try? access.text(in: element)
    }

    private func captureReadableText(
        in element: AXUIElement,
        context: AXTextInputTargetContext?
    ) throws -> String? {
        do {
            return try access.text(in: element)
        } catch KeyboardWriteReadError.retryable, TextTargetError.unsupported {
            return nil
        } catch {
            guard shouldStopBeforeUncertainWebWrite(context) else { throw error }
            return nil
        }
    }

    private func readCodexTextDocument(
        rawText: String,
        selection: TextRange,
        evidence: AXPlaceholderEvidence,
        element: AXUIElement
    ) throws -> AXTextDocumentState {
        let probe = AXTextCoordinateProbe { [weak self] range in
            guard let self else { return nil }
            return try self.readTextEvidence(.axStringForRange, fields: [
                "requestedRangeLocationUTF16": String(range.location),
                "requestedRangeLengthUTF16": String(range.length)
            ]) { try self.access.coordinateText(for: range, in: element) }
        }
        return try AXTextDocumentResolver.resolve(
            rawText: rawText,
            selection: selection,
            placeholderEvidence: evidence,
            probe: probe
        )
    }

    private func placeholderEvidence(in element: AXUIElement) -> AXPlaceholderEvidence {
        access.placeholderEvidence(in: element)
    }

    private func recordCoordinateResolution(
        state: AXTextDocumentState,
        evidence: AXPlaceholderEvidence
    ) {
        let key = "resolved:\(state.mapping.source.rawValue):\(state.mapping.coordinateDocumentLength)"
        guard key != lastCoordinateDiagnosticKey else { return }
        lastCoordinateDiagnosticKey = key
        recordDiagnostic("ax_coordinate_mapping_resolved", [
            "coordinateSource": state.mapping.source.rawValue,
            "placeholderNormalized": String(state.placeholderNormalized),
            "axValueLengthUTF16": String(state.mapping.rawDocumentLength),
            "axCoordinateLengthUTF16": String(state.mapping.coordinateDocumentLength),
            "omittedStructuralSeparatorCount": String(state.mapping.omittedStructuralSeparatorCount),
            "placeholderAttributePresent": String(evidence.explicitPlaceholder?.isEmpty == false),
            "placeholderMarkedNodeCount": String(evidence.markedTexts.count),
            "placeholderOtherNodeCount": String(evidence.unmarkedTexts.filter { !$0.isEmpty }.count)
        ])
    }

    private func recordCoordinateResolutionFailure(
        _ error: AXTextDocumentResolutionError,
        rawText: String,
        selection: TextRange,
        evidence: AXPlaceholderEvidence,
        confirming: Bool = false
    ) {
        let reason = coordinateResolutionCode(for: error)
        let key = "failed:\(reason):\(rawText.utf16.count):\(selection.location):\(selection.length)"
        guard key != lastCoordinateDiagnosticKey else { return }
        lastCoordinateDiagnosticKey = key
        recordDiagnostic(confirming ? "ax_coordinate_mapping_retryable" : "ax_coordinate_mapping_failed", [
            "reason": reason,
            "axValueLengthUTF16": String(rawText.utf16.count),
            "selectionLocation": String(selection.location),
            "selectionLength": String(selection.length),
            "placeholderAttributePresent": String(evidence.explicitPlaceholder?.isEmpty == false),
            "placeholderMarkedNodeCount": String(evidence.markedTexts.count),
            "placeholderOtherNodeCount": String(evidence.unmarkedTexts.filter { !$0.isEmpty }.count)
        ])
    }

    private func coordinateResolutionCode(for error: AXTextDocumentResolutionError) -> String {
        switch error {
        case .invalidSelection: return "invalid_selection"
        case .coordinateReadUnavailable: return "coordinate_read_unavailable"
        case .coordinateLengthMismatch: return "coordinate_length_mismatch"
        case .coordinateTextMismatch: return "coordinate_text_mismatch"
        case .selectionOutOfBounds: return "selection_out_of_bounds"
        case .selectedRangeUnavailable: return "selected_range_unavailable"
        }
    }

    private func readableSelection(in element: AXUIElement) -> TextRange? {
        try? access.selection(in: element)
    }

    private func captureReadableSelection(
        in element: AXUIElement,
        context: AXTextInputTargetContext?
    ) throws -> TextRange? {
        do {
            return try access.selection(in: element)
        } catch KeyboardWriteReadError.retryable, TextTargetError.unsupported {
            return nil
        } catch {
            guard shouldStopBeforeUncertainWebWrite(context) else { throw error }
            return nil
        }
    }

    private func shouldStopBeforeUncertainWebWrite(_ context: AXTextInputTargetContext?) -> Bool {
        guard let context,
              context.role == "AXTextArea" || context.role == "AXTextField" else {
            return false
        }
        switch context.ancestorScanStatus {
        case .webArea, .truncated, .cycle, .readFailure:
            return true
        case .completeWithoutWebArea:
            return false
        }
    }

    private func isValidTextRange(_ range: TextRange, in text: String) -> Bool {
        range.location >= 0
            && range.length >= 0
            && range.location <= text.utf16.count
            && range.length <= text.utf16.count - range.location
    }

}

@MainActor
final class SystemAXTextTargetAccess: AXTextTargetAccess {
    private struct AncestorAttributeReadFailure: Error {}
    private var readDiagnostics: [TextInputDiagnostic] = []
    private var activeContinuityScanID: String?
    private var activeContinuityScanObjectGeneration: String?
    private var activeContinuityScanDeadlineNanoseconds: UInt64?
    private var activeContinuityScanFailureFields: [String: String]?
    private var activeContinuityScanSummaryFields: [String: String]?
    private(set) var lastContinuityScanID: String?
    private(set) var lastContinuityScanSummaryFields: [String: String]?
    private var readDiagnosticEvictionCount = 0
    private var firstReadDiagnosticEvictionAt: Date?
    private var lastReadDiagnosticEvictionAt: Date?
    private var firstReadDiagnosticEvictionMonotonicNanoseconds: UInt64?
    private var lastReadDiagnosticEvictionMonotonicNanoseconds: UInt64?
    private var coalescedReadDiagnosticCount = 0
    private var lastReadDiagnosticQueueIncidentAt: Date?
    private var lastReadDiagnosticQueueIncidentMonotonicNanoseconds: UInt64?
    private var continuityDiagnosticsEnabled = true
    struct ContinuityAXReader {
        var copyAttributeValue: (AXUIElement, String) -> (AXError, CFTypeRef?)
        var setMessagingTimeout: (AXUIElement, Float) -> Void
        var processIdentifier: (AXUIElement) -> pid_t?
        var now: () -> Date
        var monotonicNanoseconds: () -> UInt64
        var isAttributeSettable: (AXUIElement, String) -> Bool

        init(
            copyAttributeValue: @escaping (AXUIElement, String) -> (AXError, CFTypeRef?),
            setMessagingTimeout: @escaping (AXUIElement, Float) -> Void,
            processIdentifier: @escaping (AXUIElement) -> pid_t?,
            now: @escaping () -> Date,
            monotonicNanoseconds: @escaping () -> UInt64,
            isAttributeSettable: @escaping (AXUIElement, String) -> Bool = { _, _ in false }
        ) {
            self.copyAttributeValue = copyAttributeValue
            self.setMessagingTimeout = setMessagingTimeout
            self.processIdentifier = processIdentifier
            self.now = now
            self.monotonicNanoseconds = monotonicNanoseconds
            self.isAttributeSettable = isAttributeSettable
        }

        static let system = ContinuityAXReader(
            copyAttributeValue: { element, name in
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                return (status, value)
            },
            setMessagingTimeout: { AXUIElementSetMessagingTimeout($0, $1) },
            processIdentifier: { element in
                var processID: pid_t = 0
                guard AXUIElementGetPid(element, &processID) == .success, processID != 0 else { return nil }
                return processID
            },
            now: Date.init,
            monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            isAttributeSettable: { element, attribute in
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
                    && settable.boolValue
            }
        )
    }

    private let continuityAXReader: ContinuityAXReader

    init(continuityAXReader: ContinuityAXReader = .system) {
        self.continuityAXReader = continuityAXReader
    }

    func lastContinuityScanObservationID() -> String? { lastContinuityScanID }
    func lastContinuityScanSummary() -> [String: String]? { lastContinuityScanSummaryFields }

    func setContinuityDiagnosticsEnabled(_ enabled: Bool) {
        continuityDiagnosticsEnabled = enabled
        guard !enabled else { return }
        readDiagnostics.removeAll(keepingCapacity: true)
        readDiagnosticEvictionCount = 0
        firstReadDiagnosticEvictionAt = nil
        lastReadDiagnosticEvictionAt = nil
        firstReadDiagnosticEvictionMonotonicNanoseconds = nil
        lastReadDiagnosticEvictionMonotonicNanoseconds = nil
        coalescedReadDiagnosticCount = 0
        lastReadDiagnosticQueueIncidentAt = nil
        lastReadDiagnosticQueueIncidentMonotonicNanoseconds = nil
        lastContinuityScanID = nil
        lastContinuityScanSummaryFields = nil
        activeContinuityScanFailureFields = nil
        activeContinuityScanSummaryFields = nil
        activeContinuityScanObjectGeneration = nil
    }

    func setContinuityScanObjectGeneration(_ generation: String?) {
        activeContinuityScanObjectGeneration = generation
    }

    func setContinuityScanBudgetNanoseconds(_ budget: UInt64?) {
        activeContinuityScanDeadlineNanoseconds = budget.map {
            continuityAXReader.monotonicNanoseconds() &+ $0
        }
    }

    private func continuityScanDeadline() -> Date {
        guard let deadlineNanoseconds = activeContinuityScanDeadlineNanoseconds else {
            return continuityAXReader.now().addingTimeInterval(0.25)
        }
        let nowNanoseconds = continuityAXReader.monotonicNanoseconds()
        let remainingNanoseconds = deadlineNanoseconds > nowNanoseconds
            ? deadlineNanoseconds - nowNanoseconds
            : 0
        return continuityAXReader.now().addingTimeInterval(Double(remainingNanoseconds) / 1_000_000_000)
    }

    func drainReadDiagnostics() -> [TextInputDiagnostic] {
        guard continuityDiagnosticsEnabled else {
            setContinuityDiagnosticsEnabled(false)
            return []
        }
        var result = readDiagnostics
        if readDiagnosticEvictionCount > 0 || coalescedReadDiagnosticCount > 0 {
            let now = lastReadDiagnosticQueueIncidentAt ?? continuityAXReader.now()
            result.append(TextInputDiagnostic(
                timestamp: now,
                monotonicTimestampNanoseconds: lastReadDiagnosticQueueIncidentMonotonicNanoseconds
                    ?? continuityAXReader.monotonicNanoseconds(),
                event: "ax_read_diagnostic_queue_summary",
                fields: [
                    "evictedCount": String(readDiagnosticEvictionCount),
                    "firstEvictionAt": firstReadDiagnosticEvictionAt.map(DiagnosticReportTime.format) ?? "none",
                    "lastEvictionAt": lastReadDiagnosticEvictionAt.map(DiagnosticReportTime.format) ?? "none",
                    "firstEvictionMonotonicNanoseconds": firstReadDiagnosticEvictionMonotonicNanoseconds.map(String.init) ?? "none",
                    "lastEvictionMonotonicNanoseconds": lastReadDiagnosticEvictionMonotonicNanoseconds.map(String.init) ?? "none",
                    "coalescedDuplicateCount": String(coalescedReadDiagnosticCount),
                    "capacity": "16"
                ]
            ))
        }
        readDiagnostics.removeAll(keepingCapacity: true)
        readDiagnosticEvictionCount = 0
        firstReadDiagnosticEvictionAt = nil
        lastReadDiagnosticEvictionAt = nil
        firstReadDiagnosticEvictionMonotonicNanoseconds = nil
        lastReadDiagnosticEvictionMonotonicNanoseconds = nil
        coalescedReadDiagnosticCount = 0
        lastReadDiagnosticQueueIncidentAt = nil
        lastReadDiagnosticQueueIncidentMonotonicNanoseconds = nil
        return result
    }

    private func recordReadStatus(_ status: AXError, attribute: String) {
        guard status != .success else { return }
        let fields = ["axAttribute": attribute, "axStatus": String(status.rawValue)]
        appendReadDiagnostic(event: "ax_read_failed", fields: fields)
    }

    private func appendReadDiagnostic(event: String, fields: [String: String]) {
        guard continuityDiagnosticsEnabled else { return }
        let timestamp = continuityAXReader.now()
        let monotonicTimestamp = continuityAXReader.monotonicNanoseconds()
        if readDiagnostics.last?.event == event, readDiagnostics.last?.fields == fields {
            coalescedReadDiagnosticCount += 1
            lastReadDiagnosticQueueIncidentAt = timestamp
            lastReadDiagnosticQueueIncidentMonotonicNanoseconds = monotonicTimestamp
            return
        }
        if readDiagnostics.count >= 16 {
            readDiagnostics.removeFirst()
            readDiagnosticEvictionCount += 1
            let evictedAt = timestamp
            firstReadDiagnosticEvictionAt = firstReadDiagnosticEvictionAt ?? evictedAt
            lastReadDiagnosticEvictionAt = evictedAt
            firstReadDiagnosticEvictionMonotonicNanoseconds = firstReadDiagnosticEvictionMonotonicNanoseconds
                ?? monotonicTimestamp
            lastReadDiagnosticEvictionMonotonicNanoseconds = monotonicTimestamp
            lastReadDiagnosticQueueIncidentAt = evictedAt
            lastReadDiagnosticQueueIncidentMonotonicNanoseconds = monotonicTimestamp
        }
        var recordedFields = fields
        if let activeContinuityScanID { recordedFields["scanID"] = activeContinuityScanID }
        if let activeContinuityScanObjectGeneration {
            recordedFields["objectGeneration"] = activeContinuityScanObjectGeneration
        }
        readDiagnostics.append(TextInputDiagnostic(
            timestamp: timestamp,
            monotonicTimestampNanoseconds: monotonicTimestamp,
            event: event,
            fields: recordedFields
        ))
    }

    private func recordEditorContinuityScanDiagnostic(
        stage: String,
        reason: String,
        attribute: String? = nil,
        status: AXError? = nil,
        depth: Int? = nil,
        visitedNodes: Int? = nil,
        candidateIndex: Int? = nil,
        candidateCount: Int? = nil,
        candidateEditableCounts: [Int]? = nil,
        editableEditorCount: Int? = nil,
        scanStartedAt: UInt64
    ) {
        let now = continuityAXReader.monotonicNanoseconds()
        let fields = AXTextEditorContinuityScanDiagnostic.fields(
            stage: stage,
            reason: reason,
            attribute: attribute,
            status: status?.rawValue,
            depth: depth,
            visitedNodes: visitedNodes,
            candidateIndex: candidateIndex,
            candidateCount: candidateCount,
            candidateEditableCounts: candidateEditableCounts,
            editableEditorCount: editableEditorCount,
            elapsedMilliseconds: max(0, now &- scanStartedAt) / 1_000_000
        )
        if activeContinuityScanID != nil {
            activeContinuityScanFailureFields = fields
            for key in ["candidateCount", "visitedNodes", "editableEditorCount"] {
                if let value = fields[key] { activeContinuityScanSummaryFields?[key] = value }
            }
        }
        appendReadDiagnostic(event: AXTextEditorContinuityScanDiagnostic.event, fields: fields)
    }

    func isProseMirrorEditor(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXRoleAttribute as String, from: element) == "AXTextArea"
            && classTokens(in: element).contains("prosemirror")
    }

    func requestInputPermissions() throws {
        guard AXIsProcessTrusted() else {
            throw TextTargetError.accessibilityDenied
        }
        guard CGPreflightPostEventAccess() else {
            throw TextTargetError.postEventDenied
        }
    }

    func currentApplication() -> TextTargetApplication? {
        NSWorkspace.shared.frontmostApplication.map {
            TextTargetApplication(
                name: $0.localizedName ?? "未知应用",
                bundleIdentifier: $0.bundleIdentifier,
                processIdentifier: Int32($0.processIdentifier)
            )
        }
    }

    func focusedElement() throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        guard let elementObject = try attribute(kAXFocusedUIElementAttribute as String, from: system) else {
            throw TextTargetError.unsupported
        }
        return elementObject as! AXUIElement
    }

    func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success, processID != 0 else {
            return nil
        }
        return processID
    }

    func elementValidity(_ element: AXUIElement) -> AXTextElementValidity {
        let scanStartedAt = continuityAXReader.monotonicNanoseconds()
        continuityAXReader.setMessagingTimeout(element, 0.03)
        let (status, _) = continuityAXReader.copyAttributeValue(element, kAXRoleAttribute as String)
        switch status {
        case .success: return .valid
        case .invalidUIElement:
            recordEditorContinuityScanDiagnostic(
                stage: "previous_handle_validity",
                reason: "invalid_handle",
                attribute: kAXRoleAttribute as String,
                status: status,
                scanStartedAt: scanStartedAt
            )
            return .invalid
        default:
            recordEditorContinuityScanDiagnostic(
                stage: "previous_handle_validity",
                reason: "read_failed",
                attribute: kAXRoleAttribute as String,
                status: status,
                scanStartedAt: scanStartedAt
            )
            return .unavailable
        }
    }

    func editorContinuityEvidence(for element: AXUIElement) -> AXTextEditorContinuityEvidence? {
        let priorScanID = activeContinuityScanID
        let priorObjectGeneration = activeContinuityScanObjectGeneration
        let scanID = UUID().uuidString
        lastContinuityScanID = scanID
        let startedAt = continuityAXReader.monotonicNanoseconds()
        activeContinuityScanID = scanID
        activeContinuityScanSummaryFields = [:]
        activeContinuityScanFailureFields = nil
        let evidence = scanEditorContinuityEvidence(for: element)
        let failureFields = activeContinuityScanFailureFields
        let scanMetrics = activeContinuityScanSummaryFields ?? [:]
        activeContinuityScanID = priorScanID
        activeContinuityScanObjectGeneration = priorObjectGeneration
        activeContinuityScanFailureFields = nil
        activeContinuityScanSummaryFields = nil
        var fields: [String: String] = [
            "scanID": scanID,
            "objectGeneration": priorObjectGeneration ?? "unknown",
            "scanPath": "ancestor_scan",
            "scanComplete": String(evidence?.scanComplete == true),
            "elapsedMilliseconds": String(max(0, continuityAXReader.monotonicNanoseconds() &- startedAt) / 1_000_000)
        ]
        fields.merge(scanMetrics) { _, new in new }
        fields["candidateCount"] = fields["candidateCount"]
            ?? String(evidence?.editableEditorCount ?? Int(failureFields?["candidateCount"] ?? "") ?? 0)
        fields["visitedNodes"] = fields["visitedNodes"] ?? failureFields?["visitedNodes"] ?? "unknown"
        if let evidence {
            fields["outcome"] = "unique_editor_found"
            fields["rolePathDepth"] = String(evidence.rolesFromEditorToAnchor.count)
            fields["identifierPresence"] = evidence.identifiersFromEditorToAnchor.map { $0 == nil ? "missing" : "present" }.joined(separator: ",")
        } else {
            fields["outcome"] = "scan_failed"
            if let failureFields {
                fields["stopStage"] = failureFields["scanStage"] ?? "unknown"
                fields["stopReason"] = failureFields["reason"] ?? "unknown"
                fields["failureAttribute"] = failureFields["axAttribute"] ?? "none"
                fields["failureStatus"] = failureFields["axStatus"] ?? "none"
            }
        }
        appendReadDiagnostic(event: "editor_continuity_scan_summary", fields: fields)
        if continuityDiagnosticsEnabled {
            lastContinuityScanSummaryFields = fields
        } else {
            lastContinuityScanID = nil
            lastContinuityScanSummaryFields = nil
        }
        return evidence
    }

    private func scanEditorContinuityEvidence(for element: AXUIElement) -> AXTextEditorContinuityEvidence? {
        let deadline = continuityScanDeadline()
        let scanStartedAt = continuityAXReader.monotonicNanoseconds()
        var node = element
        var roles: [String] = []
        var identifiers: [String?] = []
        var candidates: [(element: AXUIElement, role: String, depth: Int)] = []
        var webArea: AXUIElement?

        for depth in 0..<64 {
            guard continuityAXReader.now() < deadline else {
                recordEditorContinuityScanDiagnostic(
                    stage: "ancestor_role", reason: "deadline_exceeded",
                    attribute: kAXRoleAttribute as String, depth: depth,
                    scanStartedAt: scanStartedAt
                )
                return nil
            }
            guard let role = requiredAXString(
                kAXRoleAttribute as String, in: node, stage: "ancestor_role",
                depth: depth, deadline: deadline, scanStartedAt: scanStartedAt
            ) else { return nil }
            roles.append(role)
            guard let identifier = optionalAXString(
                kAXIdentifierAttribute as String, in: node, deadline: deadline,
                stage: "ancestor_identifier", depth: depth, scanStartedAt: scanStartedAt
            ) else {
                return nil
            }
            identifiers.append(identifier)
            if role == "AXWebArea" {
                webArea = node
                break
            }
            if role == "AXGroup" || role == "AXContainer" {
                candidates.append((node, role, depth))
            }
            guard let parent = requiredAXElement(
                "AXParent", in: node, stage: "ancestor_parent", depth: depth,
                deadline: deadline, scanStartedAt: scanStartedAt
            ) else { return nil }
            node = parent
        }
        guard let webArea else {
            recordEditorContinuityScanDiagnostic(
                stage: "ancestor_scan", reason: "web_area_not_found_before_depth_limit",
                depth: 64, candidateCount: candidates.count,
                scanStartedAt: scanStartedAt
            )
            return nil
        }
        guard let window = requiredAXElement(
            kAXWindowAttribute as String,
            in: element,
            stage: "target_window",
            depth: 0,
            deadline: deadline,
            scanStartedAt: scanStartedAt
        ),
        let targetProcessID = continuityAXReader.processIdentifier(element),
        let windowProcessID = continuityAXReader.processIdentifier(window),
        windowProcessID == targetProcessID else {
            recordEditorContinuityScanDiagnostic(
                stage: "target_window", reason: "window_identity_unavailable_or_wrong_process",
                attribute: kAXWindowAttribute as String, scanStartedAt: scanStartedAt
            )
            return nil
        }

        var scannedCandidateCounts: [Int] = []
        for (candidateIndex, candidate) in candidates.enumerated() {
            guard continuityAXReader.now() < deadline else {
                recordEditorContinuityScanDiagnostic(
                    stage: "candidate_subtree", reason: "deadline_exceeded",
                    depth: candidate.depth, visitedNodes: 0,
                    candidateIndex: candidateIndex, candidateCount: candidates.count,
                    scanStartedAt: scanStartedAt
                )
                return nil
            }
            guard let (count, complete, visitedNodes) = editableEditorCount(
                in: candidate.element, deadline: deadline, candidateIndex: candidateIndex,
                candidateCount: candidates.count, scanStartedAt: scanStartedAt
            ), complete else { return nil }
            scannedCandidateCounts.append(count)
            activeContinuityScanSummaryFields?["candidateCount"] = String(candidates.count)
            let nodesVisitedSoFar = Int(activeContinuityScanSummaryFields?["visitedNodes"] ?? "\(roles.count)") ?? roles.count
            activeContinuityScanSummaryFields?["visitedNodes"] = String(nodesVisitedSoFar + visitedNodes)
            if count == 1 {
                return AXTextEditorContinuityEvidence(
                    webArea: webArea,
                    window: window,
                    editorAnchor: candidate.element,
                    editorAnchorRole: candidate.role,
                    rolesFromEditorToAnchor: Array(roles.prefix(candidate.depth)),
                    identifiersFromEditorToAnchor: Array(identifiers.prefix(candidate.depth)),
                    editableEditorCount: count,
                    scanComplete: true
                )
            }
        }
        recordEditorContinuityScanDiagnostic(
            stage: "candidate_selection", reason: "no_unique_editable_editor",
            candidateCount: candidates.count,
            candidateEditableCounts: scannedCandidateCounts,
            editableEditorCount: scannedCandidateCounts.reduce(0, +),
            scanStartedAt: scanStartedAt
        )
        activeContinuityScanSummaryFields?["candidateCount"] = String(candidates.count)
        let priorVisitedNodes = Int(activeContinuityScanSummaryFields?["visitedNodes"] ?? "0") ?? 0
        activeContinuityScanSummaryFields?["visitedNodes"] = String(roles.count + priorVisitedNodes)
        return nil
    }

    func editorContinuityEvidence(
        for element: AXUIElement,
        anchoredAt previous: AXTextEditorContinuityEvidence
    ) -> AXTextEditorContinuityEvidence? {
        let priorScanID = activeContinuityScanID
        let priorObjectGeneration = activeContinuityScanObjectGeneration
        let scanID = UUID().uuidString
        lastContinuityScanID = scanID
        let startedAt = continuityAXReader.monotonicNanoseconds()
        activeContinuityScanID = scanID
        activeContinuityScanSummaryFields = [:]
        activeContinuityScanFailureFields = nil
        let evidence = scanAnchoredEditorContinuityEvidence(for: element, anchoredAt: previous)
        let failureFields = activeContinuityScanFailureFields
        let scanMetrics = activeContinuityScanSummaryFields ?? [:]
        activeContinuityScanID = priorScanID
        activeContinuityScanObjectGeneration = priorObjectGeneration
        activeContinuityScanFailureFields = nil
        activeContinuityScanSummaryFields = nil
        var fields: [String: String] = [
            "scanID": scanID,
            "objectGeneration": priorObjectGeneration ?? "unknown",
            "scanPath": "captured_anchor_subtree",
            "scanComplete": String(evidence?.scanComplete == true),
            "elapsedMilliseconds": String(max(0, continuityAXReader.monotonicNanoseconds() &- startedAt) / 1_000_000)
        ]
        fields.merge(scanMetrics) { _, new in new }
        fields["candidateCount"] = fields["candidateCount"]
            ?? String(evidence?.editableEditorCount ?? Int(failureFields?["candidateCount"] ?? "") ?? 0)
        fields["visitedNodes"] = fields["visitedNodes"] ?? failureFields?["visitedNodes"] ?? "unknown"
        if let evidence {
            fields["outcome"] = "unique_editor_found"
            fields["rolePathDepth"] = String(evidence.rolesFromEditorToAnchor.count)
            fields["identifierPresence"] = evidence.identifiersFromEditorToAnchor.map { $0 == nil ? "missing" : "present" }.joined(separator: ",")
        } else {
            fields["outcome"] = "scan_failed"
            if let failureFields {
                fields["stopStage"] = failureFields["scanStage"] ?? "unknown"
                fields["stopReason"] = failureFields["reason"] ?? "unknown"
                fields["failureAttribute"] = failureFields["axAttribute"] ?? "none"
                fields["failureStatus"] = failureFields["axStatus"] ?? "none"
            }
        }
        appendReadDiagnostic(event: "editor_continuity_scan_summary", fields: fields)
        if continuityDiagnosticsEnabled {
            lastContinuityScanSummaryFields = fields
        } else {
            lastContinuityScanID = nil
            lastContinuityScanSummaryFields = nil
        }
        return evidence
    }

    private func scanAnchoredEditorContinuityEvidence(
        for element: AXUIElement,
        anchoredAt previous: AXTextEditorContinuityEvidence
    ) -> AXTextEditorContinuityEvidence? {
        let started = continuityAXReader.monotonicNanoseconds()
        let deadline = continuityScanDeadline()
        guard let previousWindow = previous.window,
              let currentWindow = requiredAXElement(
                kAXWindowAttribute as String,
                in: element,
                stage: "anchored_target_window",
                depth: 0,
                deadline: deadline,
                scanStartedAt: started
              ),
              let elementProcessID = continuityAXReader.processIdentifier(element),
              let windowProcessID = continuityAXReader.processIdentifier(currentWindow),
              CFEqual(previousWindow, currentWindow),
              windowProcessID == elementProcessID else {
            recordEditorContinuityScanDiagnostic(
                stage: "anchored_target_window", reason: "window_identity_changed_or_unavailable",
                attribute: kAXWindowAttribute as String, scanStartedAt: started
            )
            return nil
        }
        do {
            let anchorBelongsToCapturedWebArea = try AXAnchoredEditorScanner.isDescendant(
                previous.editorAnchor,
                of: previous.webArea,
                equals: { CFEqual($0, $1) },
                parent: { node in
                    guard let parent = self.requiredAXElement(
                        "AXParent",
                        in: node,
                        stage: "anchored_web_area_relation",
                        depth: 0,
                        deadline: deadline,
                        scanStartedAt: started
                    ) else {
                        throw AXAnchoredEditorScanFailure(
                            attribute: "AXParent", status: 0, reason: "web_area_relation_unavailable"
                        )
                    }
                    return parent
                }
            )
            guard anchorBelongsToCapturedWebArea else {
                recordEditorContinuityScanDiagnostic(
                    stage: "anchored_web_area_relation", reason: "captured_anchor_left_web_area",
                    attribute: "AXParent", scanStartedAt: started
                )
                return nil
            }
        } catch let failure as AXAnchoredEditorScanFailure {
            recordEditorContinuityScanDiagnostic(
                stage: "anchored_web_area_relation", reason: failure.reason,
                attribute: failure.attribute, status: AXError(rawValue: failure.status),
                scanStartedAt: started
            )
            return nil
        } catch {
            recordEditorContinuityScanDiagnostic(
                stage: "anchored_web_area_relation", reason: "unexpected_parent_scan_failure",
                attribute: "AXParent", scanStartedAt: started
            )
            return nil
        }
        func value(_ name: String, in node: AXUIElement, optional: Bool = false) throws -> CFTypeRef? {
            var result: CFTypeRef?
            continuityAXReader.setMessagingTimeout(node, 0.03)
            let (status, value) = continuityAXReader.copyAttributeValue(node, name)
            result = value
            if status == .success { return result }
            if optional && (status == .noValue || status == .attributeUnsupported) { return nil }
            if name == "AXChildren", status == .noValue { return nil }
            throw AXAnchoredEditorScanFailure(attribute: name, status: status.rawValue, reason: "read_failed")
        }
        do {
            let result = try AXAnchoredEditorScanner.scan(
                anchor: previous.editorAnchor,
                target: element,
                anchorRole: previous.editorAnchorRole,
                equals: { CFEqual($0, $1) },
                role: { node in
                    guard let string = try value(kAXRoleAttribute as String, in: node) as? String else {
                        throw AXAnchoredEditorScanFailure(attribute: kAXRoleAttribute as String,
                            status: AXError.success.rawValue, reason: "unexpected_value_type")
                    }
                    return string
                },
                identifier: { node in
                    try value(kAXIdentifierAttribute as String, in: node, optional: true) as? String
                },
                subrole: { node in
                    try value(kAXSubroleAttribute as String, in: node, optional: true) as? String
                },
                readOnly: { node in
                    do {
                        guard let raw = try value("AXReadOnly", in: node), let flag = raw as? Bool else {
                            return nil
                        }
                        return flag
                    } catch let failure as AXAnchoredEditorScanFailure
                        where failure.attribute == "AXReadOnly"
                            && [AXError.noValue.rawValue, AXError.attributeUnsupported.rawValue].contains(failure.status) {
                        continuityAXReader.setMessagingTimeout(node, 0.03)
                        guard continuityAXReader.isAttributeSettable(node, kAXValueAttribute as String) else {
                            throw failure
                        }
                        activeContinuityScanSummaryFields?["writabilityEvidence"] = "AXValue_settable_after_AXReadOnly_unavailable"
                        return false
                    }
                },
                children: { node in
                    guard let raw = try value("AXChildren", in: node) else { return [] }
                    guard let children = raw as? [AXUIElement] else {
                        throw AXAnchoredEditorScanFailure(attribute: "AXChildren",
                            status: AXError.success.rawValue, reason: "unexpected_value_type")
                    }
                    return children
                }
            )
            activeContinuityScanSummaryFields?["candidateCount"] = String(result.editableEditorCount)
            activeContinuityScanSummaryFields?["visitedNodes"] = String(result.visitedNodeCount)
            guard result.editableEditorCount == 1,
                  result.targetFound,
                  let roles = result.rolesFromEditorToAnchor,
                  let identifiers = result.identifiersFromEditorToAnchor else {
                recordEditorContinuityScanDiagnostic(
                    stage: "anchored_candidate_subtree", reason: "target_not_unique_in_stable_anchor",
                    candidateEditableCounts: [result.editableEditorCount],
                    editableEditorCount: result.editableEditorCount, scanStartedAt: started
                )
                return nil
            }
            return AXTextEditorContinuityEvidence(
                webArea: previous.webArea,
                window: currentWindow,
                editorAnchor: previous.editorAnchor,
                editorAnchorRole: previous.editorAnchorRole,
                rolesFromEditorToAnchor: roles,
                identifiersFromEditorToAnchor: identifiers,
                editableEditorCount: result.editableEditorCount,
                scanComplete: true
            )
        } catch let failure as AXAnchoredEditorScanFailure {
            recordEditorContinuityScanDiagnostic(
                stage: "anchored_candidate_subtree", reason: failure.reason,
                attribute: failure.attribute,
                status: AXError(rawValue: failure.status),
                visitedNodes: nil, editableEditorCount: nil, scanStartedAt: started
            )
            return nil
        } catch {
            recordEditorContinuityScanDiagnostic(
                stage: "anchored_candidate_subtree", reason: "unexpected_scan_failure",
                scanStartedAt: started
            )
            return nil
        }
    }

    private func editableEditorCount(
        in root: AXUIElement,
        deadline: Date,
        candidateIndex: Int,
        candidateCount: Int,
        scanStartedAt: UInt64
    ) -> (Int, Bool, Int)? {
        var pending = [root]
        var visited: [AXUIElement] = []
        var editableCount = 0
        while !pending.isEmpty {
            guard continuityAXReader.now() < deadline else {
                recordEditorContinuityScanDiagnostic(
                    stage: "candidate_subtree", reason: "deadline_exceeded",
                    depth: visited.count, visitedNodes: visited.count,
                    candidateIndex: candidateIndex, candidateCount: candidateCount,
                    editableEditorCount: editableCount, scanStartedAt: scanStartedAt
                )
                activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
                activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
                return (editableCount, false, visited.count)
            }
            guard visited.count < 160 else {
                recordEditorContinuityScanDiagnostic(
                    stage: "candidate_subtree", reason: "node_limit_reached",
                    depth: visited.count, visitedNodes: visited.count,
                    candidateIndex: candidateIndex, candidateCount: candidateCount,
                    editableEditorCount: editableCount, scanStartedAt: scanStartedAt
                )
                activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
                activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
                return (editableCount, false, visited.count)
            }
            let node = pending.removeLast()
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            guard let role = requiredAXString(
                kAXRoleAttribute as String, in: node, stage: "candidate_role",
                depth: visited.count - 1, deadline: deadline, scanStartedAt: scanStartedAt,
                visitedNodes: visited.count, candidateIndex: candidateIndex,
                candidateCount: candidateCount, editableEditorCount: editableCount
            ) else {
                activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
                activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
                return (editableCount, false, visited.count)
            }
            if ["AXTextArea", "AXTextField", "AXSearchField"].contains(role) {
                guard let subrole = optionalAXString(
                    kAXSubroleAttribute as String, in: node, deadline: deadline,
                    stage: "candidate_subrole", depth: visited.count - 1,
                    scanStartedAt: scanStartedAt, visitedNodes: visited.count,
                    candidateIndex: candidateIndex, candidateCount: candidateCount,
                    editableEditorCount: editableCount
                ), subrole != "AXSecureTextField" else {
                    activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
                    activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
                    return (editableCount, false, visited.count)
                }
                guard requiredAXBoolean(
                    "AXReadOnly", in: node, stage: "candidate_read_only",
                    depth: visited.count - 1, deadline: deadline, scanStartedAt: scanStartedAt,
                    visitedNodes: visited.count, candidateIndex: candidateIndex,
                    candidateCount: candidateCount, editableEditorCount: editableCount
                ) == false else {
                    activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
                    activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
                    return (editableCount, false, visited.count)
                }
                editableCount += 1
            }
            guard continuityAXReader.now() < deadline else {
                recordEditorContinuityScanDiagnostic(
                    stage: "candidate_children", reason: "deadline_exceeded",
                    attribute: "AXChildren", depth: visited.count - 1,
                    visitedNodes: visited.count, candidateIndex: candidateIndex,
                    candidateCount: candidateCount, editableEditorCount: editableCount,
                    scanStartedAt: scanStartedAt
                )
                activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
                activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
                return (editableCount, false, visited.count)
            }
            var childValue: CFTypeRef?
            continuityAXReader.setMessagingTimeout(node, 0.03)
            let (status, value) = continuityAXReader.copyAttributeValue(node, "AXChildren")
            childValue = value
            switch status {
            case .success:
                guard let children = childValue as? [AXUIElement] else {
                    recordEditorContinuityScanDiagnostic(
                        stage: "candidate_children", reason: "unexpected_value_type",
                        attribute: "AXChildren", status: status,
                        depth: visited.count - 1, visitedNodes: visited.count,
                        candidateIndex: candidateIndex, candidateCount: candidateCount,
                        editableEditorCount: editableCount, scanStartedAt: scanStartedAt
                    )
                    activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
                    activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
                    return (editableCount, false, visited.count)
                }
                pending.append(contentsOf: children)
            case .noValue: break
            default:
                recordEditorContinuityScanDiagnostic(
                    stage: "candidate_children", reason: "read_failed",
                    attribute: "AXChildren", status: status,
                    depth: visited.count - 1, visitedNodes: visited.count,
                    candidateIndex: candidateIndex, candidateCount: candidateCount,
                    editableEditorCount: editableCount, scanStartedAt: scanStartedAt
                )
                activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
                activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
                return (editableCount, false, visited.count)
            }
        }
        activeContinuityScanSummaryFields?["candidateCount"] = String(candidateCount)
        activeContinuityScanSummaryFields?["visitedNodes"] = String(visited.count)
        return (editableCount, true, visited.count)
    }

    private func requiredAXString(
        _ name: String,
        in element: AXUIElement,
        stage: String,
        depth: Int,
        deadline: Date,
        scanStartedAt: UInt64,
        visitedNodes: Int = 0,
        candidateIndex: Int? = nil,
        candidateCount: Int? = nil,
        editableEditorCount: Int? = nil
    ) -> String? {
        guard continuityAXReader.now() < deadline else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: "deadline_exceeded", attribute: name,
                depth: depth, visitedNodes: visitedNodes, candidateIndex: candidateIndex,
                candidateCount: candidateCount, editableEditorCount: editableEditorCount,
                scanStartedAt: scanStartedAt
            )
            return nil
        }
        var value: CFTypeRef?
        continuityAXReader.setMessagingTimeout(element, 0.03)
        let (status, copiedValue) = continuityAXReader.copyAttributeValue(element, name)
        value = copiedValue
        guard status == .success else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: "read_failed", attribute: name, status: status,
                depth: depth, visitedNodes: visitedNodes, candidateIndex: candidateIndex,
                candidateCount: candidateCount, editableEditorCount: editableEditorCount,
                scanStartedAt: scanStartedAt
            )
            return nil
        }
        guard let value, let string = value as? String else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: value == nil ? "value_missing" : "unexpected_value_type",
                attribute: name, status: status, depth: depth, visitedNodes: visitedNodes,
                candidateIndex: candidateIndex, candidateCount: candidateCount,
                editableEditorCount: editableEditorCount, scanStartedAt: scanStartedAt
            )
            return nil
        }
        return string
    }

    private func optionalAXString(
        _ name: String,
        in element: AXUIElement,
        deadline: Date,
        stage: String,
        depth: Int,
        scanStartedAt: UInt64,
        visitedNodes: Int = 0,
        candidateIndex: Int? = nil,
        candidateCount: Int? = nil,
        editableEditorCount: Int? = nil
    ) -> String?? {
        guard continuityAXReader.now() < deadline else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: "deadline_exceeded", attribute: name,
                depth: depth, visitedNodes: visitedNodes, candidateIndex: candidateIndex,
                candidateCount: candidateCount, editableEditorCount: editableEditorCount,
                scanStartedAt: scanStartedAt
            )
            return nil
        }
        var value: CFTypeRef?
        continuityAXReader.setMessagingTimeout(element, 0.03)
        let (status, copiedValue) = continuityAXReader.copyAttributeValue(element, name)
        value = copiedValue
        switch status {
        case .success:
            guard let value else { return .some(nil) }
            guard let string = value as? String else {
                recordEditorContinuityScanDiagnostic(
                    stage: stage, reason: "unexpected_value_type", attribute: name,
                    status: .success, depth: depth, visitedNodes: visitedNodes,
                    candidateIndex: candidateIndex, candidateCount: candidateCount,
                    editableEditorCount: editableEditorCount, scanStartedAt: scanStartedAt
                )
                return .some(nil)
            }
            return .some(string)
        case .attributeUnsupported, .noValue: return .some(nil)
        default:
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: "read_failed", attribute: name, status: status,
                depth: depth, visitedNodes: visitedNodes, candidateIndex: candidateIndex,
                candidateCount: candidateCount, editableEditorCount: editableEditorCount,
                scanStartedAt: scanStartedAt
            )
            return nil
        }
    }

    private func requiredAXElement(
        _ name: String,
        in element: AXUIElement,
        stage: String,
        depth: Int,
        deadline: Date,
        scanStartedAt: UInt64
    ) -> AXUIElement? {
        guard continuityAXReader.now() < deadline else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: "deadline_exceeded", attribute: name,
                depth: depth, scanStartedAt: scanStartedAt
            )
            return nil
        }
        var value: CFTypeRef?
        continuityAXReader.setMessagingTimeout(element, 0.03)
        let (status, copiedValue) = continuityAXReader.copyAttributeValue(element, name)
        value = copiedValue
        guard status == .success else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: "read_failed", attribute: name, status: status,
                depth: depth, scanStartedAt: scanStartedAt
            )
            return nil
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: value == nil ? "value_missing" : "unexpected_value_type",
                attribute: name, status: status, depth: depth,
                scanStartedAt: scanStartedAt
            )
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func requiredAXBoolean(
        _ name: String,
        in element: AXUIElement,
        stage: String,
        depth: Int,
        deadline: Date,
        scanStartedAt: UInt64,
        visitedNodes: Int,
        candidateIndex: Int,
        candidateCount: Int,
        editableEditorCount: Int
    ) -> Bool? {
        guard continuityAXReader.now() < deadline else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: "deadline_exceeded", attribute: name,
                depth: depth, visitedNodes: visitedNodes, candidateIndex: candidateIndex,
                candidateCount: candidateCount, editableEditorCount: editableEditorCount,
                scanStartedAt: scanStartedAt
            )
            return nil
        }
        var value: CFTypeRef?
        continuityAXReader.setMessagingTimeout(element, 0.03)
        let (status, copiedValue) = continuityAXReader.copyAttributeValue(element, name)
        value = copiedValue
        if status == .noValue { return false }
        guard status == .success else {
            recordEditorContinuityScanDiagnostic(
                stage: stage, reason: "read_failed", attribute: name, status: status,
                depth: depth, visitedNodes: visitedNodes, candidateIndex: candidateIndex,
                candidateCount: candidateCount, editableEditorCount: editableEditorCount,
                scanStartedAt: scanStartedAt
            )
            return nil
        }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        recordEditorContinuityScanDiagnostic(
            stage: stage, reason: value == nil ? "value_missing" : "unexpected_value_type",
            attribute: name, status: status, depth: depth, visitedNodes: visitedNodes,
            candidateIndex: candidateIndex, candidateCount: candidateCount,
            editableEditorCount: editableEditorCount, scanStartedAt: scanStartedAt
        )
        return nil
    }

    func textInputContext(for element: AXUIElement) -> AXTextInputTargetContext? {
        let role = stringAttribute(kAXRoleAttribute as String, from: element)
        let subroleState = stringAttributeState(kAXSubroleAttribute as String, from: element)
        let subrole = subroleState.value
        let secureAttribute = boolAttribute("AXSecureTextField", from: element)
        let isSecure: Bool?
        if subrole == "AXSecureTextField" {
            isSecure = true
        } else if !subroleState.known {
            isSecure = nil
        } else {
            isSecure = secureAttribute
        }
        let isReadOnly = boolAttribute("AXReadOnly", from: element)

        let deadline = Date().addingTimeInterval(0.25)
        var webArea: AXUIElement?
        var parentReadFailure = false
        let scan = AXTextAncestorScanner.scan(
            start: element,
            nodeLimit: 64,
            deadlineReached: { Date() >= deadline },
            role: { [weak self] node in
                self?.stringAttribute(kAXRoleAttribute as String, from: node)
            },
            parent: { [weak self] node in
                do {
                    return try self?.parentElementAttribute("AXParent", from: node)
                } catch {
                    parentReadFailure = true
                    return nil
                }
            },
            equals: { lhs, rhs in CFEqual(lhs, rhs) },
            onWebArea: { node, _ in webArea = node }
        )
        let resolvedScan = parentReadFailure && scan.status == .completeWithoutWebArea
            ? AXTextAncestorScanResult(status: .readFailure, webAreaDepth: nil)
            : scan
        return AXTextInputTargetContext(
            role: role,
            hasWebAreaAncestor: resolvedScan.status == .webArea,
            webURL: webArea.flatMap { urlAttribute("AXURL", from: $0) },
            isReadOnly: isReadOnly,
            isSecure: isSecure,
            ancestorScanStatus: resolvedScan.status,
            webAreaDepth: resolvedScan.webAreaDepth
        )
    }

    func text(in element: AXUIElement) throws -> String? {
        let value: CFTypeRef?
        do {
            value = try attribute(kAXValueAttribute as String, from: element)
        } catch TextTargetError.unsupported {
            return nil
        }
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let attributedText = value as? NSAttributedString { return attributedText.string }
        return nil
    }

    func selection(in element: AXUIElement) throws -> TextRange? {
        let value: CFTypeRef?
        do {
            value = try attribute(kAXSelectedTextRangeAttribute as String, from: element)
        } catch TextTargetError.unsupported {
            return nil
        }
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return TextRange(location: range.location, length: range.length)
    }

    func coordinateText(for range: TextRange, in element: AXUIElement) throws -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            throw TextTargetError.writeFailed
        }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        recordReadStatus(status, attribute: kAXStringForRangeParameterizedAttribute as String)
        switch status {
        case .success:
            guard let result else { return nil }
            if let text = result as? String { return text }
            if let attributedText = result as? NSAttributedString { return attributedText.string }
            return nil
        case .attributeUnsupported, .noValue:
            return nil
        case .cannotComplete:
            throw KeyboardWriteReadError.retryable
        default:
            throw TextTargetError.writeFailed
        }
    }

    func placeholderEvidence(in element: AXUIElement) -> AXPlaceholderEvidence {
        let explicitPlaceholder = stringAttribute("AXPlaceholderValue", from: element)
        var markedTexts: [String] = []
        var unmarkedTexts: [String] = []
        var visitedCount = 0

        func visit(
            _ node: AXUIElement,
            depth: Int,
            inheritedPlaceholder: Bool,
            isRoot: Bool
        ) {
            guard depth <= 6, visitedCount < 64 else { return }
            visitedCount += 1
            let marked = inheritedPlaceholder || classTokens(in: node).contains("placeholder")
            if !isRoot,
               stringAttribute("AXRole", from: node) == "AXStaticText",
               let text = stringAttribute(kAXValueAttribute as String, from: node),
               !text.isEmpty {
                if marked {
                    markedTexts.append(text)
                } else {
                    unmarkedTexts.append(text)
                }
            }
            for child in childElements(in: node) {
                visit(child, depth: depth + 1, inheritedPlaceholder: marked, isRoot: false)
            }
        }

        visit(element, depth: 0, inheritedPlaceholder: false, isRoot: true)
        return AXPlaceholderEvidence(
            explicitPlaceholder: explicitPlaceholder,
            markedTexts: markedTexts,
            unmarkedTexts: unmarkedTexts
        )
    }

    func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    func setSelection(_ range: TextRange, on element: AXUIElement) throws -> Int32 {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            throw TextTargetError.writeFailed
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ).rawValue
    }

    func setSelectedText(_ text: String, on element: AXUIElement) throws -> Int32 {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ).rawValue
    }

    func setValue(_ text: String, on element: AXUIElement) throws -> Int32 {
        AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        ).rawValue
    }

    private func childElements(in element: AXUIElement) -> [AXUIElement] {
        guard let value = try? attribute("AXChildren", from: element) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        guard let value = try? attribute(name, from: element) else { return nil }
        if let text = value as? String { return text }
        if let attributedText = value as? NSAttributedString { return attributedText.string }
        return nil
    }

    private func stringAttributeState(_ name: String, from element: AXUIElement) -> (value: String?, known: Bool) {
        var value: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.03)
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch status {
        case .success:
            if let text = value as? String { return (text, true) }
            if let attributedText = value as? NSAttributedString { return (attributedText.string, true) }
            return (nil, false)
        case .noValue:
            return (nil, true)
        default:
            recordReadStatus(status, attribute: name)
            return (nil, false)
        }
    }

    private func classTokens(in element: AXUIElement) -> Set<String> {
        guard let value = try? attribute("AXDOMClassList", from: element) else { return [] }
        if let values = value as? [String] {
            return Set(values.flatMap { classTokens(in: $0) })
        }
        return classTokens(in: String(describing: value))
    }

    private func classTokens(in value: String) -> Set<String> {
        Set(
            value
                .split { character in
                    !(character.isLetter || character.isNumber)
                }
                .map { $0.lowercased() }
        )
    }

    private func boolAttribute(_ name: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.03)
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status != .noValue else { return false }
        guard status == .success, let value else {
            recordReadStatus(status, attribute: name)
            return nil
        }
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func urlAttribute(_ name: String, from element: AXUIElement) -> URL? {
        guard let value = try? attribute(name, from: element) else { return nil }
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func parentElementAttribute(_ name: String, from element: AXUIElement) throws -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.03)
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch status {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw AncestorAttributeReadFailure()
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        case .noValue:
            return nil
        default:
            recordReadStatus(status, attribute: name)
            throw AncestorAttributeReadFailure()
        }
    }

    private func attribute(_ name: String, from element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.03)
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if [kAXFocusedUIElementAttribute, kAXValueAttribute, kAXSelectedTextRangeAttribute].contains(name) {
            recordReadStatus(status, attribute: name)
        }
        switch status {
        case .success:
            return value
        case .attributeUnsupported, .noValue:
            throw TextTargetError.unsupported
        case .cannotComplete:
            throw KeyboardWriteReadError.retryable
        case .invalidUIElement where [kAXValueAttribute as String, kAXSelectedTextRangeAttribute as String].contains(name):
            throw AXAttributeReadFailure(attribute: name, status: status.rawValue)
        default:
            throw TextTargetError.writeFailed
        }
    }
}

@MainActor
private final class KeyboardEventSender: AXTextTargetKeyboardEventSending, @unchecked Sendable {
    private let stageObserver: ((String) -> Void)?

    init(stageObserver: ((String) -> Void)? = nil) {
        self.stageObserver = stageObserver
    }
    private let queue = DispatchQueue(label: "local.tencent.voice.mvp.keyboard-events")
    private let leftArrowKeyCode: CGKeyCode = 123
    private let rightArrowKeyCode: CGKeyCode = 124
    private let deleteKeyCode: CGKeyCode = 51

    func selectTrailingText(_ previousText: String, processID: pid_t?) throws {
        try queue.sync {
            guard let source = CGEventSource(stateID: .privateState) else { throw TextTargetError.writeFailed }
            stageObserver?("selection_post_begin")
            for _ in previousText {
                try sendKey(keyCode: leftArrowKeyCode, flags: .maskShift, source: source, processID: processID)
            }
            stageObserver?("selection_post_end")
        }
    }

    func replaceSelection(with text: String, processID: pid_t?) throws {
        try queue.sync {
            stageObserver?("replacement_post_begin")
            if text.isEmpty {
                guard let source = CGEventSource(stateID: .privateState) else { throw TextTargetError.writeFailed }
                try sendKey(keyCode: deleteKeyCode, source: source, processID: processID)
            } else {
                try sendText(text, processID: processID)
            }
            stageObserver?("replacement_post_end")
        }
    }

    func send(_ text: String, processID: pid_t?) throws {
        try queue.sync {
            stageObserver?("append_post_begin")
            try sendText(text, processID: processID)
            stageObserver?("append_post_end")
        }
    }

    func advanceCaretRight(processID: pid_t?) throws {
        try queue.sync {
            guard let source = CGEventSource(stateID: .privateState) else {
                throw TextTargetError.writeFailed
            }
            stageObserver?("caret_recovery_post_begin")
            try sendKey(keyCode: rightArrowKeyCode, source: source, processID: processID)
            stageObserver?("caret_recovery_post_end")
        }
    }

    func replaceTrailingText(
        _ previousText: String,
        with text: String,
        processID: pid_t?
    ) throws {
        try queue.sync {
            guard !previousText.isEmpty else {
                try sendText(text, processID: processID)
                return
            }
            guard let source = CGEventSource(stateID: .privateState) else {
                throw TextTargetError.writeFailed
            }
            stageObserver?("selection_post_begin")
            for _ in previousText {
                try sendKey(
                    keyCode: leftArrowKeyCode,
                    flags: .maskShift,
                    source: source,
                    processID: processID
                )
            }
            stageObserver?("selection_post_end")
            stageObserver?("replacement_post_begin")
            if text.isEmpty {
                try sendKey(
                    keyCode: deleteKeyCode,
                    source: source,
                    processID: processID
                )
            } else {
                try sendText(text, processID: processID)
            }
            stageObserver?("replacement_post_end")
        }
    }

    private func sendText(_ text: String, processID: pid_t?) throws {
        guard !text.isEmpty else { return }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw TextTargetError.writeFailed
        }

        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count,
               units[end - 1] >= 0xD800,
               units[end - 1] <= 0xDBFF,
               units[end] >= 0xDC00,
               units[end] <= 0xDFFF {
                end -= 1
            }
            guard end > start else { throw TextTargetError.writeFailed }
            let chunk = String(decoding: units[start..<end], as: UTF16.self)
            guard let keyDown = SyntheticKeyboardEventFactory.unicodeEvent(
                source: source,
                text: chunk,
                keyDown: true
            ),
                  let keyUp = SyntheticKeyboardEventFactory.unicodeEvent(
                    source: source,
                    text: "",
                    keyDown: false
                  ) else {
                throw TextTargetError.writeFailed
            }
            post(keyDown, processID: processID)
            post(keyUp, processID: processID)
            start = end
        }
    }

    private func sendKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        source: CGEventSource,
        processID: pid_t?
    ) throws {
        guard let keyDown = SyntheticKeyboardEventFactory.keyEvent(
            source: source,
            keyCode: keyCode,
            keyDown: true,
            flags: flags
        ),
              let keyUp = SyntheticKeyboardEventFactory.keyEvent(
                source: source,
                keyCode: keyCode,
                keyDown: false,
                flags: flags
              ) else {
            throw TextTargetError.writeFailed
        }
        post(keyDown, processID: processID)
        post(keyUp, processID: processID)
    }

    private func post(_ event: CGEvent, processID: pid_t?) {
        if let processID {
            event.postToPid(processID)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}

enum SyntheticKeyboardEventFactory {
    static func keyEvent(
        source: CGEventSource,
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags = []
    ) -> CGEvent? {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else { return nil }
        event.flags = flags
        return event
    }

    static func unicodeEvent(
        source: CGEventSource,
        text: String,
        keyDown: Bool
    ) -> CGEvent? {
        guard let event = keyEvent(source: source, keyCode: 0, keyDown: keyDown) else {
            return nil
        }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        event.flags = []
        return event
    }
}
