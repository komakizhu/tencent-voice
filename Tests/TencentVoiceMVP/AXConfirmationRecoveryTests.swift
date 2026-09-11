import XCTest
@testable import TencentVoiceMVP

@MainActor
final class AXConfirmationRecoveryTests: XCTestCase {
    func testCollapsedCaretDuringSameLengthRevisionWaitsForConsistentText() async throws {
        let prefix = String(repeating: "草", count: 149)
        let old = prefix + "甲"
        let new = prefix + "乙"
        let selected = KeyboardDocumentState(text: old, selection: .init(location: 149, length: 1), rawText: old)
        let result = KeyboardDocumentState(text: new, selection: .init(location: 150, length: 0), rawText: new)
        var clock: UInt64 = 30_000_000_000 // Long silence before this transaction.
        var sends = 0
        var reads = 0
        try await KeyboardWriteAcknowledgement.replaceSelection(
            selected: selected, result: result, now: { clock }, sleep: { clock += $0 },
            read: {
                if sends == 0 { return selected }
                reads += 1
                return try KeyboardWriteAcknowledgement.readObservation {
                    let state = try AXTextDocumentResolver.resolve(
                        rawText: reads == 1 ? old : new,
                        selection: result.selection,
                        placeholderEvidence: AXPlaceholderEvidence(),
                        probe: AXTextCoordinateProbe { range in
                            (new as NSString).substring(with: NSRange(location: range.location, length: range.length))
                        }
                    )
                    return .init(text: state.text, selection: state.selection, rawText: state.rawText)
                }
            }, insert: { sends += 1 }
        )
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(clock, 30_010_000_000)
    }

    func testTransientCoordinateReadRemainsUnconfirmedUntilDeadline() async {
        for error in [AXTextDocumentResolutionError.coordinateReadUnavailable,
                      .coordinateTextMismatch] {
            var clock: UInt64 = 0
            do {
                try await KeyboardWriteAcknowledgement.wait(
                    for: .init(text: "甲", selection: .init(location: 1, length: 0)),
                    timeoutNanoseconds: 20_000_000, now: { clock }, sleep: { clock += $0 }
                ) {
                    try KeyboardWriteAcknowledgement.readObservation { throw error }
                }
                XCTFail("A transient inconsistent snapshot must never confirm delivery")
            } catch {
                XCTAssertEqual((error as? TextTargetError)?.diagnosticCode, "text_target_write_failed")
            }
            XCTAssertEqual(clock, 20_000_000)
        }
    }

    func testInvalidCoordinateSnapshotRemainsTerminal() async {
        for error in [AXTextDocumentResolutionError.invalidSelection,
                      .coordinateLengthMismatch, .selectionOutOfBounds,
                      .selectedRangeUnavailable] {
            var clock: UInt64 = 0
            do {
                try await KeyboardWriteAcknowledgement.wait(
                    for: .init(text: "甲", selection: .init(location: 1, length: 0)),
                    timeoutNanoseconds: 20_000_000, now: { clock }, sleep: { clock += $0 }
                ) {
                    try KeyboardWriteAcknowledgement.readObservation { throw error }
                }
                XCTFail("An invalid coordinate snapshot must stop confirmation immediately")
            } catch let observed as AXTextDocumentResolutionError {
                XCTAssertEqual(observed, error)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(clock, 0)
        }
    }

    func testFocusChangeAndCancellationAreNotConvertedToRetry() {
        XCTAssertThrowsError(try KeyboardWriteAcknowledgement.readObservation { throw TextTargetError.targetChanged }) {
            XCTAssertEqual(($0 as? TextTargetError)?.diagnosticCode, "text_target_changed")
        }
        XCTAssertThrowsError(try KeyboardWriteAcknowledgement.readObservation { throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testMatchingFirstReadHasNoWait() async throws {
        let state = KeyboardDocumentState(text: "中文😀", selection: .init(location: 4, length: 0))
        var sleeps = 0
        try await KeyboardWriteAcknowledgement.wait(for: state, sleep: { _ in sleeps += 1 }) {
            try KeyboardWriteAcknowledgement.readObservation { state }
        }
        XCTAssertEqual(sleeps, 0)
    }

    func testMatchingObservationReturnsItsCoordinateMapping() async throws {
        let mapping = AXTextCoordinateMapping(
            source: .axStringForRange,
            rawDocumentLength: 4,
            coordinateDocumentLength: 3,
            omittedStructuralSeparatorCount: 1,
            rawBoundaryOffsets: [0, 2, 3, 4],
            rawPlaceholderRange: nil
        )
        let expected = KeyboardDocumentState(
            text: "😀好",
            selection: .init(location: 3, length: 0),
            rawText: "😀\n好"
        )
        let observed = try await KeyboardWriteAcknowledgement.wait(
            for: expected,
            matches: { expected, observed in
                observed.compare(to: expected, allowingStructuralRawDifference: true) == .matched
            },
            read: {
                .init(
                    text: expected.text,
                    selection: expected.selection,
                    rawText: expected.rawText,
                    mapping: mapping
                )
            }
        )

        XCTAssertEqual(observed.mapping, mapping)
    }
}
