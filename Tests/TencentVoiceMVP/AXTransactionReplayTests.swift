import XCTest
@testable import TencentVoiceMVP

@MainActor
final class AXTransactionReplayTests: XCTestCase {
    private func edit(old: String = "甲", new: String = "乙", draft: String = "草稿😀\n") -> ReplayEdit {
        let text = draft + old
        return ReplayEdit(before: .init(text: text, selection: .init(location: text.utf16.count, length: 0)),
                          range: .init(location: draft.utf16.count, length: old.utf16.count), insertion: new)
    }

    func testNegativeControlCurrentAcknowledgementAbortsOnMixedRead() async {
        let change = edit(old: String(repeating: "甲", count: 150), new: String(repeating: "乙", count: 150))
        var sends = 0
        var reads = 0
        do {
            try await KeyboardWriteAcknowledgement.replaceSelection(
                selected: .init(text: change.selected.text, selection: change.selected.selection),
                result: .init(text: change.result.text, selection: change.result.selection),
                read: {
                    reads += 1
                    if sends > 0 { throw ReplayOutcome.unconfirmed }
                    return .init(text: change.selected.text, selection: change.selected.selection)
                }, insert: { sends += 1 }
            )
            XCTFail("The old branch must reproduce immediate abort on a read error")
        } catch { XCTAssertEqual(error as? ReplayOutcome, .unconfirmed) }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(reads, 2)
    }

