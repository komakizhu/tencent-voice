import ApplicationServices
import XCTest
@testable import TencentVoiceMVP

private typealias ReplayTextRange = TencentVoiceMVP.TextRange

@MainActor
final class AXTextTargetReplayTests: XCTestCase {
    func testCodexLeadingAndInteriorEmptyParagraphsAcceptCollapsedMarker() async throws {
        let cases = [
            (
                name: "leading",
                before: "\n\n甲乙丙",
                insertionLocation: 0,
                afterFirst: "今\n甲乙丙",
                afterAppend: "今天\n甲乙丙",
                afterRevision: "今明\n甲乙丙",
                expectedClass: "leading_empty_paragraph"
            ),
            (
                name: "interior",
                before: "甲\n\n乙🙂丙",
                insertionLocation: 1,
                afterFirst: "甲今\n乙🙂丙",
                afterAppend: "甲今天\n乙🙂丙",
                afterRevision: "甲今明\n乙🙂丙",
                expectedClass: "interior_empty_paragraph"
            )
        ]

        for testCase in cases {
            let access = ReplayAXTextTargetAccess(
                text: testCase.before,
                selection: .init(location: testCase.insertionLocation, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = testCase.before
            access.writeSnapshots = [
                .init(
                    rawText: testCase.afterFirst,
                    coordinateText: testCase.afterFirst,
                    selection: .init(location: testCase.insertionLocation + 1, length: 0)
                ),
                .init(
                    rawText: testCase.afterAppend,
                    coordinateText: testCase.afterAppend,
                    selection: .init(location: testCase.insertionLocation + 2, length: 0)
                ),
                .init(
                    rawText: testCase.afterRevision,
                    coordinateText: testCase.afterRevision,
                    selection: .init(location: testCase.insertionLocation + 2, length: 0)
                )
            ]
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(
                access: access,
                keyboardEventSender: sender,
                acknowledgementTimeoutNanoseconds: 20_000_000
            )

            _ = try target.capture()
            try target.paste("今")
            try await target.acknowledgeKeyboardWrite()
            try target.paste("天")
            try await target.acknowledgeKeyboardWrite()
            try target.replaceTrailingText("今天", with: "今明")
            try await target.acknowledgeKeyboardWrite()

            XCTAssertEqual(access.rawText, testCase.afterRevision, testCase.name)
            XCTAssertEqual(access.selection, .init(location: testCase.insertionLocation + 2, length: 0), testCase.name)
            XCTAssertEqual(sender.appendPosts, 2, testCase.name)
            XCTAssertEqual(sender.replacementPosts, 1, testCase.name)
            let diagnostics = target.drainDiagnostics()
            XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" }, testCase.name)
            let acknowledgement = try XCTUnwrap(
                diagnostics.first {
                    $0.event == "keyboard_write_acknowledged"
                        && $0.fields["receiptRepresentationTransition"] == "empty_paragraph_marker_collapsed"
                },
                testCase.name
            )
            XCTAssertEqual(acknowledgement.fields["ackInsertionPositionClass"], testCase.expectedClass, testCase.name)
        }
    }

    func testCodexSingleInteriorNewlineUsesPrimaryReceipt() async throws {
        let before = "甲\n乙"
        let after = "甲今\n乙"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = before
        access.writeSnapshots = [
            .init(rawText: after, coordinateText: after, selection: .init(location: 2, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, after)
        XCTAssertEqual(sender.totalPosts, 1)
        let acknowledgement = try XCTUnwrap(
            target.drainDiagnostics().first { $0.event == "keyboard_write_acknowledged" }
        )
        XCTAssertEqual(acknowledgement.fields["receiptRepresentationTransition"], "none")
        XCTAssertEqual(acknowledgement.fields["ackInsertionPositionClass"], "not_applicable")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal0Classification"], "equal")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal0CoordinateUnit"], "UTF16")
    }

    func testCodexRevisionUsesKeyboardSelectionToPreserveEmptyParagraph() async throws {
        let before = "甲甲甲甲甲甲甲甲甲乙丙丁\n\n戊己庚"
        let after = "甲甲甲甲甲甲甲甲甲辛壬癸\n\n戊己庚"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 12, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateIncludesStructuralSeparators = true
        access.selectionRangeIsSettable = true
        access.simulateAccessibilityEmptyParagraphCollapse = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.replaceTrailingText("乙丙丁", with: "辛壬癸")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, after)
        XCTAssertEqual(access.selection, .init(location: 12, length: 0))
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(
            target.drainDiagnostics().last(where: { $0.event == "keyboard_selection_submitted" })?.fields["route"],
            "keyboard"
        )
    }

    func testNonCodexRevisionKeepsAccessibilitySelectionRoute() async throws {
        let before = "甲甲甲甲甲甲甲甲甲乙丙丁\n\n戊己庚"
        let after = "甲甲甲甲甲甲甲甲甲辛壬癸\n\n戊己庚"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 12, length: 0),
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
        )
        access.coordinateIncludesStructuralSeparators = true
        access.selectionRangeIsSettable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.replaceTrailingText("乙丙丁", with: "辛壬癸")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, after)
        XCTAssertEqual(access.selection, .init(location: 12, length: 0))
        XCTAssertEqual(sender.selectionPosts, 0)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(
            target.drainDiagnostics().last(where: { $0.event == "keyboard_selection_submitted" })?.fields["route"],
            "ax_range"
        )
    }

    func testCodexDeletionUsesKeyboardSelectionWithoutRemovingEmptyParagraph() async throws {
        let before = "甲甲甲甲甲甲甲甲甲乙丙丁\n\n戊己庚"
        let after = "甲甲甲甲甲甲甲甲甲\n\n戊己庚"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 12, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateIncludesStructuralSeparators = true
        access.selectionRangeIsSettable = true
        access.simulateAccessibilityEmptyParagraphCollapse = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.replaceTrailingText("乙丙丁", with: "")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, after)
        XCTAssertEqual(access.selection, .init(location: 9, length: 0))
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
    }

    func testCodexLeadingEmptyParagraphCandidateAcceptsRetainedRawMarker() async throws {
        let before = "\n\n甲"
        let afterFirstRaw = "\n今\n甲"
        let afterFirstCoordinate = "今\n甲"
        let afterSecondRaw = "\n今天\n甲"
        let afterSecondCoordinate = "今天\n甲"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = before
        access.writeSnapshots = [
            .init(
                rawText: afterFirstRaw,
                coordinateText: afterFirstCoordinate,
                selection: .init(location: 1, length: 0)
            ),
            .init(
                rawText: afterSecondRaw,
                coordinateText: afterSecondCoordinate,
                selection: .init(location: 2, length: 0)
            )
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()
        try target.paste("天")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, afterSecondRaw)
        XCTAssertEqual(access.coordinateText, afterSecondCoordinate)
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.appendPosts, 2)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexLeadingSingleEmptyParagraphRetainsRawBoundaryForContinuationAndRevision() async throws {
        let before = "\nABC"
        let afterFirstRaw = "X\n\nABC"
        let afterFirstCoordinate = "XABC"
        let afterAppendRaw = "XY\n\nABC"
        let afterAppendCoordinate = "XYABC"
        let afterRevisionRaw = "XZ\n\nABC"
        let afterRevisionCoordinate = "XZABC"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = before
        access.writeSnapshots = [
            .init(rawText: afterFirstRaw, coordinateText: afterFirstCoordinate, selection: .init(location: 1, length: 0)),
            .init(rawText: afterAppendRaw, coordinateText: afterAppendCoordinate, selection: .init(location: 2, length: 0)),
            .init(rawText: afterRevisionRaw, coordinateText: afterRevisionCoordinate, selection: .init(location: 2, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("X")
        try await target.acknowledgeKeyboardWrite()
        try target.paste("Y")
        try await target.acknowledgeKeyboardWrite()
        try target.replaceTrailingText("XY", with: "XZ")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, afterRevisionRaw)
        XCTAssertEqual(access.coordinateText, afterRevisionCoordinate)
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.appendPosts, 2)
        XCTAssertEqual(sender.replacementPosts, 1)
        let diagnostics = target.drainDiagnostics()
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
        let firstAcknowledgement = try XCTUnwrap(
            diagnostics.first { $0.event == "keyboard_write_acknowledged" }
        )
        XCTAssertEqual(firstAcknowledgement.fields["ackCandidateCount"], "4")
        XCTAssertEqual(firstAcknowledgement.fields["ackDiffFinal3CandidateMatched"], "true")
        XCTAssertEqual(firstAcknowledgement.fields["ackDiffFinal3Classification"], "equal")
    }

    func testCodexPrimaryReceiptKeepsAllRepresentationCandidatesInDiagnostics() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n\nABC",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateIncludesStructuralSeparators = true
        access.writeSnapshots = [
            .init(
                rawText: "X\n\nABC",
                coordinateText: "X\n\nABC",
                selection: .init(location: 1, length: 0)
            )
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("X")
        try await target.acknowledgeKeyboardWrite()

        let acknowledgement = try XCTUnwrap(
            target.drainDiagnostics().first { $0.event == "keyboard_write_acknowledged" }
        )
        XCTAssertEqual(acknowledgement.fields["ackCandidateCount"], "3")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal0CandidateMatched"], "true")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal1CandidateMatched"], "false")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal2CandidateMatched"], "false")
    }

    func testCodexLeadingSingleEmptyParagraphPreservesUTF16AnchorForEmojiAndCombiningText() async throws {
        let before = "\n甲"
        let first = "😀"
        let appended = "e\u{301}"
        let afterFirstRaw = "😀\n\n甲"
        let afterFirstCoordinate = "😀甲"
        let afterAppendRaw = "😀e\u{301}\n\n甲"
        let afterAppendCoordinate = "😀e\u{301}甲"
        let afterRevisionRaw = "😀好\n\n甲"
        let afterRevisionCoordinate = "😀好甲"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = before
        access.writeSnapshots = [
            .init(rawText: afterFirstRaw, coordinateText: afterFirstCoordinate, selection: .init(location: first.utf16.count, length: 0)),
            .init(rawText: afterAppendRaw, coordinateText: afterAppendCoordinate, selection: .init(location: (first + appended).utf16.count, length: 0)),
            .init(rawText: afterRevisionRaw, coordinateText: afterRevisionCoordinate, selection: .init(location: (first + "好").utf16.count, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste(first)
        try await target.acknowledgeKeyboardWrite()
        try target.paste(appended)
        try await target.acknowledgeKeyboardWrite()
        try target.replaceTrailingText(first + appended, with: first + "好")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, afterRevisionRaw)
        XCTAssertEqual(access.coordinateText, afterRevisionCoordinate)
        XCTAssertEqual(access.selection, .init(location: (first + "好").utf16.count, length: 0))
        XCTAssertEqual(sender.totalPosts, 3)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexLeadingSingleEmptyParagraphClearsAnchorAfterEmptyReplacement() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\nABC",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "\nABC"
        access.writeSnapshots = [
            .init(rawText: "X\n\nABC", coordinateText: "XABC", selection: .init(location: 1, length: 0)),
            .init(rawText: "\n\nABC", coordinateText: "ABC", selection: .init(location: 0, length: 0)),
            .init(rawText: "\n\nQABC", coordinateText: "QABC", selection: .init(location: 1, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("X")
        try await target.acknowledgeKeyboardWrite()
        try target.replaceTrailingText("X", with: "")
        try await target.acknowledgeKeyboardWrite()
        try target.paste("Q")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "\n\nQABC")
        XCTAssertEqual(access.coordinateText, "QABC")
        XCTAssertEqual(sender.appendPosts, 2)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexLeadingSingleEmptyParagraphRejectsOutsideStructureAndBodyChanges() async throws {
        let cases = [
            (raw: "XY\nA\nBC", coordinate: "XYABC", comparison: "rawTextMismatch"),
            (raw: "XY\n\nABD", coordinate: "XYABD", comparison: "documentMismatch")
        ]

        for testCase in cases {
            let access = ReplayAXTextTargetAccess(
                text: "\nABC",
                selection: .init(location: 0, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = "\nABC"
            access.writeSnapshots = [
                .init(rawText: "X\n\nABC", coordinateText: "XABC", selection: .init(location: 1, length: 0)),
                .init(rawText: testCase.raw, coordinateText: testCase.coordinate, selection: .init(location: 2, length: 0))
            ]
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(
                access: access,
                keyboardEventSender: sender,
                acknowledgementTimeoutNanoseconds: 20_000_000
            )

            _ = try target.capture()
            try target.paste("X")
            try await target.acknowledgeKeyboardWrite()
            try target.paste("Y")
            do {
                try await target.acknowledgeKeyboardWrite()
                XCTFail("the out-of-scope change must remain unconfirmed")
            } catch { }

            let failure = try XCTUnwrap(target.drainDiagnostics().last { $0.event == "keyboard_write_unconfirmed" })
            XCTAssertEqual(failure.fields["comparison"], testCase.comparison)
            XCTAssertEqual(sender.appendPosts, 2)
        }
    }

    func testCodexLeadingSingleEmptyParagraphDoesNotMatchContinuousEmptyParagraphs() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n\nABC",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "\n\nABC"
        access.writeSnapshots = [
            .init(rawText: "X\n\n\nABC", coordinateText: "XABC", selection: .init(location: 1, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("X")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("a continuous empty-paragraph representation must remain unconfirmed")
        } catch { }

        let failure = try XCTUnwrap(target.drainDiagnostics().last { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(failure.fields["comparison"], "documentMismatch")
        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testCodexLeadingSingleEmptyParagraphRetriesTransientReadWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\nABC",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "\nABC"
        access.writeSnapshots = [
            .init(rawText: "X\n\nABC", coordinateText: "XABC", selection: .init(location: 1, length: 0)),
            .init(rawText: "XY\n\nABC", coordinateText: "XYABC", selection: .init(location: 2, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 50_000_000
        )

        _ = try target.capture()
        try target.paste("X")
        try await target.acknowledgeKeyboardWrite()
        try target.paste("Y")
        access.nextTextReadError = KeyboardWriteReadError.retryable
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "XY\n\nABC")
        XCTAssertEqual(sender.appendPosts, 2)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexLeadingSingleEmptyParagraphClearsAnchorOnFocusChangeAndCapture() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\nABC",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "\nABC"
        access.writeSnapshots = [
            .init(rawText: "X\n\nABC", coordinateText: "XABC", selection: .init(location: 1, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("X")
        try await target.acknowledgeKeyboardWrite()

        access.focusChanged = true
        XCTAssertThrowsError(try target.paste("Y")) { error in
            XCTAssertEqual(error as? TextTargetError, .targetChanged)
        }
        XCTAssertEqual(sender.appendPosts, 1)

        access.focusChanged = false
        access.rawText = "\nABC"
        access.coordinateOverride = "\nABC"
        access.selection = .init(location: 0, length: 0)
        _ = try target.capture()
        access.writeSnapshots = [
            .init(rawText: "Z\n\nABC", coordinateText: "ZABC", selection: .init(location: 1, length: 0))
        ]
        try target.paste("Z")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "Z\n\nABC")
        XCTAssertEqual(sender.appendPosts, 2)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexLeadingSingleEmptyParagraphClearsAnchorOnCancellation() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\nABC",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "\nABC"
        access.writeSnapshots = [
            .init(rawText: "X\n\nABC", coordinateText: "XABC", selection: .init(location: 1, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("X")
        try await target.acknowledgeKeyboardWrite()

        // The next operation must use the ordinary document mapping after
        // cancellation; retaining the private anchor would produce a
        // different raw representation and must be observable as a failure.
        target.cancelAXWrite()
        access.writeSnapshots = [
            .init(rawText: "X\n\nYABC", coordinateText: "XYABC", selection: .init(location: 2, length: 0))
        ]
        try target.paste("Y")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "X\n\nYABC")
        XCTAssertEqual(access.coordinateText, "XYABC")
        XCTAssertEqual(sender.appendPosts, 2)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexReportShapedEmptyParagraphStatesContinueAfterFirstCharacter() async throws {
        let cases = [
            (prefixLength: 341, emptyParagraphCount: 3),
            (prefixLength: 340, emptyParagraphCount: 4),
            (prefixLength: 336, emptyParagraphCount: 8)
        ]

        for testCase in cases {
            let prefix = String(repeating: "甲", count: testCase.prefixLength)
            let before = prefix + String(repeating: "\n", count: testCase.emptyParagraphCount)
            let insertionOffset = 342 - testCase.prefixLength
            let afterFirst = prefix
                + String(repeating: "\n", count: insertionOffset)
                + "乙"
                + String(repeating: "\n", count: testCase.emptyParagraphCount - insertionOffset - 1)
            let afterAppend = prefix
                + String(repeating: "\n", count: insertionOffset)
                + "乙丙"
            let afterRevision = prefix
                + String(repeating: "\n", count: insertionOffset)
                + "乙丁"

            XCTAssertEqual(before.utf16.count, 344)
            XCTAssertEqual(afterFirst.utf16.count, 344)
            XCTAssertEqual(afterFirst.utf16.count, before.utf16.count)

            let access = ReplayAXTextTargetAccess(
                text: before,
                selection: .init(location: 342, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = before
            access.writeSnapshots = [
                .init(rawText: afterFirst, coordinateText: afterFirst, selection: .init(location: 343, length: 0)),
                .init(rawText: afterAppend, coordinateText: afterAppend, selection: .init(location: 344, length: 0)),
                .init(rawText: afterRevision, coordinateText: afterRevision, selection: .init(location: 344, length: 0))
            ]
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(access: access, keyboardEventSender: sender,
                acknowledgementTimeoutNanoseconds: 20_000_000)

            _ = try target.capture()
            try target.paste("乙")
            try await target.acknowledgeKeyboardWrite()
            try target.paste("丙")
            try await target.acknowledgeKeyboardWrite()
            try target.replaceTrailingText("乙丙", with: "乙丁")
            try await target.acknowledgeKeyboardWrite()

            XCTAssertEqual(access.rawText, afterRevision)
            XCTAssertEqual(access.selection, .init(location: 344, length: 0))
            XCTAssertEqual(sender.appendPosts, 2)
            XCTAssertEqual(sender.replacementPosts, 1)
            XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
        }
    }

    func testCodexTrailingEmptyParagraphCandidatesCoverEachInsertionPosition() async throws {
        let prefix = "草稿"
        let emptyParagraphCount = 4

        for insertionOffset in 0..<emptyParagraphCount {
            let before = prefix + String(repeating: "\n", count: emptyParagraphCount)
            let after = prefix
                + String(repeating: "\n", count: insertionOffset)
                + "甲"
                + String(repeating: "\n", count: emptyParagraphCount - insertionOffset - 1)
            let insertionLocation = prefix.utf16.count + insertionOffset
            let access = ReplayAXTextTargetAccess(
                text: before,
                selection: .init(location: insertionLocation, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = before
            access.writeSnapshots = [
                .init(
                    rawText: after,
                    coordinateText: after,
                    selection: .init(location: insertionLocation + 1, length: 0)
                )
            ]
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(
                access: access,
                keyboardEventSender: sender,
                acknowledgementTimeoutNanoseconds: 20_000_000
            )

            _ = try target.capture()
            try target.paste("甲")
            try await target.acknowledgeKeyboardWrite()

            XCTAssertEqual(access.rawText, after, "failed at trailing insertion offset \(insertionOffset)")
            XCTAssertEqual(access.selection, .init(location: insertionLocation + 1, length: 0))
            XCTAssertEqual(sender.totalPosts, 1)
            let diagnostics = target.drainDiagnostics()
            XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
            let acknowledgement = try XCTUnwrap(diagnostics.first { $0.event == "keyboard_write_acknowledged" })
            let expectedClass: String = switch insertionOffset {
            case 0: "first_trailing_newline"
            case emptyParagraphCount - 1: "last_trailing_newline"
            case emptyParagraphCount - 2: "second_last_trailing_newline"
            default: "middle_trailing_newline"
            }
            XCTAssertEqual(acknowledgement.fields["ackInsertionPositionClass"], expectedClass)
        }
    }

    func testCodexReport81To82CanComeFromEitherWrongEditorOrStaleAXState() async throws {
        var failures: [[String: String]] = []
        for capturedWrongEditor in [true, false] {
            let original = String(repeating: "甲", count: 81)
            let access = ReplayAXTextTargetAccess(text: original,
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001))
            var visibleCapturedEditor = original
            var visibleOtherEditor = ""
            let sender = ReplayKeyboardEventSender(access: access)
            sender.appendOverride = { text in
                if capturedWrongEditor { visibleOtherEditor += text }
                else { visibleCapturedEditor += text }
            }
            var now: UInt64 = 0
            let target = AXTextTarget(access: access, keyboardEventSender: sender,
                writeTiming: .init(now: { now }, sleep: { now += $0 }),
                acknowledgementTimeoutNanoseconds: 5_000_000_000)
            _ = try target.capture()
            try target.paste("乙")
            do {
                try await target.acknowledgeKeyboardWrite()
                XCTFail("Stale readback must not be accepted or trigger another send")
            } catch { }
            let failed = try XCTUnwrap(target.drainDiagnostics().first { $0.event == "keyboard_write_unconfirmed" })
            XCTAssertEqual(failed.fields["expectedDocumentLength"], "82")
            XCTAssertEqual(failed.fields["observedLengthUTF16"], "81")
            XCTAssertEqual(failed.fields["expectedSelectionLocation"], "82")
            XCTAssertEqual(failed.fields["actualSelectionLocation"], "81")
            XCTAssertEqual(failed.fields["comparison"], "documentMismatch")
            XCTAssertEqual(sender.totalPosts, 1)
            XCTAssertEqual(visibleCapturedEditor, capturedWrongEditor ? original : original + "乙")
            XCTAssertEqual(visibleOtherEditor, capturedWrongEditor ? "乙" : "")
            failures.append(failed.fields)
        }
        XCTAssertEqual(failures[0], failures[1], "Existing reports cannot distinguish these two independently reproduced causes")
    }

    func testEvidenceObserverCorrelatesCaptureDispatchAndFailureWithoutResendingOrText() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "私密草稿", application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
        let sender = ReplayKeyboardEventSender(access: access)
        var evidence: [TextInputDiagnostic] = []
        var targetPresent = false
        let target = AXTextTarget(evidenceObserver: { diagnostic, element, pid in
            evidence.append(diagnostic)
            targetPresent = element != nil
            XCTAssertEqual(pid, 9001)
        }, access: access, keyboardEventSender: sender)
        _ = try target.capture()
        try target.paste("机密输入")
        access.nextTextReadError = TextTargetError.writeFailed
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("Unreadable confirmation must still stop")
        } catch { XCTAssertEqual(error as? TextTargetError, .writeFailed) }
        let captured = try XCTUnwrap(evidence.first { $0.event == "input_target_captured" })
        let submitted = try XCTUnwrap(evidence.first { $0.event == "keyboard_write_submitted" })
        let failed = try XCTUnwrap(evidence.first { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(captured.fields["inputSessionGeneration"], failed.fields["inputSessionGeneration"])
        XCTAssertEqual(submitted.fields["keyboardOperationGeneration"], failed.fields["keyboardOperationGeneration"])
        XCTAssertEqual(failed.fields["keyboardOperationGeneration"], "1")
        XCTAssertTrue(targetPresent)
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertFalse(evidence.flatMap { $0.fields.values }.contains { $0.contains("私密草稿") || $0.contains("机密输入") })
    }

    func testRealAXReplayContinuesAfterCodexRemovesFinalEmptyParagraphOnFirstCharacter() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n", selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateIncludesStructuralSeparators = true
        access.writeSnapshots = [
            .init(rawText: "甲", coordinateText: "甲", selection: .init(location: 1, length: 0)),
            .init(rawText: "甲乙", coordinateText: "甲乙", selection: .init(location: 2, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: projection("甲", revision: 1))
        await finish(injector, finalText: "甲", advancing: clock)
        injector.apply(projection: projection("甲乙", revision: 2))
        await finish(injector, finalText: "甲乙", advancing: clock)

        XCTAssertEqual(access.rawText, "甲乙")
        XCTAssertEqual(access.coordinateText, "甲乙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.appendPosts, 2, "each character growth is posted once")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertTrue(injector.drainDiagnostics().contains {
            $0.event == "keyboard_write_acknowledged"
                && $0.fields["receiptRepresentationTransition"] == "trailing_newline_collapsed"
        })
    }

    func testDiagnosticReportsImmediateReadFailureWithoutChangingRetryPolicy() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n", selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        _ = try target.capture()
        try target.paste("你好")
        access.nextTextReadError = TextTargetError.writeFailed
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("Diagnostic instrumentation must preserve the existing failure")
        } catch {
            XCTAssertEqual(error as? TextTargetError, .writeFailed)
        }
        let diagnostic = try XCTUnwrap(target.drainDiagnostics().first { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(diagnostic.fields["readAttempts"], "1")
        XCTAssertEqual(diagnostic.fields["comparison"], "unreadable")
        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testAcknowledgementEvidenceRetainsEarlyStateAfterLaterMismatch() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿", application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateIncludesStructuralSeparators = true
        let sender = ReplayKeyboardEventSender(access: access)
        var observedDiagnostics: [TextInputDiagnostic] = []
        var now: UInt64 = 0
        let target = AXTextTarget(
            evidenceObserver: { diagnostic, _, _ in observedDiagnostics.append(diagnostic) },
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { now }, sleep: { now += $0 }),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("甲")
        access.failNextCoordinateReads = 1
        access.queuedTextReadSnapshots = [
            .init(rawText: "草稿甲乙", coordinateText: "草稿甲乙", selection: .init(location: 4, length: 0)),
            .init(rawText: "草稿甲乙", coordinateText: "草稿甲乙", selection: .init(location: 4, length: 0)),
            .init(rawText: "草稿甲乙丙", coordinateText: "草稿甲乙丙", selection: .init(location: 5, length: 0))
        ]

        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("A later mismatching state must remain unconfirmed")
        } catch { XCTAssertEqual(error as? TextTargetError, .writeFailed) }

        let diagnostic = try XCTUnwrap(target.drainDiagnostics().first { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(diagnostic.fields["ackCandidateCount"], "1")
        XCTAssertEqual(diagnostic.fields["ackFirstReadableAXValueLengthUTF16"], "4")
        XCTAssertEqual(diagnostic.fields["ackFirstReadableCoordinateLengthUTF16"], "4")
        XCTAssertEqual(diagnostic.fields["ackFirstChangedAXValueLengthUTF16"], "4")
        XCTAssertEqual(diagnostic.fields["ackFirstChangedSelectionLocation"], "4")
        XCTAssertEqual(diagnostic.fields["ackFirstChangedCandidateMatches"], "false")
        XCTAssertEqual(diagnostic.fields["ackFinalAXValueLengthUTF16"], "5")
        XCTAssertEqual(diagnostic.fields["ackFinalSelectionLocation"], "5")
        XCTAssertEqual(diagnostic.fields["ackFinalCandidateMatches"], "false")
        XCTAssertFalse(diagnostic.fields["ackFirstReadErrorCode", default: ""].isEmpty)
        XCTAssertEqual(diagnostic.fields["observedAXValueLengthUTF16"], "5")
        XCTAssertEqual(DiagnosticLogSanitizer.fields(diagnostic.fields)["observedAXValueLengthUTF16"], "5")
        XCTAssertFalse(diagnostic.fields.values.contains { $0.contains("草稿") || $0.contains("甲乙") })
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(diagnostic.fields["inputSessionGeneration"], "1")
        XCTAssertEqual(diagnostic.fields["keyboardOperationGeneration"], "1")
        XCTAssertTrue(observedDiagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testReplacementReadFailureDoesNotReusePreDispatchCandidateMatch() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲乙",
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.replaceTrailingText("乙", with: "丁")
        sender.onReplacement = { access.persistentTextReadError = TextTargetError.writeFailed }
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("A post-dispatch read failure must remain unconfirmed")
        } catch { XCTAssertEqual(error as? TextTargetError, .writeFailed) }

        let diagnostic = try XCTUnwrap(target.drainDiagnostics().first { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(diagnostic.fields["comparison"], "unreadable")
        XCTAssertEqual(diagnostic.fields["ackFinalCandidateMatches"], "")
        XCTAssertEqual(diagnostic.fields["ackFirstReadableSelectionLocation"], "1")
        XCTAssertEqual(diagnostic.fields["ackFirstReadErrorCode"], "text_target_write_failed")
        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testSafariAXFailureDuringConfirmationRecoversWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿", application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        _ = try target.capture()
        try target.paste("甲")
        access.nextTextReadError = AXAttributeReadFailure(attribute: kAXValueAttribute as String, status: -25202)
        try await target.acknowledgeKeyboardWrite()
        try await target.writeKeyboardText(previousText: "", with: "乙")
        XCTAssertEqual(access.rawText, "草稿甲乙")
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertTrue(target.drainDiagnostics().contains { $0.event == "keyboard_state_read_retryable" })
    }

    func testSafariPersistentAXFailureTimesOutWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "", application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
        let sender = ReplayKeyboardEventSender(access: access)
        var now: UInt64 = 0
        let target = AXTextTarget(access: access, keyboardEventSender: sender,
            writeTiming: .init(now: { now }, sleep: { now += $0 }),
            acknowledgementTimeoutNanoseconds: 20_000_000)
        _ = try target.capture()
        try target.paste("甲")
        access.persistentTextReadError = AXAttributeReadFailure(attribute: kAXValueAttribute as String, status: -25202)
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("Unreadable state cannot confirm")
        } catch { XCTAssertEqual(error as? TextTargetError, .writeFailed) }
        XCTAssertEqual(now, 20_000_000)
        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testAXReadFailureRecoveryIsLimitedToSafariEditorAndKnownAttributes() async throws {
        for (bundle, proseMirror, attribute, status) in [
            ("md.obsidian", false, kAXValueAttribute as String, -25202),
            ("com.apple.Safari", true, "AXOtherAttribute", -25202),
            ("com.apple.Safari", true, kAXValueAttribute as String, AXError.failure.rawValue)
        ] {
            let access = ReplayAXTextTargetAccess(text: "", application: .init(name: "App", bundleIdentifier: bundle, processIdentifier: 9001))
            access.proseMirror = proseMirror
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(access: access, keyboardEventSender: sender)
            _ = try target.capture()
            try target.paste("甲")
            access.nextTextReadError = AXAttributeReadFailure(attribute: attribute, status: status)
            do {
                try await target.acknowledgeKeyboardWrite()
                XCTFail("Unrelated failures must remain terminal")
            } catch { XCTAssertEqual(error as? TextTargetError, .writeFailed) }
            XCTAssertEqual(sender.totalPosts, 1)
            XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_state_read_retryable" })
        }
    }

    func testSafariPreflightReadFailureRecoversBeforeSending() async throws {
        let access = ReplayAXTextTargetAccess(text: "", application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001))
        access.proseMirror = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        _ = try target.capture()
        access.nextTextReadError = AXAttributeReadFailure(attribute: kAXValueAttribute as String, status: -25202)
        try await target.writeKeyboardText(previousText: "", with: "甲")
        XCTAssertEqual(access.rawText, "甲")
        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testSafariExtraCharactersRemainUnconfirmedWithUsefulEvidence() async throws {
        let access = ReplayAXTextTargetAccess(text: String(repeating: "草", count: 497),
            selection: .init(location: 496, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001))
        access.proseMirror = true
        let sender = ReplayKeyboardEventSender(access: access)
        var now: UInt64 = 0
        let target = AXTextTarget(access: access, keyboardEventSender: sender,
            writeTiming: .init(now: { now }, sleep: { now += $0 }),
            acknowledgementTimeoutNanoseconds: 20_000_000)
        _ = try target.capture()
        try target.paste("甲")
        access.rawText += "乙丙"
        access.selection = .init(location: 499, length: 0)
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("Extra characters cannot be accepted as a receipt")
        } catch { XCTAssertEqual(error as? TextTargetError, .writeFailed) }
        XCTAssertEqual(sender.totalPosts, 1)
        let diagnostic = try XCTUnwrap(target.drainDiagnostics().first { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(diagnostic.fields["expectedDocumentLength"], "498")
        XCTAssertEqual(diagnostic.fields["observedLengthUTF16"], "500")
        XCTAssertEqual(diagnostic.fields["expectedSelectionLocation"], "497")
        XCTAssertEqual(diagnostic.fields["actualSelectionLocation"], "499")
        XCTAssertEqual(diagnostic.fields["comparison"], "documentMismatch")
    }

    func testSafariInvalidHandleRecoveryPreservesLongDraftAndTailRevision() async throws {
        XCTAssertEqual(AXError.invalidUIElement.rawValue, -25202)
        for draft in ["草稿", String(repeating: "草😀", count: 500)] {
            let access = ReplayAXTextTargetAccess(text: draft, application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001))
            access.proseMirror = true
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(access: access, keyboardEventSender: sender)
            _ = try target.capture()
            try target.paste("你好")
            access.nextTextReadError = AXAttributeReadFailure(attribute: kAXValueAttribute as String, status: -25202)
            access.onTextReadFailure = { access.focusedElementRebuildsBeforeNextWrite = 1 }
            try await target.acknowledgeKeyboardWrite()
            try target.replaceTrailingText("你好", with: "您好")
            access.nextSelectionReadError = AXAttributeReadFailure(attribute: kAXSelectedTextRangeAttribute as String, status: -25202)
            try await target.acknowledgeKeyboardWrite()
            XCTAssertEqual(access.rawText, draft + "您好")
            XCTAssertEqual(access.selection.location, draft.utf16.count + 2)
            XCTAssertEqual(sender.appendPosts, 1)
            XCTAssertEqual(sender.replacementPosts, 1)
            XCTAssertTrue(target.drainDiagnostics().contains { $0.event == "safari_keyboard_target_reacquired" && $0.fields["phase"] == "invalid_element_read" })
        }
    }

    func testSafariApplicationSwitchDuringInvalidHandleRecoveryStops() async throws {
        let access = ReplayAXTextTargetAccess(text: "", application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001))
        access.proseMirror = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        _ = try target.capture()
        try target.paste("甲")
        access.nextTextReadError = AXAttributeReadFailure(attribute: kAXValueAttribute as String, status: -25202)
        access.onTextReadFailure = {
            access.currentApplicationOverride = .init(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 9002)
        }
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("Application changes must stop recovery")
        } catch { XCTAssertEqual(error as? TextTargetError, .targetChanged) }
        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testSystemAXReadFailureRecordsStatusAndDrainsWithoutContent() throws {
        let access = SystemAXTextTargetAccess()
        _ = try? access.text(in: AXUIElementCreateSystemWide())
        let diagnostic = try XCTUnwrap(access.drainReadDiagnostics().first)
        XCTAssertEqual(diagnostic.event, "ax_read_failed")
        XCTAssertEqual(diagnostic.fields["axAttribute"], kAXValueAttribute as String)
        XCTAssertNotEqual(diagnostic.fields["axStatus"], "0")
        XCTAssertEqual(diagnostic.fields.count, 2)
        XCTAssertTrue(access.drainReadDiagnostics().isEmpty)
    }

    func testSafariProseMirrorUsesAcknowledgedKeyboardInputDespiteWritableAX() async throws {
        for draft in ["\n", "已有草稿\n"] {
            let access = ReplayAXTextTargetAccess(
                text: draft,
                selection: .init(location: draft.utf16.count - 1, length: 0),
                application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
            )
            access.proseMirror = true
            access.textAttributesAreSettable = true
            access.coordinateIncludesStructuralSeparators = true
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(access: access, keyboardEventSender: sender)
            let injector = TextInjector(target: target)
            try injector.begin()
            XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
            injector.apply(projection: projection("你好", revision: 1))
            try await injector.finish(finalText: "你好")
            injector.apply(projection: projection("您好😀", revision: 2))
            try await injector.finish(finalText: "您好😀")
            XCTAssertEqual(access.rawText, String(draft.dropLast()) + "您好😀\n")
            XCTAssertEqual(access.axTextWrites, 0)
            XCTAssertEqual(injector.errorCount, 0)
            let posts = sender.totalPosts
            access.focusChanged = true
            injector.apply(projection: projection("您好😀继续", revision: 3))
            try await injector.finish(finalText: "您好😀继续")
            XCTAssertEqual(sender.totalPosts, posts)
            XCTAssertEqual(injector.degradationCode, "text_target_changed")
        }
    }

    func testSafariProseMirrorReacquiresRebuiltAXElementWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.focusedElementRebuildsBeforeNextWrite = 1
        access.focusedElementRebuildsAfterNextWrite = 1
        access.readSnapshotsAfterNextWrite = [
            .init(rawText: "\n", coordinateText: "\n", selection: .init(location: 0, length: 0)),
            .init(rawText: "你好\n", coordinateText: "你好\n", selection: .init(location: 2, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("你好", revision: 1))
        try await injector.finish(finalText: "你好")

        XCTAssertEqual(access.rawText, "你好\n")
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertTrue(injector.drainDiagnostics().contains { $0.event == "safari_keyboard_target_reacquired" })
    }

    func testSafariProseMirrorDoesNotResendAfterExternalEditDuringAcknowledgement() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿",
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
        access.readSnapshotsAfterNextWrite = [
            .init(rawText: "用户编辑", coordinateText: "用户编辑", selection: .init(location: 4, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("草稿语音", revision: 1))
        await finish(injector, finalText: "草稿语音", advancing: clock)

        XCTAssertEqual(access.rawText, "用户编辑")
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        XCTAssertEqual(injector.degradationCode, "text_target_write_failed")
    }

    func testSafariProseMirrorReacquiresDuringTailReplacementWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "已有\n",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
        access.selectionRangeIsSettable = true
        access.coordinateIncludesStructuralSeparators = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("你好", revision: 1))
        try await injector.finish(finalText: "你好")
        XCTAssertEqual(access.rawText, "已有你好\n")

        access.focusedElementRebuildsAfterNextWrite = 1
        injector.apply(projection: projection("您好", revision: 2))
        try await injector.finish(finalText: "您好")

        XCTAssertEqual(access.rawText, "已有您好\n")
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertTrue(injector.drainDiagnostics().contains { $0.event == "safari_keyboard_target_reacquired" })
    }

    func testSafariProseMirrorStopsWithoutResendingAfterApplicationSwitch() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("已有", revision: 1))
        try await injector.finish(finalText: "已有")
        let posts = sender.totalPosts

        access.currentApplicationOverride = .init(
            name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 9002
        )
        injector.apply(projection: projection("已有继续", revision: 2))
        try await injector.finish(finalText: "已有继续")

        XCTAssertEqual(sender.totalPosts, posts)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
    }

    func testSafariNativeFieldKeepsAXReplacement() throws {
        let access = ReplayAXTextTargetAccess(
            text: "搜索", application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        let injector = TextInjector(target: AXTextTarget(access: access))
        try injector.begin()
        XCTAssertEqual(injector.modeDescription, "ax")
    }

    func testObsidianUsesKeyboardAcknowledgementWhenAXWriteIsMisleading() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "已有",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Obsidian", bundleIdentifier: "md.obsidian", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target, pacingClock: clock)

        try injector.begin()
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")

        access.readSnapshotsAfterNextWrite = [
            .init(rawText: "已有", coordinateText: "已有", selection: .init(location: 2, length: 0)),
            .init(rawText: "已有语音", coordinateText: "已有语音", selection: .init(location: 4, length: 0))
        ]
        injector.apply(projection: projection("语音", revision: 1))
        await finish(injector, finalText: "语音", advancing: clock)

        XCTAssertEqual(access.rawText, "已有语音")
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)

        access.readSnapshotsAfterNextWrite = [
            .init(rawText: "已有语音", coordinateText: "已有语音", selection: .init(location: 4, length: 0)),
            .init(rawText: "已有语境", coordinateText: "已有语境", selection: .init(location: 4, length: 0))
        ]
        injector.apply(projection: projection("语境", revision: 2))
        await finish(injector, finalText: "语境", advancing: clock)

        XCTAssertEqual(access.rawText, "已有语境")
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(sender.totalPosts, 2, "a delayed readback must not resend the keyboard event")
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testWebInputRoutingIsGenericAndKeepsSpecializedTargets() {
        let chrome = TextTargetApplication(
            name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001
        )
        let webContext = AXTextInputTargetContext(
            role: "AXTextArea",
            hasWebAreaAncestor: true,
            webURL: URL(string: "https://example.com"),
            isReadOnly: false,
            isSecure: false,
            ancestorScanStatus: .webArea,
            webAreaDepth: 11
        )

        XCTAssertEqual(
            AXTextInputStrategy.select(application: chrome, context: webContext),
            .acknowledgedKeyboard(reason: "web_editable_text_control")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(
                application: chrome,
                context: AXTextInputTargetContext(
                    role: "AXTextField", hasWebAreaAncestor: true, webURL: webContext.webURL,
                    isReadOnly: false, isSecure: false
                )
            ),
            .acknowledgedKeyboard(reason: "web_editable_text_control")
        )

        let rejectedContexts = [
            AXTextInputTargetContext(
                role: "AXTextArea", hasWebAreaAncestor: false, webURL: webContext.webURL,
                isReadOnly: false, isSecure: false
            )
        ]
        for context in rejectedContexts {
            XCTAssertEqual(
                AXTextInputStrategy.select(application: chrome, context: context),
                .accessibility
            )
        }
        for context in [
            AXTextInputTargetContext(
                role: "AXTextArea", hasWebAreaAncestor: true, webURL: webContext.webURL,
                isReadOnly: true, isSecure: false
            ),
            AXTextInputTargetContext(
                role: "AXTextArea", hasWebAreaAncestor: true, webURL: webContext.webURL,
                isReadOnly: false, isSecure: true
            )
        ] {
            XCTAssertEqual(
                AXTextInputStrategy.select(application: chrome, context: context),
                .safeStop(reason: "web_control_not_editable")
            )
        }
        XCTAssertEqual(
            AXTextInputStrategy.select(
                application: chrome,
                context: AXTextInputTargetContext(
                    role: "AXTextArea", hasWebAreaAncestor: true, webURL: webContext.webURL,
                    isReadOnly: false, isSecure: false, ancestorScanStatus: .truncated
                )
            ),
            .safeStop(reason: "web_ancestor_unclassified")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(
                application: chrome,
                context: AXTextInputTargetContext(
                    role: "AXTextArea", hasWebAreaAncestor: true, webURL: webContext.webURL,
                    isReadOnly: nil, isSecure: false, ancestorScanStatus: .webArea
                )
            ),
            .safeStop(reason: "web_editability_unknown")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(
                application: TextTargetApplication(
                    name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001
                ),
                context: webContext
            ),
            .accessibility
        )
        for bundleIdentifier in ["com.openai.codex", "com.apple.Safari", "md.obsidian"] {
            XCTAssertEqual(
                AXTextInputStrategy.select(
                    application: TextTargetApplication(
                        name: bundleIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: 9001
                    ),
                    context: AXTextInputTargetContext(
                        role: "AXTextArea", hasWebAreaAncestor: true, webURL: nil,
                        isReadOnly: nil, isSecure: nil, ancestorScanStatus: .readFailure
                    )
                ),
                .accessibility,
                "specialized route must survive transient classification failure for \(bundleIdentifier)"
            )
        }
    }

    func testWebInputRoutingStopsWhenReadableStateIsMissing() {
        let context = AXTextInputTargetContext(
            role: "AXTextArea",
            hasWebAreaAncestor: true,
            webURL: nil,
            isReadOnly: false,
            isSecure: false,
            ancestorScanStatus: .webArea
        )
        let strategy = AXTextInputStrategy.select(
            application: TextTargetApplication(
                name: "Anki", bundleIdentifier: "net.ankiweb.anki", processIdentifier: 9001
            ),
            context: context,
            hasReadableTextState: false
        )
        XCTAssertEqual(strategy, .safeStop(reason: "web_text_state_unreadable"))
    }

    func testAncestorScannerUsesSameBoundForDeepWebAreaAndStopsAtTruncation() {
        let deepChain = Dictionary(uniqueKeysWithValues: (0...11).map { ($0, $0 + 1) })
        let deepResult = AXTextAncestorScanner.scan(
            start: 0,
            nodeLimit: 64,
            role: { $0 == 11 ? "AXWebArea" : "AXGroup" },
            parent: { deepChain[$0] },
            equals: ==
        )
        XCTAssertEqual(deepResult, .init(status: .webArea, webAreaDepth: 11))

        let truncatedResult = AXTextAncestorScanner.scan(
            start: 0,
            nodeLimit: 8,
            role: { _ in "AXGroup" },
            parent: { $0 + 1 },
            equals: ==
        )
        XCTAssertEqual(truncatedResult.status, .truncated)

        let unreadableResult = AXTextAncestorScanner.scan(
            start: 0,
            role: { _ in nil },
            parent: { _ in nil },
            equals: ==
        )
        XCTAssertEqual(unreadableResult.status, .readFailure)
    }

    func testChromePoeTextareaWithWritableAXAttributesUsesAcknowledgedKeyboard() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.axWriteNoOp = true
        access.configureWebAncestorChain(depth: 11, webURL: URL(string: "https://poe.com/GPT-4o-mini"))
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("甲乙", revision: 1))
        try await injector.finish(finalText: "甲乙")

        XCTAssertEqual(access.rawText, "甲乙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(access.axTextWrites, 0, "Poe must not use the Chrome AXSelectedText setter")
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        let diagnostics = injector.drainDiagnostics()
        let capture = try XCTUnwrap(diagnostics.first { $0.event == "input_target_captured" })
        XCTAssertEqual(capture.fields["inputStrategy"], "acknowledged_keyboard")
        XCTAssertEqual(capture.fields["inputStrategyReason"], "web_editable_text_control")
    }

    func testQtWebEngineLikeTextAreaAvoidsMisleadingAXValue() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "已有",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Anki", bundleIdentifier: "net.ankiweb.anki", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.axWriteNoOp = true
        access.configureWebAncestorChain(depth: 3)
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("语音", revision: 1))
        try await injector.finish(finalText: "语音")

        XCTAssertEqual(access.rawText, "已有语音")
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testChromePoeRoutingDoesNotGuessWhenAXTextStateIsUnreadable() throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.alwaysFailTextReads = true
        access.configureWebAncestorChain(depth: 11, webURL: URL(string: "https://poe.com/GPT-4o-mini"))
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        let snapshot = try target.capture()
        XCTAssertEqual(snapshot.preferredInputStrategy, .safeStop(reason: "web_text_state_unreadable"))
        XCTAssertFalse(target.requiresKeyboardAcknowledgement)

        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection("不应盲发", revision: 1))
        try injector.finishImmediately(finalText: "不应盲发")
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertEqual(access.axTextWrites, 0)
    }

    func testUnclassifiedWebAncestorStopsBeforeAXReplacement() throws {
        let access = ReplayAXTextTargetAccess(
            text: "已有",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.configureCyclicAncestorChain()
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        let snapshot = try target.capture()
        XCTAssertEqual(snapshot.preferredInputStrategy, .safeStop(reason: "web_ancestor_unclassified"))
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection("不应发送", revision: 1))
        try injector.finishImmediately(finalText: "不应发送")

        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        XCTAssertEqual(injector.degradationCode, "web_ancestor_unclassified")
    }

    func testWebReadFailureDoesNotFallBackToUnconfirmedKeyboardInput() throws {
        let access = ReplayAXTextTargetAccess(
            text: "已有",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.persistentTextReadError = TextTargetError.writeFailed
        access.configureWebAncestorChain(depth: 11)
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        let snapshot = try target.capture()
        XCTAssertEqual(snapshot.preferredInputStrategy, .safeStop(reason: "web_text_state_unreadable"))
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection("不应发送", revision: 1))
        try injector.finishImmediately(finalText: "不应发送")

        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(injector.degradationCode, "web_text_state_unreadable")
    }

    func testInvalidWebSelectionIsNotAcceptedAsReadableState() throws {
        let access = ReplayAXTextTargetAccess(
            text: "已有",
            selection: .init(location: 99, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.configureWebAncestorChain(depth: 11)
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        let snapshot = try target.capture()
        XCTAssertEqual(snapshot.preferredInputStrategy, .safeStop(reason: "web_text_state_unreadable"))
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection("不应发送", revision: 1))
        try injector.finishImmediately(finalText: "不应发送")

        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertEqual(access.axTextWrites, 0)
    }

    func testChromePoeKeyboardRoutePreservesDraftCaretAndEmojiRevision() async throws {
        let draft = "前置😀后缀"
        let insertionLocation = "前置😀".utf16.count
        let access = ReplayAXTextTargetAccess(
            text: draft,
            selection: .init(location: insertionLocation, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.configureWebAncestorChain(depth: 11, webURL: URL(string: "https://poe.com/GPT-4o-mini"))
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("中文", revision: 1))
        injector.apply(projection: projection("中文😀", revision: 2))
        try await injector.finish(finalText: "中文😀")

        XCTAssertEqual(access.rawText, "前置😀中文😀后缀")
        XCTAssertEqual(access.selection, .init(location: insertionLocation + "中文😀".utf16.count, length: 0))
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(sender.totalPosts, 1, "coalesced revision must not duplicate the first draft insertion")
        XCTAssertEqual(injector.errorCount, 0)
    }

    func testChromePoeKeyboardRouteStopsAfterNavigationBeforeDispatch() throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.configureWebAncestorChain(depth: 11, webURL: URL(string: "https://poe.com/GPT-4o-mini"))
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        _ = try target.capture()
        access.configureNativeAncestorChain()

        XCTAssertThrowsError(try target.paste("不应发送")) { error in
            XCTAssertEqual(error as? TextTargetError, .targetChanged)
        }
        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertTrue(target.drainDiagnostics().contains { $0.event == "input_strategy_changed" })
    }

    func testChromePoeKeyboardRouteWaitsForDelayedReadbackWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "已有",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.configureWebAncestorChain(depth: 11, webURL: URL(string: "https://poe.com/GPT-4o-mini"))
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target, pacingClock: clock)

        try injector.begin()
        access.readSnapshotsAfterNextWrite = [
            .init(rawText: "已有", coordinateText: "已有", selection: .init(location: 2, length: 0)),
            .init(rawText: "已有语音", coordinateText: "已有语音", selection: .init(location: 4, length: 0))
        ]
        injector.apply(projection: projection("语音", revision: 1))
        await finish(injector, finalText: "语音", advancing: clock)

        access.readSnapshotsAfterNextWrite = [
            .init(rawText: "已有语音", coordinateText: "已有语音", selection: .init(location: 4, length: 0)),
            .init(rawText: "已有语境", coordinateText: "已有语境", selection: .init(location: 4, length: 0))
        ]
        injector.apply(projection: projection("语境", revision: 2))
        await finish(injector, finalText: "语境", advancing: clock)

        XCTAssertEqual(access.rawText, "已有语境")
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testChromePoeKeyboardRouteStopsOnExternalEditOrFocusChangeWithoutResending() async throws {
        for change in ["external", "focus"] {
            let access = ReplayAXTextTargetAccess(
                text: "已有",
                selection: .init(location: 2, length: 0),
                application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
            )
            access.textAttributesAreSettable = true
            access.configureWebAncestorChain(depth: 11, webURL: URL(string: "https://poe.com/GPT-4o-mini"))
            let sender = ReplayKeyboardEventSender(access: access)
            let clock = ManualKeyboardPacingClock()
            let target = AXTextTarget(
                access: access,
                keyboardEventSender: sender,
                writeTiming: .init(
                    now: { clock.nowNanoseconds },
                    sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
                ),
                acknowledgementTimeoutNanoseconds: 20_000_000
            )
            let injector = TextInjector(target: target, pacingClock: clock)

            try injector.begin()
            injector.apply(projection: projection("语音", revision: 1))
            await finish(injector, finalText: "语音", advancing: clock)
            let posts = sender.totalPosts
            if change == "external" {
                access.externalEdit("用户编辑")
            } else {
                access.focusChanged = true
            }

            injector.apply(projection: projection("语境", revision: 2))
            await finish(injector, finalText: "语境", advancing: clock)

            XCTAssertEqual(sender.totalPosts, posts, change)
            XCTAssertEqual(access.axTextWrites, 0, change)
            XCTAssertEqual(injector.modeDescription, "disabled_after_error", change)
            XCTAssertEqual(injector.degradationCode, "text_target_changed", change)
            if change == "external" {
                XCTAssertEqual(access.rawText, "用户编辑")
            } else {
                XCTAssertEqual(access.rawText, "已有语音")
            }
        }
    }

    func testCodexWithoutReadableAXTextKeepsLegacyKeyboardFallback() throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿",
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.alwaysFailTextReads = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        let snapshot = try target.capture()
        XCTAssertFalse(snapshot.preferredInputStrategy.prefersAcknowledgedKeyboard)
        XCTAssertFalse(target.requiresKeyboardAcknowledgement)
        try target.paste("甲")

        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(access.rawText, "草稿甲")
    }

    func testAXWriteMustWaitForReadbackBeforeAdvancingState() async throws {
        let before = String(repeating: "草", count: 1068)
        let firstDocument = NSMutableString(string: before)
        firstDocument.insert("甲乙", at: 4)
        let afterFirst = firstDocument as String
        let secondDocument = NSMutableString(string: afterFirst)
        secondDocument.replaceCharacters(in: NSRange(location: 4, length: 2), with: "甲乙丙丁")
        let afterSecond = secondDocument as String
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 4, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.axWriteNoOp = true
        access.axWriteReadSnapshotsByWrite = [
            [
                .init(rawText: before, coordinateText: before, selection: .init(location: 4, length: 0)),
                .init(rawText: afterFirst, coordinateText: afterFirst, selection: .init(location: 6, length: 0))
            ],
            [
                .init(rawText: afterFirst, coordinateText: afterFirst, selection: .init(location: 6, length: 0)),
                .init(rawText: afterSecond, coordinateText: afterSecond, selection: .init(location: 8, length: 0))
            ]
        ]
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("甲乙", revision: 1))
        await finish(injector, finalText: "甲乙", advancing: clock)
        injector.apply(projection: projection("甲乙丙丁", revision: 2))
        await finish(injector, finalText: "甲乙丙丁", advancing: clock)

        XCTAssertEqual(access.rawText, afterSecond)
        XCTAssertEqual(access.axTextWrites, 2)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "ax")
        let diagnostics = injector.drainDiagnostics()
        let firstAcknowledgement = try XCTUnwrap(diagnostics.first {
            $0.event == "ax_write_acknowledged"
                && $0.fields["axExpectedValueLengthUTF16"] == String(afterFirst.utf16.count)
        })
        XCTAssertEqual(firstAcknowledgement.fields["axPreflightFirstReadableAXValueLengthUTF16"], "1068")
        XCTAssertEqual(firstAcknowledgement.fields["axPreflightFirstReadableSelectionLocation"], "4")
        XCTAssertEqual(firstAcknowledgement.fields["axFirstReadableAXValueLengthUTF16"], "1068")
        XCTAssertEqual(firstAcknowledgement.fields["axFirstChangedAXValueLengthUTF16"], "1068")
        XCTAssertEqual(firstAcknowledgement.fields["axFirstChangedCandidateMatches"], "false")
        XCTAssertEqual(firstAcknowledgement.fields["axFinalAXValueLengthUTF16"], "1070")
        XCTAssertEqual(firstAcknowledgement.fields["axFinalSelectionLocation"], "6")
        XCTAssertGreaterThan(Int(firstAcknowledgement.fields["axPreflightReadAttempts"] ?? "0") ?? 0, 0)
        XCTAssertGreaterThan(Int(firstAcknowledgement.fields["axReadAttempts"] ?? "0") ?? 0, 1)
    }

    func testAXWriteValueBranchConfirmsEmojiRevisionAndDoesNotRetry() async throws {
        let before = "已有草稿"
        let first = before + "😀甲"
        let revised = before + "😀乙"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: before.utf16.count, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.selectedTextAttributeIsSettable = false
        access.valueAttributeIsSettable = true
        access.axWriteReadSnapshotsByWrite = [
            [
                .init(rawText: before, coordinateText: before, selection: .init(location: before.utf16.count, length: 0)),
                .init(rawText: first, coordinateText: first, selection: .init(location: first.utf16.count, length: 0))
            ],
            [
                .init(rawText: first, coordinateText: first, selection: .init(location: first.utf16.count, length: 0)),
                .init(rawText: revised, coordinateText: revised, selection: .init(location: revised.utf16.count, length: 0))
            ]
        ]
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("😀甲", revision: 1))
        await finish(injector, finalText: "😀甲", advancing: clock)
        injector.apply(projection: projection("😀乙", revision: 2))
        await finish(injector, finalText: "😀乙", advancing: clock)

        XCTAssertEqual(access.rawText, revised)
        XCTAssertEqual(access.axTextWrites, 2)
        XCTAssertEqual(injector.errorCount, 0)
        let diagnostics = injector.drainDiagnostics()
        XCTAssertEqual(diagnostics.filter { $0.event == "ax_write_submitted" }.count, 2)
        XCTAssertTrue(diagnostics.contains { $0.event == "ax_write_acknowledged" && $0.fields["axWriteKind"] == "value" })
    }

    func testAXWriteTimeoutStopsWithoutRetryingOrAdvancingAfterNoOp() async throws {
        let before = String(repeating: "草", count: 1068)
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 4, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.axWriteNoOp = true
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("甲乙", revision: 1))
        await finish(injector, finalText: "甲乙", advancing: clock)
        injector.apply(projection: projection("甲乙丙", revision: 2))
        await finish(injector, finalText: "甲乙丙", advancing: clock)

        XCTAssertEqual(access.rawText, before)
        XCTAssertEqual(access.axTextWrites, 1, "a successful AX return must never cause a second write")
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.degradationCode, "text_target_write_failed")
        let diagnostics = injector.drainDiagnostics()
        XCTAssertEqual(diagnostics.filter { $0.event == "ax_write_submitted" }.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.event == "ax_write_unconfirmed" }.count, 1)
        XCTAssertEqual(diagnostics.first { $0.event == "ax_write_unconfirmed" }?.fields["axFinalCandidateMatches"], "false")
    }

    func testAXWriteRejectsExternalEditAndFocusChangeBeforeNextOperation() async throws {
        for change in [ReplayTargetChange.externalEdit, .focus] {
            let before = "草稿"
            let access = ReplayAXTextTargetAccess(
                text: before,
                selection: .init(location: before.utf16.count, length: 0),
                application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
            )
            access.textAttributesAreSettable = true
            let target = AXTextTarget(access: access, acknowledgementTimeoutNanoseconds: 20_000_000)
            let injector = TextInjector(target: target)

            try injector.begin()
            injector.apply(projection: projection("甲", revision: 1))
            try await injector.finish(finalText: "甲")
            let writesBeforeChange = access.axTextWrites
            switch change {
            case .externalEdit:
                access.externalEdit("用户编辑")
            case .focus:
                access.focusChanged = true
            }
            injector.apply(projection: projection("甲乙", revision: 2))
            try await injector.finish(finalText: "甲乙")

            XCTAssertEqual(access.axTextWrites, writesBeforeChange)
            XCTAssertEqual(injector.errorCount, 1)
            XCTAssertEqual(injector.degradationCode, "text_target_changed")
        }
    }

    func testAXWritePersistentReadFailureStopsAfterSingleSubmission() async throws {
        let before = "草稿"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: before.utf16.count, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.onAXTextWrite = { access.persistentTextReadError = KeyboardWriteReadError.retryable }
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("甲", revision: 1))
        await finish(injector, finalText: "甲", advancing: clock)

        XCTAssertEqual(access.axTextWrites, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.degradationCode, "text_target_write_failed")
        let diagnostics = injector.drainDiagnostics()
        let failure = try XCTUnwrap(diagnostics.first { $0.event == "ax_write_unconfirmed" })
        XCTAssertEqual(failure.fields["axFirstReadErrorCode"], "ax_read_retryable")
        XCTAssertGreaterThan(Int(failure.fields["axReadAttempts"] ?? "0") ?? 0, 1)
    }

    func testAXWriteCancellationInvalidatesLateReadbackWithoutSecondSubmission() async throws {
        let before = "草稿"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: before.utf16.count, length: 0),
            application: .init(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.axWriteNoOp = true
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("甲", revision: 1))
        let finishTask = Task { try? await injector.finish(finalText: "甲") }
        for _ in 0..<30 {
            await Task.yield()
            if access.axTextWrites == 1 { break }
        }
        injector.cancel()
        clock.advance(by: 100_000_000)
        for _ in 0..<30 { await Task.yield() }
        await finishTask.value

        XCTAssertEqual(access.axTextWrites, 1)
        XCTAssertEqual(access.rawText, before)
        XCTAssertEqual(injector.modeDescription, "inactive")
    }

    func testCodexMainAndCommentReplayAcceptMoreThanThousandCharacters() async throws {
        for placeholder in ["询问任何问题", "\n添加可选评论…"] {
            let access = ReplayAXTextTargetAccess(
                text: placeholder,
                selection: .init(location: 0, length: 0),
                placeholderEvidence: .init(markedTexts: [placeholder.trimmingCharacters(in: .newlines)]),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            let sender = ReplayKeyboardEventSender(access: access)
            let clock = ManualKeyboardPacingClock()
            let target = AXTextTarget(access: access, keyboardEventSender: sender,
                writeTiming: .init(now: { clock.nowNanoseconds }, sleep: { try await clock.sleep(nanoseconds: $0) }))
            let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)
            try injector.begin()
            var accumulator = ASRProjectionAccumulator()
            var expected = ""
            for segment in 0..<24 {
                let sentence = "第\(segment)句。" + String(repeating: "长语音输入应当保留灵感", count: 5) + "😀。"
                expected += sentence
                let update = ASRUpdate(text: sentence, isFinal: true, sequence: segment)
                injector.apply(projection: try XCTUnwrap(accumulator.apply(update)))
                for _ in 0..<180 {
                    await Task.yield()
                    clock.advance(by: 10_000_000)
                }
                XCTAssertEqual(injector.errorCount, 0, placeholder)
            }
            injector.apply(projection: try XCTUnwrap(accumulator.apply(.streamEnded)))
            await finish(injector, finalText: expected, advancing: clock)
            XCTAssertGreaterThan(expected.count, 1000)
            XCTAssertEqual(access.rawText, expected, placeholder)
            XCTAssertEqual(injector.modeDescription, "keyboard_live_tail", placeholder)
            XCTAssertEqual(injector.errorCount, 0, placeholder)
            injector.cancel()
        }
    }

    func testCodexReconciliationRetriesTransientCoordinateMismatch() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿", application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        _ = try target.capture()
        access.coordinateOverride = "旧稿"
        XCTAssertEqual(try target.reconcileKeyboardStateForUserEdit(), .matched)
        XCTAssertEqual(sender.totalPosts, 0, "An inconsistent read must not send input")
        access.coordinateOverride = nil
        XCTAssertEqual(try target.reconcileKeyboardStateForUserEdit(), .matched)
        try target.paste("继续")
        try await target.acknowledgeKeyboardWrite()
        XCTAssertEqual(access.rawText, "草稿继续")
    }

    func testRealAXReplayRetriesTransientPreflightReadWithoutDegrading() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "Draft: ",
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("first wrong", revision: 1))
        await finish(injector, finalText: "first wrong", advancing: clock)
        XCTAssertEqual(access.rawText, "Draft: first wrong")
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(clock.sleepCallCount, 0, "a matching first observation is immediate")

        access.failNextTextReads = 1
        access.failNextSelectionReads = 1
        injector.apply(projection: projection("first corrected", revision: 2))
        await finish(injector, finalText: "first corrected", advancing: clock)

        XCTAssertEqual(access.rawText, "Draft: first corrected")
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertGreaterThanOrEqual(clock.sleepCallCount, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertEqual(injector.writeCount, 2)
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains { $0.event == "keyboard_state_read_retryable" })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_confirmed_state_changed" })
        let operation = try XCTUnwrap(
            diagnostics.first {
                $0.event == "input_operation" && $0.fields["revision"] == "2"
            }
        )
        XCTAssertEqual(operation.fields["segmentID"], "1")
        XCTAssertEqual(operation.fields["operationStatus"], "acknowledged")
        XCTAssertEqual(operation.fields["targetCompletionConfirmed"], "true")
        XCTAssertEqual(operation.fields["localDispatchCompleted"], "true")
        XCTAssertNotNil(operation.fields["dispatchStartedMonotonicMilliseconds"])
        XCTAssertNotNil(operation.fields["feedbackObservedMonotonicMilliseconds"])
    }

    func testRealAXReplayRetriesTransientIdentityFocusReadWithoutDegrading() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "Draft: ",
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        access.failFocusedElementReadAtCount = access.focusedElementReadCount + 3
        injector.apply(projection: projection("voice input", revision: 1))
        await finish(injector, finalText: "voice input", advancing: clock)

        XCTAssertEqual(access.rawText, "Draft: voice input")
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertGreaterThanOrEqual(clock.sleepCallCount, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertEqual(injector.writeCount, 1)
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(
            diagnostics.contains {
                $0.event == "keyboard_state_read_retryable"
                    && $0.fields["phase"] == "identity_check"
            }
        )
    }

    func testRealAXReplayDoesNotStallAtFirstCharacterAfterFinalSegmentBoundary() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿\n",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: segmentProjection(
            committed: "",
            active: "第一句话",
            id: 1,
            revision: 1
        ))
        injector.apply(projection: segmentProjection(
            committed: "",
            active: "第一句话",
            id: 1,
            revision: 2,
            isFinal: true
        ))

        // A brief pause lets the first segment enter its final flush while the
        // next segment starts arriving, which is the observed user path.
        for _ in 0..<2 {
            await Task.yield()
            clock.advance(by: 10_000_000)
        }

        injector.apply(projection: segmentProjection(
            committed: "第一句话",
            active: "我",
            id: 2,
            revision: 3
        ))
        injector.apply(projection: segmentProjection(
            committed: "第一句话",
            active: "我的",
            id: 2,
            revision: 4
        ))
        injector.apply(projection: segmentProjection(
            committed: "第一句话",
            active: "我的内",
            id: 2,
            revision: 5
        ))
        injector.apply(projection: segmentProjection(
            committed: "第一句话",
            active: "我的内裤",
            id: 2,
            revision: 6,
            isFinal: true
        ))

        for _ in 0..<300 {
            await Task.yield()
            clock.advance(by: 10_000_000)
        }

        XCTAssertEqual(access.rawText, "草稿\n第一句话我的内裤")
        XCTAssertEqual(access.coordinateText, "草稿第一句话我的内裤")
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertEqual(injector.errorCount, 0)
    }

    func testRealAXReplayHandlesManualNewlineBeforeRestartedSession() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿",
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: projection("第一句话", revision: 1))
        await finish(injector, finalText: "第一句话", advancing: clock)
        XCTAssertEqual(access.rawText, "草稿第一句话")
        let postsBeforeRestart = sender.appendPosts

        // This is the independent AX snapshot observed after the first
        // recording ended and the user inserted a newline manually. The next
        // write will publish AXValue with the newline retained while its range
        // text collapses that trailing separator.
        access.coordinateIncludesStructuralSeparators = true
        access.rawText.append("\n")
        access.selection = .init(location: "草稿第一句话".utf16.count, length: 0)
        access.collapseStructuralSeparatorsAfterNextWrite = true
        XCTAssertEqual(access.rawText, "草稿第一句话\n")
        XCTAssertEqual(access.coordinateText, "草稿第一句话\n")
        XCTAssertEqual(access.selection, .init(location: "草稿第一句话".utf16.count, length: 0))

        try injector.begin()
        injector.apply(projection: projection("乙", revision: 1))
        await finish(injector, finalText: "乙", advancing: clock)
        injector.apply(projection: projection("乙后", revision: 2))
        await finish(injector, finalText: "乙后", advancing: clock)
        injector.apply(projection: projection("乙", revision: 3))
        await finish(injector, finalText: "乙", advancing: clock)

        XCTAssertEqual(access.rawText, "草稿第一句话\n乙")
        XCTAssertEqual(access.coordinateText, "草稿第一句话乙")
        XCTAssertEqual(access.selection, .init(location: "草稿第一句话乙".utf16.count, length: 0))
        XCTAssertEqual(sender.appendPosts, postsBeforeRestart + 2, "the restarted line is sent once per growth step")
        XCTAssertEqual(sender.replacementPosts, 1, "later revision uses the existing trailing replacement path")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        let diagnostics = injector.drainDiagnostics()
        let acknowledgement = try XCTUnwrap(
            diagnostics.first {
                $0.event == "keyboard_write_acknowledged"
                    && $0.fields["receiptRepresentationTransition"] == "trailing_newline_collapsed"
            }
        )
        XCTAssertEqual(acknowledgement.fields["receiptRepresentationTransition"], "trailing_newline_collapsed")
    }

    func testRealAXReplayHandlesMultipleEmptyParagraphsBeforeRestartedSession() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿",
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: projection("第一句话", revision: 1))
        await finish(injector, finalText: "第一句话", advancing: clock)
        let prefix = "草稿第一句话"
        let emptyParagraphCount = 3
        let beforeRestart = prefix + String(repeating: "\n", count: emptyParagraphCount)
        let afterFirst = prefix
            + String(repeating: "\n", count: emptyParagraphCount - 1)
            + "乙"
        let afterSecond = afterFirst + "后"

        // The first finish represents stopping the recording. The following
        // snapshot is the document after three manual Shift+Return presses.
        access.rawText = beforeRestart
        access.coordinateOverride = beforeRestart
        access.selection = .init(location: beforeRestart.utf16.count - 1, length: 0)
        access.writeSnapshots = [
            .init(
                rawText: afterFirst,
                coordinateText: afterFirst,
                selection: .init(location: afterFirst.utf16.count, length: 0)
            ),
            .init(
                rawText: afterSecond,
                coordinateText: afterSecond,
                selection: .init(location: afterSecond.utf16.count, length: 0)
            )
        ]
        let postsBeforeRestart = sender.appendPosts

        try injector.begin()
        injector.apply(projection: projection("乙", revision: 1))
        await finish(injector, finalText: "乙", advancing: clock)
        injector.apply(projection: projection("乙后", revision: 2))
        await finish(injector, finalText: "乙后", advancing: clock)

        XCTAssertEqual(access.rawText, afterSecond)
        XCTAssertEqual(sender.appendPosts, postsBeforeRestart + 2)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testRealAXReplayHandlesTwoEmptyParagraphsFromChromiumSnapshot() async throws {
        // Independently sampled from macOS AX on Chromium 152.0.7977.84:
        // <p>甲</p><p><br></p><p><br></p> -> <p>甲</p><p><br></p><p>乙</p>.
        // Unlike the one-newline case, AXValue loses the final placeholder LF.
        let access = ReplayAXTextTargetAccess(
            text: "甲\n\n",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲\n\n"
        access.writeSnapshots = [
            .init(rawText: "甲\n乙", coordinateText: "甲\n乙", selection: .init(location: 3, length: 0)),
            .init(rawText: "甲\n乙丙", coordinateText: "甲\n乙丙", selection: .init(location: 4, length: 0))
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)
        try injector.begin()
        injector.apply(projection: projection("乙", revision: 1))
        await finish(injector, finalText: "乙", advancing: clock)
        injector.apply(projection: projection("乙丙", revision: 2))
        await finish(injector, finalText: "乙丙", advancing: clock)

        XCTAssertEqual(access.rawText, "甲\n乙丙", "speech must continue beyond the first character")
        XCTAssertEqual(sender.appendPosts, 2, "each growth is posted once")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testRealAXReplayHandlesArbitraryTrailingEmptyParagraphCount() async throws {
        for emptyParagraphCount in [2, 3, 4, 8, 32, 128] {
            let prefix = "草稿第一句"
            let trailingSeparators = String(repeating: "\n", count: emptyParagraphCount)
            let firstRawText = prefix + trailingSeparators
            let afterFirstText = prefix
                + String(repeating: "\n", count: emptyParagraphCount - 1)
                + "乙"
            let afterSecondText = afterFirstText + "丙"
            let access = ReplayAXTextTargetAccess(
                text: firstRawText,
                selection: .init(location: firstRawText.utf16.count - 1, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = firstRawText
            access.writeSnapshots = [
                .init(
                    rawText: afterFirstText,
                    coordinateText: afterFirstText,
                    selection: .init(location: afterFirstText.utf16.count, length: 0)
                ),
                .init(
                    rawText: afterSecondText,
                    coordinateText: afterSecondText,
                    selection: .init(location: afterSecondText.utf16.count, length: 0)
                )
            ]
            let sender = ReplayKeyboardEventSender(access: access)
            let clock = ManualKeyboardPacingClock()
            let target = AXTextTarget(
                access: access,
                keyboardEventSender: sender,
                writeTiming: .init(
                    now: { clock.nowNanoseconds },
                    sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
                ),
                acknowledgementTimeoutNanoseconds: 20_000_000
            )
            let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

            try injector.begin()
            injector.apply(projection: projection("乙", revision: 1))
            await finish(injector, finalText: "乙", advancing: clock)
            injector.apply(projection: projection("乙丙", revision: 2))
            await finish(injector, finalText: "乙丙", advancing: clock)

            XCTAssertEqual(access.rawText, afterSecondText, "failed at (emptyParagraphCount) trailing empty paragraphs")
            XCTAssertEqual(sender.appendPosts, 2, "failed at (emptyParagraphCount) trailing empty paragraphs")
            XCTAssertEqual(injector.errorCount, 0, "failed at (emptyParagraphCount) trailing empty paragraphs")
            XCTAssertEqual(injector.modeDescription, "keyboard_live_tail", "failed at (emptyParagraphCount) trailing empty paragraphs")
        }
    }

    func testRealAXReplayRejectsTransitionWithDifferentRawDocument() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿\n",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateIncludesStructuralSeparators = true
        access.collapseStructuralSeparatorsAfterNextWrite = true
        access.transitionRawOverride = "草稿\n乙\n"
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: projection("乙", revision: 1))
        await finish(injector, finalText: "乙", advancing: clock)

        XCTAssertEqual(access.rawText, "草稿\n乙\n")
        XCTAssertEqual(access.coordinateText, "草稿乙")
        XCTAssertEqual(sender.appendPosts, 1, "a rejected receipt must not resend the character")
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(
            diagnostics.contains {
                $0.event == "keyboard_write_unconfirmed"
                    && $0.fields["comparison"] != "matched"
            }
        )
        let failure = try XCTUnwrap(diagnostics.last { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(failure.fields["ackDiffEarly0OperationRangeAvailable"], "true")
        XCTAssertEqual(failure.fields["ackDiffFinal0OperationRangeAvailable"], "true")
    }

    func testDiagnosticDiffIsAttachedToEarlyAndFinalCodexFailureObservations() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲\n乙",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲乙"
        access.writeSnapshots = [
            .init(
                rawText: "甲丙\n乙",
                coordinateText: "甲丙乙",
                selection: .init(location: 2, length: 0)
            )
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        var now: UInt64 = 0
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { now }, sleep: { now += $0 }),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("丙")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("the structural mismatch must remain unconfirmed")
        } catch { }

        let failure = try XCTUnwrap(target.drainDiagnostics().last { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(failure.fields["ackDiffEarly0Classification"], "structural_local")
        XCTAssertEqual(failure.fields["ackDiffFinal0Classification"], "structural_local")
        XCTAssertEqual(failure.fields["ackDiffEarly0CoordinateUnit"], "UTF16")
        XCTAssertEqual(failure.fields["ackDiffFinal0MappingValid"], "true")
        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testRealAXReplayContinuesAfterStructuralNewlineAtSegmentBoundary() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿\n",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target, keyboardSmoothing: .live, pacingClock: clock)

        try injector.begin()
        injector.apply(projection: segmentProjection(
            committed: "",
            active: "我",
            id: 1,
            revision: 1,
            isFinal: true
        ))
        injector.apply(projection: segmentProjection(
            committed: "我\n",
            active: "的",
            id: 2,
            revision: 2
        ))
        injector.apply(projection: segmentProjection(
            committed: "我\n",
            active: "的内",
            id: 2,
            revision: 3
        ))
        injector.apply(projection: segmentProjection(
            committed: "我\n",
            active: "的内裤，我的内裤。",
            id: 2,
            revision: 4,
            isFinal: true
        ))

        let completion = Task { try? await injector.finish(finalText: "我\n的内裤，我的内裤。") }
        for _ in 0..<600 {
            await Task.yield()
            clock.advance(by: 10_000_000)
        }
        await completion.value

        XCTAssertEqual(access.rawText, "草稿\n我\n的内裤，我的内裤。")
        XCTAssertEqual(access.coordinateText, "草稿我的内裤，我的内裤。")
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertEqual(injector.errorCount, 0)
    }

    func testRealAXReplayStopsImmediatelyOnPermissionFailure() {
        let access = ReplayAXTextTargetAccess(
            text: "Draft: ",
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        access.permissionError = .accessibilityDenied
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        XCTAssertThrowsError(try target.capture()) { error in
            XCTAssertEqual(error as? TextTargetError, .accessibilityDenied)
        }
        XCTAssertEqual(access.textReadCount, 0)
        XCTAssertEqual(sender.totalPosts, 0)
    }

    func testRealAXReplayUsesCoordinateMappingForMultilineUnicodeAndTransientCoordinateRead() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "第一\n第二",
            selection: .init(location: 4, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("世界", revision: 1))
        await finish(injector, finalText: "世界", advancing: clock)
        XCTAssertEqual(access.rawText, "第一\n第二世界")
        XCTAssertEqual(access.coordinateText, "第一第二世界")

        access.failNextCoordinateReads = 1
        injector.apply(projection: projection("世😀", revision: 2))
        await finish(injector, finalText: "世😀", advancing: clock)

        XCTAssertEqual(access.rawText, "第一\n第二世😀")
        XCTAssertEqual(access.coordinateText, "第一第二世😀")
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testRealAXReplayAcceptsLeadingStructuralSeparatorDuringRevision() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n草稿",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("新增草", revision: 1))
        try await injector.finish(finalText: "新增草")
        injector.apply(projection: projection("新增后", revision: 2))
        try await injector.finish(finalText: "新增后")

        XCTAssertEqual(access.rawText, "\n草稿新增后")
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testRealAXReplayUsesKeyboardSelectionInCoordinateSpace() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "第一\n第二",
            selection: .init(location: 4, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectionRangeIsSettable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("世界", revision: 1))
        try await injector.finish(finalText: "世界")
        injector.apply(projection: projection("世😀", revision: 2))
        try await injector.finish(finalText: "世😀")

        XCTAssertEqual(access.rawText, "第一\n第二世😀")
        XCTAssertEqual(access.coordinateText, "第一第二世😀")
        XCTAssertEqual(access.selection, .init(location: 7, length: 0))
        XCTAssertEqual(sender.selectionPosts, 1, "Codex revisions use keyboard selection events")
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
    }

    func testRealAXReplayStopsWithoutSendingAfterExternalEditOrFocusChange() async throws {
        for change in [ReplayTargetChange.externalEdit, .focus] {
            let access = ReplayAXTextTargetAccess(
                text: "Draft: ",
                application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
            )
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(access: access, keyboardEventSender: sender)
            let injector = TextInjector(target: target)

            try injector.begin()
            injector.apply(projection: projection("first", revision: 1))
            try await injector.finish(finalText: "first")
            let postsBeforeChange = sender.totalPosts

            switch change {
            case .externalEdit:
                access.externalEdit("Draft: user edit")
            case .focus:
                access.focusChanged = true
            }
            injector.apply(projection: projection("first next", revision: 2))
            try await injector.finish(finalText: "first next")

            XCTAssertEqual(sender.totalPosts, postsBeforeChange)
            XCTAssertEqual(injector.errorCount, 1)
            XCTAssertEqual(injector.degradationCode, "text_target_changed")
            XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        }
    }

    func testRealAXReplayCancellationDuringPreflightDoesNotSend() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "Draft: ",
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target)
        try injector.begin()
        access.failNextTextReads = 1
        injector.apply(projection: projection("cancelled", revision: 1))

        for _ in 0..<30 {
            await Task.yield()
            if access.textReadCount >= 2 { break }
        }
        XCTAssertEqual(sender.totalPosts, 0)
        injector.cancel()
        clock.advance(by: 10_000_000)
        for _ in 0..<30 { await Task.yield() }

        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertEqual(access.rawText, "Draft: ")
    }

    func testRealAXReplayKeepsPersistentReadFailureUnconfirmedWithoutSending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "Draft: ",
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            preflightTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        access.alwaysFailTextReads = true
        injector.apply(projection: projection("never sent", revision: 1))
        await finish(injector, finalText: "never sent", advancing: clock)

        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertEqual(access.rawText, "Draft: ")
        XCTAssertEqual(injector.degradationCode, "text_target_write_failed")
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
    }

    func testRealAXReplayDoesNotInsertWhenSelectionOperationIsLost() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "Draft: ",
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            ),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("first wrong", revision: 1))
        await finish(injector, finalText: "first wrong", advancing: clock)
        sender.dropNextSelection = true
        injector.apply(projection: projection("first corrected", revision: 2))
        await finish(injector, finalText: "first corrected", advancing: clock)

        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 0)
        XCTAssertEqual(access.rawText, "Draft: first wrong")
        XCTAssertEqual(injector.degradationCode, "text_target_write_failed")
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
    }

    func testRealAXReplayContinuesFor43ResultsAfterRecovery() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿\n",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        access.failNextCoordinateReads = 1
        injector.apply(projection: projection("初始", revision: 1))
        await finish(injector, finalText: "初始", advancing: clock)
        var finalText = "初始"
        for index in 1...43 {
            finalText = "结果" + String(repeating: "续", count: index)
            injector.apply(projection: projection(finalText, revision: UInt64(index + 1)))
            try await injector.finish(finalText: finalText)
        }

        XCTAssertEqual(access.rawText, "草稿\n" + finalText)
        XCTAssertEqual(sender.totalPosts, 44)
        XCTAssertEqual(injector.writeCount, 44)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testRealAXReplayCoalesces43ResultsWhilePreflightIsPaused() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "Draft: ",
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { nanoseconds in try await clock.sleep(nanoseconds: nanoseconds) }
            )
        )
        let injector = TextInjector(target: target)

        try injector.begin()
        access.failNextTextReads = 1
        injector.apply(projection: projection("开始", revision: 1))
        for _ in 0..<30 {
            await Task.yield()
            if access.textReadCount >= 2 { break }
        }
        for index in 1...43 {
            injector.apply(projection: projection("候选\(index)", revision: UInt64(index + 1)))
        }
        await finish(injector, finalText: "候选43", advancing: clock)

        XCTAssertEqual(access.rawText, "Draft: 候选43")
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertEqual(injector.writeCount, 2)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testRealAXReplayReplacesPlaceholderRepresentationOnce() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n添加可选评论…",
            selection: .init(location: 0, length: 0),
            placeholderEvidence: .init(markedTexts: ["添加可选评论…"]),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("你好世界😀", revision: 1))
        try await injector.finish(finalText: "你好世界😀")

        XCTAssertEqual(access.rawText, "你好世界😀")
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    private func finish(
        _ injector: TextInjector,
        finalText: String,
        advancing clock: ManualKeyboardPacingClock
    ) async {
        let task = Task { try? await injector.finish(finalText: finalText) }
        for _ in 0..<600 {
            await Task.yield()
            clock.advance(by: 10_000_000)
        }
        await task.value
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

    private func segmentProjection(
        committed: String,
        active: String,
        id: Int,
        revision: UInt64,
        isFinal: Bool = false
    ) -> ASRProjection {
        ASRProjection(
            committedText: committed,
            activeSegmentText: active,
            activeSegmentID: id,
            activeIsFinal: isFinal,
            revision: revision,
            changed: true,
            isFinal: isFinal
        )
    }
}

