import Foundation
import XCTest
@testable import TencentVoiceMVP

private typealias UniverseTextRange = TencentVoiceMVP.TextRange

@MainActor
final class AXCoordinateUniverseTests: XCTestCase {
    func testPlanLocalBoundaryUniverseHasTheDeclaredCardinality() {
        let counts = PlanLocalBoundaryUniverse.projectedCounts()

        XCTAssertEqual(counts.emptySelectionCases, 978_672)
        XCTAssertEqual(counts.allRangeCases, 2_842_224)
        XCTAssertEqual(PlanLocalBoundaryUniverse.contextCount, 4)
        XCTAssertEqual(PlanLocalBoundaryUniverse.separatorUnitCount, 0...3)
        XCTAssertEqual(PlanLocalBoundaryUniverse.payloadCount, 12)
    }

    func testExpandedLocalBoundaryUniverseCoversEveryDeclaredAxis() throws {
        var shapeCount = 0
        var stateCount = 0
        var productionCheckedShapeCount = 0
        var observedSemanticKinds: Set<LocalSeparatorSemantic> = []
        var observedEncodings: Set<LocalSeparatorEncoding> = []
        var observedRepresentations: Set<LocalCoordinateRepresentation> = []
        var observedContexts: Set<LocalBodyContext> = []

        for context in LocalBodyContext.allCases {
            for separatorCount in 0...3 {
                for units in LocalSeparatorUnit.allSequences(count: separatorCount) {
                    let shape = LocalBoundaryShape(context: context, units: units)
                    let (raw, coordinate) = shape.texts()
                    shapeCount += 1
                    observedContexts.insert(context)
                    observedSemanticKinds.formUnion(units.map(\.semantic))
                    observedEncodings.formUnion(units.map(\.encoding))
                    observedRepresentations.formUnion(units.map(\.representation))
                    stateCount += LocalPayload.allCases.count

                    // This oracle is deliberately built from the shape model,
                    // not from AXTextCoordinateAlignment or the production
                    // resolver. It checks that the generated coordinate text
                    // only omits declared structural units.
                    XCTAssertEqual(
                        coordinate,
                        shape.coordinateTextByIndependentOracle()
                    )
                    let resolved = try AXTextDocumentResolver.resolve(
                        rawText: raw,
                        selection: .init(location: coordinate.utf16.count, length: 0),
                        placeholderEvidence: .init(),
                        probe: localPrefixProbe(coordinate)
                    )
                    XCTAssertEqual(resolved.text, coordinate)
                    XCTAssertFalse(
                        resolved.mapping.rawRangeCandidates(
                            for: .init(location: coordinate.utf16.count, length: 0)
                        ).isEmpty,
                        "No compatible end boundary for \(shape)"
                    )
                    productionCheckedShapeCount += 1
                }
            }
        }

        XCTAssertEqual(shapeCount, 17_476)
        XCTAssertEqual(stateCount, 209_712)
        XCTAssertEqual(productionCheckedShapeCount, shapeCount)
        XCTAssertEqual(observedContexts, Set(LocalBodyContext.allCases))
        XCTAssertEqual(observedSemanticKinds, Set(LocalSeparatorSemantic.allCases))
        XCTAssertEqual(observedEncodings, Set(LocalSeparatorEncoding.allCases))
        XCTAssertEqual(observedRepresentations, Set(LocalCoordinateRepresentation.allCases))
    }

    func testExpandedLocalBoundaryUniverseExecutesEveryPayloadAtOuterBoundaries() throws {
        var shapeCount = 0
        var payloadStateCount = 0
        var boundaryCaseCount = 0

        for context in LocalBodyContext.allCases {
            for separatorCount in 0...3 {
                for units in LocalSeparatorUnit.allSequences(count: separatorCount) {
                    let shape = LocalBoundaryShape(context: context, units: units)
                    let (raw, coordinate) = shape.texts()
                    let coordinateBoundaries = [
                        UniverseTextRange(location: 0, length: 0),
                        UniverseTextRange(location: coordinate.utf16.count, length: 0)
                    ].reduce(into: [UniverseTextRange]()) { result, range in
                        if !result.contains(range) { result.append(range) }
                    }

                    for payload in LocalPayload.allCases {
                        payloadStateCount += 1
                        for range in coordinateBoundaries {
                            let rawRanges = independentRawRangeCandidates(
                                rawText: raw,
                                coordinateText: coordinate,
                                coordinateRange: range
                            )
                            XCTAssertFalse(
                                rawRanges.isEmpty,
                                "payload boundary has no raw path: shape=\(shape), range=\(range)"
                            )

                            let coordinateAfter = replacing(
                                coordinate,
                                range: range,
                                with: payload.text
                            )
                            let afterSelection = UniverseTextRange(
                                location: range.location + payload.text.utf16.count,
                                length: 0
                            )

                            for rawRange in rawRanges {
                                let rawAfter = replacing(
                                    raw,
                                    range: rawRange,
                                    with: payload.text
                                )
                                let resolved = try AXTextDocumentResolver.resolve(
                                    rawText: rawAfter,
                                    selection: afterSelection,
                                    placeholderEvidence: .init(),
                                    probe: localPrefixProbe(coordinateAfter)
                                )
                                XCTAssertEqual(resolved.text, coordinateAfter)
                                XCTAssertEqual(resolved.selection, afterSelection)
                                XCTAssertFalse(
                                    resolved.mapping.rawRangeCandidates(
                                        for: afterSelection
                                    ).isEmpty,
                                    "payload boundary lost its post-write path: shape=\(shape), payload=\(payload), range=\(range), rawRange=\(rawRange)"
                                )
                                boundaryCaseCount += 1
                            }
                        }
                    }
                    shapeCount += 1
                }
            }
        }

        XCTAssertEqual(shapeCount, 17_476)
        XCTAssertEqual(payloadStateCount, 209_712)
        XCTAssertGreaterThan(boundaryCaseCount, payloadStateCount)
    }

