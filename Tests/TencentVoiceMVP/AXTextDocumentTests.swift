import XCTest
@testable import TencentVoiceMVP

@MainActor
final class AXTextDocumentTests: XCTestCase {
    func testCodexPlaceholderAXValueNormalizesOnlyWithStructuralEvidence() throws {
        let raw = "\n添加可选评论…"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 0, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(
                markedTexts: ["添加可选评论…"]
            ),
            probe: prefixProbe("添加可选评论…")
        )

        XCTAssertEqual(state.text, "")
        XCTAssertTrue(state.placeholderNormalized)
        XCTAssertEqual(state.mapping.source, .placeholder)
        XCTAssertEqual(state.mapping.rawDocumentLength, raw.utf16.count)
        XCTAssertEqual(state.mapping.coordinateDocumentLength, 0)
        XCTAssertEqual(state.mapping.omittedStructuralSeparatorCount, 0)
        XCTAssertEqual(
            state.mapping.rawRange(for: .init(location: 0, length: 0)),
            .init(location: 0, length: raw.utf16.count)
        )
    }

    func testPlaceholderMappingIsValidForKeyboardConfirmation() throws {
        let raw = "\n添加可选评论…"
        let resolved = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 0, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(
                markedTexts: ["添加可选评论…"]
            ),
            probe: prefixProbe("添加可选评论…")
        )
        let observed = KeyboardDocumentState(
            text: resolved.text,
            selection: resolved.selection,
            rawText: resolved.rawText,
            mapping: resolved.mapping
        )

        XCTAssertEqual(
            observed.compare(to: observed, allowingStructuralRawDifference: true),
            .matched
        )
    }

    func testPlaceholderLookingTextWithNoMarkerRemainsDraftText() throws {
        let raw = "添加可选评论…"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: raw.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(raw)
        )

        XCTAssertEqual(state.text, raw)
        XCTAssertFalse(state.placeholderNormalized)
    }

    func testPlaceholderMarkerDoesNotDiscardAnExistingDraft() throws {
        let raw = "已有草稿"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 0, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(
                markedTexts: ["提示"],
                unmarkedTexts: [raw]
            ),
            probe: prefixProbe(raw)
        )

        XCTAssertEqual(state.text, raw)
        XCTAssertFalse(state.placeholderNormalized)
    }

    func testAXCoordinatesCanExcludeOnlyProvenStructuralNewline() throws {
        let raw = "第一段\n第二段"
        let coordinateText = "第一段第二段"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinateText.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(coordinateText)
        )

        XCTAssertEqual(state.text, coordinateText)
        XCTAssertEqual(state.selection.location, coordinateText.utf16.count)
        XCTAssertEqual(state.mapping.omittedStructuralSeparatorCount, 1)
        XCTAssertEqual(state.mapping.coordinateDocumentLength, coordinateText.utf16.count)
    }

    func testAXCoordinatesDoNotRemoveNewlinesWhenRangeReadIncludesThem() throws {
        let raw = "第一段\n\n第二段"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: raw.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(raw)
        )

        XCTAssertEqual(state.text, raw)
        XCTAssertEqual(state.mapping.omittedStructuralSeparatorCount, 0)
    }

    func testUTF16CoordinateMappingPreservesEmoji() throws {
        let raw = "😀\n好"
        let coordinateText = "😀好"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinateText.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(coordinateText)
        )

        XCTAssertEqual(state.text, coordinateText)
        XCTAssertEqual(state.mapping.rawDocumentLength, 4)
        XCTAssertEqual(state.mapping.coordinateDocumentLength, 3)
        XCTAssertEqual(state.mapping.omittedStructuralSeparatorCount, 1)
    }

    func testSelectedTextUsesTheSameAXCoordinateSpace() throws {
        let text = "已有草稿和选中文字"
        let state = try AXTextDocumentResolver.resolve(
            rawText: text,
            selection: .init(location: 4, length: 4),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: rangeProbe(text)
        )

        XCTAssertEqual(state.text, text)
        XCTAssertEqual(state.selection, .init(location: 4, length: 4))
    }

    func testCoordinateReaderFindsFullRangeWhenSurrogateSplitIsRejected() throws {
        let raw = "a\n😀"
        let coordinateText = "a😀"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinateText.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: surrogateSafePrefixProbe(coordinateText)
        )

        XCTAssertEqual(state.text, coordinateText)
        XCTAssertEqual(state.mapping.coordinateDocumentLength, 3)
        XCTAssertEqual(state.mapping.rawBoundaryOffsets[3], raw.utf16.count)
    }

    func testUnexpectedCoordinateTextIsRejected() {
        XCTAssertThrowsError(
            try AXTextDocumentResolver.resolve(
                rawText: "第一段\n第二段",
                selection: .init(location: 6, length: 0),
                placeholderEvidence: AXPlaceholderEvidence(),
                probe: prefixProbe("第一段X第二段")
            )
        ) { error in
            XCTAssertEqual(error as? AXTextDocumentResolutionError, .coordinateTextMismatch)
        }
    }

    func testUnavailableCoordinateReadIsRejectedForSafety() {
        XCTAssertThrowsError(
            try AXTextDocumentResolver.resolve(
                rawText: "第一段\n第二段",
                selection: .init(location: 6, length: 0),
                placeholderEvidence: AXPlaceholderEvidence(),
                probe: AXTextCoordinateProbe { _ in nil }
            )
        ) { error in
            XCTAssertEqual(error as? AXTextDocumentResolutionError, .coordinateReadUnavailable)
        }
    }

    func testStaleAXValueBehindAdvancedSelectionIsRecognizedAsTransient() {
        let staleRawText = "abcdef"
        let advancedSelection = TextRange(location: 7, length: 0)
        let expectedSelection = advancedSelection

        XCTAssertThrowsError(
            try AXTextDocumentResolver.resolve(
                rawText: staleRawText,
                selection: advancedSelection,
                placeholderEvidence: AXPlaceholderEvidence(),
                probe: rangeProbe(staleRawText)
            )
        ) { error in
            XCTAssertEqual(error as? AXTextDocumentResolutionError, .invalidSelection)
        }
        XCTAssertTrue(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: staleRawText,
                selection: advancedSelection,
                confirmedRawText: staleRawText,
                expectedSelection: expectedSelection
            )
        )
        XCTAssertFalse(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: "different",
                selection: advancedSelection,
                confirmedRawText: staleRawText,
                expectedSelection: expectedSelection
            )
        )
    }

    func testAcknowledgedWriterHandlesPlaceholderAndRevisionWithoutLosingCharacters() async throws {
        let target = CoordinateAwareCodexTarget(
            rawText: "\n添加可选评论…",
            placeholderEvidence: AXPlaceholderEvidence(markedTexts: ["添加可选评论…"])
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("然", revision: 1))
        await settle()
        injector.apply(projection: projection("然后", revision: 2))
        try await injector.finish(finalText: "然后")

        XCTAssertEqual(target.rawText, "然后")
        XCTAssertEqual(target.acknowledgementCount, 2)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertNil(injector.degradationCode)
    }

    func testAcknowledgedWriterHandlesPlaceholderWhenRangeInterfaceDisappears() async throws {
        let target = CoordinateAwareCodexTarget(
            rawText: "\n添加可选评论…",
            placeholderEvidence: AXPlaceholderEvidence(markedTexts: ["添加可选评论…"]),
            coordinateReadUnavailableAfterPlaceholder: true
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("然", revision: 1))
        await settle()
        injector.apply(projection: projection("然后", revision: 2))
        try await injector.finish(finalText: "然后")

        XCTAssertEqual(target.rawText, "然后")
        XCTAssertEqual(target.acknowledgementCount, 2)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertNil(injector.degradationCode)
    }

    func testAcknowledgedWriterUsesAXCoordinatesForMultilineDocument() async throws {
        let target = CoordinateAwareCodexTarget(rawText: "第一段\n第二段")
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("甲", revision: 1))
        await settle()
        injector.apply(projection: projection("甲乙", revision: 2))
        try await injector.finish(finalText: "甲乙")

        XCTAssertEqual(target.rawText, "第一段\n第二段甲乙")
        XCTAssertEqual(target.acknowledgementCount, 2)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertNil(injector.degradationCode)
    }

    func testAcknowledgedWriterStopsWhenHiddenRawDocumentChanges() async throws {
        let target = CoordinateAwareCodexTarget(rawText: "第一段\n第二段")
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("甲", revision: 1))
        await settle()
        target.mutateRawText("第一段\n\n第二段甲")
        injector.apply(projection: projection("甲乙", revision: 2))
        try await injector.finish(finalText: "甲乙")

        XCTAssertEqual(target.rawText, "第一段\n\n第二段甲")
        XCTAssertEqual(target.acknowledgementCount, 1)
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
    }

    func testReplacementSurvivesOldSelectionWithUnavailableOrMixedRangeRead() async throws {
        for unavailable in [true, false] {
            let old = String(repeating: "甲", count: 152) + "一二三四五六"
            let new = String(repeating: "甲", count: 152) + "😀修订"
            let selected = KeyboardDocumentState(text: old, selection: .init(location: 152, length: 6), rawText: old)
            let result = KeyboardDocumentState(text: new, selection: .init(location: new.utf16.count, length: 0), rawText: new)
            var sends = 0
            var readsAfterSend = 0
            var clock: UInt64 = 0
            try await KeyboardWriteAcknowledgement.replaceSelection(
                selected: selected, result: result, now: { clock }, sleep: { clock += $0 },
                read: {
                    if sends == 0 { return selected }
                    readsAfterSend += 1
                    let stale = readsAfterSend == 1
                    let raw = stale ? old : new
                    let selection = stale ? selected.selection : result.selection
                    let state = try AXTextDocumentResolver.readDuringReplacement(
                        rawText: raw, selection: selection, acknowledgedSelection: selected
                    ) {
                        try AXTextDocumentResolver.resolve(
                            rawText: raw, selection: selection, placeholderEvidence: AXPlaceholderEvidence(),
                            probe: stale && unavailable ? AXTextCoordinateProbe { _ in nil }
                                : self.rangeProbe(stale ? String(repeating: "乙", count: old.utf16.count) : new)
                        )
                    }
                    return KeyboardDocumentState(text: state.text, selection: state.selection, rawText: state.rawText)
                }, insert: { sends += 1 }
            )
            XCTAssertEqual(sends, 1)
            XCTAssertEqual(readsAfterSend, 2)
            XCTAssertEqual(clock, 10_000_000)
        }
    }

    func testReplacementRecoveryRejectsChangedDraftSelectionAndPreDispatch() {
        let selected = KeyboardDocumentState(text: "草稿甲乙", selection: .init(location: 2, length: 2), rawText: "草稿甲乙")
        for (raw, range, acknowledged) in [
            ("改稿甲乙", selected.selection, Optional(selected)),
            ("草稿甲乙", TextRange(location: 0, length: 2), Optional(selected)),
            ("草稿甲乙", selected.selection, nil)
        ] {
            XCTAssertThrowsError(try AXTextDocumentResolver.readDuringReplacement(
                rawText: raw, selection: range, acknowledgedSelection: acknowledged
            ) { throw AXTextDocumentResolutionError.coordinateTextMismatch }) { error in
                XCTAssertEqual(error as? AXTextDocumentResolutionError, .coordinateTextMismatch)
            }
        }
    }

    private func prefixProbe(_ text: String) -> AXTextCoordinateProbe {
        AXTextCoordinateProbe { range in
            guard range.location == 0,
                  range.length >= 0,
                  range.length <= text.utf16.count else {
                return nil
            }
            return (text as NSString).substring(
                with: NSRange(location: 0, length: range.length)
            )
        }
    }

    private func rangeProbe(_ text: String) -> AXTextCoordinateProbe {
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

    private func surrogateSafePrefixProbe(_ text: String) -> AXTextCoordinateProbe {
        AXTextCoordinateProbe { range in
            guard range.location == 0,
                  range.length >= 0,
                  range.length <= text.utf16.count else {
                return nil
            }
            let units = Array(text.utf16)
            if range.length > 0,
               range.length < units.count,
               units[range.length - 1] >= 0xD800,
               units[range.length - 1] <= 0xDBFF,
               units[range.length] >= 0xDC00,
               units[range.length] <= 0xDFFF {
                return nil
            }
            return (text as NSString).substring(
                with: NSRange(location: 0, length: range.length)
            )
        }
    }

    private func projection(_ text: String, revision: UInt64) -> ASRProjection {
        ASRProjection(
            committedText: "",
            activeSegmentText: text,
            activeSegmentID: 1,
            activeIsFinal: false,
            revision: revision,
            changed: true,
            isFinal: false
        )
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

@MainActor
private final class CoordinateAwareCodexTarget: KeyboardAcknowledgingTarget {
    private let placeholderEvidence: AXPlaceholderEvidence
    private let coordinateReadUnavailableAfterPlaceholder: Bool
    private var confirmedState: KeyboardDocumentState?
    private var pendingState: KeyboardDocumentState?
    private var lastState: AXTextDocumentState?
    private var axValueFallbackAllowed = false

    private(set) var rawText: String
    private(set) var acknowledgementCount = 0
    let requiresKeyboardAcknowledgement = true

    init(
        rawText: String,
        placeholderEvidence: AXPlaceholderEvidence = AXPlaceholderEvidence(),
        coordinateReadUnavailableAfterPlaceholder: Bool = false
    ) {
        self.rawText = rawText
        self.placeholderEvidence = placeholderEvidence
        self.coordinateReadUnavailableAfterPlaceholder = coordinateReadUnavailableAfterPlaceholder
    }

    func capture() throws -> TextSnapshot {
        let state = try currentState()
        lastState = state
        confirmedState = keyboardState(from: state)
        return TextSnapshot(
            text: state.text,
            selection: state.selection,
            supportsAXReplacement: true,
            targetApplication: TextTargetApplication(
                name: "Codex",
                bundleIdentifier: "com.openai.codex",
                processIdentifier: 1
            ),
            rawText: state.rawText,
            coordinateText: state.text,
            placeholderNormalized: state.placeholderNormalized,
            coordinateMapping: state.mapping
        )
    }

    func replace(
        snapshot: TextSnapshot,
        range: TencentVoiceMVP.TextRange,
        expectedText: String,
        with text: String
    ) throws -> TencentVoiceMVP.TextRange {
        throw TextTargetError.unsupported
    }

    func paste(_ text: String) throws {
        let state = try currentState()
        guard keyboardState(from: state) == confirmedState,
              state.selection.length == 0 else {
            throw TextTargetError.targetChanged
        }
        if state.placeholderNormalized {
            rawText = text
        } else {
            guard state.selection.location == state.text.utf16.count else {
                throw TextTargetError.targetChanged
            }
            rawText.append(text)
        }
        pendingState = try keyboardState(from: currentState())
    }

    func replaceTrailingText(_ previousText: String, with text: String) throws {
        let state = try currentState()
        guard keyboardState(from: state) == confirmedState,
              state.selection.length == 0,
              state.text.hasSuffix(previousText) else {
            throw TextTargetError.targetChanged
        }
        rawText.removeLast(previousText.count)
        rawText.append(text)
        pendingState = try keyboardState(from: currentState())
    }

    func acknowledgeKeyboardWrite() async throws {
        let state = try keyboardState(from: currentState())
        guard pendingState == state else { throw TextTargetError.targetChanged }
        confirmedState = state
        pendingState = nil
        acknowledgementCount += 1
    }

    func copyToClipboard(_ text: String) throws {}

    func mutateRawText(_ text: String) {
        rawText = text
    }

    private func currentState() throws -> AXTextDocumentState {
        let coordinateText = rawText.replacingOccurrences(of: "\n", with: "")
        let selection = TextRange(location: coordinateText.utf16.count, length: 0)
        do {
            let state = try AXTextDocumentResolver.resolve(
                rawText: rawText,
                selection: selection,
                placeholderEvidence: placeholderEvidence,
                probe: AXTextCoordinateProbe { [coordinateReadUnavailableAfterPlaceholder, rawText] range in
                    if coordinateReadUnavailableAfterPlaceholder,
                       !rawText.isEmpty,
                       rawText != "\n添加可选评论…" {
                        return nil
                    }
                    guard range.location == 0,
                          range.length >= 0,
                          range.length <= coordinateText.utf16.count else {
                        return nil
                    }
                    return (coordinateText as NSString).substring(
                        with: NSRange(location: 0, length: range.length)
                    )
                }
            )
            lastState = state
            return state
        } catch let error as AXTextDocumentResolutionError {
            guard error == .coordinateReadUnavailable,
                  let previous = lastState,
                  let state = try? AXTextDocumentResolver.resolveUsingValidatedAXValueAfterPlaceholder(
                      rawText: rawText,
                      selection: selection,
                      previousState: previous,
                      continuationAllowed: axValueFallbackAllowed
                  ) else {
                throw error
            }
            axValueFallbackAllowed = true
            lastState = state
            return state
        }
    }

    private func keyboardState(from state: AXTextDocumentState) -> KeyboardDocumentState {
        KeyboardDocumentState(text: state.text, selection: state.selection, rawText: state.rawText)
    }
}
