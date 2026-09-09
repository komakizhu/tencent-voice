import XCTest
@testable import TencentVoiceMVP

@MainActor
final class AcknowledgedKeyboardWriterTests: XCTestCase {
    func testLegacyDispatchOnlyPathReproducesNextSegmentStop() throws {
        let target = DelayedKeyboardTarget()
        let injector = TextInjector(target: LegacyKeyboardView(target))
        try injector.begin()
        injector.apply(projection: projection("first"))
        injector.apply(projection: projection("first next"))
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        XCTAssertEqual(target.posts, 1)
        XCTAssertEqual(target.text, "Draft: ")
    }

    func testPendingWriteCoalescesNewCandidatesWithoutResending() async throws {
        let target = DelayedKeyboardTarget()
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection("first"))
        await settle()
        XCTAssertEqual(target.posts, 1)
        XCTAssertEqual(injector.writeCount, 0)
        injector.apply(projection: projection("first next"))
        injector.apply(projection: projection("first corrected next"))
        await settle()
        XCTAssertEqual(target.posts, 1)
        target.blocked = false
        try await injector.finish(finalText: "first corrected next")
        XCTAssertEqual(target.text, "Draft: first corrected next")
        XCTAssertEqual(target.posts, 2)
        XCTAssertEqual(injector.writeCount, 2)
        XCTAssertEqual(injector.errorCount, 0)
    }

    func testLongRevisionAndImmediateNextSegmentKeepPrefixAndUnicode() async throws {
        let target = DelayedKeyboardTarget()
        target.blocked = false
        let injector = TextInjector(target: target)
        try injector.begin()
        let prefix = String(repeating: "甲", count: 199)
        let original = prefix + String(repeating: "乙", count: 104)
        let revised = prefix + String(repeating: "丙", count: 103)
        try await injector.finish(finalText: original)
        target.blocked = true
        injector.apply(projection: projection(revised))
        await settle()
        injector.apply(projection: projection(revised + "下一句😀e\u{301}"))
        await settle()
        XCTAssertEqual(target.posts, 2)
        XCTAssertEqual(target.text, "Draft: " + original)
        target.blocked = false
        try await injector.finish(finalText: revised + "下一句😀e\u{301}")
        XCTAssertEqual(target.text, "Draft: " + revised + "下一句😀e\u{301}")
        XCTAssertEqual(injector.maximumTrailingReplacementLength, 104)
        XCTAssertEqual(injector.deepReplacementCount, 1)
        XCTAssertEqual(injector.errorCount, 0)
    }

    func testCancellationDoesNotPostQueuedCandidate() async throws {
        let target = DelayedKeyboardTarget()
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection("first"))
        await settle()
        injector.apply(projection: projection("first next"))
        injector.cancel()
        target.blocked = false
        await settle()
        XCTAssertEqual(target.posts, 1)
    }

    func testFocusChangeDuringPendingWriteStopsWithoutFollowup() async throws {
        let target = DelayedKeyboardTarget()
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection("first"))
        await settle()
        target.changed = true
        target.blocked = false
        try await injector.finish(finalText: "first next")
        XCTAssertEqual(target.posts, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
    }

    func testLivePacerFinishesOnlyAfterAcknowledgedFinalText() async throws {
        let target = DelayedKeyboardTarget()
        target.blocked = false
        let injector = TextInjector(target: target, keyboardSmoothing: .live)
        try injector.begin()
        injector.apply(projection: projection("你好世界"))
        try await injector.finish(finalText: "你好，世界😀")
        XCTAssertEqual(target.text, "Draft: 你好，世界😀")
        XCTAssertNil(target.pending)
        XCTAssertEqual(injector.errorCount, 0)
    }

    func testMatchingCaretWithStaleSameLengthTextIsNotAcknowledged() async throws {
        var clock: UInt64 = 0
        var reads = 0
        let expected = KeyboardDocumentState(text: "new", selection: .init(location: 3, length: 0))
        try await KeyboardWriteAcknowledgement.wait(for: expected, now: { clock }, sleep: { clock += $0 }) {
            reads += 1
            return clock < 400_000_000
                ? KeyboardDocumentState(text: "old", selection: expected.selection) : expected
        }
        XCTAssertEqual(clock, 400_000_000)
        XCTAssertGreaterThan(reads, 1)
    }

    func testRetryableAXValueReadWaitsForValueToCatchUp() async throws {
        var clock: UInt64 = 0
        var reads = 0
        let expected = KeyboardDocumentState(text: "abcdefg", selection: .init(location: 7, length: 0))

        try await KeyboardWriteAcknowledgement.wait(
            for: expected,
            now: { clock },
            sleep: { clock += $0 },
            read: {
                reads += 1
                if reads == 1 {
                    // The real AX adapter has already observed the advanced
                    // caret, while AXValue still contains the six-character
                    // pre-write document.
                    throw KeyboardWriteReadError.retryable
                }
                return expected
            }
        )

        XCTAssertEqual(reads, 2)
        XCTAssertEqual(clock, 10_000_000)
    }

    func testValidatedStructuralAXChangeStillAcknowledgesSkillFirstCharacter() async throws {
        let expected = KeyboardDocumentState(
            text: "技能标签正文然",
            selection: .init(location: "技能标签正文然".utf16.count, length: 0),
            rawText: "技能标签正文然"
        )
        let rawObserved = "技能标签\n正文然\n"
        let coordinateObserved = "技能标签正文然"
        let resolved = try AXTextDocumentResolver.resolve(
            rawText: rawObserved,
            selection: .init(location: coordinateObserved.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: AXTextCoordinateProbe { range in
                guard range.location == 0,
                      range.length >= 0,
                      range.length <= coordinateObserved.utf16.count else {
                    return nil
                }
                return (coordinateObserved as NSString).substring(
                    with: NSRange(location: 0, length: range.length)
                )
            }
        )
        let observed = KeyboardDocumentState(
            text: resolved.text,
            selection: resolved.selection,
            rawText: resolved.rawText,
            mapping: resolved.mapping
        )
        var clock: UInt64 = 0
        let actual = try await KeyboardWriteAcknowledgement.wait(
            for: expected,
            matches: { expected, observed in
                observed.compare(to: expected, allowingStructuralRawDifference: true) == .matched
            },
            now: { clock },
            sleep: { clock += $0 },
            read: { observed }
        )

        XCTAssertEqual(actual.rawText, rawObserved)
        XCTAssertEqual(actual.mapping, resolved.mapping)
        XCTAssertEqual(clock, 0)
    }

    func testManualEditFreezesOldVoiceTailAndContinuesAtCurrentCaret() async throws {
        let target = MixedInputKeyboardTarget()
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("原始语音", revision: 1))
        await settle()
        target.appendManualText("手动")
        injector.apply(projection: projection("原始语音继续", revision: 2))
        try await injector.finish(finalText: "原始语音继续")

        XCTAssertEqual(target.text, "草稿：原始语音手动继续")
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertTrue(injector.drainDiagnostics().contains { $0.event == "mixed_input_rebased" })
    }

    func testManualEditWithChangedRecognitionPrefixStopsWithoutOverwritingUserText() async throws {
        let target = MixedInputKeyboardTarget()
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("原始语音", revision: 1))
        await settle()
        target.appendManualText("手动")
        injector.apply(projection: projection("识别回头覆盖", revision: 2))
        try await injector.finish(finalText: "识别回头覆盖")

        XCTAssertEqual(target.text, "草稿：原始语音手动")
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
    }

    func testManualEditWhileVoiceOutputIsQueuedStopsWithoutDroppingIntoOldRange() async throws {
        let target = MixedInputKeyboardTarget()
        let clock = ManualKeyboardPacingClock()
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: projection("原始语音", revision: 1))
        await settle()
        target.appendManualText("手动")
        injector.apply(projection: projection("原始语音继续", revision: 2))
        try await injector.finish(finalText: "原始语音继续")

        XCTAssertTrue(target.text.hasPrefix("草稿：原手动"))
        XCTAssertFalse(target.text.contains("继续"))
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
    }

    func testUnresponsiveDocumentTimesOutWithoutAssumingSuccess() async {
        var clock: UInt64 = 0
        do {
            try await KeyboardWriteAcknowledgement.wait(
                for: .init(text: "new", selection: .init(location: 3, length: 0)),
                timeoutNanoseconds: 500_000_000, now: { clock }, sleep: { clock += $0 }
            ) { .init(text: "old", selection: .init(location: 3, length: 0)) }
            XCTFail("Stale text must not be acknowledged")
        } catch {
            XCTAssertEqual((error as? TextTargetError)?.diagnosticCode, "text_target_write_failed")
        }
        XCTAssertEqual(clock, 500_000_000)
    }

    func testTransientReadsStillRespectDeadlineAndFocusFailure() async {
        for focusChanges in [false, true] {
            var clock: UInt64 = 0
            do {
                try await KeyboardWriteAcknowledgement.wait(
                    for: .init(text: "结果", selection: .init(location: 2, length: 0)),
                    timeoutNanoseconds: 20_000_000, now: { clock }, sleep: { clock += $0 }
                ) {
                    if focusChanges && clock > 0 { throw TextTargetError.targetChanged }
                    throw KeyboardWriteReadError.retryable
                }
                XCTFail("Unconfirmed text must never be accepted")
            } catch {
                XCTAssertEqual((error as? TextTargetError)?.diagnosticCode,
                               focusChanges ? "text_target_changed" : "text_target_write_failed")
            }
            XCTAssertEqual(clock, focusChanges ? 10_000_000 : 20_000_000)
        }
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }
    private func projection(_ text: String, revision: UInt64 = 1) -> ASRProjection {
        ASRProjection(committedText: "", activeSegmentText: text, activeSegmentID: 0,
                      activeIsFinal: false, revision: revision, changed: true, isFinal: false)
    }
}