    func testProductionAlignmentMatchesIndependentOracleForEveryExpandedRange() throws {
        var shapeCount = 0
        var rangeCount = 0
        var invalidBoundaryCount = 0

        for context in LocalBodyContext.allCases {
            for separatorCount in 0...3 {
                for units in LocalSeparatorUnit.allSequences(count: separatorCount) {
                    let shape = LocalBoundaryShape(context: context, units: units)
                    let (raw, coordinate) = shape.texts()
                    let state = try AXTextDocumentResolver.resolve(
                        rawText: raw,
                        selection: .init(location: coordinate.utf16.count, length: 0),
                        placeholderEvidence: .init(),
                        probe: localPrefixProbe(coordinate)
                    )
                    let coordinateBoundaries = universeScalarBoundaryOffsets(in: coordinate)

                    for startIndex in coordinateBoundaries.indices {
                        for endIndex in startIndex..<coordinateBoundaries.count {
                            let range = UniverseTextRange(
                                location: coordinateBoundaries[startIndex],
                                length: coordinateBoundaries[endIndex] - coordinateBoundaries[startIndex]
                            )
                            let expected = independentRawRangeCandidates(
                                rawText: raw,
                                coordinateText: coordinate,
                                coordinateRange: range
                            )
                            let actual = state.mapping.rawRangeCandidates(for: range)
                            XCTAssertEqual(
                                actual,
                                expected,
                                "range=\(range), shape=\(shape), raw=\(raw.debugDescription), coordinate=\(coordinate.debugDescription)"
                            )
                            rangeCount += 1
                        }
                    }

                    for offset in 0...coordinate.utf16.count
                        where !universeIsScalarBoundary(offset, in: coordinate) {
                        XCTAssertTrue(
                            state.mapping.rawRangeCandidates(
                                for: .init(location: offset, length: 0)
                            ).isEmpty,
                            "surrogate split must not become a raw candidate: shape=\(shape), offset=\(offset)"
                        )
                        invalidBoundaryCount += 1
                    }
                    shapeCount += 1
                }
            }
        }

        XCTAssertEqual(shapeCount, 17_476)
        XCTAssertGreaterThan(rangeCount, shapeCount)
        XCTAssertEqual(invalidBoundaryCount, 0)

        let emojiRaw = "😀\n好"
        let emojiCoordinate = "😀好"
        let emojiState = try AXTextDocumentResolver.resolve(
            rawText: emojiRaw,
            selection: .init(location: emojiCoordinate.utf16.count, length: 0),
            placeholderEvidence: .init(),
            probe: localPrefixProbe(emojiCoordinate)
        )
        for offset in 0...emojiCoordinate.utf16.count
            where !universeIsScalarBoundary(offset, in: emojiCoordinate) {
            XCTAssertTrue(
                emojiState.mapping.rawRangeCandidates(
                    for: .init(location: offset, length: 0)
                ).isEmpty,
                "surrogate split must not become a raw candidate: offset=\(offset)"
            )
            invalidBoundaryCount += 1
        }
        XCTAssertGreaterThan(invalidBoundaryCount, 0)
    }

    func testTimingUniverseHasAllDeclaredSchedulesAndRepresentativeOperations() {
        let schedules = TimingUniverse.allSchedules()
        XCTAssertEqual(schedules.count, 3_888)
        XCTAssertEqual(
            schedules.flatMap { schedule in
                TimingRepresentativeOperation.allCases.map { (schedule, $0) }
            }.count,
            46_656
        )
        XCTAssertEqual(Set(schedules.map(\.readOrder)), Set(ReadOrder.allCases))
        XCTAssertEqual(Set(schedules.map(\.delayPattern)), Set(ReadDelayPattern.allCases))
        XCTAssertEqual(Set(schedules.map(\.failurePoint)), Set(ReadFailurePoint.allCases))
        XCTAssertEqual(Set(schedules.map(\.disturbance)), Set(ReadDisturbance.allCases))
    }

    func testTimingUniverseExecutesEveryScheduleThroughAcknowledgementWaiter() async {
        let schedules = TimingUniverse.allSchedules()
        let operations = TimingRepresentativeOperation.allCases
        var acknowledged = 0
        var safelyUnconfirmed = 0

        for schedule in schedules {
            for operation in operations {
                let result = await executeTimingSchedule(schedule, operation: operation)
                let shouldAcknowledge = switch schedule.disturbance {
                case .none, .focusLeavesAndReturns:
                    true
                case .nodeRebuild, .focusLeaves, .outsideTextChanges, .outsideStructureChanges:
                    false
                }
                if result == .acknowledged {
                    acknowledged += 1
                } else {
                    safelyUnconfirmed += 1
                }
                XCTAssertEqual(
                    result == .acknowledged,
                    shouldAcknowledge,
                    "schedule=\(schedule), operation=\(operation)"
                )
            }
        }

        XCTAssertEqual(acknowledged, 15_552)
        XCTAssertEqual(safelyUnconfirmed, 31_104)
        XCTAssertEqual(acknowledged + safelyUnconfirmed, 46_656)
    }

    func testMixedAXSnapshotsNeverConfirmAndAConsistentLaterSnapshotRecovers() async throws {
        let old = timingState(
            text: "甲",
            selection: .init(location: 1, length: 0)
        )
        let new = timingState(
            text: "甲乙",
            selection: .init(location: 2, length: 0)
        )
        let mixedSnapshots: [(String, KeyboardDocumentState)] = [
            (
                "old_text_new_selection",
                KeyboardDocumentState(
                    text: old.text,
                    selection: new.selection,
                    rawText: old.rawText,
                    mapping: old.mapping
                )
            ),
            (
                "new_text_old_selection",
                KeyboardDocumentState(
                    text: new.text,
                    selection: old.selection,
                    rawText: new.rawText,
                    mapping: new.mapping
                )
            ),
            (
                "old_raw_new_coordinate",
                KeyboardDocumentState(
                    text: new.text,
                    selection: new.selection,
                    rawText: old.rawText,
                    mapping: old.mapping
                )
            ),
            (
                "new_raw_old_coordinate",
                KeyboardDocumentState(
                    text: old.text,
                    selection: old.selection,
                    rawText: new.rawText,
                    mapping: new.mapping
                )
            )
        ]

        for (name, observed) in mixedSnapshots {
            let result = KeyboardWriteConfirmation.evaluate(
                expected: new,
                observed: observed,
                operation: nil,
                isCodexTarget: true
            )
            XCTAssertFalse(result.matched, name)

            do {
                _ = try await KeyboardWriteAcknowledgement.wait(
                    for: new,
                    matches: { expected, observed in
                        KeyboardWriteConfirmation.evaluate(
                            expected: expected,
                            observed: observed,
                            operation: nil,
                            isCodexTarget: true
                        ).matched
                    },
                    timeoutNanoseconds: 0,
                    now: { 0 },
                    sleep: { _ in },
                    read: { observed }
                )
                XCTFail("a mixed AX snapshot must not confirm: (name)")
            } catch {
                // The only valid outcome is unconfirmed; the waiter must not
                // turn a partial attribute update into a receipt.
            }
        }

        var reads = 0
        var clock: UInt64 = 0
        let recovered = try await KeyboardWriteAcknowledgement.wait(
            for: new,
            matches: { expected, observed in
                KeyboardWriteConfirmation.evaluate(
                    expected: expected,
                    observed: observed,
                    operation: nil,
                    isCodexTarget: true
                ).matched
            },
            timeoutNanoseconds: 2,
            now: { clock },
            sleep: { _ in clock += 1 },
            read: {
                reads += 1
                return reads == 1 ? mixedSnapshots[0].1 : new
            }
        )
        XCTAssertEqual(recovered, new)
        XCTAssertEqual(reads, 2)
    }