private enum ReplayTargetChange: Equatable {
    case externalEdit
    case focus
}

private enum ReplaySelectionRoute {
    case accessibility
    case keyboard
}

private struct ReplayAXSnapshot {
    let rawText: String
    let coordinateText: String
    let selection: ReplayTextRange
}

@MainActor
private final class ReplayAXTextTargetAccess: AXTextTargetAccess {
    let element = AXUIElementCreateApplication(9001)
    private let otherElement = AXUIElementCreateApplication(9002)
    let application: TextTargetApplication
    var currentApplicationOverride: TextTargetApplication?
    var rawText: String
    var selection: ReplayTextRange
    var placeholderEvidenceValue: AXPlaceholderEvidence
    var failNextTextReads = 0
    var nextTextReadError: (any Error)?
    var persistentTextReadError: (any Error)?
    var nextSelectionReadError: (any Error)?
    var onTextReadFailure: (() -> Void)?
    var alwaysFailTextReads = false
    var failNextSelectionReads = 0
    var failNextCoordinateReads = 0
    var permissionError: TextTargetError?
    var selectionRangeIsSettable = false
    var proseMirror = false
    private var ancestorRoles: [Int: String] = [:]
    private var ancestorParents: [Int: Int] = [:]
    private var ancestorWebURL: URL?
    private var usesAncestorScanner = false
    var textAttributesAreSettable = false
    var selectedTextAttributeIsSettable: Bool?
    var valueAttributeIsSettable: Bool?
    private(set) var axTextWrites = 0
    var onAXTextWrite: (() -> Void)?
    var focusChanged = false
    var focusedElementRebuildsBeforeNextWrite = 0
    var focusedElementRebuildsAfterNextWrite = 0
    private var focusedElementRebuildCount = 0
    var failFocusedElementReadAtCount: Int?
    private(set) var focusedElementReadCount = 0
    var readSnapshotsAfterNextWrite: [ReplayAXSnapshot] = []
    var queuedTextReadSnapshots: [ReplayAXSnapshot] = []
    var coordinateIncludesStructuralSeparators = false
    var collapseStructuralSeparatorsAfterNextWrite = false
    var transitionRawOverride: String?
    var coordinateOverride: String?
    var writeSnapshots: [ReplayAXSnapshot] = []
    var axWriteNoOp = false
    var axWriteReadSnapshotsByWrite: [[ReplayAXSnapshot]] = []
    var simulateAccessibilityEmptyParagraphCollapse = false
    private(set) var lastSelectionRoute: ReplaySelectionRoute?

