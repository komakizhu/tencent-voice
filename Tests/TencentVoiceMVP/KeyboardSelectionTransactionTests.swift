import XCTest
@testable import TencentVoiceMVP

@MainActor
final class KeyboardSelectionTransactionTests: XCTestCase {
    func testReplacementWaitsForExactSelectionThenExactDocument() async throws {
        var clock: UInt64 = 0
        var sentAt: UInt64?
        var sends = 0
        let selected = KeyboardDocumentState(text: "abcdef", selection: .init(location: 3, length: 3))
        let result = KeyboardDocumentState(text: "abcXYZ", selection: .init(location: 6, length: 0))
        try await KeyboardWriteAcknowledgement.replaceSelection(
            selected: selected, result: result, now: { clock }, sleep: { clock += $0 },
            read: {
                if let sentAt {
                    return clock < sentAt + 100_000_000 ? selected : result
                }
                return clock < 400_000_000
                    ? .init(text: "abcdef", selection: .init(location: 5, length: 1)) : selected
            }, insert: { sends += 1; sentAt = clock }
        )
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(sentAt, 400_000_000)
        XCTAssertEqual(clock, 500_000_000)
    }

    func testDroppedSelectionEventsNeverReplaceWrongRange() async {
        var clock: UInt64 = 0
        var sends = 0
        do {
            try await KeyboardWriteAcknowledgement.replaceSelection(
                selected: .init(text: "abcdef", selection: .init(location: 0, length: 6)),
                result: .init(text: "", selection: .init(location: 0, length: 0)),
                timeoutNanoseconds: 50_000_000, now: { clock }, sleep: { clock += $0 },
                read: { .init(text: "abcdef", selection: .init(location: 1, length: 5)) },
                insert: { sends += 1 }
            )
            XCTFail("Partial selection must not be accepted")
        } catch {
            XCTAssertEqual((error as? TextTargetError)?.diagnosticCode, "text_target_write_failed")
        }
        XCTAssertEqual(sends, 0)
    }

    func testFocusChangeBeforeSelectionReceiptNeverInserts() async {
        var sends = 0
        do {
            try await KeyboardWriteAcknowledgement.replaceSelection(
                selected: .init(text: "abc", selection: .init(location: 0, length: 3)),
                result: .init(text: "xyz", selection: .init(location: 3, length: 0)),
                read: { throw TextTargetError.targetChanged }, insert: { sends += 1 }
            )
            XCTFail("Focus change must abort")
        } catch {
            XCTAssertEqual((error as? TextTargetError)?.diagnosticCode, "text_target_changed")
        }
        XCTAssertEqual(sends, 0)
    }

    func testDeletionIsConfirmedWithoutRetry() async throws {
        let selected = KeyboardDocumentState(text: "abc", selection: .init(location: 0, length: 3))
        let result = KeyboardDocumentState(text: "", selection: .init(location: 0, length: 0))
        var state = selected
        var sends = 0
        try await KeyboardWriteAcknowledgement.replaceSelection(
            selected: selected, result: result, read: { state }, insert: { sends += 1; state = result }
        )
        XCTAssertEqual(sends, 1)
    }
}
