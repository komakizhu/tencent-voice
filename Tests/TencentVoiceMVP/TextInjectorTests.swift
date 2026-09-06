import XCTest
@testable import TencentVoiceMVP

@MainActor
final class TextInjectorTests: XCTestCase {
    func testKeyboardPacingShowsFirstCharacterImmediatelyAndCompletesWithinDeadline() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let clock = ManualKeyboardPacingClock()
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "甲乙丙丁戊",
            id: 1,
            revision: 1
        ))

        XCTAssertEqual(target.text, "甲")
        XCTAssertEqual(target.pastedTexts, ["甲"])

        await settle()
        clock.advance(by: 250_000_000)
        await settle()

        XCTAssertEqual(target.text, "甲乙丙丁戊")
        XCTAssertEqual(target.pastedTexts.first, "甲")
        XCTAssertEqual(target.pastedTexts.dropFirst().joined(), "乙丙丁戊")
    }

    func testKeyboardPacingRevisesPendingCharactersWithoutTouchingVisibleText() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let clock = ManualKeyboardPacingClock()
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "甲乙丙丁戊",
            id: 1,
            revision: 1
        ))
        await settle()
        injector.apply(projection: projection(
            committed: "",
            active: "甲乙改丁戊",
            id: 1,
            revision: 2
        ))

        XCTAssertEqual(target.text, "甲")

        clock.advance(by: 250_000_000)
        await settle()

        XCTAssertEqual(target.text, "甲乙改丁戊")
        XCTAssertFalse(target.text.contains("丙"))
    }

    func testKeyboardPacingFlushesPendingCharactersOnFinal() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let clock = ManualKeyboardPacingClock()
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "甲乙丙丁戊",
            id: 1,
            revision: 1
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "甲乙丙丁戊",
            id: 1,
            revision: 2,
            isFinal: true
        ))

        XCTAssertEqual(target.text, "甲乙")

        await settle()
        clock.advance(by: 120_000_000)
        await settle()

        XCTAssertEqual(target.text, "甲乙丙丁戊")
    }

    func testKeyboardFinalRevisionDoesNotDisableFollowingSegment() throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃苹果",
            id: 1,
            revision: 1
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃香蕉",
            id: 1,
            revision: 2
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "我要吃香蕉",
            id: 1,
            revision: 3,
            isFinal: true
        ))
        injector.apply(projection: projection(
            committed: "我要吃香蕉",
            active: "下一句",
            id: 2,
            revision: 4
        ))

        XCTAssertEqual(target.text, "我要吃香蕉下一句")
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertNil(target.copiedText)
    }

    func testKeyboardTargetChangeUsesSafeCopyInsteadOfEditingTheWrongText() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃苹果",
            id: 1,
            revision: 1
        ))
        target.text = "用户已经移动到其他文字"
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃香蕉",
            id: 1,
            revision: 2
        ))
        try await injector.finish(finalText: "我想吃香蕉")

        XCTAssertEqual(target.text, "用户已经移动到其他文字")
        XCTAssertEqual(target.copiedText, "我想吃香蕉")
        XCTAssertEqual(injector.modeDescription, "safe_copy")
    }

    func testKeyboardDeepPartialRevisionIsImmediatelyReplacedWithoutBackspaces() throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)
        let committed = "这是已经确认的一大段前缀，后面还有稳定内容。"
        let initial = "这是一段很长的稳定前缀，中间候选正在变化，后面还有一大段应该保持不动的文字。"
        let revised = "这是一段很长的稳定前缀，中间候选已经修订，后面还有一大段应该保持不动的文字。"

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: committed, id: 1, revision: 1))
        injector.apply(projection: projection(committed: committed, active: initial, id: 2, revision: 2))
        injector.apply(projection: projection(committed: committed, active: revised, id: 2, revision: 3))

        XCTAssertEqual(target.text, committed + revised)
        XCTAssertEqual(target.trailingReplacementLengths.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(target.trailingReplacementLengths.first), 12)
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertEqual(injector.backspaceCount, 0)

        injector.apply(projection: projection(committed: committed, active: revised, id: 2, revision: 4, isFinal: true))

        XCTAssertEqual(target.text, committed + revised)
        XCTAssertEqual(target.trailingReplacementLengths.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(target.trailingReplacementLengths.first), 12)
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertEqual(injector.backspaceCount, 0)
    }

    func testFinishKeepsReplacementMetricsUntilSessionCleanup() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)
        let initial = "这是很长很长的旧候选文字，后面仍然有很多内容"
        let revised = "这是完全不同的新候选文字，后面仍然有很多内容"

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: initial,
            id: 1,
            revision: 1
        ))
        injector.apply(projection: projection(
            committed: "",
            active: revised,
            id: 1,
            revision: 2
        ))
        try await injector.finish(finalText: revised)

        XCTAssertEqual(injector.deepReplacementCount, 1)
        XCTAssertGreaterThan(injector.maximumTrailingReplacementLength, 12)

        injector.cancel()
        XCTAssertEqual(injector.deepReplacementCount, 0)
        XCTAssertEqual(injector.maximumTrailingReplacementLength, 0)
    }

    func testKeyboardPartialAppearsImmediatelyAndGrowthAppends() throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "这是一个稳定",
            id: 1,
            revision: 1
        ))
        XCTAssertEqual(target.text, "这是一个稳定")

        injector.apply(projection: projection(
            committed: "",
            active: "这是一个稳定的长句",
            id: 1,
            revision: 2
        ))
        XCTAssertEqual(target.pastedTexts, ["这是一个稳定", "的长句"])
        XCTAssertEqual(target.text, "这是一个稳定的长句")

        injector.apply(projection: projection(
            committed: "",
            active: "这是一个稳定的长句，继续说",
            id: 1,
            revision: 3
        ))

        XCTAssertEqual(target.pastedTexts, ["这是一个稳定", "的长句", "，继续说"])
        XCTAssertEqual(target.text, "这是一个稳定的长句，继续说")
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertEqual(injector.backspaceCount, 0)
    }

    func testKeyboardServerStableMetadataDoesNotDelayVisiblePartial() throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "这是一个正在变化的句子",
            id: 1,
            revision: 1,
            stablePrefix: "这是一个"
        ))

        XCTAssertEqual(target.pastedTexts, ["这是一个正在变化的句子"])

        injector.apply(projection: projection(
            committed: "",
            active: "这是一个正在变化的句子，继续说",
            id: 1,
            revision: 2,
            stablePrefix: "这是一个正在变化的"
        ))

        XCTAssertEqual(target.pastedTexts, ["这是一个正在变化的句子", "，继续说"])
        XCTAssertEqual(target.text, "这是一个正在变化的句子，继续说")
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testActiveRevisionDoesNotDisableKeyboardLiveTailPath() throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃苹果",
            id: 1,
            revision: 1
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃香蕉",
            id: 1,
            revision: 2
        ))

        XCTAssertEqual(target.text, "我想吃香蕉")

        injector.apply(projection: projection(
            committed: "",
            active: "我要喝水",
            id: 1,
            revision: 3
        ))

        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertEqual(target.text, "我要喝水")
        XCTAssertLessThanOrEqual(target.trailingReplacementLengths.max() ?? 0, 12)
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertEqual(injector.backspaceCount, 0)
    }

    func testFinalKeepsServerStablePrefixAndFlushesOnlyTheUnstableTail() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃苹果",
            id: 1,
            revision: 1,
            stablePrefix: "我想"
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃香蕉",
            id: 1,
            revision: 2,
            isFinal: true
        ))
        try await injector.finish(finalText: "我想吃香蕉")

        XCTAssertEqual(target.pastedTexts, ["我想吃苹果"])
        XCTAssertEqual(target.text, "我想吃香蕉")
        XCTAssertEqual(target.trailingReplacementLengths, [2])
        XCTAssertNil(target.copiedText)
        XCTAssertEqual(injector.backspaceCount, 0)
    }

    func testKeyboardStablePrefixSurvivesActiveRevisionWithoutDeletingSubmittedText() throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃苹果",
            id: 1,
            revision: 1
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "我想吃香蕉",
            id: 1,
            revision: 2
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "我想喝西瓜",
            id: 1,
            revision: 3
        ))

        XCTAssertEqual(target.pastedTexts, ["我想吃苹果"])
        XCTAssertEqual(target.text, "我想喝西瓜")
        XCTAssertEqual(injector.backspaceCount, 0)

        injector.apply(projection: projection(
            committed: "",
            active: "我想喝葡萄",
            id: 1,
            revision: 4,
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "我想喝葡萄。",
            id: 1,
            revision: 5,
            isFinal: true
        ))

        XCTAssertEqual(target.pastedTexts, ["我想吃苹果", "。"])
        XCTAssertEqual(target.text, "我想喝葡萄。")
        XCTAssertLessThanOrEqual(target.trailingReplacementLengths.max() ?? 0, 12)
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertEqual(injector.backspaceCount, 0)
    }

    func testKeyboardStablePrefixPreservesEmojiAndCombiningCharacters() throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)
        let first = "😀e\u{301}"
        let second = "😀e\u{301}之后"

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: first, id: 1, revision: 1))
        injector.apply(projection: projection(committed: "", active: second, id: 1, revision: 2))
        injector.apply(projection: projection(
            committed: "",
            active: "😀e\u{301}之后再",
            id: 1,
            revision: 3
        ))

        XCTAssertEqual(target.pastedTexts, ["😀e\u{301}", "之后", "再"])
        XCTAssertEqual(target.text, "😀e\u{301}之后再")
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertEqual(injector.backspaceCount, 0)
    }

    func testKeyboardShorterInterimProjectionDoesNotTripSafeCopy() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(
            committed: "",
            active: "这是一段正在输入的文字",
            id: 1,
            revision: 1
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "这是一段正在输入的文字，继续",
            id: 1,
            revision: 2
        ))
        injector.apply(projection: projection(
            committed: "",
            active: "这是一段正在输入的文字，继续完成",
            id: 1,
            revision: 3
        ))

        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        let submittedBeforeRetraction = target.text

        injector.apply(projection: projection(
            committed: "",
            active: "这是一段正在输入",
            id: 1,
            revision: 4
        ))

        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertNotEqual(target.text, submittedBeforeRetraction)
        XCTAssertEqual(target.text, "这是一段正在输入")
        XCTAssertLessThanOrEqual(target.trailingReplacementLengths.max() ?? 0, 12)

        injector.apply(projection: projection(
            committed: "",
            active: "这是一段正在输入的文字，继续完成",
            id: 1,
            revision: 5,
            isFinal: true
        ))
        try await injector.finish(finalText: "这是一段正在输入的文字，继续完成")

        XCTAssertEqual(target.text, "这是一段正在输入的文字，继续完成")
        XCTAssertNil(target.copiedText)
        XCTAssertEqual(target.replaceCallCount, 0)
    }

    func testPartialUpdatesReplaceOwnedRange() async throws {
        let target = FakeTextTarget(text: "前缀")
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "你", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "", active: "你好", id: 1, revision: 2))
        injector.apply(projection: projection(committed: "", active: "你好呀", id: 1, revision: 3, isFinal: true))
        try await injector.finish(finalText: "你好呀")
        XCTAssertEqual(target.text, "前缀你好呀")
        XCTAssertEqual(target.replaceCallCount, 3)
    }

    func testExternalEditStopsLiveReplacementAndCopiesFinal() async throws {
        let target = FakeTextTarget(text: "原文")
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "临时", id: 1, revision: 1))
        target.text = "用户自己改过的文字"
        injector.apply(projection: projection(committed: "", active: "最终", id: 1, revision: 2))
        try await injector.finish(finalText: "最终")
        XCTAssertEqual(target.text, "用户自己改过的文字")
        XCTAssertEqual(target.copiedText, "最终")
    }

    func testAXUnsupportedTargetUsesKeyboardSegmentCommitMode() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        injector.apply(projection: projection(committed: "", active: "实时", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "", active: "实时结果", id: 1, revision: 2, isFinal: true))
        try await injector.finish(finalText: "实时结果")

        XCTAssertEqual(target.pastedTexts, ["实时", "结果"])
        XCTAssertEqual(target.text, "实时结果")
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertNil(target.copiedText)
    }

    func testKeyboardSegmentCommitDoesNotDeleteEarlierSegment() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "第一段", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "第一段", active: "第二段", id: 2, revision: 2))
        injector.apply(projection: projection(committed: "第一段", active: "第二段", id: 2, revision: 3, isFinal: true))
        try await injector.finish(finalText: "第一段第二段")

        XCTAssertEqual(target.pastedTexts, ["第一段", "第二段"])
        XCTAssertEqual(target.text, "第一段第二段")
        XCTAssertEqual(target.replaceCallCount, 0)
        XCTAssertNil(target.copiedText)
    }

    func testKeyboardLiveTailPureGrowthOnlyAppendsText() async throws {
        let target = AppendOnlyTextTarget()
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "第一", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "第一", active: "第二", id: 2, revision: 2))
        injector.apply(projection: projection(committed: "第一", active: "第二段", id: 2, revision: 3, isFinal: true))
        try await injector.finish(finalText: "第一第二段")

        XCTAssertEqual(target.pastedTexts, ["第一", "第二", "段"])
        XCTAssertNil(target.copiedText)
    }

    func testKeyboardStreamEndCommitsBufferedPartialOnce() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "未完成", id: 1, revision: 1))
        XCTAssertEqual(target.pastedTexts, ["未完成"])

        injector.apply(projection: ASRProjection(
            committedText: "未完成",
            activeSegmentText: "",
            activeSegmentID: nil,
            activeIsFinal: false,
            revision: 2,
            changed: false,
            isFinal: false,
            isStreamEnded: true
        ))
        try await injector.finish(finalText: "未完成")

        XCTAssertEqual(target.pastedTexts, ["未完成"])
        XCTAssertEqual(target.text, "未完成")
    }

    func testKeyboardEmptyFinishUsesLastKnownPartial() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "最后的 partial", id: 1, revision: 1))
        try await injector.finish(finalText: "")

        XCTAssertEqual(target.pastedTexts, ["最后的 partial"])
        XCTAssertEqual(target.text, "最后的 partial")
    }

    func testKeyboardEmptyNewSegmentBoundaryCommitsPreviousSegment() throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "第一句", id: 1, revision: 1))
        injector.apply(projection: ASRProjection(
            committedText: "第一句",
            activeSegmentText: "",
            activeSegmentID: 2,
            activeIsFinal: false,
            revision: 2,
            changed: false,
            isFinal: false
        ))

        XCTAssertEqual(target.pastedTexts, ["第一句"])
        XCTAssertEqual(target.text, "第一句")
    }

    func testKeyboardSegmentCommitPreservesEmojiAndCombiningCharacters() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "😀", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "😀", active: "e\u{301}", id: 2, revision: 2))
        injector.apply(projection: projection(committed: "😀", active: "e\u{301}", id: 2, revision: 3, isFinal: true))
        try await injector.finish(finalText: "😀e\u{301}")

        XCTAssertEqual(target.pastedTexts, ["😀", "e\u{301}"])
        XCTAssertEqual(target.text, "😀e\u{301}")
    }

    func testKeyboardRepeatedFinalDoesNotDuplicateText() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        let finalProjection = projection(committed: "", active: "最终", id: 1, revision: 1, isFinal: true)
        injector.apply(projection: finalProjection)
        injector.apply(projection: ASRProjection(
            committedText: "",
            activeSegmentText: "最终",
            activeSegmentID: 1,
            activeIsFinal: true,
            revision: 2,
            changed: false,
            isFinal: true
        ))
        try await injector.finish(finalText: "最终")

        XCTAssertEqual(target.pastedTexts, ["最终"])
        XCTAssertEqual(target.text, "最终")
    }

    func testKeyboardCommittedRevisionIsCorrectedWithoutStoppingInput() async throws {
        let target = FakeTextTarget(text: "", supportsAXReplacement: false)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "第一", active: "当前", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "不同", active: "当前", id: 1, revision: 2))
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        try await injector.finish(finalText: "不同当前")

        XCTAssertEqual(target.text, "不同当前")
        XCTAssertNil(target.copiedText)
        XCTAssertEqual(target.pastedTexts, ["第一当前"])
    }

    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

@MainActor
private func projection(
    committed: String,
    active: String,
    id: Int,
    revision: UInt64,
    isFinal: Bool = false,
    stablePrefix: String? = nil
) -> ASRProjection {
    ASRProjection(
        committedText: committed,
        activeSegmentText: active,
        activeSegmentID: id,
        activeIsFinal: isFinal,
        revision: revision,
        changed: true,
        isFinal: isFinal,
        activeStablePrefixText: stablePrefix
    )
}

@MainActor
private final class AppendOnlyTextTarget: TextTarget {
    private(set) var pastedTexts: [String] = []
    private(set) var copiedText: String?

    func capture() throws -> TextSnapshot {
        throw TextTargetError.unsupported
    }

    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String, with replacement: String) throws -> TencentVoiceMVP.TextRange {
        throw TextTargetError.unsupported
    }

    func paste(_ text: String) throws {
        pastedTexts.append(text)
    }

    func copyToClipboard(_ text: String) throws {
        copiedText = text
    }
}