@MainActor
private final class DelayedKeyboardTarget: KeyboardAcknowledgingTarget {
    let requiresKeyboardAcknowledgement = true
    var text = "Draft: "
    var pending: String?
    var blocked = true
    var changed = false
    var posts = 0

    func capture() throws -> TextSnapshot {
        .init(text: text, selection: .init(location: text.utf16.count, length: 0),
              targetApplication: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 1))
    }
    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String,
                 with text: String) throws -> TencentVoiceMVP.TextRange { throw TextTargetError.unsupported }
    func paste(_ insertion: String) throws {
        guard pending == nil, !changed else { throw TextTargetError.targetChanged }
        pending = text + insertion
        posts += 1
    }
    func replaceTrailingText(_ previous: String, with insertion: String) throws {
        guard pending == nil, !changed, text.hasSuffix(previous) else { throw TextTargetError.targetChanged }
        pending = String(text.dropLast(previous.count)) + insertion
        posts += 1
    }
    func acknowledgeKeyboardWrite() async throws {
        while blocked { try Task.checkCancellation(); await Task.yield() }
        try Task.checkCancellation()
        guard !changed else { throw TextTargetError.targetChanged }
        if let pending { text = pending }
        pending = nil
    }
    func copyToClipboard(_ text: String) throws {}
}