    func test150UnitSameLengthRevisionRecoversAfter17msObservation() {
        let change = edit(old: "甲", new: "乙", draft: String(repeating: "草", count: 149))
        let editor = ReplayEditor(change.before)
        editor.onInsertion = { e in
            e.now += 17_000_000
            e.visible.selection = change.result.selection
            e.coordinate = change.result.text // AXValue remains old, caret is collapsed.
        }
        editor.onTick = { $0.exposeActual() }
        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .confirmed)
        XCTAssertEqual(editor.actual, change.result)
        XCTAssertEqual(editor.insertionPosts, 1)
        XCTAssertEqual(editor.illegalPosts, 0)
        XCTAssertEqual(editor.now, 27_000_000)
    }

    func testExhaustiveIndependentFieldDelaysPreserveDraftAndSendOnce() {
        let cases = [("甲", "乙"), ("短", "更长的一句"), ("很长的一句", "短"),
                     ("删掉", ""), ("", "追加😀"), ("👨‍👩‍👧‍👦e\u{301}\r\n", "😀\n乙")]
        var runs = 0
        for (old, new) in cases {
            for rawDelay in 0...5 {
                for selectionDelay in 0...5 {
                    for rangeDelay in 0...5 {
                        let change = edit(old: old, new: new)
                        let editor = ReplayEditor(change.before)
                        let expose: (ReplayEditor) -> Void = { e in
                            if e.ticks >= rawDelay { e.visible.text = e.actual.text }
                            if e.ticks >= selectionDelay { e.visible.selection = e.actual.selection }
                            if e.ticks >= rangeDelay { e.coordinate = e.actual.text }
                        }
                        editor.onInsertion = expose
                        editor.onTick = expose
                        let label = "case=\(runs), raw=\(rawDelay), selection=\(selectionDelay), range=\(rangeDelay)"
                        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .confirmed, label)
                        XCTAssertEqual(editor.actual, change.result, label)
                        XCTAssertEqual(editor.insertionPosts, 1, label)
                        XCTAssertEqual(editor.illegalPosts, 0, label)
                        XCTAssertTrue(editor.actual.text.hasPrefix(change.protectedPrefix), label)
                        runs += 1
                    }
                }
            }
        }
        XCTAssertEqual(runs, 1296)
    }

    func testAllFieldUpdatePositionsInsideCollectionAreReplayed() {
        // Three independent visibility changes at any of 8 primitive-read slots.
        // This is not a fake atomic snapshot: changes can split raw/range reads.
        for rawSlot in 1...8 {
            for selectionSlot in 1...8 {
                for rangeSlot in 1...8 {
                    let change = edit()
                    let editor = ReplayEditor(change.before)
                    var postReads = 0
                    editor.onInsertion = { _ in }
                    editor.onRead = { e, _ in
                        guard e.insertionPosts > 0 else { return }
                        postReads += 1
                        if postReads >= rawSlot { e.visible.text = e.actual.text }
                        if postReads >= selectionSlot { e.visible.selection = e.actual.selection }
                        if postReads >= rangeSlot { e.coordinate = e.actual.text }
                    }
                    let label = "slots=\(rawSlot),\(selectionSlot),\(rangeSlot)"
                    XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .confirmed, label)
                    XCTAssertEqual(editor.insertionPosts, 1, label)
                    XCTAssertEqual(editor.illegalPosts, 0, label)
                }
            }
        }
    }

    func testDelayedSelectionMustBeConfirmedBeforeInsertion() {
        let change = edit()
        let editor = ReplayEditor(change.before)
        editor.onSelection = { _ in }
        editor.onTick = { e in
            XCTAssertEqual(e.insertionPosts, 0)
            if e.ticks == 4 { e.exposeActual() }
        }
        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .confirmed)
        XCTAssertEqual(editor.ticks, 4)
        XCTAssertEqual(editor.illegalPosts, 0)
    }

    func testUnavailablePreflightRecoversWithoutPrematureSelection() {
        let change = edit()
        let editor = ReplayEditor(change.before)
        editor.available = false
        editor.onTick = { e in
            XCTAssertEqual(e.selectionPosts, 0)
            if e.ticks == 3 { e.available = true }
        }
        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .confirmed)
        XCTAssertEqual(editor.illegalPosts, 0)
    }

    func testFocusChangeAtEveryReadStopsSubsequentPosts() {
        for slot in 1...26 {
            let change = edit()
            let editor = ReplayEditor(change.before)
            var postsAtChange: Int?
            editor.onRead = { e, _ in
                if e.primitiveReads == slot {
                    postsAtChange = e.insertionPosts
                    e.focused = false
                }
            }
            XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .focusChanged, "slot=\(slot)")
            XCTAssertNotNil(postsAtChange)
            XCTAssertEqual(editor.insertionPosts, postsAtChange)
            XCTAssertEqual(editor.illegalPosts, 0)
        }
    }

    func testCancellationAtEveryReadStopsSubsequentPosts() {
        for slot in 1...26 {
            let change = edit()
            let editor = ReplayEditor(change.before)
            var postsAtCancel: Int?
            editor.onRead = { e, _ in
                if e.primitiveReads == slot { e.cancelled = true; postsAtCancel = e.insertionPosts }
            }
            XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .cancelled, "slot=\(slot)")
            XCTAssertEqual(editor.insertionPosts, postsAtCancel)
            XCTAssertEqual(editor.illegalPosts, 0)
        }
    }

    func testChangedDraftStopsBeforeSendAndAfterSendWithoutRollback() {
        for afterSend in [false, true] {
            let change = edit()
            let editor = ReplayEditor(change.before)
            let modify: (ReplayEditor) -> Void = { e in
                e.actual.text = "用户新草稿" + e.actual.text
                e.exposeActual()
            }
            if afterSend { editor.onInsertion = modify } else { modify(editor) }
            XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .externalEdit)
            XCTAssertEqual(editor.insertionPosts, afterSend ? 1 : 0)
            XCTAssertTrue(editor.actual.text.hasPrefix("用户新草稿"))
        }
    }

    func testPermanentMismatchTimesOutWithoutResendOrFalseSuccess() {
        for unavailable in [false, true] {
            let change = edit()
            let editor = ReplayEditor(change.before)
            editor.onInsertion = { e in
                e.available = !unavailable
                e.visible.selection = change.result.selection // old, same-length text
            }
            XCTAssertEqual(ReplayTransaction(edit: change, editor: editor, timeout: 50_000_000).run(), .unconfirmed)
            XCTAssertEqual(editor.now, 50_000_000)
            XCTAssertEqual(editor.insertionPosts, 1)
            XCTAssertFalse(editor.trace.contains("confirm"))
        }
    }

    func testFirstMatchingObservationHasNoPollingDelay() {
        let change = edit()
        let editor = ReplayEditor(change.before)
        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .confirmed)
        XCTAssertEqual(editor.now, 0)
        XCTAssertEqual(editor.ticks, 0)
    }

    func testDroppedSelectionNeverSendsReplacement() {
        let change = edit()
        let editor = ReplayEditor(change.before)
        editor.onSelection = { e in
            e.actual.selection = change.before.selection
            e.exposeActual()
        }
        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor, timeout: 20_000_000).run(), .unconfirmed)
        XCTAssertEqual(editor.selectionPosts, 1)
        XCTAssertEqual(editor.insertionPosts, 0)
        XCTAssertEqual(editor.actual, change.before)
    }

    func testSlowReadCannotConfirmAfterDeadline() {
        let change = edit()
        let editor = ReplayEditor(change.before)
        editor.onRead = { e, _ in
            if e.insertionPosts == 1 { e.now += 10_000_000 }
        }
        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor, timeout: 20_000_000).run(), .unconfirmed)
        XCTAssertEqual(editor.insertionPosts, 1)
        XCTAssertFalse(editor.trace.contains("confirm"))
    }

    func testExternalChangeWithinEditedTailRemainsUnconfirmed() {
        let change = edit()
        let editor = ReplayEditor(change.before)
        editor.onInsertion = { e in
            e.actual.text = change.protectedPrefix + "用户替换的尾部"
            e.actual.selection = .init(location: e.actual.text.utf16.count, length: 0)
            e.exposeActual()
        }
        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor, timeout: 20_000_000).run(), .unconfirmed)
        XCTAssertEqual(editor.actual.text, change.protectedPrefix + "用户替换的尾部")
        XCTAssertEqual(editor.insertionPosts, 1)
    }

    func testLongSilenceDoesNotConsumeNextTransactionDeadline() {
        let change = edit()
        let editor = ReplayEditor(change.before)
        editor.now = 30_000_000_000
        editor.onInsertion = { _ in }
        editor.onTick = { $0.exposeActual() }
        XCTAssertEqual(ReplayTransaction(edit: change, editor: editor).run(), .confirmed)
        XCTAssertEqual(editor.now, 30_010_000_000)
    }

    func testRealWriterContinues43ResultsAfterRecoveredRevision() async throws {
        let target = ReplayWriterTarget(draft: "草稿😀\n")
        var commits = 0
        var failures = 0
        let writer = AcknowledgedKeyboardWriter(target: target, onCommit: { _, _ in commits += 1 },
                                               onFailure: { _ in failures += 1 })
        target.editor.onInsertion = { e in
            e.coordinate = e.actual.text
            e.visible.selection = e.actual.selection
        }
        target.editor.onTick = { $0.exposeActual() }
        try await writer.finish("甲")
        try await writer.finish("乙")
        for index in 1...43 { try await writer.finish("乙" + String(repeating: "续", count: index)) }
        XCTAssertEqual(writer.confirmedText, "乙" + String(repeating: "续", count: 43))
        XCTAssertEqual(target.editor.actual.text, "草稿😀\n" + writer.confirmedText)
        XCTAssertEqual(commits, 45)
        XCTAssertEqual(target.editor.insertionPosts, 45)
        XCTAssertEqual(target.editor.illegalPosts, 0)
        XCTAssertEqual(failures, 0)
    }

    func testRealWriterCoalesces43CandidatesDuringPendingTransaction() async throws {
        let target = ReplayWriterTarget(draft: "草稿：")
        var commits = 0
        let writer = AcknowledgedKeyboardWriter(target: target, onCommit: { _, _ in commits += 1 },
                                               onFailure: { XCTFail("Unexpected error: \($0)") })
        target.editor.onInsertion = { e in
            if e.insertionPosts == 1 {
                do {
                    for index in 1...43 { try writer.accept("结果\(index)") }
                } catch { XCTFail("Unexpected candidate rejection: \(error)") }
            }
            e.exposeActual()
        }
        try await writer.finish("开始")
        XCTAssertEqual(writer.confirmedText, "结果43")
        XCTAssertEqual(target.editor.actual.text, "草稿：结果43")
        XCTAssertEqual(target.editor.insertionPosts, 2)
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(target.editor.illegalPosts, 0)
    }
}