    func markKeyboardSelectionRoute() {
        lastSelectionRoute = .keyboard
    }
    private(set) var textReadCount = 0
    private(set) var coordinateReadCount = 0

    var coordinateText: String {
        if let coordinateOverride { return coordinateOverride }
        if coordinateIncludesStructuralSeparators {
            return rawText
        }
        return rawText.filter { $0 != "\n" && $0 != "\r" && $0 != "\u{2028}" && $0 != "\u{2029}" }
    }

    init(
        text: String,
        selection: ReplayTextRange? = nil,
        placeholderEvidence: AXPlaceholderEvidence = .init(),
        application: TextTargetApplication
    ) {
        rawText = text
        self.selection = selection ?? .init(location: text.utf16.count, length: 0)
        placeholderEvidenceValue = placeholderEvidence
        self.application = application
    }

    func requestInputPermissions() throws {
        if let permissionError { throw permissionError }
    }
    func currentApplication() -> TextTargetApplication? { currentApplicationOverride ?? application }

    func focusedElement() throws -> AXUIElement {
        focusedElementReadCount += 1
        if failFocusedElementReadAtCount == focusedElementReadCount {
            failFocusedElementReadAtCount = nil
            throw KeyboardWriteReadError.retryable
        }
        if focusedElementRebuildsBeforeNextWrite > 0 {
            focusedElementRebuildsBeforeNextWrite -= 1
            return rebuiltElement
        }
        if focusedElementRebuildCount > 0 {
            focusedElementRebuildCount -= 1
            return rebuiltElement
        }
        return focusChanged ? otherElement : element
    }

