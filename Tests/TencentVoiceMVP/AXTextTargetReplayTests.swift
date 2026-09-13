import ApplicationServices
import XCTest
@testable import TencentVoiceMVP

private typealias ReplayTextRange = TencentVoiceMVP.TextRange

@MainActor
final class AXTextTargetReplayTests: XCTestCase {
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
                    && $0.fields["comparison"] == "documentMismatch"
            }
        )
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

    func testRealAXReplayKeepsAccessibilitySelectionInCoordinateSpace() async throws {
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
        XCTAssertEqual(sender.selectionPosts, 0, "AX range route does not add keyboard selection events")
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
    var rawText: String
    var selection: ReplayTextRange
    var placeholderEvidenceValue: AXPlaceholderEvidence
    var failNextTextReads = 0
    var alwaysFailTextReads = false
    var failNextSelectionReads = 0
    var failNextCoordinateReads = 0
    var permissionError: TextTargetError?
    var selectionRangeIsSettable = false
    var focusChanged = false
    var coordinateIncludesStructuralSeparators = false
    var collapseStructuralSeparatorsAfterNextWrite = false
    var transitionRawOverride: String?
    var coordinateOverride: String?
    var writeSnapshots: [ReplayAXSnapshot] = []
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
    func currentApplication() -> TextTargetApplication? { application }

    func focusedElement() throws -> AXUIElement {
        focusChanged ? otherElement : element
    }

    func processIdentifier(of element: AXUIElement) -> pid_t? { 9001 }

    func text(in element: AXUIElement) throws -> String? {
        textReadCount += 1
        if alwaysFailTextReads || failNextTextReads > 0 {
            if failNextTextReads > 0 { failNextTextReads -= 1 }
            throw KeyboardWriteReadError.retryable
        }
        return rawText
    }

    func selection(in element: AXUIElement) throws -> ReplayTextRange? {
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
        selectionRangeIsSettable && attribute == (kAXSelectedTextRangeAttribute as String)
    }

    func setSelection(_ range: ReplayTextRange, on element: AXUIElement) throws -> Int32 {
        selection = range
        return AXError.success.rawValue
    }

    func setSelectedText(_ text: String, on element: AXUIElement) throws -> Int32 {
        applyReplacement(text, range: selection)
        return AXError.success.rawValue
    }

    func setValue(_ text: String, on element: AXUIElement) throws -> Int32 {
        rawText = text
        selection = .init(location: coordinateText.utf16.count, length: 0)
        placeholderEvidenceValue = .init()
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

    var totalPosts: Int { appendPosts + replacementPosts }

    init(access: ReplayAXTextTargetAccess) {
        self.access = access
    }

    func selectTrailingText(_ previousText: String, processID: pid_t?) throws {
        selectionPosts += 1
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
    }

    func send(_ text: String, processID: pid_t?) throws {
        appendPosts += 1
        access.applyAppend(text)
    }

    func replaceTrailingText(_ previousText: String, with text: String, processID: pid_t?) throws {
        selectionPosts += 1
        let range = ReplayTextRange(
            location: access.selection.location - previousText.utf16.count,
            length: previousText.utf16.count
        )
        replacementPosts += 1
        access.applyReplacement(text, range: range)
    }
}