    func testFixedSeedOperationUniverseRunsWithinDocumentAndNodeBounds() {
        var operationCount = 0
        var maximumUTF16Length = 0
        var maximumNodeCount = 0
        var maximumSeparatorCount = 0
        var observedOperations: Set<GeneratedOperation> = []

        for seed in 0..<32 {
            for sequence in 0..<100 {
                var generator = StableGenerator(seed: UInt64(seed * 100 + sequence))
                var model = GeneratedDocumentModel()
                for _ in 0..<40 {
                    let operation = GeneratedOperation.allCases[
                        generator.nextInt(upperBound: GeneratedOperation.allCases.count)
                    ]
                    observedOperations.insert(operation)
                    model.apply(operation, generator: &generator)
                    operationCount += 1
                    maximumUTF16Length = max(maximumUTF16Length, model.text.utf16.count)
                    maximumNodeCount = max(maximumNodeCount, model.nodeCount)
                    maximumSeparatorCount = max(maximumSeparatorCount, model.separatorCount)
                    XCTAssertLessThanOrEqual(model.text.utf16.count, 256)
                    XCTAssertLessThanOrEqual(model.nodeCount, 16)
                    XCTAssertLessThanOrEqual(model.separatorCount, 12)
                    XCTAssertTrue(model.isAtScalarBoundary)
                    let resolved = try? AXTextDocumentResolver.resolve(
                        rawText: model.text,
                        selection: .init(location: model.caret, length: 0),
                        placeholderEvidence: .init(),
                        probe: localPrefixProbe(model.text)
                    )
                    XCTAssertEqual(resolved?.text, model.text)
                    XCTAssertEqual(resolved?.selection, .init(location: model.caret, length: 0))
                }
            }
        }

        XCTAssertEqual(operationCount, 128_000)
        XCTAssertEqual(observedOperations, Set(GeneratedOperation.allCases))
        XCTAssertLessThanOrEqual(maximumUTF16Length, 256)
        XCTAssertLessThanOrEqual(maximumNodeCount, 16)
        XCTAssertLessThanOrEqual(maximumSeparatorCount, 12)
    }

    func testFixedSeedOperationUniverseExercisesProductionConfirmationPath() async {
        var operationCount = 0
        var acknowledgedCount = 0
        var rejectedCount = 0
        var observedOperations: Set<GeneratedOperation> = []

        for seed in 0..<32 {
            for sequence in 0..<100 {
                var generator = StableGenerator(seed: UInt64(seed * 100 + sequence))
                var model = GeneratedDocumentModel()
                var trace: [GeneratedTraceStep] = []
                for step in 0..<40 {
                    let operation = GeneratedOperation.allCases[
                        generator.nextInt(upperBound: GeneratedOperation.allCases.count)
                    ]
                    observedOperations.insert(operation)
                    let before = generatedKeyboardState(text: model.text, rawCaret: model.caret)
                    model.apply(operation, generator: &generator)
                    let after = generatedKeyboardState(text: model.text, rawCaret: model.caret)
                    let diagnosticOperation = generatedDiagnosticOperation(
                        before: before,
                        after: after,
                        generation: UInt64(operationCount + 1)
                    )
                    let ownWrite = operation.isOwnWrite
                    let expected = ownWrite ? after : before
                    let observed = ownWrite
                        ? after
                        : generatedExternalObservation(after)
                    let mappingValid = KeyboardWriteConfirmation.mappingIsValid(
                        observed,
                        isCodexTarget: true
                    )
                    let summary = KeyboardDiagnosticDiffCalculator.compare(
                        expected: expected,
                        observed: observed,
                        operation: diagnosticOperation,
                        mappingValid: mappingValid
                    )
                    let acknowledged = await generatedAcknowledgement(
                        expected: expected,
                        observed: observed,
                        operation: diagnosticOperation
                    )
                    let summaryMatches = ownWrite
                        ? summary.classification == .equal
                        : summary.classification != .equal
                    trace.append(
                        GeneratedTraceStep(
                            operation: String(describing: operation),
                            beforeText: before.text,
                            afterText: after.text,
                            expectedText: expected.text,
                            expectedRawText: expected.rawText ?? "",
                            expectedSelectionLocation: expected.selection.location,
                            expectedSelectionLength: expected.selection.length,
                            observedText: observed.text,
                            observedRawText: observed.rawText ?? "",
                            observedSelectionLocation: observed.selection.location,
                            observedSelectionLength: observed.selection.length,
                            operationLocation: diagnosticOperation.coordinateRange.location,
                            operationLength: diagnosticOperation.coordinateRange.length,
                            insertedLength: diagnosticOperation.insertedLengthUTF16,
                            operationGeneration: diagnosticOperation.operationGeneration,
                            shouldAcknowledge: ownWrite
                        )
                    )
                    if acknowledged != ownWrite || !summaryMatches {
                        let minimalTrace = minimizeGeneratedTrace(trace)
                        let artifact = GeneratedCounterexample(
                            seed: seed,
                            sequence: sequence,
                            step: step,
                            trace: minimalTrace
                        )
                        let artifactPath = saveGeneratedCounterexample(artifact)
                        XCTFail(
                            "seed=\(seed), sequence=\(sequence), step=\(step), operation=\(operation), counterexample=\(artifactPath ?? "not_saved")"
                        )
                    }

                    XCTAssertEqual(
                        acknowledged,
                        ownWrite,
                        "seed=\(seed), sequence=\(sequence), step=\(step), operation=\(operation)"
                    )
                    if ownWrite {
                        XCTAssertEqual(
                            summary.classification,
                            .equal,
                            "seed=\(seed), sequence=\(sequence), step=\(step), operation=\(operation), before=\(before.text.debugDescription), after=\(after.text.debugDescription), diagnostic=\(diagnosticOperation)"
                        )
                        acknowledgedCount += 1
                    } else {
                        XCTAssertNotEqual(
                            summary.classification,
                            .equal,
                            "seed=\(seed), sequence=\(sequence), step=\(step), operation=\(operation)"
                        )
                        rejectedCount += 1
                    }
                    operationCount += 1
                }
            }
        }

        XCTAssertEqual(operationCount, 128_000)
        XCTAssertEqual(observedOperations, Set(GeneratedOperation.allCases))
        XCTAssertGreaterThan(acknowledgedCount, 0)
        XCTAssertGreaterThan(rejectedCount, 0)
        XCTAssertEqual(acknowledgedCount + rejectedCount, operationCount)
    }

    func testGeneratedCounterexampleReducerPersistsTheMinimalFailingTrace() throws {
        let passing = GeneratedTraceStep(
            operation: "noOp",
            beforeText: "",
            afterText: "",
            expectedText: "",
            expectedRawText: "",
            expectedSelectionLocation: 0,
            expectedSelectionLength: 0,
            observedText: "",
            observedRawText: "",
            observedSelectionLocation: 0,
            observedSelectionLength: 0,
            operationLocation: 0,
            operationLength: 0,
            insertedLength: 0,
            operationGeneration: 1,
            shouldAcknowledge: true
        )
        let failing = GeneratedTraceStep(
            operation: "wrongBody",
            beforeText: "甲",
            afterText: "乙",
            expectedText: "甲",
            expectedRawText: "甲",
            expectedSelectionLocation: 1,
            expectedSelectionLength: 0,
            observedText: "乙",
            observedRawText: "乙",
            observedSelectionLocation: 1,
            observedSelectionLength: 0,
            operationLocation: 0,
            operationLength: 0,
            insertedLength: 1,
            operationGeneration: 2,
            shouldAcknowledge: true
        )
        let reduced = minimizeGeneratedTrace([passing, failing, passing])
        XCTAssertEqual(reduced, [failing])
        XCTAssertTrue(generatedTraceFails(reduced))

        let counterexample = GeneratedCounterexample(
            seed: 999,
            sequence: 1,
            step: 2,
            trace: reduced
        )
        let path = try XCTUnwrap(saveGeneratedCounterexample(counterexample))
        let saved = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(try JSONDecoder().decode(GeneratedCounterexample.self, from: saved), counterexample)
    }