    private let rebuiltElement = AXUIElementCreateApplication(9003)

    func processIdentifier(of element: AXUIElement) -> pid_t? { 9001 }

    func textInputContext(for element: AXUIElement) -> AXTextInputTargetContext? {
        if usesAncestorScanner {
            let scan = AXTextAncestorScanner.scan(
                start: 0,
                role: { ancestorRoles[$0] },
                parent: { ancestorParents[$0] },
                equals: ==
            )
            return AXTextInputTargetContext(
                role: ancestorRoles[0],
                hasWebAreaAncestor: scan.status == .webArea,
                webURL: scan.status == .webArea ? ancestorWebURL : nil,
                isReadOnly: false,
                isSecure: false,
                ancestorScanStatus: scan.status,
                webAreaDepth: scan.webAreaDepth
            )
        }
        return nil
    }

    func configureWebAncestorChain(depth: Int, webURL: URL? = nil, role: String = "AXTextArea") {
        usesAncestorScanner = true
        ancestorRoles = [0: role]
        ancestorParents = [:]
        guard depth > 0 else {
            ancestorRoles[0] = "AXWebArea"
            ancestorWebURL = webURL
            return
        }
        for node in 1...depth {
            ancestorRoles[node] = node == depth ? "AXWebArea" : "AXGroup"
            ancestorParents[node - 1] = node
        }
        ancestorWebURL = webURL
    }

