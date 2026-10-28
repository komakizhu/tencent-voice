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

    func testCoordinateMappingRetainsEveryCompatibleRawCaretBoundary() throws {
        let raw = "甲\n\n乙"
        let coordinateText = "甲乙"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 1, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe(coordinateText)
        )

        XCTAssertEqual(
            state.mapping.rawRangeCandidates(for: .init(location: 1, length: 0)),
            [
                .init(location: 1, length: 0),
                .init(location: 2, length: 0),
                .init(location: 3, length: 0)
            ]
        )
        XCTAssertNil(
            state.mapping.rawRange(for: .init(location: 1, length: 0)),
            "an ambiguous boundary must not be collapsed to the rightmost candidate"
        )
        XCTAssertEqual(state.mapping.rawBoundaryCandidates[1], [1, 2, 3])
        XCTAssertEqual(
            state.mapping.rawRangeCandidates(for: .init(location: 1, length: 1)),
            [
                .init(location: 1, length: 3),
                .init(location: 2, length: 2),
                .init(location: 3, length: 1)
            ]
        )
        for range in [
            TextRange(location: 0, length: 0),
            TextRange(location: 1, length: 0),
            TextRange(location: 1, length: 1),
            TextRange(location: 2, length: 0)
        ] {
            let candidates = state.mapping.rawRangeCandidates(for: range)
            if candidates.count == 1 {
                XCTAssertEqual(state.mapping.rawRange(for: range), candidates.first)
            } else {
                XCTAssertNil(
                    state.mapping.rawRange(for: range),
                    "ambiguous range must remain unresolved: \(range) -> \(candidates)"
                )
            }
        }
    }

    func testStructuralTransitionKeepsEveryCompatibleRawBoundaryHypothesis() throws {
        let raw = "甲\n\n\n乙"
        let coordinateText = "甲\n乙"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 1, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe(coordinateText)
        )
        let range = TextRange(location: 1, length: 0)
        let rawRanges = state.mapping.rawRangeCandidates(for: range)
        XCTAssertGreaterThanOrEqual(rawRanges.count, 2)

        let candidates = AXTextStructuralTransitionModel.candidates(
            document: coordinateText,
            range: range,
            text: "今",
            rawDocument: raw,
            rawRanges: rawRanges,
            mapping: state.mapping
        )
        XCTAssertEqual(candidates.count, rawRanges.count * 4)
        for rawRange in rawRanges {
            XCTAssertEqual(
                candidates.filter { $0.rawOperationRange == rawRange }.count,
                4,
                "missing structural hypotheses for raw boundary (rawRange)"
            )
        }
        XCTAssertTrue(
            candidates.contains {
                $0.rawOperationRange == rawRanges[0]
                    && $0.rawInsertionSeparatorLength == 3
            }
        )
    }

    func testCoordinateMappingRejectsSameLengthStaleAlignment() throws {
        let state = try AXTextDocumentResolver.resolve(
            rawText: "甲\n乙",
            selection: .init(location: 1, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe("甲乙")
        )

        XCTAssertFalse(
            AXTextDocumentResolver.isValidCoordinateMapping(
                state.mapping,
                rawText: "丁\n乙",
                coordinateText: "丁乙"
            )
        )
    }

    func testCoordinateMappingKeepsCRLFAndUnicodeSeparatorsAsDistinctCandidates() throws {
        let raw = "甲\r\n\u{2028}\u{2029}乙"
        let coordinateText = "甲乙"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 1, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe(coordinateText)
        )

        XCTAssertEqual(
            state.mapping.rawRangeCandidates(for: .init(location: 1, length: 0)).map(\.location),
            [1, 3, 4, 5]
        )
        XCTAssertEqual(state.mapping.rawBoundaryCandidates[1], [1, 3, 4, 5])
        XCTAssertEqual(state.mapping.rawBoundaryCandidates[2], [6])
    }

    func testStandaloneCRRemains正文AndCannotBeSilentlyOmitted() throws {
        let raw = "甲\r乙"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: raw.utf16.count, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe(raw)
        )

        XCTAssertEqual(state.text, raw)
        XCTAssertEqual(state.mapping.omittedStructuralSeparatorCount, 0)
        XCTAssertEqual(
            state.mapping.rawRangeCandidates(
                for: .init(location: raw.utf16.count, length: 0)
            ),
            [.init(location: raw.utf16.count, length: 0)]
        )

        XCTAssertThrowsError(
            try AXTextDocumentResolver.resolve(
                rawText: raw,
                selection: .init(location: 2, length: 0),
                placeholderEvidence: .init(),
                probe: prefixProbe("甲乙")
            )
        ) { error in
            XCTAssertEqual(error as? AXTextDocumentResolutionError, .coordinateReadUnavailable)
        }
    }

    func testCRLFInteriorBoundaryIsNotAWritableCaret() throws {
        let raw = "甲\r\n乙"
        let coordinateText = "甲乙"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinateText.utf16.count, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe(coordinateText)
        )

        XCTAssertEqual(
            state.mapping.rawRangeCandidates(for: .init(location: 1, length: 0)),
            [.init(location: 1, length: 0), .init(location: 3, length: 0)]
        )
        XCTAssertFalse(
            state.mapping.rawBoundaryCandidates[1].contains(2),
            "the boundary between CR and LF is not a writable caret"
        )
    }

    func testCRLFIsOneStructuralUnitAndLFIsNotOmittableAlone() throws {
        let scalars = Array("\r\n".unicodeScalars)
        XCTAssertTrue(AXTextStructural.isStructuralSeparator(at: 0, in: scalars))
        XCTAssertTrue(AXTextStructural.isStructuralSeparator(at: 1, in: scalars))
        XCTAssertEqual(
            AXTextStructural.structuralUnitRange(startingAt: 0, in: "\r\n"),
            .init(location: 0, length: 2)
        )
        XCTAssertNil(AXTextStructural.structuralUnitRange(startingAt: 1, in: "\r\n"))

        let state = try AXTextDocumentResolver.resolve(
            rawText: "甲\r\n乙",
            selection: .init(location: 2, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe("甲\n乙")
        )

        XCTAssertEqual(state.mapping.omittedStructuralSeparatorCount, 1)
        XCTAssertEqual(state.mapping.rawBoundaryCandidates[1], [1])
        XCTAssertEqual(state.mapping.rawBoundaryCandidates[2], [3])
    }

    func testCRLFNormalizationFiltersTheRawInteriorCaret() throws {
        let raw = "甲\r\n乙"
        let exact = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 3, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe(raw)
        )

        XCTAssertEqual(exact.text, raw)
        XCTAssertEqual(
            exact.mapping.rawRangeCandidates(for: .init(location: 3, length: 0)),
            [.init(location: 3, length: 0)]
        )

        let normalized = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 3, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe("甲\n乙")
        )
        XCTAssertEqual(normalized.text, "甲\n乙")
        XCTAssertFalse(normalized.mapping.rawBoundaryCandidates[2].contains(2))

        let bodyCR = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 3, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe("甲\r乙")
        )
        XCTAssertEqual(bodyCR.text, "甲\r乙")
        XCTAssertFalse(bodyCR.mapping.rawBoundaryCandidates[2].contains(2))
    }

    func testCoordinateReaderSkipsAValidLengthButIncompleteCRLFSnapshot() throws {
        let raw = "甲\r\n乙"
        let coordinate = "甲乙"
        let probe = AXTextCoordinateProbe { range in
            guard range.location == 0 else { return nil }
            switch range.length {
            case 0: return ""
            case 3: return "甲\r\n"
            case 2: return coordinate
            default: return nil
            }
        }

        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinate.utf16.count, length: 0),
            placeholderEvidence: .init(),
            probe: probe
        )

        XCTAssertEqual(state.text, coordinate)
        XCTAssertEqual(state.mapping.rawDocumentLength, raw.utf16.count)
        XCTAssertEqual(state.mapping.coordinateDocumentLength, coordinate.utf16.count)
    }

    func testCoordinateMappingDoesNotTreatZeroWidthTextAsASeparator() throws {
        let zeroWidth = "\u{200B}"
        let raw = "甲\(zeroWidth)\n乙"
        let coordinateText = "甲\(zeroWidth)乙"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 2, length: 0),
            placeholderEvidence: .init(),
            probe: prefixProbe(coordinateText)
        )

        XCTAssertEqual(state.text, coordinateText)
        XCTAssertEqual(state.mapping.rawRangeCandidates(for: .init(location: 2, length: 0)), [
            .init(location: 2, length: 0),
            .init(location: 3, length: 0)
        ])
    }

    func testKeyboardDocumentStateAcceptsLeadingStructuralSeparatorMapping() throws {
        let raw = "\n" + String(repeating: "字", count: 13)
        let coordinateText = String(repeating: "字", count: 13)
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinateText.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(coordinateText)
        )
        let observed = KeyboardDocumentState(
            text: state.text,
            selection: state.selection,
            rawText: state.rawText,
            mapping: state.mapping
        )

        XCTAssertEqual(
            observed.compare(to: observed, allowingStructuralRawDifference: true),
            .matched
        )
        XCTAssertNil(
            state.mapping.rawRange(for: .init(location: 0, length: 0)),
            "the leading omitted separator leaves the document-start boundary ambiguous"
        )
        XCTAssertEqual(state.mapping.rawRange(for: .init(location: 13, length: 0)), .init(location: 14, length: 0))
    }

    func testKeyboardDocumentStateAcceptsMultipleLeadingStructuralSeparators() throws {
        for prefix in ["\n\n", "\n\r\n\u{2028}"] {
            let coordinateText = "保留草稿😀"
            let state = try AXTextDocumentResolver.resolve(
                rawText: prefix + coordinateText,
                selection: .init(location: coordinateText.utf16.count, length: 0),
                placeholderEvidence: AXPlaceholderEvidence(),
                probe: prefixProbe(coordinateText)
            )
            let observed = KeyboardDocumentState(
                text: state.text,
                selection: state.selection,
                rawText: state.rawText,
                mapping: state.mapping
            )

            XCTAssertEqual(
                observed.compare(to: observed, allowingStructuralRawDifference: true),
                .matched,
                "prefix: \(prefix.debugDescription)"
            )
            XCTAssertEqual(state.mapping.omittedStructuralSeparatorCount, prefix.unicodeScalars.count)
        }
    }

    func testKeyboardDocumentStateRejectsInconsistentStructuralMapping() throws {
        let raw = "\n有效草稿"
        let coordinateText = "有效草稿"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinateText.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(coordinateText)
        )
        let mapping = state.mapping
        let forgedOffsets = mapping.rawBoundaryOffsets.enumerated().map { index, offset in
            index == 0 ? 0 : offset
        }
        let forgedOffsetMapping = AXTextCoordinateMapping(
            source: mapping.source,
            rawDocumentLength: mapping.rawDocumentLength,
            coordinateDocumentLength: mapping.coordinateDocumentLength,
            omittedStructuralSeparatorCount: mapping.omittedStructuralSeparatorCount,
            rawBoundaryOffsets: forgedOffsets,
            rawPlaceholderRange: mapping.rawPlaceholderRange
        )
        let forgedSeparatorCountMapping = AXTextCoordinateMapping(
            source: mapping.source,
            rawDocumentLength: mapping.rawDocumentLength,
            coordinateDocumentLength: mapping.coordinateDocumentLength,
            omittedStructuralSeparatorCount: 0,
            rawBoundaryOffsets: mapping.rawBoundaryOffsets,
            rawPlaceholderRange: mapping.rawPlaceholderRange
        )

        for forgedMapping in [forgedOffsetMapping, forgedSeparatorCountMapping] {
            let observed = KeyboardDocumentState(
                text: state.text,
                selection: state.selection,
                rawText: state.rawText,
                mapping: forgedMapping
            )
            XCTAssertEqual(
                observed.compare(to: observed, allowingStructuralRawDifference: true),
                .rawMappingUnavailable
            )
        }
    }

    func testValidButDifferentMappingSourceIsNotTheExpectedReceiptMapping() throws {
        let raw = "A\nB"
        let coordinateText = "AB"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 1, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(coordinateText)
        )
        let alternateMapping = AXTextCoordinateMapping(
            source: .axValueAfterPlaceholderTransition,
            rawDocumentLength: state.mapping.rawDocumentLength,
            coordinateDocumentLength: state.mapping.coordinateDocumentLength,
            omittedStructuralSeparatorCount: state.mapping.omittedStructuralSeparatorCount,
            rawBoundaryCandidates: state.mapping.rawBoundaryCandidates,
            rawPlaceholderRange: state.mapping.rawPlaceholderRange
        )

        XCTAssertTrue(
            AXTextDocumentResolver.isValidCoordinateMapping(
                alternateMapping,
                rawText: raw,
                coordinateText: coordinateText
            )
        )
        XCTAssertNotEqual(alternateMapping, state.mapping)

        let expected = KeyboardDocumentState(
            text: state.text,
            selection: state.selection,
            rawText: state.rawText,
            mapping: state.mapping
        )
        let observed = KeyboardDocumentState(
            text: state.text,
            selection: state.selection,
            rawText: state.rawText,
            mapping: alternateMapping
        )
        XCTAssertEqual(
            observed.compare(to: expected, allowingStructuralRawDifference: true),
            .matched,
            "validity alone must not make a different mapping an exact receipt"
        )
        XCTAssertFalse(observed.matchesExpectedMapping(of: expected))
    }

    func testMultipleEquivalentReceiptMappingsStayUnconfirmed() throws {
        let raw = "A\nB"
        let coordinateText = "AB"
        let resolved = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: 1, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(coordinateText)
        )
        let exactMapping = resolved.mapping.withSource(.pendingReceiptExactAXValue)
        let structuralMapping = resolved.mapping.withSource(.pendingReceiptStructuralAugmentation)
        let exactState = KeyboardDocumentState(
            text: coordinateText,
            selection: resolved.selection,
            rawText: raw,
            mapping: exactMapping
        )
        let structuralState = KeyboardDocumentState(
            text: coordinateText,
            selection: resolved.selection,
            rawText: raw,
            mapping: structuralMapping
        )

        let result = KeyboardWriteConfirmation.evaluateCandidates(
            expectedCandidates: [exactState, structuralState],
            observed: exactState,
            operation: nil,
            isCodexTarget: true
        )

        XCTAssertFalse(result.matched)
        XCTAssertNil(result.matchedIndex)
        XCTAssertEqual(result.matchedIndexes, [0, 1])
        XCTAssertEqual(result.comparison, .ambiguousReceipt)
        XCTAssertEqual(result.comparisons, [.matched, .matched])
    }

    func testExactReceiptTakesPriorityOverStructuralFallbackCandidate() throws {
        let coordinateText = "A新B"
        let selection = TextRange(location: 2, length: 0)
        let exactRaw = "A\n\n新B"
        let fallbackRaw = "A\n新B"
        let exact = try AXTextDocumentResolver.resolve(
            rawText: exactRaw,
            selection: selection,
            placeholderEvidence: .init(),
            probe: prefixProbe(coordinateText)
        )
        let fallback = try AXTextDocumentResolver.resolve(
            rawText: fallbackRaw,
            selection: selection,
            placeholderEvidence: .init(),
            probe: prefixProbe(coordinateText)
        )
        let exactState = KeyboardDocumentState(
            text: coordinateText,
            selection: selection,
            rawText: exactRaw,
            mapping: exact.mapping
        )
        let fallbackState = KeyboardDocumentState(
            text: coordinateText,
            selection: selection,
            rawText: fallbackRaw,
            mapping: fallback.mapping
        )
        let result = KeyboardWriteConfirmation.evaluateCandidates(
            expectedCandidates: [exactState, fallbackState],
            observed: exactState,
            operation: .init(
                coordinateRange: .init(location: 1, length: 0),
                insertedLengthUTF16: 1,
                inputText: "新",
                operationGeneration: 1
            ),
            isCodexTarget: true
        )

        XCTAssertTrue(result.matched)
        XCTAssertEqual(result.matchedIndex, 0)
        XCTAssertEqual(result.matchedIndexes, [0])
        XCTAssertEqual(result.comparison, .matched)
        XCTAssertEqual(result.comparisons, [.matched, .rawTextMismatch])
    }

    func testKeyboardDocumentStateRejectsSurrogateBoundaryMapping() throws {
        let raw = "😀\n好"
        let coordinateText = "😀好"
        let state = try AXTextDocumentResolver.resolve(
            rawText: raw,
            selection: .init(location: coordinateText.utf16.count, length: 0),
            placeholderEvidence: AXPlaceholderEvidence(),
            probe: prefixProbe(coordinateText)
        )
        let invalidMapping = AXTextCoordinateMapping(
            source: state.mapping.source,
            rawDocumentLength: state.mapping.rawDocumentLength,
            coordinateDocumentLength: state.mapping.coordinateDocumentLength,
            omittedStructuralSeparatorCount: state.mapping.omittedStructuralSeparatorCount,
            rawBoundaryOffsets: [0, 2, 3, 4],
            rawPlaceholderRange: nil
        )
        let observed = KeyboardDocumentState(
            text: state.text,
            selection: state.selection,
            rawText: state.rawText,
            mapping: invalidMapping
        )

        XCTAssertEqual(
            observed.compare(to: observed, allowingStructuralRawDifference: true),
            .rawMappingUnavailable
        )
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

    func testResolverRejectsIllegalUTF16SelectionBoundariesInCoordinateSpace() {
        XCTAssertThrowsError(
            try AXTextDocumentResolver.resolve(
                rawText: "a😀",
                selection: .init(location: 2, length: 0),
                placeholderEvidence: .init(),
                probe: prefixProbe("a😀")
            )
        ) { error in
            XCTAssertEqual(error as? AXTextDocumentResolutionError, .selectionOutOfBounds)
        }

        // The AX selection is expressed in coordinate text. Offset 2 is a
        // valid raw AXValue boundary before the emoji, but becomes the middle
        // of the emoji after the structural newline is omitted.
        XCTAssertThrowsError(
            try AXTextDocumentResolver.resolve(
                rawText: "a\n😀",
                selection: .init(location: 2, length: 0),
                placeholderEvidence: .init(),
                probe: prefixProbe("a😀")
            )
        ) { error in
            XCTAssertEqual(error as? AXTextDocumentResolutionError, .selectionOutOfBounds)
        }
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
        let cases: [(rawText: String, text: String)] = [
            ("a\n😀", "a😀"),
            ("a\r\n😀", "a😀"),
            ("\n\r\n😀\u{2028}\n", "😀")
        ]

        for (rawText, text) in cases {
            let confirmed = KeyboardDocumentState(
                text: text,
                selection: .init(location: text.utf16.count, length: 0),
                rawText: rawText
            )
            let expectedSelection = TextRange(location: text.utf16.count + 1, length: 0)

            XCTAssertTrue(
                AXTextDocumentResolver.isStaleAXValueBehindSelection(
                    rawText: rawText,
                    selection: expectedSelection,
                    confirmedState: confirmed,
                    expectedSelection: expectedSelection
                ),
                "The previous editable UTF-16 length must ignore structural separators in \(rawText.debugDescription)"
            )
        }

        let staleRawText = "a\n😀"
        let confirmed = KeyboardDocumentState(
            text: "a😀",
            selection: .init(location: 3, length: 0),
            rawText: staleRawText
        )
        let advancedSelection = TextRange(location: 4, length: 0)

        XCTAssertThrowsError(
            try AXTextDocumentResolver.resolve(
                rawText: staleRawText,
                selection: TextRange(location: 4, length: 0),
                placeholderEvidence: AXPlaceholderEvidence(),
                probe: rangeProbe("a😀")
            )
        ) { error in
            XCTAssertEqual(error as? AXTextDocumentResolutionError, .selectionOutOfBounds)
        }
        XCTAssertTrue(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: staleRawText,
                selection: advancedSelection,
                confirmedState: confirmed,
                expectedSelection: advancedSelection
            )
        )
        XCTAssertFalse(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: "different",
                selection: advancedSelection,
                confirmedState: confirmed,
                expectedSelection: advancedSelection
            )
        )
        XCTAssertFalse(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: staleRawText,
                selection: TextRange(location: 3, length: 0),
                confirmedState: confirmed,
                expectedSelection: advancedSelection
            )
        )
        XCTAssertFalse(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: staleRawText,
                selection: TextRange(location: 4, length: 1),
                confirmedState: confirmed,
                expectedSelection: TextRange(location: 4, length: 1)
            )
        )
        XCTAssertFalse(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: staleRawText,
                selection: advancedSelection,
                confirmedState: nil,
                expectedSelection: advancedSelection
            )
        )
        XCTAssertFalse(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: staleRawText,
                selection: advancedSelection,
                confirmedState: confirmed,
                expectedSelection: nil
            )
        )
        XCTAssertFalse(
            AXTextDocumentResolver.isStaleAXValueBehindSelection(
                rawText: staleRawText,
                selection: TextRange(location: 3, length: 0),
                confirmedState: confirmed,
                expectedSelection: TextRange(location: 3, length: 0)
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
        XCTAssertEqual(injector.modeDescription, "safe_copy")
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
            coordinateMapping: state.mapping,
            preferredInputStrategy: .acknowledgedKeyboard(reason: "codex_editable_text_control")
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