// Negative control: the same delayed editor behind the previous sync interface.
@MainActor
private final class LegacyKeyboardView: TextTarget {
    let target: DelayedKeyboardTarget
    init(_ target: DelayedKeyboardTarget) { self.target = target }
    func capture() throws -> TextSnapshot { try target.capture() }
    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String,
                 with text: String) throws -> TencentVoiceMVP.TextRange { throw TextTargetError.unsupported }
    func paste(_ text: String) throws { try target.paste(text) }
    func replaceTrailingText(_ previous: String, with text: String) throws { try target.replaceTrailingText(previous, with: text) }
    func copyToClipboard(_ text: String) throws {}
}

@MainActor
private final class MixedInputKeyboardTarget: KeyboardAcknowledgingTarget {
    let requiresKeyboardAcknowledgement = true
    private(set) var text = "草稿："
    private var selection = TencentVoiceMVP.TextRange(location: 3, length: 0)
    private var confirmedText = "草稿："
    private var confirmedSelection = TencentVoiceMVP.TextRange(location: 3, length: 0)
    private var pendingText: String?
    private var pendingSelection: TencentVoiceMVP.TextRange?
    private var hasManualEdit = false

    func capture() throws -> TextSnapshot {
        TextSnapshot(
            text: text,
            selection: selection,
            targetApplication: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 1)
        )
    }

    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String, with text: String) throws -> TencentVoiceMVP.TextRange {
        throw TextTargetError.unsupported
    }

    func paste(_ insertion: String) throws {
        guard pendingText == nil,
              text == confirmedText,
              selection == confirmedSelection else {
            throw TextTargetError.targetChanged
        }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: NSRange(location: selection.location, length: selection.length), with: insertion)
        pendingText = mutable as String
        pendingSelection = TencentVoiceMVP.TextRange(location: selection.location + insertion.utf16.count, length: 0)
    }

    func replaceTrailingText(_ previousText: String, with insertion: String) throws {
        guard pendingText == nil,
              text == confirmedText,
              selection == confirmedSelection,
              text.hasSuffix(previousText) else {
            throw TextTargetError.targetChanged
        }
        pendingText = String(text.dropLast(previousText.count)) + insertion
        pendingSelection = TencentVoiceMVP.TextRange(location: pendingText?.utf16.count ?? 0, length: 0)
    }

    func acknowledgeKeyboardWrite() async throws {
        try Task.checkCancellation()
        guard let pendingText, let pendingSelection else { throw TextTargetError.writeFailed }
        text = pendingText
        selection = pendingSelection
        confirmedText = text
        confirmedSelection = selection
        self.pendingText = nil
        self.pendingSelection = nil
    }

    func reconcileKeyboardStateForUserEdit() throws -> KeyboardReconciliation {
        guard hasManualEdit else { return .matched }
        hasManualEdit = false
        confirmedText = text
        confirmedSelection = selection
        return .externalEdit
    }

    func appendManualText(_ insertion: String) {
        text.append(insertion)
        selection = TencentVoiceMVP.TextRange(location: text.utf16.count, length: 0)
        hasManualEdit = true
    }

    func copyToClipboard(_ text: String) throws {}
}