    func configureNativeAncestorChain(role: String = "AXTextArea") {
        usesAncestorScanner = true
        ancestorRoles = [0: role]
        ancestorParents = [:]
        ancestorWebURL = nil
    }

    func configureCyclicAncestorChain(role: String = "AXTextArea") {
        usesAncestorScanner = true
        ancestorRoles = [0: role]
        ancestorParents = [0: 0]
        ancestorWebURL = nil
    }

    func text(in element: AXUIElement) throws -> String? {
        textReadCount += 1
        if let error = persistentTextReadError { throw error }
        if let error = nextTextReadError {
            nextTextReadError = nil
            onTextReadFailure?()
            onTextReadFailure = nil
            throw error
        }
        if !queuedTextReadSnapshots.isEmpty {
            let snapshot = queuedTextReadSnapshots.removeFirst()
            rawText = snapshot.rawText
            coordinateOverride = snapshot.coordinateText
            selection = snapshot.selection
        }
        if alwaysFailTextReads || failNextTextReads > 0 {
            if failNextTextReads > 0 { failNextTextReads -= 1 }
            throw KeyboardWriteReadError.retryable
        }
        return rawText
    }

    func selection(in element: AXUIElement) throws -> ReplayTextRange? {
        if let error = nextSelectionReadError {
            nextSelectionReadError = nil
            throw error
        }
        if failNextSelectionReads > 0 {
            failNextSelectionReads -= 1
            throw KeyboardWriteReadError.retryable
        }
        return selection
    }