    func testIndependentOracleDetectsWrongInsertionParagraphAndOutsideChanges() {
        let raw = "甲\n\n乙"
        let insertionIndex = raw.index(raw.startIndex, offsetBy: 1)
        let expected = raw.replacingCharacters(in: insertionIndex..<insertionIndex, with: "今")
        let wrongBoundary = raw.index(raw.startIndex, offsetBy: 3)
        let wrongInsertion = raw.replacingCharacters(
            in: wrongBoundary..<wrongBoundary,
            with: "今"
        )

        XCTAssertEqual(expected, "甲今\n\n乙")
        XCTAssertNotEqual(expected, wrongInsertion)
        XCTAssertNotEqual(independentParagraphs(expected), independentParagraphs(wrongInsertion))

        let outsideChange = "甲今\n\n丙"
        XCTAssertNotEqual(independentParagraphs(expected), independentParagraphs(outsideChange))
    }

    func testSelectionReplacementUniverseUsesSharedConfirmationForBothDirections() async {
        let documents = [
            "甲乙",
            "😀e\u{301}\n乙",
            "甲\n\n乙",
            "左中右"
        ]
        var replacementCount = 0

        for document in documents {
            let initial = generatedKeyboardState(
                text: document,
                coordinateSelection: .init(location: 0, length: 0)
            )
            let boundaries = scalarBoundaryOffsets(in: initial.text)
            for startIndex in boundaries.indices {
                for endIndex in boundaries.indices where endIndex > startIndex {
                    let first = boundaries[startIndex]
                    let second = boundaries[endIndex]
                    // AX exposes a normalized range. Exercise both possible
                    // user drag directions against the same logical span.
                    for (anchor, focus) in [(first, second), (second, first)] {
                        let selection = TextRange(
                            location: min(anchor, focus),
                            length: abs(focus - anchor)
                        )
                        let before = generatedKeyboardState(
                            text: document,
                            coordinateSelection: selection
                        )
                        guard let mapping = before.mapping else {
                            XCTFail("generated selection has no mapping: \(document.debugDescription)")
                            continue
                        }
                        let rawRanges = mapping.rawRangeCandidates(for: selection)
                        XCTAssertFalse(rawRanges.isEmpty, "selection=\(selection), document=\(document.debugDescription)")

                        for payload in LocalPayload.allCases {
                            let payloadScalars = Array(payload.text.unicodeScalars)
                            let coordinatePayload = payloadScalars
                                .enumerated()
                                .filter {
                                    !universeIsStructuralSeparator(
                                        payloadScalars[$0.offset],
                                        at: $0.offset,
                                        in: payloadScalars
                                    )
                                }
                                .reduce(into: "") { result, item in
                                    let scalar = item.element
                                    result.unicodeScalars.append(scalar)
                                }
                            let coordinateAfterText = replacing(
                                before.text,
                                range: selection,
                                with: coordinatePayload
                            )
                            let afterSelection = TextRange(
                                location: selection.location + coordinatePayload.utf16.count,
                                length: 0
                            )
                            for rawRange in rawRanges {
                                let rawAfterText = replacing(
                                    document,
                                    range: rawRange,
                                    with: payload.text
                                )
                                let after = generatedKeyboardState(
                                    text: rawAfterText,
                                    coordinateSelection: afterSelection
                                )
                                XCTAssertEqual(after.text, coordinateAfterText)
                                let operation = generatedDiagnosticOperation(
                                    before: before,
                                    after: after,
                                    generation: UInt64(replacementCount + 1)
                                )
                                let correct = KeyboardWriteConfirmation.evaluate(
                                    expected: after,
                                    observed: after,
                                    operation: operation,
                                    isCodexTarget: true
                                )
                                XCTAssertTrue(
                                    correct.matched,
                                    "correct selection replacement rejected: document=\(document.debugDescription), selection=\(selection), payload=\(payload.text.debugDescription), rawRange=\(rawRange)"
                                )

                                let outsideText = rawAfterText + "外"
                                let outside = generatedKeyboardState(
                                    text: outsideText,
                                    coordinateSelection: afterSelection
                                )
                                let rejected = KeyboardWriteConfirmation.evaluate(
                                    expected: after,
                                    observed: outside,
                                    operation: operation,
                                    isCodexTarget: true
                                )
                                XCTAssertFalse(
                                    rejected.matched,
                                    "outside edit was acknowledged: document=\(document.debugDescription), selection=\(selection), payload=\(payload.text.debugDescription), rawRange=\(rawRange)"
                                )
                                replacementCount += 1

                                // The acknowledgement waiter must use the same
                                // predicate as the target, not plain equality.
                                let correctAcknowledgement = await generatedAcknowledgement(
                                    expected: after,
                                    observed: after,
                                    operation: operation
                                )
                                XCTAssertTrue(correctAcknowledgement)
                                let outsideAcknowledgement = await generatedAcknowledgement(
                                    expected: after,
                                    observed: outside,
                                    operation: operation
                                )
                                XCTAssertFalse(outsideAcknowledgement)
                            }
                        }
                    }
                }
            }
        }

        XCTAssertGreaterThan(replacementCount, 0)

        let emoji = "😀x"
        XCTAssertThrowsError(
            try AXTextDocumentResolver.resolve(
                rawText: emoji,
                selection: .init(location: 1, length: 0),
                placeholderEvidence: .init(),
                probe: localPrefixProbe(emoji)
            )
        ) { error in
            XCTAssertEqual(error as? AXTextDocumentResolutionError, .selectionOutOfBounds)
        }
    }

    private func executeTimingSchedule(
        _ schedule: TimingSchedule,
        operation: TimingRepresentativeOperation
    ) async -> TimingExecutionResult {
        let expected = timingExpectedState(for: operation)
        let readStages = timingReadStages(for: schedule.readOrder)
        var clock: UInt64 = 0
        var attempt = 0
        var failureInjected = false
        var disturbanceInjected = false

        do {
            _ = try await KeyboardWriteAcknowledgement.wait(
                for: expected,
                matches: { expected, observed in
                    KeyboardWriteConfirmation.evaluate(
                        expected: expected,
                        observed: observed,
                        operation: nil,
                        isCodexTarget: true
                    ).matched
                },
                timeoutNanoseconds: 16,
                now: { clock },
                sleep: { requested in
                    clock += min(requested, 1)
                }
            ) {
                let stage = readStages[attempt % readStages.count]
                attempt += 1
                switch stage {
                case .rawRead:
                    clock += UInt64(schedule.delayPattern.firstReadDelay)
                case .coordinateRead:
                    clock += UInt64(schedule.delayPattern.secondReadDelay)
                case .selectionRead:
                    clock += UInt64(schedule.delayPattern.thirdReadDelay)
                case .none:
                    break
                }

                let failureMatches = schedule.failurePoint != .none
                    && !failureInjected
                    && stage == schedule.failurePoint
                let rebuildMatches = schedule.disturbance == .nodeRebuild
                    && !disturbanceInjected
                if failureMatches {
                    failureInjected = true
                    throw KeyboardWriteReadError.retryable
                }
                if rebuildMatches {
                    disturbanceInjected = true
                    throw TextTargetError.targetChanged
                }

                if schedule.disturbance == .focusLeavesAndReturns,
                   !disturbanceInjected {
                    disturbanceInjected = true
                    return timingWrongState(for: expected)
                }
                if schedule.disturbance == .focusLeaves
                    || schedule.disturbance == .outsideTextChanges
                    || schedule.disturbance == .outsideStructureChanges {
                    return timingWrongState(for: expected)
                }
                return expected
            }
            return .acknowledged
        } catch {
            return .unconfirmed
        }
    }