    func coordinateText(for range: ReplayTextRange, in element: AXUIElement) throws -> String? {
        coordinateReadCount += 1
        if failNextCoordinateReads > 0 {
            failNextCoordinateReads -= 1
            throw KeyboardWriteReadError.retryable
        }
        let text = coordinateText
        guard range.location >= 0,
              range.length >= 0,
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location else {
            return nil
        }
        return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }

    func placeholderEvidence(in element: AXUIElement) -> AXPlaceholderEvidence {
        placeholderEvidenceValue
    }

    func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        if attribute == (kAXSelectedTextRangeAttribute as String) {
            return selectionRangeIsSettable
        }
        if attribute == (kAXSelectedTextAttribute as String) {
            return selectedTextAttributeIsSettable ?? textAttributesAreSettable
        }
        if attribute == (kAXValueAttribute as String) {
            return valueAttributeIsSettable ?? textAttributesAreSettable
        }
        return false
    }

    func isProseMirrorEditor(_ element: AXUIElement) -> Bool {
        proseMirror && !CFEqual(element, otherElement)
    }

    func setSelection(_ range: ReplayTextRange, on element: AXUIElement) throws -> Int32 {
        lastSelectionRoute = .accessibility
        selection = range
        return AXError.success.rawValue
    }

    func setSelectedText(_ text: String, on element: AXUIElement) throws -> Int32 {
        axTextWrites += 1
        onAXTextWrite?()
        onAXTextWrite = nil
        if !axWriteNoOp {
            applyReplacement(text, range: selection)
        }
        if !axWriteReadSnapshotsByWrite.isEmpty {
            queuedTextReadSnapshots = axWriteReadSnapshotsByWrite.removeFirst()
        }
        return AXError.success.rawValue
    }

    func setValue(_ text: String, on element: AXUIElement) throws -> Int32 {
        axTextWrites += 1
        onAXTextWrite?()
        onAXTextWrite = nil
        if !axWriteNoOp {
            rawText = text
            selection = .init(location: coordinateText.utf16.count, length: 0)
        }
        placeholderEvidenceValue = .init()
        if !axWriteReadSnapshotsByWrite.isEmpty {
            queuedTextReadSnapshots = axWriteReadSnapshotsByWrite.removeFirst()
        }
        return AXError.success.rawValue
    }

    func externalEdit(_ text: String) {
        rawText = text
        selection = .init(location: coordinateText.utf16.count, length: 0)
    }

    func applyAppend(_ text: String) {
        if placeholderEvidenceValue != .init() {
            rawText = text
            let coordinateLength = text
                .filter { $0 != "\n" && $0 != "\r" && $0 != "\u{2028}" && $0 != "\u{2029}" }
                .utf16.count
            selection = .init(location: coordinateLength, length: 0)
            placeholderEvidenceValue = .init()
            return
        }
        applyReplacement(text, range: selection)
    }

    func applyReplacement(_ text: String, range: ReplayTextRange) {
        if !writeSnapshots.isEmpty {
            let snapshot = writeSnapshots.removeFirst()
            rawText = snapshot.rawText
            coordinateOverride = snapshot.coordinateText
            selection = snapshot.selection
            return
        }
        var rawRange = rawRange(for: range)
        let rawUTF16 = Array(rawText.utf16)
        let movesInsertionAfterTrailingNewline = collapseStructuralSeparatorsAfterNextWrite
            && range.length == 0
            && rawRange.length == 0
            && rawRange.location < rawUTF16.count
            && rawUTF16[rawRange.location] == 0x0A
        if movesInsertionAfterTrailingNewline {
            rawRange.location += 1
        }
        let mutable = NSMutableString(string: rawText)
        mutable.replaceCharacters(in: NSRange(location: rawRange.location, length: rawRange.length), with: text)
        rawText = mutable as String
        if lastSelectionRoute == .accessibility,
           simulateAccessibilityEmptyParagraphCollapse {
            let replacementEnd = rawRange.location + text.utf16.count
            let units = Array(rawText.utf16)
            if replacementEnd < units.count, units[replacementEnd] == 0x0A {
                let collapsed = NSMutableString(string: rawText)
                collapsed.deleteCharacters(in: NSRange(location: replacementEnd, length: 1))
                rawText = collapsed as String
            }
        }
        if movesInsertionAfterTrailingNewline {
            collapseStructuralSeparatorsAfterNextWrite = false
            coordinateIncludesStructuralSeparators = false
            if let transitionRawOverride {
                rawText = transitionRawOverride
                self.transitionRawOverride = nil
            }
        }
        // Codex's AX coordinate space omits structural line separators. A
        // keyboard insertion still changes AXValue, but the reported caret
        // advances only by the coordinate-visible portion of the insertion.
        let coordinateInsertionLength = text
            .filter { $0 != "\n" && $0 != "\r" && $0 != "\u{2028}" && $0 != "\u{2029}" }
            .utf16.count
        selection = .init(location: range.location + coordinateInsertionLength, length: 0)
        placeholderEvidenceValue = .init()
    }

    func armPostWriteReplay() {
        focusedElementRebuildCount = focusedElementRebuildsAfterNextWrite
        focusedElementRebuildsAfterNextWrite = 0
        queuedTextReadSnapshots = readSnapshotsAfterNextWrite
        readSnapshotsAfterNextWrite.removeAll()
    }

    private func rawRange(for range: ReplayTextRange) -> ReplayTextRange {
        if placeholderEvidenceValue != .init() {
            return .init(location: 0, length: rawText.utf16.count)
        }
        let coordinateScalars = Array(coordinateText.unicodeScalars)
        var coordinateIndex = 0
        var coordinateOffset = 0
        var rawOffset = 0
        var boundaries = Array(repeating: -1, count: coordinateText.utf16.count + 1)
        boundaries[0] = 0
        for scalar in rawText.unicodeScalars {
            if coordinateIndex < coordinateScalars.count, scalar == coordinateScalars[coordinateIndex] {
                let length = scalar.utf16.count
                rawOffset += length
                coordinateOffset += length
                boundaries[coordinateOffset] = rawOffset
                coordinateIndex += 1
            } else if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                rawOffset += scalar.utf16.count
                boundaries[coordinateOffset] = rawOffset
            }
        }
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length < boundaries.count,
              boundaries[range.location] >= 0,
              boundaries[range.location + range.length] >= boundaries[range.location] else {
            return .init(location: rawText.utf16.count, length: 0)
        }
        return .init(
            location: boundaries[range.location],
            length: boundaries[range.location + range.length] - boundaries[range.location]
        )
    }
}