    private func timingExpectedState(
        for operation: TimingRepresentativeOperation
    ) -> KeyboardDocumentState {
        switch operation {
        case .firstCharacter: return timingState(text: "今", selection: .init(location: 1, length: 0))
        case .continuation: return timingState(text: "今天", selection: .init(location: 2, length: 0))
        case .equalLengthRewrite: return timingState(text: "甲丁", selection: .init(location: 2, length: 0))
        case .growingRewrite: return timingState(text: "甲丁戊", selection: .init(location: 3, length: 0))
        case .shrinkingRewrite: return timingState(text: "甲", selection: .init(location: 1, length: 0))
        case .deletion: return timingState(text: "", selection: .init(location: 0, length: 0))
        case .undo: return timingState(text: "甲", selection: .init(location: 1, length: 0))
        case .redo: return timingState(text: "甲乙", selection: .init(location: 2, length: 0))
        case .moveCaret: return timingState(text: "甲乙", selection: .init(location: 1, length: 0))
        case .stopAndRestart: return timingState(text: "甲乙", selection: .init(location: 2, length: 0))
        case .focusChange: return timingState(text: "甲乙", selection: .init(location: 2, length: 0))
        case .externalEdit: return timingState(text: "甲乙", selection: .init(location: 2, length: 0))
        }
    }

    private func timingState(text: String, selection: UniverseTextRange) -> KeyboardDocumentState {
        generatedKeyboardState(
            text: text,
            coordinateSelection: selection,
            coordinateText: text
        )
    }

    private func timingWrongState(for expected: KeyboardDocumentState) -> KeyboardDocumentState {
        timingState(
            text: expected.text + "外部",
            selection: expected.selection
        )
    }
}

private enum TimingExecutionResult: Equatable {
    case acknowledged
    case unconfirmed
}

private enum LocalBodyContext: CaseIterable, Hashable {
    case empty
    case rightText
    case bothSidesText
    case leftText
}

private enum LocalSeparatorSemantic: CaseIterable, Hashable {
    case paragraphBreak
    case softBreak
}

private enum LocalSeparatorEncoding: CaseIterable, Hashable {
    case lf
    case crlf
    case lineSeparator
    case paragraphSeparator

    var text: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .lineSeparator: return "\u{2028}"
        case .paragraphSeparator: return "\u{2029}"
        }
    }
}

private enum LocalCoordinateRepresentation: CaseIterable, Hashable {
    case retained
    case omitted
}

private struct LocalSeparatorUnit: Hashable {
    let semantic: LocalSeparatorSemantic
    let encoding: LocalSeparatorEncoding
    let representation: LocalCoordinateRepresentation

    static func allSequences(count: Int) -> [[LocalSeparatorUnit]] {
        guard count > 0 else { return [[]] }
        let prefixes = allSequences(count: count - 1)
        return prefixes.flatMap { prefix in
            LocalSeparatorSemantic.allCases.flatMap { semantic in
                LocalSeparatorEncoding.allCases.flatMap { encoding in
                    LocalCoordinateRepresentation.allCases.map { representation in
                        prefix + [
                            LocalSeparatorUnit(
                                semantic: semantic,
                                encoding: encoding,
                                representation: representation
                            )
                        ]
                    }
                }
            }
        }
    }
}

private struct LocalBoundaryShape: CustomStringConvertible {
    let context: LocalBodyContext
    let units: [LocalSeparatorUnit]

    func texts() -> (raw: String, coordinate: String) {
        let separatorText = units.map { $0.encoding.text }.joined()
        let body: (String, String)
        switch context {
        case .empty: body = ("", "")
        case .rightText: body = ("", "右")
        case .bothSidesText: body = ("左", "右")
        case .leftText: body = ("左", "")
        }
        let raw = body.0 + separatorText + body.1
        return (raw, coordinateTextByIndependentOracle())
    }

    func coordinateTextByIndependentOracle() -> String {
        let body: (String, String)
        switch context {
        case .empty: body = ("", "")
        case .rightText: body = ("", "右")
        case .bothSidesText: body = ("左", "右")
        case .leftText: body = ("左", "")
        }
        let coordinateSeparators = units
            .filter { $0.representation == .retained }
            .map { $0.encoding.text }
            .joined()
        return body.0 + coordinateSeparators + body.1
    }

    var description: String {
        "context=\(context), units=\(units.count)"
    }
}

private enum LocalPayload: CaseIterable {
    case empty
    case chinese
    case ascii
    case space
    case nonBreakingSpace
    case lf
    case crlf
    case lineSeparator
    case paragraphSeparator
    case zeroWidthSpace
    case emoji
    case combining

    var text: String {
        switch self {
        case .empty: return ""
        case .chinese: return "今"
        case .ascii: return "AB"
        case .space: return " "
        case .nonBreakingSpace: return "\u{00A0}"
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .lineSeparator: return "\u{2028}"
        case .paragraphSeparator: return "\u{2029}"
        case .zeroWidthSpace: return "\u{200B}"
        case .emoji: return "😀"
        case .combining: return "e\u{301}"
        }
    }
}

private enum PlanLocalBoundaryUniverse {
    static let contextCount = 4
    static let separatorUnitCount = 0...3
    static let payloadCount = LocalPayload.allCases.count

    struct Counts {
        let emptySelectionCases: Int
        let allRangeCases: Int
    }

    // This is the count projection specified by the task brief. The expanded
    // axis generator above separately enumerates semantic kind, encoding and
    // coordinate presence; this projection is retained so the reported 90
    // combinations cannot be mistaken for the complete local universe.
    static func projectedCounts() -> Counts {
        var emptySelectionCases = 0
        var allRangeCases = 0
        for separatorCount in separatorUnitCount {
            for collapsedCount in 0...separatorCount {
                let shapeCount = binomial(separatorCount, collapsedCount)
                    * power(12, separatorCount - collapsedCount)
                    * power(4, collapsedCount)
                let rawBoundarySpan = separatorCount + collapsedCount
                emptySelectionCases += shapeCount * (rawBoundarySpan + 1)
                allRangeCases += shapeCount
                    * (rawBoundarySpan + 1)
                    * (rawBoundarySpan + 2)
                    / 2
            }
        }
        return Counts(
            emptySelectionCases: emptySelectionCases * contextCount * payloadCount,
            allRangeCases: allRangeCases * contextCount * payloadCount
        )
    }

    private static func power(_ base: Int, _ exponent: Int) -> Int {
        (0..<exponent).reduce(1) { value, _ in value * base }
    }

    private static func binomial(_ n: Int, _ k: Int) -> Int {
        guard k > 0 else { return 1 }
        return (1...k).reduce(1) { value, index in
            value * (n - index + 1) / index
        }
    }
}

private enum ReadOrder: CaseIterable, Hashable {
    case rawCoordinateSelection
    case rawSelectionCoordinate
    case coordinateRawSelection
    case coordinateSelectionRaw
    case selectionRawCoordinate
    case selectionCoordinateRaw
}

private struct ReadDelayPattern: Hashable {
    let firstReadDelay: Int
    let secondReadDelay: Int
    let thirdReadDelay: Int

    static let allCases: [ReadDelayPattern] = (0...2).flatMap { first in
        (0...2).flatMap { second in
            (0...2).map { third in
                ReadDelayPattern(
                    firstReadDelay: first,
                    secondReadDelay: second,
                    thirdReadDelay: third
                )
            }
        }
    }
}

private enum ReadFailurePoint: CaseIterable, Hashable {
    case none
    case rawRead
    case coordinateRead
    case selectionRead
}

private enum ReadDisturbance: CaseIterable, Hashable {
    case none
    case nodeRebuild
    case focusLeaves
    case focusLeavesAndReturns
    case outsideTextChanges
    case outsideStructureChanges
}

private enum TimingRepresentativeOperation: CaseIterable {
    case firstCharacter
    case continuation
    case equalLengthRewrite
    case growingRewrite
    case shrinkingRewrite
    case deletion
    case undo
    case redo
    case moveCaret
    case stopAndRestart
    case focusChange
    case externalEdit
}

private struct TimingSchedule: Hashable {
    let readOrder: ReadOrder
    let delayPattern: ReadDelayPattern
    let failurePoint: ReadFailurePoint
    let disturbance: ReadDisturbance
}

private func timingReadStages(for order: ReadOrder) -> [ReadFailurePoint] {
    switch order {
    case .rawCoordinateSelection:
        return [.rawRead, .coordinateRead, .selectionRead]
    case .rawSelectionCoordinate:
        return [.rawRead, .selectionRead, .coordinateRead]
    case .coordinateRawSelection:
        return [.coordinateRead, .rawRead, .selectionRead]
    case .coordinateSelectionRaw:
        return [.coordinateRead, .selectionRead, .rawRead]
    case .selectionRawCoordinate:
        return [.selectionRead, .rawRead, .coordinateRead]
    case .selectionCoordinateRaw:
        return [.selectionRead, .coordinateRead, .rawRead]
    }
}

private enum TimingUniverse {
    static func allSchedules() -> [TimingSchedule] {
        ReadOrder.allCases.flatMap { order in
            ReadDelayPattern.allCases.flatMap { delay in
                ReadFailurePoint.allCases.flatMap { failure in
                    ReadDisturbance.allCases.map {
                        TimingSchedule(
                            readOrder: order,
                            delayPattern: delay,
                            failurePoint: failure,
                            disturbance: $0
                        )
                    }
                }
            }
        }
    }
}

private struct StableGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state ^= state >> 30
        state &*= 0xBF58_476D_1CE4_E5B9
        state ^= state >> 27
        state &*= 0x94D0_49BB_1331_11EB
        state ^= state >> 31
        return Int(state % UInt64(upperBound))
    }
}

private enum GeneratedOperation: CaseIterable, Hashable {
    case insert
    case rewrite
    case delete
    case undo
    case redo
    case moveCaret
    case stopAndRestart
    case focusChange
    case externalTextEdit
    case externalStructureEdit
    case nodeRebuild
    case noOp

    var isOwnWrite: Bool {
        switch self {
        case .insert, .rewrite, .delete, .undo, .redo, .stopAndRestart, .noOp:
            return true
        case .moveCaret, .focusChange, .externalTextEdit, .externalStructureEdit, .nodeRebuild:
            return false
        }
    }
}

private func generatedKeyboardState(text: String, rawCaret: Int) -> KeyboardDocumentState {
    precondition(rawCaret >= 0)
    precondition(rawCaret <= text.utf16.count)
    precondition(universeIsScalarBoundary(rawCaret, in: text))
    let coordinateText = generatedCoordinateText(text)
    let caretIndex = String.Index(utf16Offset: rawCaret, in: text)
    let coordinateCaret = generatedCoordinateText(String(text[..<caretIndex])).utf16.count
    return generatedKeyboardState(
        text: text,
        coordinateSelection: .init(location: coordinateCaret, length: 0),
        coordinateText: coordinateText
    )
}

private func generatedKeyboardState(
    text: String,
    coordinateSelection: UniverseTextRange
) -> KeyboardDocumentState {
    generatedKeyboardState(
        text: text,
        coordinateSelection: coordinateSelection,
        coordinateText: generatedCoordinateText(text)
    )
}

private func generatedKeyboardState(
    text: String,
    coordinateSelection: UniverseTextRange,
    coordinateText: String
) -> KeyboardDocumentState {
    guard let resolved = try? AXTextDocumentResolver.resolve(
        rawText: text,
        selection: coordinateSelection,
        placeholderEvidence: .init(),
        probe: localPrefixProbe(coordinateText)
    ) else {
        preconditionFailure(
            "generated state is not a valid coordinate observation: raw=\(text.debugDescription), coordinate=\(coordinateText.debugDescription), selection=\(coordinateSelection)"
        )
    }
    return KeyboardDocumentState(
        text: resolved.text,
        selection: resolved.selection,
        rawText: resolved.rawText,
        mapping: resolved.mapping
    )
}

private func generatedCoordinateText(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    return scalars.enumerated().reduce(into: "") { result, item in
        guard !universeIsStructuralSeparator(item.element, at: item.offset, in: scalars) else {
            return
        }
        let scalar = item.element
        result.unicodeScalars.append(scalar)
    }
}

private func generatedDiagnosticOperation(
    before: KeyboardDocumentState,
    after: KeyboardDocumentState,
    generation: UInt64
) -> KeyboardDiagnosticDiffOperation {
    let beforeScalars = Array(before.text.unicodeScalars)
    let afterScalars = Array(after.text.unicodeScalars)
    var prefix = 0
    while prefix < beforeScalars.count,
          prefix < afterScalars.count,
          beforeScalars[prefix] == afterScalars[prefix] {
        prefix += 1
    }
    var suffix = 0
    while suffix < beforeScalars.count - prefix,
          suffix < afterScalars.count - prefix,
          beforeScalars[beforeScalars.count - suffix - 1]
            == afterScalars[afterScalars.count - suffix - 1] {
        suffix += 1
    }
    let beforeOffsets = scalarBoundaryOffsets(in: before.text)
    let afterOffsets = scalarBoundaryOffsets(in: after.text)
    let location = beforeOffsets[prefix]
    let beforeEnd = beforeScalars.count - suffix
    let afterEnd = afterScalars.count - suffix
    let consumed = beforeOffsets[beforeEnd] - location
    let inserted = afterOffsets[afterEnd] - afterOffsets[prefix]
    let insertedText = String(
        after.text[stringRange(
            .init(location: afterOffsets[prefix], length: inserted),
            in: after.text
        )]
    )
    return KeyboardDiagnosticDiffOperation(
        coordinateRange: .init(location: location, length: consumed),
        insertedLengthUTF16: inserted,
        inputText: insertedText,
        operationGeneration: generation
    )
}

private func generatedExternalObservation(
    _ state: KeyboardDocumentState
) -> KeyboardDocumentState {
    let rawText = (state.rawText ?? state.text) + "外"
    return generatedKeyboardState(
        text: rawText,
        coordinateSelection: state.selection
    )
}