@MainActor
private final class ReplayKeyboardEventSender: AXTextTargetKeyboardEventSending {
    let access: ReplayAXTextTargetAccess
    private var pendingSelection: ReplayTextRange?
    private(set) var appendPosts = 0
    private(set) var selectionPosts = 0
    private(set) var replacementPosts = 0
    var dropNextSelection = false
    var appendOverride: ((String) -> Void)?
    var onReplacement: (() -> Void)?

    var totalPosts: Int { appendPosts + replacementPosts }

    init(access: ReplayAXTextTargetAccess) {
        self.access = access
    }

    func selectTrailingText(_ previousText: String, processID: pid_t?) throws {
        selectionPosts += 1
        access.markKeyboardSelectionRoute()
        let location = access.selection.location - previousText.utf16.count
        pendingSelection = .init(location: location, length: previousText.utf16.count)
        if dropNextSelection {
            dropNextSelection = false
        } else {
            access.selection = pendingSelection!
        }
    }

    func replaceSelection(with text: String, processID: pid_t?) throws {
        replacementPosts += 1
        access.applyReplacement(text, range: pendingSelection ?? access.selection)
        pendingSelection = nil
        access.armPostWriteReplay()
        onReplacement?()
        onReplacement = nil
    }

    func send(_ text: String, processID: pid_t?) throws {
        appendPosts += 1
        if let appendOverride { appendOverride(text); return }
        access.applyAppend(text)
        access.armPostWriteReplay()
    }

    func replaceTrailingText(_ previousText: String, with text: String, processID: pid_t?) throws {
        selectionPosts += 1
        let range = ReplayTextRange(
            location: access.selection.location - previousText.utf16.count,
            length: previousText.utf16.count
        )
        replacementPosts += 1
        access.applyReplacement(text, range: range)
        access.armPostWriteReplay()
    }
}