@MainActor
private func generatedAcknowledgement(
    expected: KeyboardDocumentState,
    observed: KeyboardDocumentState,
    operation: KeyboardDiagnosticDiffOperation
) async -> Bool {
    do {
        _ = try await KeyboardWriteAcknowledgement.wait(
            for: expected,
            matches: { expected, observed in
                KeyboardWriteConfirmation.evaluate(
                    expected: expected,
                    observed: observed,
                    operation: operation,
                    isCodexTarget: true
                ).matched
            },
            timeoutNanoseconds: 0,
            now: { 0 },
            sleep: { _ in },
            read: { observed }
        )
        return true
    } catch {
        return false
    }
}

private struct GeneratedTraceStep: Codable, Equatable {
    let operation: String
    let beforeText: String
    let afterText: String
    let expectedText: String
    let expectedRawText: String
    let expectedSelectionLocation: Int
    let expectedSelectionLength: Int
    let observedText: String
    let observedRawText: String
    let observedSelectionLocation: Int
    let observedSelectionLength: Int
    let operationLocation: Int
    let operationLength: Int
    let insertedLength: Int
    let operationGeneration: UInt64
    let shouldAcknowledge: Bool
}

private struct GeneratedCounterexample: Codable, Equatable {
    let seed: Int
    let sequence: Int
    let step: Int
    let trace: [GeneratedTraceStep]
}

private func generatedTraceFails(_ trace: [GeneratedTraceStep]) -> Bool {
    trace.contains { step in
        let expected = KeyboardDocumentState(
            text: step.expectedText,
            selection: .init(
                location: step.expectedSelectionLocation,
                length: step.expectedSelectionLength
            ),
            rawText: step.expectedRawText
        )
        let observed = KeyboardDocumentState(
            text: step.observedText,
            selection: .init(
                location: step.observedSelectionLocation,
                length: step.observedSelectionLength
            ),
            rawText: step.observedRawText
        )
        let summary = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: .init(
                coordinateRange: .init(
                    location: step.operationLocation,
                    length: step.operationLength
                ),
                insertedLengthUTF16: step.insertedLength,
                operationGeneration: step.operationGeneration
            ),
            mappingValid: true
        )
        return (summary.classification == .equal) != step.shouldAcknowledge
    }
}

private func minimizeGeneratedTrace(
    _ trace: [GeneratedTraceStep]
) -> [GeneratedTraceStep] {
    var current = trace
    var index = 0
    while index < current.count {
        var candidate = current
        candidate.remove(at: index)
        if !candidate.isEmpty, generatedTraceFails(candidate) {
            current = candidate
        } else {
            index += 1
        }
    }
    return current
}

private func saveGeneratedCounterexample(
    _ counterexample: GeneratedCounterexample
) -> String? {
    let root = URL(fileURLWithPath: ".build/test-artifacts/ax-coordinate-counterexamples")
    let file = root.appendingPathComponent(
        "seed-\(counterexample.seed)-sequence-\(counterexample.sequence)-step-\(counterexample.step).json"
    )
    do {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(counterexample)
        try data.write(to: file, options: .atomic)
        return file.path
    } catch {
        return nil
    }
}

private struct GeneratedDocumentModel {
    private struct Snapshot {
        let text: String
        let caret: Int
        let focused: Bool
        let nodeCount: Int
        let separatorCount: Int
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    var text = ""
    var caret = 0
    var focused = true
    var nodeCount = 1
    var separatorCount = 0

    var isAtScalarBoundary: Bool {
        scalarBoundaryOffsets(in: text).contains(caret)
    }

    mutating func apply(_ operation: GeneratedOperation, generator: inout StableGenerator) {
        switch operation {
        case .insert:
            replaceCurrentRange(with: generatedToken(generator: &generator))
        case .rewrite:
            replacePreviousScalar(with: generatedToken(generator: &generator))
        case .delete:
            guard let range = previousScalarRange() else { return }
            saveUndo()
            text.removeSubrange(stringRange(range, in: text))
            caret = range.location
            refreshDerivedState()
        case .undo:
            guard let snapshot = undoStack.popLast() else { return }
            redoStack.append(currentSnapshot())
            restore(snapshot)
        case .redo:
            guard let snapshot = redoStack.popLast() else { return }
            undoStack.append(currentSnapshot())
            restore(snapshot)
        case .moveCaret:
            let boundaries = scalarBoundaryOffsets(in: text)
            caret = boundaries[generator.nextInt(upperBound: boundaries.count)]
        case .stopAndRestart:
            focused = false
            focused = true
        case .focusChange:
            focused.toggle()
        case .externalTextEdit:
            replaceCurrentRange(with: "外")
        case .externalStructureEdit:
            replaceCurrentRange(with: "\n")
        case .nodeRebuild:
            nodeCount = min(16, max(1, generator.nextInt(upperBound: 17)))
        case .noOp:
            break
        }
    }

    private mutating func replacePreviousScalar(with token: String) {
        guard let range = previousScalarRange() else {
            replaceCurrentRange(with: token)
            return
        }
        replace(range, with: token)
    }

    private mutating func replaceCurrentRange(with token: String) {
        replace(.init(location: caret, length: 0), with: token)
    }

    private mutating func replace(_ range: UniverseTextRange, with token: String) {
        let resultingLength = text.utf16.count - range.length + token.utf16.count
        let replacedText = String(text[stringRange(range, in: text)])
        let resultingSeparatorCount = separatorCount
            - structuralSeparatorCount(in: replacedText)
            + structuralSeparatorCount(in: token)
        guard resultingLength <= 256, resultingSeparatorCount <= 12 else { return }
        saveUndo()
        text.replaceSubrange(stringRange(range, in: text), with: token)
        caret = range.location + token.utf16.count
        refreshDerivedState()
    }

    private mutating func saveUndo() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll(keepingCapacity: true)
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(text: text, caret: caret, focused: focused, nodeCount: nodeCount, separatorCount: separatorCount)
    }

    private mutating func restore(_ snapshot: Snapshot) {
        text = snapshot.text
        caret = snapshot.caret
        focused = snapshot.focused
        nodeCount = snapshot.nodeCount
        separatorCount = snapshot.separatorCount
    }

    private mutating func refreshDerivedState() {
        separatorCount = structuralSeparatorCount(in: text)
        caret = min(caret, text.utf16.count)
    }

    private func previousScalarRange() -> UniverseTextRange? {
        let boundaries = scalarBoundaryOffsets(in: text)
        guard let index = boundaries.firstIndex(of: caret), index > 0 else { return nil }
        return .init(location: boundaries[index - 1], length: caret - boundaries[index - 1])
    }

    private func generatedToken(generator: inout StableGenerator) -> String {
        switch generator.nextInt(upperBound: 8) {
        case 0: return "今"
        case 1: return "AB"
        case 2: return " "
        case 3: return "\u{00A0}"
        case 4: return "😀"
        case 5: return "e\u{301}"
        case 6: return "\u{200B}"
        default: return "\n"
        }
    }
}

private func structuralSeparatorCount(in text: String) -> Int {
    let scalars = Array(text.unicodeScalars)
    return scalars.enumerated().reduce(into: 0) { count, item in
        if universeIsStructuralSeparator(item.element, at: item.offset, in: scalars) {
            count += 1
        }
    }
}

private func scalarBoundaryOffsets(in text: String) -> [Int] {
    var result = [0]
    var offset = 0
    for scalar in text.unicodeScalars {
        offset += scalar.utf16.count
        result.append(offset)
    }
    return result
}

private func universeScalarBoundaryOffsets(in text: String) -> [Int] {
    var result = [0]
    var offset = 0
    for scalar in text.unicodeScalars {
        offset += scalar.utf16.count
        result.append(offset)
    }
    return result
}

private func universeIsScalarBoundary(_ offset: Int, in text: String) -> Bool {
    guard offset >= 0, offset <= text.utf16.count else { return false }
    return universeScalarBoundaryOffsets(in: text).contains(offset)
}

private func independentRawRangeCandidates(
    rawText: String,
    coordinateText: String,
    coordinateRange: UniverseTextRange
) -> [UniverseTextRange] {
    let rawScalars = Array(rawText.unicodeScalars)
    let coordinateScalars = Array(coordinateText.unicodeScalars)
    let rawOffsets = universeScalarBoundaryOffsets(in: rawText)
    let coordinateOffsets = universeScalarBoundaryOffsets(in: coordinateText)

    guard coordinateRange.location >= 0,
          coordinateRange.length >= 0,
          coordinateRange.location <= coordinateText.utf16.count,
          coordinateRange.length <= coordinateText.utf16.count - coordinateRange.location,
          let startCoordinateIndex = coordinateOffsets.firstIndex(of: coordinateRange.location),
          let endCoordinateIndex = coordinateOffsets.firstIndex(of: coordinateRange.location + coordinateRange.length) else {
        return []
    }

    struct IndexedEdge: Hashable {
        let rawIndex: Int
        let fromCoordinateIndex: Int
        let toCoordinateIndex: Int
    }

    struct Node: Hashable {
        let rawIndex: Int
        let coordinateIndex: Int
    }

    var reachable = Array(repeating: Set<Int>(), count: rawScalars.count + 1)
    reachable[0] = [0]
    var edgesByRawIndex = Array(repeating: [IndexedEdge](), count: rawScalars.count)

    for rawIndex in rawScalars.indices {
        let scalar = rawScalars[rawIndex]
        for coordinateIndex in reachable[rawIndex] {
            if coordinateIndex < coordinateScalars.count,
               scalar == coordinateScalars[coordinateIndex] {
                edgesByRawIndex[rawIndex].append(
                    IndexedEdge(
                        rawIndex: rawIndex,
                        fromCoordinateIndex: coordinateIndex,
                        toCoordinateIndex: coordinateIndex + 1
                    )
                )
                reachable[rawIndex + 1].insert(coordinateIndex + 1)
            }
            if universeIsStructuralSeparator(scalar, at: rawIndex, in: rawScalars) {
                edgesByRawIndex[rawIndex].append(
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
        return []
    }

    var canReachEnd = Array(repeating: Set<Int>(), count: rawScalars.count + 1)
    canReachEnd[rawScalars.count] = [coordinateScalars.count]
    for rawIndex in rawScalars.indices.reversed() {
        for edge in edgesByRawIndex[rawIndex]
            where reachable[rawIndex].contains(edge.fromCoordinateIndex)
                && canReachEnd[rawIndex + 1].contains(edge.toCoordinateIndex) {
            canReachEnd[rawIndex].insert(edge.fromCoordinateIndex)
        }
    }

    var validEdges: [IndexedEdge] = []
    for edges in edgesByRawIndex {
        validEdges.append(contentsOf: edges.filter {
            reachable[$0.rawIndex].contains($0.fromCoordinateIndex)
                && canReachEnd[$0.rawIndex + 1].contains($0.toCoordinateIndex)
        })
    }

    var candidates = Array(repeating: [Int](), count: coordinateText.utf16.count + 1)
    var adjacency: [Node: [Node]] = [:]
    candidates[0].append(0)
    candidates[coordinateText.utf16.count].append(rawText.utf16.count)
    for edge in validEdges {
        let from = Node(rawIndex: edge.rawIndex, coordinateIndex: edge.fromCoordinateIndex)
        let to = Node(rawIndex: edge.rawIndex + 1, coordinateIndex: edge.toCoordinateIndex)
        adjacency[from, default: []].append(to)
        candidates[coordinateOffsets[edge.fromCoordinateIndex]].append(rawOffsets[edge.rawIndex])
        candidates[coordinateOffsets[edge.toCoordinateIndex]].append(rawOffsets[edge.rawIndex + 1])
    }
    candidates = candidates.map { offsets in
        Array(Set(offsets)).sorted().filter {
            !universeIsCRLFInteriorBoundary($0, in: rawText)
        }
    }

    guard !candidates[coordinateRange.location].isEmpty,
          !candidates[coordinateRange.location + coordinateRange.length].isEmpty else {
        return []
    }

    let startCandidates = candidates[coordinateRange.location]
    let endCandidates = candidates[coordinateRange.location + coordinateRange.length]
    if startCoordinateIndex == endCoordinateIndex {
        return startCandidates.map { .init(location: $0, length: 0) }
    }

    func hasPath(from start: Node, to end: Node) -> Bool {
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

    var result: [UniverseTextRange] = []
    for start in startCandidates {
        for end in endCandidates where end >= start {
            let startNode = Node(rawIndex: rawOffsets.firstIndex(of: start)!, coordinateIndex: startCoordinateIndex)
            let endNode = Node(rawIndex: rawOffsets.firstIndex(of: end)!, coordinateIndex: endCoordinateIndex)
            if hasPath(from: startNode, to: endNode) {
                result.append(.init(location: start, length: end - start))
            }
        }
    }
    return result.sorted {
        if $0.location != $1.location { return $0.location < $1.location }
        return $0.length < $1.length
    }
}

private func universeIsStructuralSeparator(
    _ scalar: UnicodeScalar,
    at index: Int,
    in scalars: [UnicodeScalar]
) -> Bool {
    switch scalar.value {
    case 0x0A, 0x2028, 0x2029:
        return true
    case 0x0D:
        return index + 1 < scalars.count && scalars[index + 1].value == 0x0A
    default:
        return false
    }
}

private func universeIsCRLFInteriorBoundary(_ offset: Int, in text: String) -> Bool {
    guard offset > 0, offset < text.utf16.count else { return false }
    let units = Array(text.utf16)
    return units[offset - 1] == 0x0D && units[offset] == 0x0A
}

private func stringRange(_ range: UniverseTextRange, in text: String) -> Range<String.Index> {
    let start = String.Index(utf16Offset: range.location, in: text)
    let end = String.Index(utf16Offset: range.location + range.length, in: text)
    return start..<end
}

private func replacing(
    _ text: String,
    range: UniverseTextRange,
    with replacement: String
) -> String {
    let mutable = NSMutableString(string: text)
    mutable.replaceCharacters(
        in: NSRange(location: range.location, length: range.length),
        with: replacement
    )
    return mutable as String
}

private func localPrefixProbe(_ text: String) -> AXTextCoordinateProbe {
    AXTextCoordinateProbe { range in
        guard range.location >= 0,
              range.length >= 0,
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location else {
            return nil
        }
        return (text as NSString).substring(
            with: NSRange(location: range.location, length: range.length)
        )
    }
}

private func independentParagraphs(_ text: String) -> [String] {
    var paragraphs = [String]()
    var current = ""
    for scalar in text.unicodeScalars {
        if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" {
            paragraphs.append(current)
            current.removeAll(keepingCapacity: true)
        } else {
            current.unicodeScalars.append(scalar)
        }
    }
    paragraphs.append(current)
    return paragraphs
}
