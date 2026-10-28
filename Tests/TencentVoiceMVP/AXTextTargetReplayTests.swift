import ApplicationServices
import Foundation
import XCTest
@testable import TencentVoiceMVP

private typealias ReplayTextRange = TencentVoiceMVP.TextRange

@MainActor
final class AXTextTargetReplayTests: XCTestCase {
    func testAXConfirmedKeyboardSelectionCanDisagreeWithEditorAndDiagnosticRetainsWrongResult() async throws {
        let access = ReplayAXTextTargetAccess(text: "先甲",
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001))
        let sender = ReplayKeyboardEventSender(access: access)
        sender.keyboardSelectionOnlyUpdatesAX = true
        let clock = ManualKeyboardPacingClock()
        let target = AXTextTarget(access: access, keyboardEventSender: sender,
            writeTiming: .init(now: { clock.nowNanoseconds }, sleep: { clock.advance(by: $0) }),
            acknowledgementTimeoutNanoseconds: 20_000_000)
        _ = try target.capture()
        try target.replaceTrailingText("甲", with: "乙")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("AX selection agreement alone must not confirm a wrong document")
        } catch { }
        XCTAssertEqual(access.rawText, "先甲乙", "Reproduce the wrong editor selection, not an idealized AX editor")
        XCTAssertEqual(sender.replacementPosts, 1)
        let events = target.drainDiagnostics()
        XCTAssertTrue(events.contains { $0.event == "keyboard_selection_acknowledged" })
        XCTAssertFalse(events.contains { $0.event == "keyboard_write_acknowledged" })
        XCTAssertTrue(events.flatMap(\.textEvidence).contains { $0.kind == .axValue && $0.text == "先甲乙" })
        XCTAssertTrue(events.flatMap(\.textEvidence).contains { $0.kind == .expectedDocument && $0.text == "先乙" })
    }

    func testConfirmedCaretRollbackIsRecordedAsObservationNotProvenUserAction() async throws {
        let initial = String(repeating: "甲", count: 138)
        let access = ReplayAXTextTargetAccess(text: initial,
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001))
        let clock = ManualKeyboardPacingClock()
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender,
            writeTiming: .init(now: { clock.nowNanoseconds }, sleep: { clock.advance(by: $0) }))
        _ = try target.capture()
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()
        XCTAssertEqual(access.selection.location, 139)
        clock.advance(by: 72_000_000)
        // Environment stimulus, independent of production mapping: unchanged text,
        // but the AX caret moves back after the prior write was acknowledged.
        access.selection = .init(location: 138, length: 0)
        _ = try target.reconcileKeyboardStateForUserEdit()
        let event = try XCTUnwrap(target.drainDiagnostics().first { $0.event == "keyboard_state_change_observed" })
        XCTAssertEqual(event.fields["cause"], "unknown")
        XCTAssertEqual(event.fields["previousSelectionLocation"], "139")
        XCTAssertEqual(event.fields["currentSelectionLocation"], "138")
        XCTAssertEqual(event.textEvidence.first { $0.kind == .axValue }?.text, initial + "乙")
        XCTAssertEqual(access.rawText, initial + "乙")
        XCTAssertEqual(sender.totalPosts, 1, "Diagnostic observation must not resend or repair the draft")
    }

    func testDeferredAXSelectionEffectCanFollowAcknowledgementWithoutChangingTheBody() async throws {
        let initial = String(repeating: "甲", count: 138)
        let access = ReplayAXTextTargetAccess(text: initial,
            selection: .init(location: 138, length: 0),
            application: .init(name: "Editor", bundleIdentifier: "com.example.editor", processIdentifier: 9001))
        access.selectionRangeIsSettable = true
        access.deferNextAXSelectionApplication = true
        let clock = ManualKeyboardPacingClock()
        access.replayTime = { clock.nowNanoseconds }
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender,
            writeTiming: .init(now: { clock.nowNanoseconds }, sleep: { clock.advance(by: $0) }))

        _ = try target.capture()
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()
        access.recordTimingEvent("write_acknowledged")
        XCTAssertEqual(access.rawText, initial + "乙")
        XCTAssertEqual(access.selection.location, 139)

        clock.advance(by: 72_000_000)
        access.applyDeferredAXSelectionApplication()
        _ = try target.reconcileKeyboardStateForUserEdit()

        XCTAssertEqual(access.rawText, initial + "乙", "The delayed caret effect must not alter document text")
        XCTAssertEqual(access.selection.location, 138)
        XCTAssertEqual(sender.totalPosts, 1)
        let events = access.timingEvents
        let request = try XCTUnwrap(events.firstIndex { $0.name == "ax_selection_set_requested" })
        let returned = try XCTUnwrap(events.firstIndex { $0.name == "ax_selection_set_returned" })
        let send = try XCTUnwrap(events.firstIndex { $0.name == "text_sent" })
        let acknowledgement = try XCTUnwrap(events.firstIndex { $0.name == "write_acknowledged" })
        let delayedApply = try XCTUnwrap(events.firstIndex { $0.name == "deferred_editor_selection_applied" })
        XCTAssertLessThan(request, returned)
        XCTAssertLessThan(returned, send)
        XCTAssertLessThan(send, acknowledgement)
        XCTAssertLessThan(acknowledgement, delayedApply)
        XCTAssertEqual(events[acknowledgement].time - events[send].time, 0)
        XCTAssertEqual(events[delayedApply].time - events[acknowledgement].time, 72_000_000)
        XCTAssertEqual(events[acknowledgement].axSelection?.location, 139)
        XCTAssertEqual(events[delayedApply].editorSelection?.location, 138)
        XCTAssertEqual(events[request].axSelection?.location, 138)
        XCTAssertEqual(events[returned].time, events[request].time)

        let diagnostics = target.drainDiagnostics()
        let axRequest = try XCTUnwrap(diagnostics.first { $0.event == "ax_selected_text_range_set_requested" })
        let axReturn = try XCTUnwrap(diagnostics.first { $0.event == "ax_selected_text_range_set_returned" })
        let stableReadback = try XCTUnwrap(diagnostics.first { $0.event == "keyboard_selection_stabilized" })
        let axRequestID = try XCTUnwrap(axRequest.fields["axSelectionRequestID"])
        XCTAssertEqual(axReturn.fields["axSelectionRequestID"], axRequestID)
        XCTAssertEqual(stableReadback.fields["axSelectionRequestID"], axRequestID)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(UInt64(axRequest.fields["requestMonotonicNanoseconds"] ?? "")),
            try XCTUnwrap(UInt64(axReturn.fields["returnMonotonicNanoseconds"] ?? ""))
        )
        XCTAssertEqual(stableReadback.fields["selectionEffectObservation"], "ax_readback_only_not_editor_internal_state")
    }

    func testCodexContinuousAppendDoesNotQueueAXSelectionThatCanMoveTheNextInsert() async throws {
        let initial = String(repeating: "甲", count: 51)
        let access = ReplayAXTextTargetAccess(
            text: initial,
            selection: .init(location: initial.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectionRangeIsSettable = true
        access.configureNativeAncestorChain()
        access.deferNextAXSelectionApplication = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000)

        let snapshot = try target.capture()
        try target.paste("，那")
        do {
            try await target.acknowledgeKeyboardWrite()
        } catch {
            XCTFail("the first append should be acknowledged before the delayed selection is applied: \(error)")
            return
        }
        sender.beforeNextAppend = { access.applyDeferredAXSelectionApplication() }
        try target.paste("必")
        var secondAppendWasAcknowledged = false
        do {
            try await target.acknowledgeKeyboardWrite()
            secondAppendWasAcknowledged = true
        } catch { }

        XCTAssertEqual(snapshot.preferredInputStrategy, .acknowledgedKeyboard(reason: "codex_editable_text_control"))
        XCTAssertTrue(secondAppendWasAcknowledged, "a stale AX selection must not derail the next keyboard append")
        XCTAssertEqual(access.rawText, initial + "，那必")
        XCTAssertEqual(access.selection, .init(location: 54, length: 0))
        XCTAssertEqual(access.selectionSetCalls, 0)
        XCTAssertEqual(sender.appendPosts, 2, "each recognized update is submitted once")
    }

    func testStaleAXSelectionReadsAreDistinguishedFromAppliedEditorSelection() async throws {
        let access = ReplayAXTextTargetAccess(text: "甲", selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001))
        access.selectionRangeIsSettable = true
        access.staleSelectionReadsAfterNextTextWrite = 2
        let clock = ManualKeyboardPacingClock()
        access.replayTime = { clock.nowNanoseconds }
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender,
            writeTiming: .init(now: { clock.nowNanoseconds }, sleep: { clock.advance(by: $0) }),
            acknowledgementTimeoutNanoseconds: 20_000_000)

        _ = try target.capture()
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()
        access.recordTimingEvent("write_acknowledged")

        XCTAssertEqual(access.rawText, "甲乙")
        XCTAssertEqual(access.selection.location, 2)
        XCTAssertEqual(sender.totalPosts, 1)
        let events = access.timingEvents
        let send = try XCTUnwrap(events.firstIndex { $0.name == "text_sent" })
        let staleReads = events.enumerated().filter { $0.element.name == "ax_selection_read_stale" }
        let acknowledgement = try XCTUnwrap(events.firstIndex { $0.name == "write_acknowledged" })
        XCTAssertEqual(staleReads.count, 2)
        XCTAssertTrue(staleReads.allSatisfy { $0.element.axSelection?.location == 1 })
        XCTAssertTrue(staleReads.allSatisfy { $0.element.editorSelection?.location == 2 })
        XCTAssertGreaterThan(staleReads[0].offset, send)
        XCTAssertLessThan(staleReads[1].offset, acknowledgement)
    }

    func testDiagnosticDispatchSeparatesPayloadFromWholeDocumentAndReadback() async throws {
        let access = ReplayAXTextTargetAccess(text: "已有正文", selection: .init(location: 4, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001))
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender,
                                  acknowledgementTimeoutNanoseconds: 20_000_000)
        _ = try target.capture()
        try target.paste("甲")
        try await target.acknowledgeKeyboardWrite()
        try target.replaceTrailingText("甲", with: "乙")
        try await target.acknowledgeKeyboardWrite()
        let events = target.drainDiagnostics()
        let dispatches = events.filter { $0.event == "text_dispatch_returned" }
        XCTAssertEqual(dispatches.count, 2)
        XCTAssertEqual(dispatches.flatMap(\.textEvidence).filter { $0.kind == .sentText }.map(\.text), ["甲", "乙"])
        XCTAssertEqual(dispatches.flatMap(\.textEvidence).filter { $0.kind == .expectedDocument }.map(\.text),
                       ["已有正文甲", "已有正文乙"])
        XCTAssertEqual(access.rawText, "已有正文乙")
        XCTAssertEqual(access.selection, .init(location: 5, length: 0))
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
    }

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

    func testCodexReportShapedHiddenSeparatorBoundaryUsesObservedRawCandidate() async throws {
        let prefix = String(repeating: "甲", count: 69) + "\n"
        let suffix = String(repeating: "乙", count: 578)
        let beforeRaw = prefix + "\n\n" + suffix
        let beforeCoordinate = prefix + suffix
        let afterFirstRaw = prefix + "今\n\n" + suffix
        let afterFirstCoordinate = prefix + "今" + suffix
        let afterSecondRaw = prefix + "今天\n\n" + suffix
        let afterSecondCoordinate = prefix + "今天" + suffix

        let access = ReplayAXTextTargetAccess(
            text: beforeRaw,
            selection: .init(location: prefix.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = beforeCoordinate
        access.writeSnapshots = [
            .init(
                rawText: afterFirstRaw,
                coordinateText: afterFirstCoordinate,
                selection: .init(location: prefix.utf16.count + 1, length: 0)
            ),
            .init(
                rawText: afterSecondRaw,
                coordinateText: afterSecondCoordinate,
                selection: .init(location: prefix.utf16.count + 2, length: 0)
            )
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        var clock: UInt64 = 0
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { clock }, sleep: { clock += $0 }),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()
        try target.paste("天")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, afterSecondRaw)
        XCTAssertEqual(access.coordinateText, afterSecondCoordinate)
        XCTAssertEqual(access.selection, .init(location: prefix.utf16.count + 2, length: 0))
        XCTAssertEqual(sender.appendPosts, 2)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexReportShapeRetriesOld650SnapshotBeforeConfirmingNew651Snapshot() async throws {
        let prefix = String(repeating: "甲", count: 69) + "\n"
        let suffix = String(repeating: "乙", count: 578)
        let beforeRaw = prefix + "\n\n" + suffix
        let beforeCoordinate = prefix + suffix
        let afterRaw = prefix + "今\n\n" + suffix
        let afterCoordinate = prefix + "今" + suffix
        XCTAssertEqual(beforeRaw.utf16.count, 650)
        XCTAssertEqual(beforeCoordinate.utf16.count, 648)
        XCTAssertEqual(afterRaw.utf16.count, 651)
        XCTAssertEqual(afterCoordinate.utf16.count, 649)

        let access = ReplayAXTextTargetAccess(
            text: beforeRaw,
            selection: .init(location: prefix.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = beforeCoordinate
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { text in
            XCTAssertEqual(text, "今")
            // Match the report's observed order: the first post-dispatch
            // read is still the 650/648 pre-write snapshot, then the editor
            // publishes the unique 651/649 representation of the edit.
            access.queuedTextReadSnapshots = [
                .init(
                    rawText: beforeRaw,
                    coordinateText: beforeCoordinate,
                    selection: .init(location: prefix.utf16.count, length: 0)
                ),
                .init(
                    rawText: afterRaw,
                    coordinateText: afterCoordinate,
                    selection: .init(location: prefix.utf16.count + 1, length: 0)
                )
            ]
            access.rawText = afterRaw
            access.coordinateOverride = afterCoordinate
            access.selection = .init(location: prefix.utf16.count + 1, length: 0)
        }

        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, afterRaw)
        XCTAssertEqual(access.coordinateText, afterCoordinate)
        XCTAssertEqual(access.selection, .init(location: prefix.utf16.count + 1, length: 0))
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexStructuralAXValueLagAfterCaretAdvanceWaitsForCompleteReceipt() async throws {
        for initialRaw in ["\nTask Router", "Task\nRouter"] {
            let initialCoordinate = initialRaw.filter { $0 != "\n" }
            let access = ReplayAXTextTargetAccess(
                text: initialRaw,
                selection: .init(location: initialCoordinate.utf16.count, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            let clock = ManualKeyboardPacingClock()
            let sender = ReplayKeyboardEventSender(access: access)
            let target = AXTextTarget(
                access: access,
                keyboardEventSender: sender,
                writeTiming: .init(
                    now: { clock.nowNanoseconds },
                    sleep: { clock.advance(by: $0) }
                ),
                acknowledgementTimeoutNanoseconds: 50_000_000
            )

            _ = try target.capture()
            for character in "abcdef" {
                try target.paste(String(character))
                try await target.acknowledgeKeyboardWrite()
            }

            let oldRaw = access.rawText
            let oldCoordinate = access.coordinateText
            let oldSelection = access.selection
            let advancedSelection = ReplayTextRange(location: oldCoordinate.utf16.count + 1, length: 0)
            let newRaw = oldRaw + ","
            let newCoordinate = oldCoordinate + ","
            access.readSnapshotsAfterNextWrite = [
                .init(rawText: oldRaw, coordinateText: oldCoordinate, selection: oldSelection),
                .init(rawText: oldRaw, coordinateText: oldCoordinate, selection: advancedSelection),
                .init(rawText: newRaw, coordinateText: newCoordinate, selection: advancedSelection)
            ]

            try target.paste(",")
            try await target.acknowledgeKeyboardWrite()

            XCTAssertEqual(access.rawText, newRaw)
            XCTAssertEqual(access.coordinateText, newCoordinate)
            XCTAssertEqual(access.selection, advancedSelection)
            XCTAssertEqual(sender.appendPosts, 7, "The comma must be posted once after six confirmed writes")
            XCTAssertTrue(access.queuedTextReadSnapshots.isEmpty, "Acknowledgement must wait for the complete snapshot")
            XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
        }
    }

    func testCodexStructuralAXValueLagSupportsMultiCharacterAppend() async throws {
        let initialRaw = "Task\nRouter"
        let initialCoordinate = initialRaw.filter { $0 != "\n" }
        let access = ReplayAXTextTargetAccess(
            text: initialRaw,
            selection: .init(location: initialCoordinate.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let clock = ManualKeyboardPacingClock()
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { clock.nowNanoseconds }, sleep: { clock.advance(by: $0) }),
            acknowledgementTimeoutNanoseconds: 50_000_000
        )

        _ = try target.capture()
        for character in "abcdef" {
            try target.paste(String(character))
            try await target.acknowledgeKeyboardWrite()
        }
        let oldRaw = access.rawText
        let oldCoordinate = access.coordinateText
        let oldSelection = access.selection
        let payload = "😀,"
        let newSelection = ReplayTextRange(location: oldCoordinate.utf16.count + payload.utf16.count, length: 0)
        let newRaw = oldRaw + payload
        let newCoordinate = oldCoordinate + payload
        access.readSnapshotsAfterNextWrite = [
            .init(rawText: oldRaw, coordinateText: oldCoordinate, selection: oldSelection),
            .init(rawText: oldRaw, coordinateText: oldCoordinate, selection: newSelection),
            .init(rawText: newRaw, coordinateText: newCoordinate, selection: newSelection)
        ]

        try target.paste(payload)
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, newRaw)
        XCTAssertEqual(access.coordinateText, newCoordinate)
        XCTAssertEqual(access.selection, newSelection)
        XCTAssertEqual(sender.appendPosts, 7)
        XCTAssertTrue(access.queuedTextReadSnapshots.isEmpty)
    }

    func testCodexStructuralAXValueLagAfterTailReplacementWaitsForFullReceipt() async throws {
        let initialRaw = "\nTask Router"
        let initialCoordinate = initialRaw.filter { $0 != "\n" }
        let access = ReplayAXTextTargetAccess(
            text: initialRaw,
            selection: .init(location: initialCoordinate.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let clock = ManualKeyboardPacingClock()
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { clock.nowNanoseconds }, sleep: { clock.advance(by: $0) }),
            acknowledgementTimeoutNanoseconds: 50_000_000
        )

        _ = try target.capture()
        try target.paste("abcdef")
        try await target.acknowledgeKeyboardWrite()
        let oldRaw = access.rawText
        let oldCoordinate = access.coordinateText
        let selectedTail = ReplayTextRange(location: oldCoordinate.utf16.count - 2, length: 2)
        let newRaw = String(oldRaw.dropLast(2)) + "zxy"
        let newCoordinate = String(oldCoordinate.dropLast(2)) + "zxy"
        let newSelection = ReplayTextRange(location: oldCoordinate.utf16.count + 1, length: 0)
        access.readSnapshotsAfterNextWrite = [
            .init(rawText: oldRaw, coordinateText: oldCoordinate, selection: selectedTail),
            .init(rawText: oldRaw, coordinateText: oldCoordinate, selection: newSelection),
            .init(rawText: newRaw, coordinateText: newCoordinate, selection: newSelection)
        ]

        try target.replaceTrailingText("ef", with: "zxy")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, newRaw)
        XCTAssertEqual(access.coordinateText, newCoordinate)
        XCTAssertEqual(access.selection, newSelection)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertTrue(access.queuedTextReadSnapshots.isEmpty)
        let events = target.drainDiagnostics()
        let selectionConfirmed = try XCTUnwrap(events.firstIndex { $0.event == "keyboard_selection_acknowledged" })
        let replacementSent = try XCTUnwrap(events.firstIndex { $0.event == "keyboard_replacement_submitted" })
        XCTAssertLessThan(selectionConfirmed, replacementSent)
    }

    func testCodexPersistentStructuralAXValueLagTimesOutWithoutResending() async throws {
        let initialRaw = "Task\nRouter"
        let initialCoordinate = initialRaw.filter { $0 != "\n" }
        let access = ReplayAXTextTargetAccess(
            text: initialRaw,
            selection: .init(location: initialCoordinate.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let clock = ManualKeyboardPacingClock()
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { clock.nowNanoseconds }, sleep: { clock.advance(by: $0) }),
            acknowledgementTimeoutNanoseconds: 20_000_000
        )
        _ = try target.capture()
        let oldRaw = access.rawText
        let oldCoordinate = access.coordinateText
        let advancedSelection = ReplayTextRange(location: oldCoordinate.utf16.count + 1, length: 0)
        access.readSnapshotsAfterNextWrite = Array(repeating: .init(
            rawText: oldRaw,
            coordinateText: oldCoordinate,
            selection: advancedSelection
        ), count: 3)

        try target.paste(",")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("Persistent body lag must remain unconfirmed until the acknowledgement deadline")
        } catch {
            XCTAssertEqual(error as? TextTargetError, .writeFailed)
        }

        XCTAssertEqual(access.rawText, oldRaw, "The draft must remain at the last observed body")
        XCTAssertEqual(sender.appendPosts, 1, "A timeout must never submit the character twice")
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_acknowledged" })
    }

    func testCodexStructuralAXValueLagCanBeCancelledWhileWaiting() async throws {
        let initialRaw = "Task\nRouter"
        let initialCoordinate = initialRaw.filter { $0 != "\n" }
        let access = ReplayAXTextTargetAccess(
            text: initialRaw,
            selection: .init(location: initialCoordinate.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let clock = ManualKeyboardPacingClock()
        let sender = ReplayKeyboardEventSender(access: access)
        var acknowledgementTask: Task<Void, Never>?
        var acknowledgementError: Error?
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(
                now: { clock.nowNanoseconds },
                sleep: { _ in acknowledgementTask?.cancel() }
            ),
            acknowledgementTimeoutNanoseconds: 50_000_000
        )
        _ = try target.capture()
        let oldRaw = access.rawText
        let oldCoordinate = access.coordinateText
        let advancedSelection = ReplayTextRange(location: oldCoordinate.utf16.count + 1, length: 0)
        access.readSnapshotsAfterNextWrite = [
            .init(rawText: oldRaw, coordinateText: oldCoordinate, selection: advancedSelection),
            .init(rawText: oldRaw + ",", coordinateText: oldCoordinate + ",", selection: advancedSelection)
        ]
        try target.paste(",")
        acknowledgementTask = Task {
            do {
                try await target.acknowledgeKeyboardWrite()
            } catch {
                acknowledgementError = error
            }
        }
        await acknowledgementTask?.value

        XCTAssertTrue(acknowledgementError is CancellationError)
        XCTAssertEqual(sender.appendPosts, 1)
        XCTAssertEqual(access.rawText, oldRaw)
        XCTAssertEqual(access.queuedTextReadSnapshots.count, 1)
    }

    func testCodexConfirmedRawBoundaryIsReusedForTheNextAppend() async throws {
        let prefix = String(repeating: "甲", count: 70)
        let suffix = String(repeating: "乙", count: 20)
        let beforeRaw = prefix + "\n\n" + suffix
        let beforeCoordinate = prefix + suffix
        let afterFirstRaw = prefix + "今\n\n" + suffix
        let afterFirstCoordinate = prefix + "今" + suffix
        let afterSecondRaw = prefix + "今天\n\n" + suffix

        let access = ReplayAXTextTargetAccess(
            text: beforeRaw,
            selection: .init(location: prefix.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = beforeCoordinate
        // Both edits are supplied as observed editor results. The second
        // receipt must nevertheless be built from the raw boundary selected
        // by the first confirmed result, rather than reopening every boundary
        // in the new AX snapshot.
        access.writeSnapshots = [
            .init(
                rawText: afterFirstRaw,
                coordinateText: afterFirstCoordinate,
                selection: .init(location: prefix.utf16.count + 1, length: 0)
            ),
            .init(
                rawText: afterSecondRaw,
                coordinateText: prefix + "今天" + suffix,
                selection: .init(location: prefix.utf16.count + 2, length: 0)
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

        XCTAssertEqual(
            access.rawText,
            afterSecondRaw,
            "a confirmed middle boundary must be used by the next append"
        )
        XCTAssertEqual(sender.appendPosts, 2)
        let diagnostics = target.drainDiagnostics()
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
        let acknowledgements = diagnostics.filter { $0.event == "keyboard_write_acknowledged" }
        XCTAssertEqual(acknowledgements.count, 2)
        XCTAssertEqual(
            acknowledgements.last?.fields["ackDiffFinal0CandidateIndex"],
            "0",
            "the confirmed raw boundary must be the next receipt's primary candidate"
        )
    }

    func testCodexReportShapedSeparatorRelocationUsesMiddleRawBoundary() async throws {
        // This is the same observable class as the failure reports where
        // AXValue and AXStringForRange keep the same total lengths, while the
        // two hidden LF units move from one side of the inserted character to
        // one unit on each side. The expected range must retain the complete
        // alignment graph's middle raw boundary; choosing only its rightmost
        // boundary would predict a different raw document.
        let prefix = String(repeating: "甲", count: 70)
        let suffix = String(repeating: "乙", count: 578)
        let beforeRaw = prefix + "\n\n" + suffix
        let beforeCoordinate = prefix + suffix
        let afterRaw = prefix + "\n今\n" + suffix
        let afterCoordinate = prefix + "今" + suffix
        XCTAssertEqual(beforeRaw.utf16.count, 650)
        XCTAssertEqual(beforeCoordinate.utf16.count, 648)
        XCTAssertEqual(afterRaw.utf16.count, 651)
        XCTAssertEqual(afterCoordinate.utf16.count, 649)

        let insertionLocation = prefix.utf16.count
        let access = ReplayAXTextTargetAccess(
            text: beforeRaw,
            selection: .init(location: insertionLocation, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = beforeCoordinate
        access.writeSnapshots = [
            .init(
                rawText: afterRaw,
                coordinateText: afterCoordinate,
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
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, afterRaw)
        XCTAssertEqual(access.coordinateText, afterCoordinate)
        XCTAssertEqual(access.selection, .init(location: insertionLocation + 1, length: 0))
        XCTAssertEqual(sender.totalPosts, 1)
        let diagnostics = target.drainDiagnostics()
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertTrue(
            diagnostics.contains {
                $0.event == "keyboard_write_acknowledged"
                    && $0.fields["ackCandidateCount"] == "3"
            },
            "the middle boundary must remain visible in the acknowledgement candidates"
        )
    }

    func testCodexSingleHiddenSeparatorRetainsBothRawBoundaryCandidates() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲\n乙",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectionRangeIsSettable = true
        access.coordinateOverride = "甲乙"
        access.writeSnapshots = [
            .init(
                rawText: "甲X\n乙",
                coordinateText: "甲X乙",
                selection: .init(location: 2, length: 0)
            ),
            .init(
                rawText: "甲X\nZ乙",
                coordinateText: "甲XZ乙",
                selection: .init(location: 3, length: 0)
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
        try target.paste("Z")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲X\nZ乙")
        XCTAssertEqual(access.coordinateText, "甲XZ乙")
        XCTAssertEqual(access.selection, .init(location: 3, length: 0))
        XCTAssertEqual(sender.totalPosts, 2)
        let diagnostics = target.drainDiagnostics()
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertTrue(
            diagnostics.contains {
                $0.event == "keyboard_write_acknowledged"
                    && $0.fields["ackCandidateCount"] == "2"
            }
        )
    }

    func testCodexEmptyWriteWithAmbiguousRawBoundariesStaysUnconfirmed() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲\n乙",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲乙"
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("identical raw receipts from different hidden boundaries must stay ambiguous")
        } catch { }

        XCTAssertEqual(sender.totalPosts, 1)
        let failure = try XCTUnwrap(
            target.drainDiagnostics().last { $0.event == "keyboard_write_unconfirmed" }
        )
        XCTAssertEqual(failure.fields["comparison"], "ambiguousReceipt")
        XCTAssertEqual(failure.fields["ackCandidateCount"], "2")
    }

    func testCodexLiveStructuralAugmentationKeepsInsertionAndContinuationPosition() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "测试\n看看",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "测试\n看看"
        access.writeSnapshots = [
            .init(
                rawText: "测试X\n\n\n看看",
                coordinateText: "测试X看看",
                selection: .init(location: 3, length: 0)
            ),
            .init(
                rawText: "测试X\n\n\nY看看",
                coordinateText: "测试XY看看",
                selection: .init(location: 4, length: 0)
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
        try target.paste("Y")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "测试X\n\n\nY看看")
        XCTAssertEqual(access.coordinateText, "测试XY看看")
        XCTAssertEqual(access.selection, .init(location: 4, length: 0))
        XCTAssertEqual(sender.totalPosts, 2)
        let diagnostics = target.drainDiagnostics()
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(
            diagnostics.filter { $0.event == "keyboard_write_acknowledged" }.count,
            2
        )
        XCTAssertTrue(
            diagnostics.contains {
                $0.event == "keyboard_write_acknowledged"
                    && $0.fields["ackDiffFinal0Classification"] == "structural_local"
            }
        )
    }

    func testCodexReportShapedTwoAddedLineMarkersConfirmAndKeepContinuationAnchor() async throws {
        // The attached failure reports have this observable shape: the
        // pre-write coordinate text retains one LF, while the post-write
        // AXValue publishes the payload followed by three LF units and the
        // coordinate text omits that whole local marker run. The two extra
        // LF units are structural representation, not user input.
        let access = ReplayAXTextTargetAccess(
            text: "甲乙\n丙丁",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲乙\n丙丁"
        access.writeSnapshots = [
            .init(
                rawText: "甲乙今\n\n\n丙丁",
                coordinateText: "甲乙今丙丁",
                selection: .init(location: 3, length: 0)
            ),
            .init(
                rawText: "甲乙今续\n\n\n丙丁",
                coordinateText: "甲乙今续丙丁",
                selection: .init(location: 4, length: 0)
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
        try target.paste("续")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲乙今续\n\n\n丙丁")
        XCTAssertEqual(access.coordinateText, "甲乙今续丙丁")
        XCTAssertEqual(access.selection, .init(location: 4, length: 0))
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexCaretAtParagraphBoundaryIsPreservedWithoutAXReseating() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "abc\nX",
            selection: .init(location: 3, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectionRangeIsSettable = true
        access.coordinateOverride = "abc\nX"
        access.configureNativeAncestorChain()
        access.simulateCodexParagraphBoundaryExpansion = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("Y")
        try await target.acknowledgeKeyboardWrite()
        try target.paste("Z")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "abcY\n\n\nZX")
        XCTAssertEqual(access.coordinateText, "abcYZX")
        XCTAssertEqual(access.selection, .init(location: 5, length: 0))
        XCTAssertEqual(access.selectionSetCalls, 0)
        XCTAssertEqual(sender.totalPosts, 2)
        let diagnostics = target.drainDiagnostics()
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(
            diagnostics.filter { $0.event == "keyboard_selection_stabilization_skipped" }.count,
            2
        )
    }

    func testCodexNodeRebuildDuringAcknowledgementRecoversWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.simulateSafariEditorLayoutRebuild = true
        access.anchoredContinuityAvailable = true
        let sender = ReplayKeyboardEventSender(access: access)
        sender.beforeNextAppend = { access.focusedElementRebuildsBeforeNextWrite = 1 }
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(sender.totalPosts, 1)
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains { $0.event == "keyboard_write_acknowledged" })
        XCTAssertTrue(diagnostics.contains { $0.event == "keyboard_target_reacquired" })
    }

    func testCodexFirstInsertUsesUniqueObservedPositionWhenInitialCaretIsStale() async throws {
        let cases = [
            (raw: "1. \n", coordinate: "1. ", payload: "磨", position: 3),
            (raw: "第一行\n第二行\n", coordinate: "第一行\n第二行", payload: "新", position: 1),
            (raw: "第一行\n第二行\n", coordinate: "第一行\n第二行", payload: "那", position: 4),
            (raw: "开头中间结尾\n", coordinate: "开头中间结尾", payload: "新", position: 4),
            (raw: "题目😀\n下一行\n", coordinate: "题目😀\n下一行", payload: "😀好", position: 8),
            (raw: "第一行\r\n第二行\r\n", coordinate: "第一行\r\n第二行", payload: "好", position: 8)
        ]
        for item in cases {
            let access = ReplayAXTextTargetAccess(
                text: item.raw,
                selection: .init(location: 0, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = item.coordinate
            let sender = ReplayKeyboardEventSender(access: access)
            sender.appendOverride = { text in
                // Model a web editor that inserts at an independently known
                // UTF16 boundary despite AX reporting the document start.
                let units = Array(item.coordinate.utf16)
                let observedUnits = Array(units[..<item.position])
                    + Array(text.utf16)
                    + Array(units[item.position...])
                let observed = String(decoding: observedUnits, as: UTF16.self)
                access.rawText = observed
                access.coordinateOverride = access.rawText
                access.selection = .init(location: item.position + text.utf16.count, length: 0)
            }
            let target = AXTextTarget(access: access, keyboardEventSender: sender)

            _ = try target.capture()
            try target.paste(item.payload)
            try await target.acknowledgeKeyboardWrite()

            let units = Array(item.coordinate.utf16)
            let expectedUnits = Array(units[..<item.position])
                + Array(item.payload.utf16)
                + Array(units[item.position...])
            XCTAssertEqual(access.rawText, String(decoding: expectedUnits, as: UTF16.self))
            XCTAssertEqual(sender.totalPosts, 1)
            XCTAssertTrue(target.drainDiagnostics().contains { $0.event == "keyboard_write_acknowledged" })
        }
    }

    func testCodexFirstInsertCalibratesAfterConfirmedEditorObjectRebuild() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "1. \n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "1. "
        access.configureWebAncestorChain(depth: 4)
        access.simulateSafariEditorLayoutRebuild = true
        access.anchoredContinuityAvailable = true
        let sender = ReplayKeyboardEventSender(access: access)
        sender.beforeNextAppend = { access.focusedElementRebuildsBeforeNextWrite = 1 }
        sender.appendOverride = { text in
            let before = Array(access.coordinateText.utf16)
            let inserted = Array(text.utf16)
            let observed = Array(before[..<3]) + inserted + Array(before[3...])
            access.rawText = String(decoding: observed, as: UTF16.self)
            access.coordinateOverride = access.rawText
            access.selection = .init(location: 3 + inserted.count, length: 0)
        }
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        _ = try target.capture()
        access.safariContinuityUnavailableReadsBeforeRecovery = 1
        try target.paste("磨")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "1. 磨")
        XCTAssertEqual(sender.totalPosts, 1)
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquired"
                && $0.fields["continuityRoute"] == "captured_anchor_subtree"
        })
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_initial_insertion_position_calibrated"
                && $0.fields["positionUTF16"] == "3"
        })
        XCTAssertEqual(diagnostics.filter { $0.event == "keyboard_write_acknowledged" }.count, 1)
    }

    func testCodexInitialInsertionCalibrationRejectsAmbiguityAndExternalEdit() async throws {
        for (before, payload, after) in [("aaaa", "a", "aaaaa"), ("abc", "b", "aXc")] {
            let access = ReplayAXTextTargetAccess(
                text: before + "\n",
                selection: .init(location: 0, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = before
            let sender = ReplayKeyboardEventSender(access: access)
            sender.appendOverride = { _ in
                access.rawText = after
                access.coordinateOverride = after
                access.selection = .init(location: after.utf16.count, length: 0)
            }
            let target = AXTextTarget(
                access: access,
                keyboardEventSender: sender,
                acknowledgementTimeoutNanoseconds: 20_000_000
            )

            _ = try target.capture()
            try target.paste(payload)
            do {
                try await target.acknowledgeKeyboardWrite()
                XCTFail("ambiguous or externally changed text must not be calibrated")
            } catch {
                XCTAssertEqual(error as? TextTargetError, .writeFailed)
            }
            XCTAssertEqual(sender.totalPosts, 1, "the uncertain append is never resent")
            XCTAssertFalse(target.drainDiagnostics().contains {
                $0.event == "keyboard_write_acknowledged"
            })
        }
    }

    func testAnchoredContinuityScannerRequiresCompleteUniqueSubtree() throws {
        let anchor = ReplayContinuityNode(role: "AXGroup")
        let section = ReplayContinuityNode(role: "AXGroup")
        let target = ReplayContinuityNode(role: "AXTextArea")
        anchor.children = [section]
        section.children = [target]
        func scan() throws -> AXAnchoredEditorScanResult {
            try AXAnchoredEditorScanner.scan(
                anchor: anchor,
                target: target,
                anchorRole: "AXGroup",
                equals: { $0 === $1 },
                role: { node in
                    if node.failAttribute == "AXRole" {
                        throw AXAnchoredEditorScanFailure(attribute: "AXRole", status: -25202, reason: "read_failed")
                    }
                    return node.role
                },
                identifier: { $0.identifier },
                subrole: { $0.subrole },
                readOnly: { node in
                    if node.failAttribute == "AXReadOnly" {
                        throw AXAnchoredEditorScanFailure(attribute: "AXReadOnly", status: -25202, reason: "read_failed")
                    }
                    return node.readOnly
                },
                children: { node in
                    if node.failAttribute == "AXChildren" {
                        throw AXAnchoredEditorScanFailure(attribute: "AXChildren", status: -25202, reason: "read_failed")
                    }
                    return node.children
                }
            )
        }

        let unique = try scan()
        XCTAssertEqual(unique.editableEditorCount, 1)
        XCTAssertTrue(unique.targetFound)
        XCTAssertEqual(unique.rolesFromEditorToAnchor, ["AXTextArea", "AXGroup"])

        section.children.append(ReplayContinuityNode(role: "AXTextField"))
        let ambiguous = try scan()
        XCTAssertEqual(ambiguous.editableEditorCount, 2)

        section.children = [target]
        for attribute in ["AXRole", "AXReadOnly", "AXChildren"] {
            section.failAttribute = attribute == "AXReadOnly" ? nil : attribute
            target.failAttribute = attribute == "AXReadOnly" ? attribute : nil
            XCTAssertThrowsError(try scan()) { error in
                XCTAssertEqual((error as? AXAnchoredEditorScanFailure)?.attribute, attribute)
            }
        }
    }

    func testAnchoredContinuityRequiresCapturedAnchorToRemainInSameWebArea() throws {
        let webArea = ReplayContinuityNode(role: "AXWebArea")
        let anchor = ReplayContinuityNode(role: "AXGroup")
        let editor = ReplayContinuityNode(role: "AXTextArea")
        let otherWebArea = ReplayContinuityNode(role: "AXWebArea")
        webArea.children = [anchor]
        anchor.parent = webArea
        anchor.children = [editor]
        editor.parent = anchor

        func isWithin(_ node: ReplayContinuityNode, _ ancestor: ReplayContinuityNode) throws -> Bool {
            try AXAnchoredEditorScanner.isDescendant(
                node,
                of: ancestor,
                equals: { $0 === $1 },
                parent: { node in
                    if node.failParentRead {
                        throw AXAnchoredEditorScanFailure(
                            attribute: "AXParent", status: -25202, reason: "read_failed"
                        )
                    }
                    return node.parent
                }
            )
        }

        XCTAssertTrue(try isWithin(anchor, webArea))
        XCTAssertFalse(try isWithin(anchor, otherWebArea))
        anchor.failParentRead = true
        XCTAssertThrowsError(try isWithin(anchor, webArea))
    }

    func testCodexParagraphBoundaryMigrationOnTheWrongSideRemainsUnconfirmed() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "abc\nX",
            selection: .init(location: 3, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectionRangeIsSettable = true
        access.coordinateOverride = "abc\nX"
        access.writeSnapshots = [
            .init(
                rawText: "abc\n\nY\nX",
                coordinateText: "abcYX",
                selection: .init(location: 4, length: 0)
            )
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("Y")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("a paragraph moved across the inserted content must not be acknowledged")
        } catch { }

        XCTAssertEqual(sender.totalPosts, 1)
        let failure = try XCTUnwrap(target.drainDiagnostics().last { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(failure.fields["ackDiffFinal0Classification"], "structural_local")
        XCTAssertEqual(failure.fields["ackDiffFinal0SeparatorDifferenceBoundaryCount"], "1")
    }

    func testCodexParagraphBoundaryMigrationWithoutWritableRangeRemainsUnconfirmed() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "abc\nX",
            selection: .init(location: 3, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "abc\nX"
        access.writeSnapshots = [
            .init(
                rawText: "abc\n\nY\nX",
                coordinateText: "abcYX",
                selection: .init(location: 4, length: 0)
            )
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("Y")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("an ambiguous paragraph boundary must not be acknowledged without a writable AX range")
        } catch { }

        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(access.selectionSetCalls, 0)
        let diagnostics = target.drainDiagnostics()
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_acknowledged" })
        let failure = try XCTUnwrap(diagnostics.last { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(failure.fields["ackDiffFinal0Classification"], "structural_local")
        XCTAssertEqual(failure.fields["ackDiffFinal0SeparatorDifferenceBoundaryCount"], "1")
    }

    func testCodexKeyboardPayloadKeepsUserLineBreaksWhenCoordinateDocumentOmitsOtherSeparators() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲\n\n乙",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲乙"
        access.writeSnapshots = [
            .init(
                rawText: "甲A\nB\n\n乙",
                coordinateText: "甲A\nB乙",
                selection: .init(location: 4, length: 0)
            )
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("A\nB")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲A\nB\n\n乙")
        XCTAssertEqual(access.coordinateText, "甲A\nB乙")
        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testCodexPayloadLineBreakRemainsRawWhenCoordinateOmitsIt() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲\n\n乙",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲乙"
        access.writeSnapshots = [
            .init(
                rawText: "甲A\nB\n\n乙",
                coordinateText: "甲AB乙",
                selection: .init(location: 3, length: 0)
            )
        ]
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("A\nB")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲A\nB\n\n乙")
        XCTAssertEqual(access.coordinateText, "甲AB乙")
        XCTAssertEqual(access.selection, .init(location: 3, length: 0))
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexReplacementAcrossHiddenStructuralRangeUsesTheObservedRawCandidate() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲\n\n旧乙",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲旧乙"
        access.writeSnapshots = [
            .init(
                rawText: "甲\n\n新乙",
                coordinateText: "甲新乙",
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
        try target.replaceTrailingText("旧", with: "新")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲\n\n新乙")
        XCTAssertEqual(access.coordinateText, "甲新乙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(sender.replacementPosts, 1)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexKeyboardPayloadPreservesEveryDeclaredInvisibleOrUnicodeCharacter() async throws {
        let payloads = [
            "\r",
            "\r\n",
            "\t",
            "\u{2028}",
            "\u{2029}",
            "\u{200B}",
            "\u{200C}\u{200D}\u{2060}\u{FEFF}",
            "👨‍👩‍👧‍👦",
            "e\u{301}",
            "重复重复"
        ]

        for payload in payloads {
            let beforeRaw = "甲\n\n乙"
            let afterRaw = "甲" + payload + "\n\n乙"
            let afterCoordinate = "甲" + payload + "乙"
            let access = ReplayAXTextTargetAccess(
                text: beforeRaw,
                selection: .init(location: 1, length: 0),
                application: .init(
                    name: "Codex",
                    bundleIdentifier: "com.openai.codex",
                    processIdentifier: 9001
                )
            )
            access.coordinateOverride = "甲乙"
            access.writeSnapshots = [
                .init(
                    rawText: afterRaw,
                    coordinateText: afterCoordinate,
                    selection: .init(location: 1 + payload.utf16.count, length: 0)
                )
            ]
            let sender = ReplayKeyboardEventSender(access: access)
            var clock: UInt64 = 0
            let target = AXTextTarget(
                access: access,
                keyboardEventSender: sender,
                writeTiming: .init(now: { clock }, sleep: { clock += $0 }),
                acknowledgementTimeoutNanoseconds: 20_000_000
            )

            do {
                _ = try target.capture()
                try target.paste(payload)
                try await target.acknowledgeKeyboardWrite()
            } catch {
                let diagnostics = target.drainDiagnostics().map { $0.event + ":" + String(describing: $0.fields) }
                XCTFail(
                    "payload \(payload.debugDescription) failed with \(error); diagnostics=\(diagnostics)"
                )
                continue
            }

            XCTAssertEqual(access.rawText, afterRaw, payload.debugDescription)
            XCTAssertEqual(access.coordinateText, afterCoordinate, payload.debugDescription)
            XCTAssertEqual(sender.totalPosts, 1, payload.debugDescription)
            XCTAssertFalse(
                target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" },
                payload.debugDescription
            )
        }
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
        XCTAssertEqual(firstAcknowledgement.fields["ackCandidateCount"], "5")
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
        XCTAssertEqual(acknowledgement.fields["ackCandidateCount"], "6")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal0CandidateMatched"], "true")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal1CandidateMatched"], "false")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal2CandidateMatched"], "false")
        XCTAssertEqual(acknowledgement.fields["ackDiffFinal3CandidateMatched"], "false")
    }

    func testCodexAXValueLocalStructuralAugmentationConfirmsWithoutCoordinateRead() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲乙",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectedTextAttributeIsSettable = true
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { _ in
            // Model the editor publishing two empty-paragraph markers in
            // AXValue while AXStringForRange is unavailable. The coordinate
            // document is still exactly the expected "甲今乙".
            access.rawText = "甲今\n\n乙"
            access.selection = .init(location: 2, length: 0)
            access.failNextCoordinateReads = 100
        }
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲今\n\n乙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.totalPosts, 1)
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "ax_coordinate_mapping_fallback"
                && $0.fields["reason"] == "pending_receipt_local_structural_augmentation"
        })
        XCTAssertTrue(diagnostics.contains {
            $0.event == "ax_coordinate_mapping_resolved"
                && $0.fields["coordinateSource"] == "pendingReceiptStructuralAugmentation"
        })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexAXValueStructuralReceiptWinsOverStaleCoordinateSnapshot() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲乙",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectedTextAttributeIsSettable = true
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { _ in
            // AXValue has the complete post-write content, while
            // AXStringForRange still exposes the pre-write coordinate text.
            // The stale coordinate snapshot cannot be used as confirmation;
            // the shared fallback may use AXValue only after proving the
            // expected coordinate content and local structural delta.
            access.rawText = "甲今\n\n乙"
            access.coordinateOverride = "甲乙"
            access.selection = .init(location: 2, length: 0)
        }
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲今\n\n乙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.totalPosts, 1)
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "ax_coordinate_mapping_fallback"
                && $0.fields["reason"] == "pending_receipt_local_structural_augmentation"
        })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
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

    func testCodexTrailingEmptyParagraphAtDocumentEndAcceptsCollapsedTerminalMarker() async throws {
        let prefix = "草稿"
        let before = prefix + "\n\n\n"
        let afterFirst = prefix + "\n\n甲"
        let afterAppend = prefix + "\n\n甲乙"
        let afterRevision = prefix + "\n\n甲丁"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: before.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = before
        access.writeSnapshots = [
            .init(
                rawText: afterFirst,
                coordinateText: afterFirst,
                selection: .init(location: afterFirst.utf16.count, length: 0)
            ),
            .init(
                rawText: afterAppend,
                coordinateText: afterAppend,
                selection: .init(location: afterAppend.utf16.count, length: 0)
            ),
            .init(
                rawText: afterRevision,
                coordinateText: afterRevision,
                selection: .init(location: afterRevision.utf16.count, length: 0)
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
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()
        try target.replaceTrailingText("甲乙", with: "甲丁")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, afterRevision)
        XCTAssertEqual(access.coordinateText, afterRevision)
        XCTAssertEqual(access.selection, .init(location: afterRevision.utf16.count, length: 0))
        XCTAssertEqual(sender.appendPosts, 2)
        XCTAssertEqual(sender.replacementPosts, 1)
        let acknowledgements = target.drainDiagnostics().filter { $0.event == "keyboard_write_acknowledged" }
        XCTAssertEqual(acknowledgements.count, 3)
        XCTAssertEqual(acknowledgements[0].fields["ackCandidateCount"], "2")
        XCTAssertEqual(acknowledgements[0].fields["receiptRepresentationTransition"], "trailing_newline_collapsed")
        XCTAssertEqual(acknowledgements[0].fields["ackInsertionPositionClass"], "terminal_after_trailing_newline")
        XCTAssertEqual(acknowledgements[1].fields["receiptRepresentationTransition"], "none")
        XCTAssertEqual(acknowledgements[2].fields["receiptRepresentationTransition"], "none")
    }

    func testCodexTerminalTrailingNewlineCandidateRejectsOutsideStructureChange() async throws {
        let before = "草稿\n\n\n"
        let observed = "草稿\n甲"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: before.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = before
        access.writeSnapshots = [
            .init(
                rawText: observed,
                coordinateText: observed,
                selection: .init(location: observed.utf16.count, length: 0)
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
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("an outside structural change must remain unconfirmed")
        } catch { }

        XCTAssertEqual(sender.totalPosts, 1)
        let failure = try XCTUnwrap(target.drainDiagnostics().last { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(failure.fields["comparison"], "documentMismatch")
    }

    func testCodexTerminalTrailingNewlineCandidateDoesNotCollapseCRLF() async throws {
        let before = "草稿\r\n"
        let observed = "草稿\r甲"
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: before.utf16.count, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = before
        access.writeSnapshots = [
            .init(
                rawText: observed,
                coordinateText: observed,
                selection: .init(location: observed.utf16.count, length: 0)
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
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("CRLF must not use the LF-only terminal candidate")
        } catch { }

        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertTrue(target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" })
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

    func testCodexTailReplacementWithSameCaretButMissingBodyCharacterStaysUnconfirmed() async throws {
        let before = String(repeating: "甲", count: 17)
        let observed = String(repeating: "甲", count: 16)
        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 12, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = before
        access.writeSnapshots = [
            .init(
                rawText: observed,
                coordinateText: observed,
                selection: .init(location: 12, length: 0)
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
        try target.replaceTrailingText("甲甲甲", with: "乙乙乙")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("a same-caret body mismatch must not be acknowledged")
        } catch { }

        XCTAssertEqual(sender.replacementPosts, 1)
        let failure = try XCTUnwrap(target.drainDiagnostics().last { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(failure.fields["expectedDocumentLength"], "17")
        XCTAssertEqual(failure.fields["observedLengthUTF16"], "16")
        XCTAssertEqual(failure.fields["expectedSelectionLocation"], "12")
        XCTAssertEqual(failure.fields["actualSelectionLocation"], "12")
        XCTAssertEqual(failure.fields["comparison"], "documentMismatch")
    }

    func testCodexReportShapedMixedBodyAndStructuralChangeStaysUnconfirmed() async throws {
        let before = "甲乙丙丁戊"
        let expectedAfter = "甲乙丙今丁戊"
        let observedRaw = "甲乙丙\n\n丁\n戊"
        let observedCoordinate = "甲乙丙丁戊"
        XCTAssertEqual(expectedAfter.utf16.count, 6)
        XCTAssertEqual(observedRaw.utf16.count, 8)
        XCTAssertEqual(observedCoordinate.utf16.count, 5)

        let access = ReplayAXTextTargetAccess(
            text: before,
            selection: .init(location: 3, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectedTextAttributeIsSettable = true
        access.writeSnapshots = [
            .init(
                rawText: observedRaw,
                coordinateText: observedCoordinate,
                selection: .init(location: 4, length: 0)
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
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("a body mismatch cannot be explained by local structural separators")
        } catch { }

        XCTAssertEqual(sender.totalPosts, 1)
        let failure = try XCTUnwrap(target.drainDiagnostics().last { $0.event == "keyboard_write_unconfirmed" })
        XCTAssertEqual(failure.fields["expectedDocumentLength"], "6")
        XCTAssertEqual(failure.fields["observedLengthUTF16"], "5")
        XCTAssertEqual(failure.fields["expectedSelectionLocation"], "4")
        XCTAssertEqual(failure.fields["actualSelectionLocation"], "4")
        XCTAssertEqual(failure.fields["comparison"], "documentMismatch")
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

    func testSafariInvalidHandleNodeRebuildStopsWithoutRetryingOrResending() async throws {
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
            do {
                try await target.acknowledgeKeyboardWrite()
                XCTFail("A rebuilt Safari text node has no stable identity to inherit the old position")
            } catch {
                XCTAssertEqual(error as? TextTargetError, .targetChanged)
            }
            XCTAssertEqual(access.rawText, draft + "你好")
            XCTAssertEqual(access.selection.location, draft.utf16.count + 2)
            XCTAssertEqual(sender.appendPosts, 1)
            XCTAssertEqual(sender.replacementPosts, 0)
            let diagnostics = target.drainDiagnostics()
            XCTAssertTrue(diagnostics.contains {
                $0.event == "keyboard_target_reacquire_rejected"
                    && $0.fields["phase"] == "invalid_element_read"
                    && $0.fields["reason"] == "stable_unique_editor_continuity_unverified"
            })
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
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "input_application_changed"
                && $0.fields["identityFailure"] == "application_changed"
                && $0.fields["applicationComparison"] == "different"
                && $0.fields["processComparison"] == "different"
        })
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

    func testSystemContinuityScannerUsesInjectableAXReadsAndReportsActualAttributeFailure() throws {
        struct Node {
            let handle: AXUIElement
            var attributes: [String: CFTypeRef]
        }
        final class Clock {
            var date = Date(timeIntervalSince1970: 1_000)
            var monotonic: UInt64 = 1_000_000
        }
        let editor = AXUIElementCreateApplication(70_101)
        let anchor = AXUIElementCreateApplication(70_102)
        let webArea = AXUIElementCreateApplication(70_103)
        let window = AXUIElementCreateApplication(70_104)
        let nodes = [
            Node(handle: editor, attributes: [
                "AXRole": "AXTextArea" as CFString,
                "AXIdentifier": "PRIVATE_IDENTIFIER_SENTINEL" as CFString,
                "AXParent": anchor,
                "AXWindow": window,
                "AXReadOnly": kCFBooleanFalse,
                "AXValue": "PRIVATE_PAGE_TEXT_SENTINEL" as CFString
            ]),
            Node(handle: anchor, attributes: [
                "AXRole": "AXGroup" as CFString,
                "AXChildren": [editor] as CFArray,
                "AXParent": webArea
            ]),
            Node(handle: webArea, attributes: [
                "AXRole": "AXWebArea" as CFString,
                "AXParent": window,
                "AXURL": "PRIVATE_PAGE_URL_SENTINEL" as CFString
            ]),
            Node(handle: window, attributes: [
                "AXRole": "AXWindow" as CFString,
                "AXTitle": "PRIVATE_WINDOW_TITLE_SENTINEL" as CFString
            ])
        ]
        var failure: (node: AXUIElement, attribute: String, status: AXError)?
        var deadlineOnParentRead = false
        var readAttributes: [String] = []
        let clock = Clock()
        let reader = SystemAXTextTargetAccess.ContinuityAXReader(
            copyAttributeValue: { element, attribute in
                readAttributes.append(attribute)
                if let failure, CFEqual(failure.node, element), failure.attribute == attribute {
                    return (failure.status, nil)
                }
                guard let node = nodes.first(where: { CFEqual($0.handle, element) }),
                      let value = node.attributes[attribute] else {
                    return (attribute == "AXChildren" ? .noValue : .attributeUnsupported, nil)
                }
                if attribute == "AXParent", deadlineOnParentRead {
                    deadlineOnParentRead = false
                    clock.date.addTimeInterval(1)
                }
                return (.success, value)
            },
            setMessagingTimeout: { _, _ in },
            processIdentifier: { element in
                nodes.first(where: { CFEqual($0.handle, element) }) == nil ? nil : 70_101
            },
            now: { clock.date },
            monotonicNanoseconds: {
                defer { clock.monotonic += 1_000_000 }
                return clock.monotonic
            }
        )
        let access = SystemAXTextTargetAccess(continuityAXReader: reader)

        let evidence = try XCTUnwrap(access.editorContinuityEvidence(for: editor))
        XCTAssertTrue(evidence.scanComplete)
        XCTAssertEqual(evidence.editableEditorCount, 1)
        XCTAssertEqual(evidence.identifiersFromEditorToAnchor.first ?? nil, "PRIVATE_IDENTIFIER_SENTINEL")

        failure = (anchor, "AXParent", .cannotComplete)
        for _ in 0..<10 {
            XCTAssertNil(access.editorContinuityEvidence(for: editor))
        }
        let drainedDiagnostics = access.drainReadDiagnostics()
        let diagnostic = try XCTUnwrap(drainedDiagnostics.first {
            $0.event == AXTextEditorContinuityScanDiagnostic.event
                && $0.fields["axAttribute"] == "AXParent"
        })
        XCTAssertEqual(diagnostic.fields["reason"], "read_failed")
        XCTAssertEqual(diagnostic.fields["axStatus"], String(AXError.cannotComplete.rawValue))
        XCTAssertEqual(diagnostic.fields["scanStage"], "ancestor_parent")
        XCTAssertFalse(diagnostic.fields.values.contains { $0.contains("AXTextArea") })
        XCTAssertFalse(drainedDiagnostics.flatMap { $0.fields.values }.contains {
            $0.contains("PRIVATE_IDENTIFIER_SENTINEL")
        })
        XCTAssertFalse(readAttributes.contains(where: { ["AXValue", "AXURL", "AXTitle"].contains($0) }),
                       "identity diagnostics must not read page text, URL, or window title")
        let sessionID = UUID()
        let exportedEvents = drainedDiagnostics.map { diagnostic in
            SessionLogEntry(
                timestamp: diagnostic.timestamp,
                monotonicTimestampNanoseconds: diagnostic.monotonicTimestampNanoseconds,
                sessionID: sessionID,
                eventID: diagnostic.eventID,
                event: diagnostic.event,
                metadata: diagnostic.fields
            )
        }
        let reportData = try DiagnosticJSON.encoder().encode(exportedEvents)
        let reportJSON = String(decoding: reportData, as: UTF8.self)
        for sentinel in [
            "PRIVATE_IDENTIFIER_SENTINEL", "PRIVATE_PAGE_TEXT_SENTINEL",
            "PRIVATE_PAGE_URL_SENTINEL", "PRIVATE_WINDOW_TITLE_SENTINEL"
        ] {
            XCTAssertFalse(reportJSON.contains(sentinel), "JSON exported private AX value \(sentinel)")
        }
        let archiveRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuityDiagnosticExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archiveRoot) }
        let archiveURL = archiveRoot.appendingPathComponent("report.zip")
        let frameTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let frameAsset = DiagnosticWindowFrameAsset(
            relativePath: "frames/000001.jpg",
            timestamp: frameTimestamp,
            monotonicNanoseconds: 1,
            jpegData: Data([0xff, 0xd8, 0xff, 0xd9])
        )
        let frameReference = DiagnosticWindowFrameReference(
            relativePath: frameAsset.relativePath,
            timestamp: frameTimestamp,
            monotonicNanoseconds: 1,
            byteCount: frameAsset.jpegData.count
        )
        let frameEvidence = DiagnosticWindowFrameEvidence(
            enabled: true,
            status: "captured",
            permissionGranted: true,
            sessionID: sessionID,
            targetPID: 70_101,
            targetBundleIdentifier: "com.apple.Safari",
            targetWindowID: 1,
            startedAt: frameTimestamp,
            stoppedAt: frameTimestamp,
            maximumFramesPerSecond: 5,
            ringDurationSeconds: 60,
            memoryLimitBytes: 80 * 1_024 * 1_024,
            ringMemoryLimitBytes: 80 * 1_024 * 1_024,
            retainedFrameCount: 1,
            droppedFrameCount: 0,
            retainedBytes: frameAsset.jpegData.count,
            frames: [frameReference],
            archiveStatus: "included"
        )
        try DiagnosticWindowFrameArchiveWriter.write(
            reportData: reportData,
            snapshot: DiagnosticWindowFrameSnapshot(evidence: frameEvidence, assets: [frameAsset]),
            destination: archiveURL
        )
        let listingProcess = Process()
        listingProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listingProcess.arguments = ["-Z1", archiveURL.path]
        let listingPipe = Pipe()
        listingProcess.standardOutput = listingPipe
        try listingProcess.run()
        listingProcess.waitUntilExit()
        XCTAssertEqual(listingProcess.terminationStatus, 0)
        let members = String(decoding: listingPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let reportMember = try XCTUnwrap(members.split(whereSeparator: \.isNewline).map(String.init)
            .first { $0.hasSuffix("/report.json") })
        let extractProcess = Process()
        extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extractProcess.arguments = ["-p", archiveURL.path, reportMember]
        let extractPipe = Pipe()
        extractProcess.standardOutput = extractPipe
        try extractProcess.run()
        extractProcess.waitUntilExit()
        XCTAssertEqual(extractProcess.terminationStatus, 0)
        let archivedJSON = String(decoding: extractPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for sentinel in [
            "PRIVATE_IDENTIFIER_SENTINEL", "PRIVATE_PAGE_TEXT_SENTINEL",
            "PRIVATE_PAGE_URL_SENTINEL", "PRIVATE_WINDOW_TITLE_SENTINEL"
        ] {
            XCTAssertFalse(archivedJSON.contains(sentinel), "ZIP exported private AX value \(sentinel)")
        }
        let archivedEvents = try DiagnosticJSON.decoder().decode([SessionLogEntry].self, from: Data(archivedJSON.utf8))
        XCTAssertTrue(archivedEvents.contains {
            $0.event == AXTextEditorContinuityScanDiagnostic.event
                && $0.metadata["axAttribute"] == "AXParent"
                && $0.metadata["axStatus"] == String(AXError.cannotComplete.rawValue)
        })
        let queueSummary = try XCTUnwrap(drainedDiagnostics.first { $0.event == "ax_read_diagnostic_queue_summary" })
        XCTAssertEqual(queueSummary.fields["capacity"], "16")
        XCTAssertEqual(queueSummary.fields["evictedCount"], "5")
        XCTAssertNotEqual(queueSummary.fields["firstEvictionAt"], "none")
        XCTAssertNotEqual(queueSummary.fields["lastEvictionAt"], "none")
        XCTAssertNotEqual(queueSummary.fields["firstEvictionMonotonicNanoseconds"], "none")
        XCTAssertNotEqual(queueSummary.fields["lastEvictionMonotonicNanoseconds"], "none")
        XCTAssertEqual(queueSummary.timestamp, Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(access.drainReadDiagnostics().isEmpty, "draining reports and resets the bounded counters")

        failure = nil
        deadlineOnParentRead = true
        XCTAssertNil(access.editorContinuityEvidence(for: editor))
        let deadlineDiagnostics = access.drainReadDiagnostics()
        XCTAssertTrue(deadlineDiagnostics.contains {
            $0.event == AXTextEditorContinuityScanDiagnostic.event
                && $0.fields["reason"] == "deadline_exceeded"
                && $0.fields["scanStage"] == "ancestor_role"
        })
        access.setContinuityDiagnosticsEnabled(false)
        XCTAssertNil(access.lastContinuityScanObservationID())
        XCTAssertNil(access.lastContinuityScanSummary())
        XCTAssertTrue(access.drainReadDiagnostics().isEmpty)
    }

    func testSystemContinuityScannerDistinguishesInjectedAXAttributeFailuresAndMissingValues() throws {
        struct Node {
            let handle: AXUIElement
            var attributes: [String: CFTypeRef]
        }
        let editor = AXUIElementCreateApplication(70_201)
        let anchor = AXUIElementCreateApplication(70_202)
        let webArea = AXUIElementCreateApplication(70_203)
        let window = AXUIElementCreateApplication(70_204)
        let nodes = [
            Node(handle: editor, attributes: [
                "AXRole": "AXTextArea" as CFString,
                "AXIdentifier": "PRIVATE_IDENTIFIER_SENTINEL" as CFString,
                "AXParent": anchor,
                "AXWindow": window,
                "AXReadOnly": kCFBooleanFalse
            ]),
            Node(handle: anchor, attributes: [
                "AXRole": "AXGroup" as CFString,
                "AXChildren": [editor] as CFArray,
                "AXParent": webArea
            ]),
            Node(handle: webArea, attributes: [
                "AXRole": "AXWebArea" as CFString,
                "AXParent": window
            ]),
            Node(handle: window, attributes: ["AXRole": "AXWindow" as CFString])
        ]
        typealias ReadOverride = (node: AXUIElement, attribute: String, status: AXError, value: CFTypeRef?)
        var override: ReadOverride?
        var valueSettableNodes: [AXUIElement] = []
        var valueSettableReadCount = 0
        var timeoutValues: [Float] = []
        let reader = SystemAXTextTargetAccess.ContinuityAXReader(
            copyAttributeValue: { element, attribute in
                if let override, CFEqual(override.node, element), override.attribute == attribute {
                    return (override.status, override.value)
                }
                guard let node = nodes.first(where: { CFEqual($0.handle, element) }),
                      let value = node.attributes[attribute] else {
                    return (attribute == "AXChildren" ? .noValue : .attributeUnsupported, nil)
                }
                return (.success, value)
            },
            setMessagingTimeout: { _, timeout in timeoutValues.append(timeout) },
            processIdentifier: { element in
                nodes.first(where: { CFEqual($0.handle, element) }) == nil ? nil : 70_201
            },
            now: Date.init,
            monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            isAttributeSettable: { element, attribute in
                guard attribute == (kAXValueAttribute as String) else { return false }
                valueSettableReadCount += 1
                return valueSettableNodes.contains { CFEqual($0, element) }
            }
        )
        let access = SystemAXTextTargetAccess(continuityAXReader: reader)
        let capturedEvidence = try XCTUnwrap(access.editorContinuityEvidence(for: editor))
        _ = access.drainReadDiagnostics()
        struct FailureCase {
            let node: AXUIElement
            let attribute: String
            let status: AXError
            let value: CFTypeRef?
            let stage: String
            let reason: String
            let evidenceExpected: Bool
        }
        let cases: [FailureCase] = [
            .init(node: editor, attribute: "AXRole", status: .cannotComplete, value: nil,
                  stage: "ancestor_role", reason: "read_failed", evidenceExpected: false),
            .init(node: editor, attribute: "AXIdentifier", status: .cannotComplete, value: nil,
                  stage: "ancestor_identifier", reason: "read_failed", evidenceExpected: false),
            .init(node: anchor, attribute: "AXParent", status: .cannotComplete, value: nil,
                  stage: "ancestor_parent", reason: "read_failed", evidenceExpected: false),
            .init(node: editor, attribute: "AXWindow", status: .cannotComplete, value: nil,
                  stage: "target_window", reason: "read_failed", evidenceExpected: false),
            .init(node: anchor, attribute: "AXChildren", status: .cannotComplete, value: nil,
                  stage: "candidate_children", reason: "read_failed", evidenceExpected: false),
            .init(node: editor, attribute: "AXSubrole", status: .cannotComplete, value: nil,
                  stage: "candidate_subrole", reason: "read_failed", evidenceExpected: false),
            .init(node: editor, attribute: "AXReadOnly", status: .cannotComplete, value: nil,
                  stage: "candidate_read_only", reason: "read_failed", evidenceExpected: false),
            .init(node: editor, attribute: "AXRole", status: .success, value: NSNumber(value: 7),
                  stage: "ancestor_role", reason: "unexpected_value_type", evidenceExpected: false),
            .init(node: anchor, attribute: "AXChildren", status: .success, value: "wrong children type" as CFString,
                  stage: "candidate_children", reason: "unexpected_value_type", evidenceExpected: false),
            .init(node: editor, attribute: "AXReadOnly", status: .success, value: "wrong boolean type" as CFString,
                  stage: "candidate_read_only", reason: "unexpected_value_type", evidenceExpected: false)
        ]

        for failure in cases {
            override = (failure.node, failure.attribute, failure.status, failure.value)
            let evidence = access.editorContinuityEvidence(for: editor)
            XCTAssertEqual(evidence != nil, failure.evidenceExpected, "\(failure.attribute) / \(failure.reason)")
            let diagnostics = access.drainReadDiagnostics()
            let detail = try XCTUnwrap(diagnostics.first {
                $0.event == AXTextEditorContinuityScanDiagnostic.event
                    && $0.fields["axAttribute"] == failure.attribute
            }, "missing diagnostic for \(failure.attribute) / \(failure.reason)")
            XCTAssertEqual(detail.fields["scanStage"], failure.stage)
            XCTAssertEqual(detail.fields["reason"], failure.reason)
            XCTAssertEqual(detail.fields["axStatus"], String(failure.status.rawValue))
        }

        override = (editor, "AXIdentifier", .noValue, nil)
        let evidenceWithMissingIdentifier = try XCTUnwrap(access.editorContinuityEvidence(for: editor))
        XCTAssertNil(evidenceWithMissingIdentifier.identifiersFromEditorToAnchor.first ?? nil)
        let missingIdentifierSummary = try XCTUnwrap(access.drainReadDiagnostics().first {
            $0.event == "editor_continuity_scan_summary"
        })
        XCTAssertEqual(missingIdentifierSummary.fields["identifierPresence"], "missing")

        let anchoredEvidence = try XCTUnwrap(access.editorContinuityEvidence(
            for: editor,
            anchoredAt: capturedEvidence
        ))
        XCTAssertTrue(anchoredEvidence.scanComplete)
        XCTAssertEqual(anchoredEvidence.editableEditorCount, 1)
        let anchoredComparison = AXTextEditorContinuity.compare(capturedEvidence, anchoredEvidence)
        XCTAssertTrue(anchoredComparison.canConfirmFromCapturedAnchor)
        XCTAssertFalse(anchoredComparison.hasIdentifierConflict)
        XCTAssertNil(anchoredEvidence.identifiersFromEditorToAnchor.first ?? nil)

        override = (editor, "AXReadOnly", .noValue, nil)
        valueSettableNodes = [editor]
        let writableFallback = try XCTUnwrap(access.editorContinuityEvidence(
            for: editor,
            anchoredAt: capturedEvidence
        ))
        XCTAssertTrue(writableFallback.scanComplete)
        XCTAssertEqual(writableFallback.editableEditorCount, 1)
        XCTAssertEqual(valueSettableReadCount, 1)
        XCTAssertEqual(
            access.lastContinuityScanSummary()?["writabilityEvidence"],
            "AXValue_settable_after_AXReadOnly_unavailable"
        )

        valueSettableNodes = []
        valueSettableReadCount = 0
        XCTAssertNil(access.editorContinuityEvidence(for: editor, anchoredAt: capturedEvidence))
        XCTAssertEqual(valueSettableReadCount, 1)
        _ = access.drainReadDiagnostics()

        override = (editor, "AXReadOnly", .cannotComplete, nil)
        valueSettableNodes = [editor]
        valueSettableReadCount = 0
        XCTAssertNil(access.editorContinuityEvidence(for: editor, anchoredAt: capturedEvidence))
        XCTAssertEqual(valueSettableReadCount, 0, "transient AX errors must not be converted into writable evidence")

        override = nil
        _ = access.editorContinuityEvidence(for: editor)
        XCTAssertFalse(timeoutValues.isEmpty)
        XCTAssertTrue(timeoutValues.allSatisfy { $0 == 0.03 }, "scanner AX call timeout must remain 30 ms")
    }

    func testRebuildAncestorAndCapturedAnchorScansShareTheExistingDeadline() throws {
        struct Node {
            let handle: AXUIElement
            var attributes: [String: CFTypeRef]
        }
        let editor = AXUIElementCreateApplication(70_211)
        let anchor = AXUIElementCreateApplication(70_212)
        let webArea = AXUIElementCreateApplication(70_213)
        let window = AXUIElementCreateApplication(70_214)
        let nodes = [
            Node(handle: editor, attributes: [
                "AXRole": "AXTextArea" as CFString,
                "AXIdentifier": "stable-editor" as CFString,
                "AXParent": anchor,
                "AXWindow": window,
                "AXReadOnly": kCFBooleanFalse
            ]),
            Node(handle: anchor, attributes: [
                "AXRole": "AXGroup" as CFString,
                "AXChildren": [editor] as CFArray,
                "AXParent": webArea
            ]),
            Node(handle: webArea, attributes: [
                "AXRole": "AXWebArea" as CFString,
                "AXParent": window
            ]),
            Node(handle: window, attributes: ["AXRole": "AXWindow" as CFString])
        ]
        var monotonicNanoseconds: UInt64 = 0
        var slowReads = false
        var attributeReadCount = 0
        let reader = SystemAXTextTargetAccess.ContinuityAXReader(
            copyAttributeValue: { element, attribute in
                attributeReadCount += 1
                if slowReads { monotonicNanoseconds += 100_000_000 }
                guard let node = nodes.first(where: { CFEqual($0.handle, element) }),
                      let value = node.attributes[attribute] else {
                    return (attribute == "AXChildren" ? .noValue : .attributeUnsupported, nil)
                }
                return (.success, value)
            },
            setMessagingTimeout: { _, _ in },
            processIdentifier: { element in
                nodes.first(where: { CFEqual($0.handle, element) }) == nil ? nil : 70_211
            },
            now: { Date(timeIntervalSince1970: Double(monotonicNanoseconds) / 1_000_000_000) },
            monotonicNanoseconds: { monotonicNanoseconds }
        )
        let access = SystemAXTextTargetAccess(continuityAXReader: reader)
        let captured = try XCTUnwrap(access.editorContinuityEvidence(for: editor))
        access.setContinuityScanBudgetNanoseconds(250_000_000)
        slowReads = true

        XCTAssertNil(access.editorContinuityEvidence(for: editor))
        let readsAfterAncestorScan = attributeReadCount
        XCTAssertGreaterThan(readsAfterAncestorScan, 0)
        XCTAssertNil(access.editorContinuityEvidence(for: editor, anchoredAt: captured))
        XCTAssertEqual(
            attributeReadCount,
            readsAfterAncestorScan,
            "the captured-anchor scan must not start a fresh 250 ms window"
        )
        XCTAssertTrue(access.drainReadDiagnostics().contains {
            $0.event == "editor_continuity_scan_summary"
                && $0.fields["scanPath"] == "captured_anchor_subtree"
                && $0.fields["scanComplete"] == "false"
        })
        access.setContinuityScanBudgetNanoseconds(nil)
    }

    func testInitialContinuityCaptureOutcomesAreDistinct() {
        XCTAssertEqual(AXTextEditorContinuity.captureOutcome(
            continuityApplicable: false,
            continuityTargetApplication: true,
            focusedElementAvailable: false,
            evidenceSaved: false,
            scanSummary: nil
        ), "focused_element_missing")
        XCTAssertEqual(AXTextEditorContinuity.captureOutcome(
            continuityApplicable: false,
            continuityTargetApplication: false,
            focusedElementAvailable: true,
            evidenceSaved: false,
            scanSummary: nil
        ), "not_applicable")
        XCTAssertEqual(AXTextEditorContinuity.captureOutcome(
            continuityApplicable: true,
            continuityTargetApplication: true,
            focusedElementAvailable: true,
            evidenceSaved: true,
            scanSummary: nil
        ), "saved")
        XCTAssertEqual(AXTextEditorContinuity.captureOutcome(
            continuityApplicable: true,
            continuityTargetApplication: true,
            focusedElementAvailable: true,
            evidenceSaved: false,
            scanSummary: ["stopReason": "no_unique_editable_editor"]
        ), "candidate_not_unique")
        XCTAssertEqual(AXTextEditorContinuity.captureOutcome(
            continuityApplicable: true,
            continuityTargetApplication: true,
            focusedElementAvailable: true,
            evidenceSaved: false,
            scanSummary: ["stopReason": "deadline_exceeded"]
        ), "scan_incomplete")
        XCTAssertEqual(AXTextEditorContinuity.captureOutcome(
            continuityApplicable: true,
            continuityTargetApplication: true,
            focusedElementAvailable: true,
            evidenceSaved: false,
            scanSummary: ["failureAttribute": "AXParent", "stopReason": "read_failed"]
        ), "scan_failed")
        XCTAssertEqual(AXTextEditorContinuity.captureOutcome(
            continuityApplicable: true,
            continuityTargetApplication: true,
            focusedElementAvailable: true,
            evidenceSaved: false,
            scanSummary: nil
        ), "scan_unavailable")
    }

    func testContinuityDiagnosticSummaryIsBoundedByEncodedJSONSize() throws {
        let fields = Dictionary(uniqueKeysWithValues: (0..<200).map { index in
            ("field\(index)", String(repeating: "界", count: 100))
        })

        let bounded = boundedContinuityDiagnosticFields(fields)
        let encoded = try JSONSerialization.data(withJSONObject: bounded, options: [.sortedKeys])

        XCTAssertLessThanOrEqual(encoded.count, 8_192)
        XCTAssertEqual(bounded["diagnosticSummaryTruncated"], "true")
        XCTAssertLessThan(bounded.count, fields.count)
    }

    func testSafariContinuityScanDiagnosticKeepsAXReadFailureDetailsWithoutText() {
        let fields = AXTextEditorContinuityScanDiagnostic.fields(
            stage: "ancestor_parent",
            reason: "read_failed",
            attribute: "AXParent",
            status: AXError.invalidUIElement.rawValue,
            depth: 2,
            candidateCount: 3,
            elapsedMilliseconds: 17
        )

        XCTAssertEqual(AXTextEditorContinuityScanDiagnostic.event, "editor_continuity_scan_diagnostic")
        XCTAssertEqual(fields["scanStage"], "ancestor_parent")
        XCTAssertEqual(fields["reason"], "read_failed")
        XCTAssertEqual(fields["axAttribute"], "AXParent")
        XCTAssertEqual(fields["axStatus"], String(AXError.invalidUIElement.rawValue))
        XCTAssertEqual(fields["depth"], "2")
        XCTAssertEqual(fields["candidateCount"], "3")
        XCTAssertEqual(fields["elapsedMilliseconds"], "17")
        XCTAssertNil(fields["text"])
        XCTAssertNil(fields["audio"])
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

    func testSafariWebTextAreaKeepsFirstCharacterAndRevisionWhenAXWriteIsNoOp() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.axWriteNoOp = true
        access.configureWebAncestorChain(depth: 4, webURL: URL(string: "https://poe.com/chat/test"))
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(access: access, keyboardEventSender: sender))

        try injector.begin()
        injector.apply(projection: projection("甲", revision: 1))
        try await injector.finish(finalText: "甲")
        injector.apply(projection: projection("甲乙", revision: 2))
        try await injector.finish(finalText: "甲乙")

        XCTAssertEqual(access.rawText, "甲乙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testSafariWebTextAreaDoesNotMistakeIdenticalEditorForRebuiltTarget() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4, webURL: URL(string: "https://poe.com/chat/test"))
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(access: access, keyboardEventSender: sender))

        try injector.begin()
        injector.apply(projection: projection("甲", revision: 1))
        try await injector.finish(finalText: "甲")

        access.focusChanged = true
        injector.apply(projection: projection("甲乙", revision: 2))
        try await injector.finish(finalText: "甲乙")

        XCTAssertEqual(access.rawText, "甲")
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
        XCTAssertEqual(injector.modeDescription, "safe_copy")
    }

    func testSafariWebTextFieldUsesAcknowledgedKeyboardWhenAXWriteIsNoOp() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.textAttributesAreSettable = true
        access.axWriteNoOp = true
        access.configureWebAncestorChain(depth: 4, role: "AXTextField")
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(access: access, keyboardEventSender: sender))

        try injector.begin()
        injector.apply(projection: projection("查", revision: 1))
        try await injector.finish(finalText: "查")

        XCTAssertEqual(access.rawText, "查")
        XCTAssertEqual(access.selection, .init(location: 1, length: 0))
        XCTAssertEqual(access.axTextWrites, 0)
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testSafariWebTailReplacementDoesNotTrustAXSelectionWriteAsPageSelection() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.selectionRangeIsSettable = true
        access.simulateAXSelectionWriteAcceptedButDoesNotMoveEditor = true
        access.configureWebAncestorChain(depth: 23, webURL: URL(string: "https://poe.com/chat/test"))
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(access: access, keyboardEventSender: sender))

        try injector.begin()
        injector.apply(projection: projection("甲乙", revision: 1))
        try await injector.finish(finalText: "甲乙")
        injector.apply(projection: projection("甲丙", revision: 2))
        try await injector.finish(finalText: "甲丙")

        XCTAssertEqual(access.rawText, "甲丙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(access.selectionSetCalls, 0)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertTrue(injector.drainDiagnostics().contains {
            $0.event == "keyboard_selection_submitted" && $0.fields["route"] == "keyboard"
        })
    }

    func testChromeWebTailReplacementDoesNotTrustAXSelectionWriteAsPageSelection() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 9001)
        )
        access.selectionRangeIsSettable = true
        access.simulateAXSelectionWriteAcceptedButDoesNotMoveEditor = true
        access.configureWebAncestorChain(depth: 23, webURL: URL(string: "https://poe.com/chat/test"))
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(access: access, keyboardEventSender: sender))

        try injector.begin()
        injector.apply(projection: projection("甲乙", revision: 1))
        try await injector.finish(finalText: "甲乙")
        injector.apply(projection: projection("甲丙", revision: 2))
        try await injector.finish(finalText: "甲丙")

        XCTAssertEqual(access.rawText, "甲丙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertEqual(sender.selectionPosts, 1)
        XCTAssertEqual(access.selectionSetCalls, 0)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertTrue(injector.drainDiagnostics().contains {
            $0.event == "keyboard_selection_submitted" && $0.fields["route"] == "keyboard"
        })
    }

    func testReplayAXSelectionWriteCanSucceedWithoutMovingWebEditorSelection() throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲乙",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.simulateAXSelectionWriteAcceptedButDoesNotMoveEditor = true
        let requested = ReplayTextRange(location: 1, length: 1)

        XCTAssertEqual(try access.setSelection(requested, on: access.element), AXError.success.rawValue)
        XCTAssertEqual(access.selection, requested)
        XCTAssertEqual(access.editorSelection, .init(location: 2, length: 0))
    }

    func testSafariProseMirrorNodeRebuildStopsBeforeTheNextWrite() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.proseMirror = true
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
        XCTAssertEqual(access.rawText, "你好\n")

        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("你好继续", revision: 2))
        try await injector.finish(finalText: "你好继续")

        XCTAssertEqual(access.rawText, "你好\n")
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        XCTAssertTrue(injector.drainDiagnostics().contains {
            $0.event == "keyboard_target_reacquire_rejected"
                && $0.fields["reason"] == "stable_unique_editor_continuity_unverified"
        })
    }

    func testSafariComposerLayoutRebuildReacquiresUniqueSameEditorWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("你好", revision: 1))
        try await injector.finish(finalText: "你好")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("你好继续", revision: 2))
        try await injector.finish(finalText: "你好继续")

        XCTAssertEqual(access.rawText, "你好继续\n")
        XCTAssertEqual(sender.totalPosts, 2, "the replacement handle must not cause the acknowledged append to be sent twice")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquired"
                && $0.fields["editableEditorCount"] == "1"
        }, "\(diagnostics.map { ($0.event, $0.fields) })")
    }

    func testSafariRebuildAcceptsCapturedAXProcessWhenItDiffersFromAppProcess() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.elementProcessIdentifier = 9002
        access.rebuiltElementProcessIdentifier = 9002
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("前文", revision: 1))
        try await injector.finish(finalText: "前文")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("前文续写", revision: 2))
        try await injector.finish(finalText: "前文续写")

        XCTAssertEqual(access.rawText, "前文续写\n")
        XCTAssertEqual(sender.totalPosts, 2, "the rebuilt AX target must receive only the new suffix")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testSafariRebuildRejectsAXProcessDifferentFromCapturedTarget() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.elementProcessIdentifier = 9002
        access.rebuiltElementProcessIdentifier = 9003
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.anchoredContinuityAvailable = true
        access.replayEditorIdentifier = nil
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("安全", revision: 1))
        try await injector.finish(finalText: "安全")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("安全续写", revision: 2))
        try await injector.finish(finalText: "安全续写")

        XCTAssertEqual(access.rawText, "安全\n")
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        XCTAssertEqual(
            injector.drainDiagnostics().first { $0.event == "safe_copy_updated" }?.textEvidence.first?.text,
            "安全续写"
        )
    }

    func testSafariRebuildUsesCapturedAnchorProofWhenReadOnlyContextIsTemporarilyMissing() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.anchoredContinuityAvailable = true
        access.replayEditorIdentifier = nil
        access.rebuiltReadOnlyUnavailable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("Safari", revision: 1))
        try await injector.finish(finalText: "Safari")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("Safari恢复", revision: 2))
        try await injector.finish(finalText: "Safari恢复")

        XCTAssertEqual(access.rawText, "Safari恢复\n")
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
    }

    func testSafariDiscardsSnapshotWhenEditorRebuildsDuringAcknowledgementRead() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.anchoredContinuityAvailable = true
        access.replayEditorIdentifier = nil
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { text in
            access.applyAppend(text)
            access.onTextRead = { access.focusedElementRebuildsBeforeNextWrite = 1 }
        }
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("同一输入框", revision: 1))
        try await injector.finish(finalText: "同一输入框")

        XCTAssertEqual(access.rawText, "同一输入框\n")
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 0)
        let diagnostics = injector.drainDiagnostics()
        let reacquired = try XCTUnwrap(diagnostics.firstIndex {
            $0.event == "keyboard_target_reacquired"
        })
        let observed = try XCTUnwrap(diagnostics.firstIndex {
            $0.event == "keyboard_document_observed" && $0.fields["phase"] == "acknowledgement"
        })
        XCTAssertLessThan(reacquired, observed, "the old-handle read must be discarded before acknowledgement")
        XCTAssertEqual(diagnostics.filter { $0.event == "keyboard_write_acknowledged" }.count, 1)
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquired"
                && $0.fields["identityOutcome"] == "confirmed_by_captured_anchor_without_identifier"
                && $0.fields["fallbackRoute"] == "attempted_captured_anchor_subtree"
        })
    }

    func testSafariComposerLayoutRebuildRecoversFromAncestorReadFailureWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.anchoredContinuityAvailable = true
        let sender = ReplayKeyboardEventSender(access: access)
        var now: UInt64 = 0
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { now }, sleep: { now += $0 }),
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("你好", revision: 1))
        try await injector.finish(finalText: "你好")
        access.safariContinuityUnavailableReadsBeforeRecovery = 1
        access.textInputContextOverride = { _ in
            AXTextInputTargetContext(
                role: "AXTextArea",
                hasWebAreaAncestor: false,
                webURL: nil,
                isReadOnly: false,
                isSecure: false,
                ancestorScanStatus: .readFailure
            )
        }
        sender.beforeNextAppend = { access.focusedElementRebuildsBeforeNextWrite = 1 }
        injector.apply(projection: projection("你好继续", revision: 2))
        try await injector.finish(finalText: "你好继续")

        let diagnostics = injector.drainDiagnostics()
        XCTAssertEqual(access.rawText, "你好继续\n")
        XCTAssertEqual(sender.totalPosts, 2, "the rebuilt handle must not cause an acknowledged append to be sent twice")
        XCTAssertEqual(injector.errorCount, 0, "\(diagnostics.map { ($0.event, $0.fields) })")
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquired"
                && $0.fields["continuityRoute"] == "captured_anchor_subtree"
        }, "\(diagnostics.filter { $0.event.contains("reacquir") }.map { ($0.event, $0.fields) })")
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_identity_confirmed"
                && $0.fields["continuityRoute"] == "captured_anchor_subtree"
        })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_target_reacquire_rejected" })
    }

    func testCodexComposerLayoutRebuildRecoversFromAncestorReadFailureWithoutResending() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.simulateSafariEditorLayoutRebuild = true
        access.anchoredContinuityAvailable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection("乙", revision: 1))
        try await injector.finish(finalText: "乙")
        access.safariContinuityUnavailableReadsBeforeRecovery = 1
        sender.beforeNextAppend = { access.focusedElementRebuildsBeforeNextWrite = 1 }
        access.queuedTextInputContexts = [AXTextInputTargetContext(
            role: "AXTextArea",
            hasWebAreaAncestor: false,
            webURL: nil,
            isReadOnly: false,
            isSecure: false,
            ancestorScanStatus: .readFailure
        )]

        injector.apply(projection: projection("乙丙", revision: 2))
        try await injector.finish(finalText: "乙丙")

        XCTAssertEqual(access.rawText, "甲乙丙")
        XCTAssertEqual(sender.totalPosts, 2)
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquired"
                && $0.fields["continuityRoute"] == "captured_anchor_subtree"
        }, "\(diagnostics.filter { $0.event.contains("reacquir") }.map { ($0.event, $0.fields) })")
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_target_reacquire_rejected" })
    }

    func testSafariComposerLayoutRebuildStopsWhenContinuityRemainsUnverifiable() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        let sender = ReplayKeyboardEventSender(access: access)
        var now: UInt64 = 0
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { now }, sleep: { now += $0 }),
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("你好", revision: 1))
        try await injector.finish(finalText: "你好")
        access.focusedElementRebuildsBeforeNextWrite = 1
        access.replayEditorIdentifier = nil
        injector.apply(projection: projection("你好继续", revision: 2))
        try await injector.finish(finalText: "你好继续")

        XCTAssertEqual(access.rawText, "你好\n")
        XCTAssertEqual(sender.totalPosts, 1, "unverified editor recovery must not dispatch the pending append")
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquire_retryable"
                && $0.fields["retryWindow"] == "existing_operation_deadline"
                && $0.fields["reason"] == "continuity_evidence_unavailable"
                && $0.fields["fallbackRoute"] == "attempted_captured_anchor_subtree"
                && $0.fields["identityOutcome"] == "identifier_missing_requires_captured_anchor_scan"
        }, "\(diagnostics.map { ($0.event, $0.fields) })")
        XCTAssertEqual(
            diagnostics.first { $0.event == "safe_copy_updated" }?.textEvidence.first?.text,
            "你好继续"
        )
    }

    func testInitialContinuityEvidenceFailureIsDistinctFromReplacementMismatch() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.safariContinuityUnavailableReadsBeforeRecovery = 1
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("首段", revision: 1))
        try await injector.finish(finalText: "首段")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("首段后续", revision: 2))
        try await injector.finish(finalText: "首段后续")

        let diagnostics = injector.drainDiagnostics()
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_editor_continuity_captured"
                && $0.fields["continuityApplicable"] == "true"
                && $0.fields["continuityEvidenceSaved"] == "false"
                && $0.fields["captureOutcome"] != nil
        })
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquire_rejected"
                && $0.fields["continuityFailure"] == "captured_evidence_missing"
                && $0.fields["fallbackRoute"] == "not_attempted_no_captured_anchor"
        })
    }

    func testSafariComposerWithMultipleIdenticalEditorsDoesNotReacquireByMatchingText() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.replayEditorIdentifier = nil
        access.anchoredContinuityAvailable = true
        access.safariEditableEditorCount = 2
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(access: access, keyboardEventSender: sender))

        try injector.begin()
        injector.apply(projection: projection("相同", revision: 1))
        try await injector.finish(finalText: "相同")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("相同后续", revision: 2))
        try await injector.finish(finalText: "相同后续")

        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(access.anchoredContinuityScanCount, 0)
        let diagnostics = injector.drainDiagnostics()
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquire_rejected"
                && $0.fields["reason"] == "stable_unique_editor_continuity_unverified"
        })
    }

    func testSafariReplacementWithoutStableEditorIdentifierRecoversFromUniqueCapturedAnchor() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.replayEditorIdentifier = nil
        access.anchoredContinuityAvailable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("相同", revision: 1))
        try await injector.finish(finalText: "相同")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("相同后续", revision: 2))
        try await injector.finish(finalText: "相同后续")

        XCTAssertEqual(access.rawText, "相同后续\n")
        XCTAssertEqual(sender.totalPosts, 2, "the recovered editor should receive only the new suffix")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        let diagnostics = injector.drainDiagnostics()
        let reacquired = try XCTUnwrap(diagnostics.first {
            $0.event == "keyboard_target_reacquired"
                && $0.fields["continuityRoute"] == "captured_anchor_subtree"
        })
        XCTAssertEqual(reacquired.fields["identityOutcome"], "confirmed_by_captured_anchor_without_identifier")
        XCTAssertEqual(reacquired.fields["leafIdentifierPresence"], "missing")
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_target_reacquire_rejected" })
    }

    func testSafariCapturedAnchorRecoveryRejectsChangedIdentifierWithoutScanningFallback() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.proseMirror = true
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.anchoredContinuityAvailable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("原文", revision: 1))
        try await injector.finish(finalText: "原文")
        access.replayEditorIdentifier = "different-editor-identifier"
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("原文后续", revision: 2))
        try await injector.finish(finalText: "原文后续")

        XCTAssertEqual(access.rawText, "原文\n")
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        XCTAssertEqual(access.anchoredContinuityScanCount, 0)
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquire_rejected"
                && $0.fields["identityOutcome"] == "identity_conflict"
                && $0.fields["firstMismatch"] == "leaf_identifier"
                && $0.fields["fallbackRoute"] == "not_attempted_ancestor_evidence_conflicts_or_structure_differs"
        })
        XCTAssertEqual(
            diagnostics.first { $0.event == "safe_copy_updated" }?.textEvidence.first?.text,
            "原文后续"
        )
    }

    func testCodexComposerWithMultipleIdenticalEditorsDoesNotReacquireByMatchingText() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "\n",
            selection: .init(location: 0, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.replayEditorIdentifier = nil
        access.anchoredContinuityAvailable = true
        access.safariEditableEditorCount = 2
        let sender = ReplayKeyboardEventSender(access: access)
        sender.beforeNextAppend = { access.focusedElementRebuildsBeforeNextWrite = 1 }
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("相同后续", revision: 1))
        try await injector.finish(finalText: "相同后续")

        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(access.anchoredContinuityScanCount, 0)
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquire_rejected"
                && $0.fields["reason"] == "stable_unique_editor_continuity_unverified"
        }, "\(diagnostics.map { ($0.event, $0.fields) })")
        XCTAssertEqual(
            diagnostics.first { $0.event == "safe_copy_updated" }?.textEvidence.first?.text,
            "相同后续"
        )
    }

    func testCodexReplacementWithoutStableEditorIdentifierRecoversFromUniqueCapturedAnchor() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        access.replayEditorIdentifier = nil
        access.anchoredContinuityAvailable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("乙", revision: 1))
        try await injector.finish(finalText: "乙")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("乙丙", revision: 2))
        try await injector.finish(finalText: "乙丙")

        XCTAssertEqual(access.rawText, "甲乙丙")
        XCTAssertEqual(sender.totalPosts, 2, "the recovered editor should receive only the new suffix")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        let diagnostics = injector.drainDiagnostics()
        let reacquired = try XCTUnwrap(diagnostics.first {
            $0.event == "keyboard_target_reacquired"
                && $0.fields["continuityRoute"] == "captured_anchor_subtree"
        })
        XCTAssertEqual(reacquired.fields["identityOutcome"], "confirmed_by_captured_anchor_without_identifier")
        XCTAssertEqual(reacquired.fields["leafIdentifierPresence"], "missing")
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_target_reacquire_rejected" })
    }

    func testCodexReplacementWithStableEditorIdentifierRecoversBeforeNextWrite() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.coordinateIncludesStructuralSeparators = true
        access.simulateSafariEditorLayoutRebuild = true
        let sender = ReplayKeyboardEventSender(access: access)
        let injector = TextInjector(target: AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        ))

        try injector.begin()
        injector.apply(projection: projection("乙", revision: 1))
        try await injector.finish(finalText: "乙")
        access.focusedElementRebuildsBeforeNextWrite = 1
        injector.apply(projection: projection("乙丙", revision: 2))
        try await injector.finish(finalText: "乙丙")

        XCTAssertEqual(access.rawText, "甲乙丙")
        XCTAssertEqual(sender.totalPosts, 2, "the confirmed replacement should receive only the pending suffix")
        XCTAssertEqual(injector.errorCount, 0)
        XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
        let diagnostics = injector.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_target_reacquired"
                && $0.fields["reason"] == "same_web_area_unique_editor_anchor_and_expected_document"
        })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_target_reacquire_rejected" })
    }

    func testCodexRebuildAfterApplicationSwitchIsRejectedBeforeAnotherWrite() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()
        access.currentApplicationOverride = .init(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 9002)
        do {
            try target.paste("丙")
            XCTFail("A different foreground process must block keyboard continuation")
        } catch {
            XCTAssertEqual(error as? TextTargetError, .targetChanged)
        }

        XCTAssertEqual(sender.totalPosts, 1)
    }

    func testCodexRebuildInAnotherWindowIsRejectedBeforeAnotherWrite() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.simulateSafariEditorLayoutRebuild = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        _ = try target.capture()
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()
        access.focusedElementRebuildsBeforeNextWrite = 1
        access.replayWindow = AXUIElementCreateApplication(9007)
        do {
            try target.paste("丙")
            XCTFail("A focused editor in another window must not inherit the old target")
        } catch {
            XCTAssertEqual(error as? TextTargetError, .targetChanged)
        }

        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertTrue(target.drainDiagnostics().contains {
            $0.event == "keyboard_target_reacquire_rejected"
                && $0.fields["reason"] == "stable_unique_editor_continuity_unverified"
        })
    }

    func testCodexRebuildIsRejectedWhileOldAccessibilityHandleStillWorks() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 4)
        access.simulateSafariEditorLayoutRebuild = true
        access.rebuiltTargetLeavesOldHandleValid = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        _ = try target.capture()
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()
        access.focusedElementRebuildsBeforeNextWrite = 1
        do {
            try target.paste("丙")
            XCTFail("A live old handle must not be replaced by text similarity")
        } catch {
            XCTAssertEqual(error as? TextTargetError, .targetChanged)
        }

        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertTrue(target.drainDiagnostics().contains {
            $0.event == "keyboard_target_reacquire_rejected"
                && $0.fields["reason"] == "old_handle_or_process_not_verified"
        })
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
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        XCTAssertEqual(injector.degradationCode, "text_target_write_failed")
    }

    func testSafariProseMirrorStopsAfterTailReplacementWhenNodeRebuilds() async throws {
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
        XCTAssertEqual(injector.errorCount, 1)
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        XCTAssertTrue(injector.drainDiagnostics().contains {
            $0.event == "keyboard_target_reacquire_rejected"
                && $0.fields["reason"] == "stable_unique_editor_continuity_unverified"
        })

        injector.apply(projection: projection("您好继续", revision: 3))
        try await injector.finish(finalText: "您好继续")
        XCTAssertEqual(access.rawText, "已有您好\n")
        XCTAssertEqual(sender.totalPosts, 2)
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
        access.configureNativeAncestorChain(role: "AXTextField")
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
            .acknowledgedKeyboard(reason: "web_editable_text_control")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(
                application: TextTargetApplication(
                    name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001
                ),
                context: AXTextInputTargetContext(
                    role: "AXTextArea", hasWebAreaAncestor: true, webURL: nil,
                    isReadOnly: false, isSecure: false, ancestorScanStatus: .readFailure
                )
            ),
            .acknowledgedKeyboard(reason: "codex_editable_text_control")
        )
        for bundleIdentifier in ["md.obsidian"] {
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
                "Obsidian must keep its specialized route when ancestry cannot be classified"
            )
        }
        let safari = TextTargetApplication(
            name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001
        )
        for scanStatus in [AXTextAncestorScanStatus.truncated, .cycle, .readFailure] {
            XCTAssertEqual(
                AXTextInputStrategy.select(
                    application: safari,
                    context: AXTextInputTargetContext(
                        role: "AXTextArea", hasWebAreaAncestor: false, webURL: nil,
                        isReadOnly: false, isSecure: false, ancestorScanStatus: scanStatus
                    )
                ),
                .safeStop(reason: "web_ancestor_unclassified"),
                "Safari must stop when web ancestry is uncertain: \(scanStatus)"
            )
        }
        XCTAssertEqual(
            AXTextInputStrategy.select(
                application: safari,
                context: AXTextInputTargetContext(
                    role: "AXTextField", hasWebAreaAncestor: false, webURL: nil,
                    isReadOnly: false, isSecure: false, ancestorScanStatus: .completeWithoutWebArea
                )
            ),
            .accessibility,
            "confirmed native Safari fields keep the normal AX route"
        )
    }

    func testCodexRoutingRequiresReadableEditableTextAndStopsWhenUnclassified() {
        let codex = TextTargetApplication(
            name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001
        )
        let editable = AXTextInputTargetContext(
            role: "AXTextArea", hasWebAreaAncestor: false, webURL: nil,
            isReadOnly: false, isSecure: false, ancestorScanStatus: .completeWithoutWebArea
        )

        XCTAssertEqual(
            AXTextInputStrategy.select(application: codex, context: editable),
            .acknowledgedKeyboard(reason: "codex_editable_text_control")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(application: codex, context: editable, hasReadableTextState: false),
            .safeStop(reason: "codex_text_state_unreadable")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(application: codex, context: nil),
            .safeStop(reason: "codex_target_unclassified")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(application: codex, context: AXTextInputTargetContext(
                role: "AXTextArea", hasWebAreaAncestor: false, webURL: nil,
                isReadOnly: nil, isSecure: false
            )),
            .safeStop(reason: "codex_editability_unknown")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(application: codex, context: AXTextInputTargetContext(
                role: "AXTextArea", hasWebAreaAncestor: false, webURL: nil,
                isReadOnly: false, isSecure: true
            )),
            .safeStop(reason: "web_control_not_editable")
        )
        XCTAssertEqual(
            AXTextInputStrategy.select(application: codex, context: AXTextInputTargetContext(
                role: "AXButton", hasWebAreaAncestor: false, webURL: nil,
                isReadOnly: false, isSecure: false
            )),
            .safeStop(reason: "codex_target_unclassified")
        )
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
        XCTAssertEqual(injector.modeDescription, "safe_copy")
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
        XCTAssertEqual(injector.modeDescription, "safe_copy")
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

    func testSafariWebEditorRetriesTemporaryStrategyReadFailureWithoutDroppingAppend() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 3, webURL: URL(string: "https://example.com"))
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        _ = try target.capture()

        let confirmedPrefix = String(repeating: "甲", count: 225)
        try await target.writeKeyboardText(previousText: "", with: confirmedPrefix)
        XCTAssertEqual(access.rawText, confirmedPrefix)

        let recoveredWebContext = AXTextInputTargetContext(
            role: "AXTextArea",
            hasWebAreaAncestor: true,
            webURL: URL(string: "https://example.com"),
            isReadOnly: false,
            isSecure: false,
            ancestorScanStatus: .webArea,
            webAreaDepth: 3
        )
        access.queuedTextInputContexts = [nil, recoveredWebContext]
        try await target.writeKeyboardText(previousText: "", with: "乙")

        XCTAssertEqual(access.rawText, confirmedPrefix + "乙")
        XCTAssertEqual(sender.totalPosts, 2, "the confirmed prefix is not resent")
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains { $0.event == "input_strategy_read_retryable" })
        XCTAssertFalse(diagnostics.contains { $0.event == "input_strategy_changed" })
        XCTAssertEqual(diagnostics.filter { $0.event == "keyboard_write_acknowledged" }.count, 2)
    }

    func testSafariWebEditorStillStopsForConfirmedNativeControl() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "",
            application: .init(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 9001)
        )
        access.configureWebAncestorChain(depth: 3)
        let sender = ReplayKeyboardEventSender(access: access)
        var clock: UInt64 = 0
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            writeTiming: .init(now: { clock }, sleep: { clock += $0 })
        )
        _ = try target.capture()
        access.configureNativeAncestorChain()

        do {
            try await target.writeKeyboardText(previousText: "", with: "不应发送")
            XCTFail("a confirmed native Safari control must not inherit the web editor route")
        } catch {
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
            XCTAssertEqual(injector.modeDescription, "safe_copy", change)
            XCTAssertEqual(injector.degradationCode, "text_target_changed", change)
            if change == "external" {
                XCTAssertEqual(access.rawText, "用户编辑")
            } else {
                XCTAssertEqual(access.rawText, "已有语音")
            }
        }
    }

    func testCodexWithoutReadableAXTextStopsAndKeepsRecognitionForSafeCopy() throws {
        let access = ReplayAXTextTargetAccess(
            text: "草稿",
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.alwaysFailTextReads = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)
        let injector = TextInjector(target: target, alwaysSaveVoiceContent: true)

        try injector.begin()
        XCTAssertEqual(injector.modeDescription, "safe_copy")
        XCTAssertFalse(target.requiresKeyboardAcknowledgement)
        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertEqual(access.rawText, "草稿")
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

    func testCodexReconciliationRejectsOutsideStructuralChangeWithSameCoordinateText() throws {
        let access = ReplayAXTextTargetAccess(
            text: "左\n右",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(access: access, keyboardEventSender: sender)

        _ = try target.capture()

        // Keep the logical coordinate document and caret unchanged while a
        // paragraph marker is inserted outside the confirmed position. This
        // is an external editor state change, not a receipt for our write.
        access.rawText = "左\n\n右"
        access.selection = .init(location: 2, length: 0)

        XCTAssertEqual(try target.reconcileKeyboardStateForUserEdit(), .externalEdit)
        XCTAssertEqual(sender.totalPosts, 0)
        XCTAssertTrue(
            target.drainDiagnostics().contains {
                $0.event == "keyboard_user_edit_detected"
                    && $0.fields["comparison"] == "rawTextMismatch"
            }
        )
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

    func testCodexReplayRetriesTransientFocusReadDuringSelectionStabilization() async throws {
        let firstRecognizedText = "那跟这个"
        let fullRecognizedText = "那跟这个后面的整段语音"
        let access = ReplayAXTextTargetAccess(
            text: firstRecognizedText,
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.selectionRangeIsSettable = true
        let sender = ReplayKeyboardEventSender(access: access)
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            preflightTimeoutNanoseconds: 100_000_000,
            acknowledgementTimeoutNanoseconds: 100_000_000
        )

        _ = try target.capture()
        // capture -> preflight's before/after focus reads -> safe-target check;
        // this is the extra AXFocusedUIElement read in synchronous selection
        // stabilization immediately before the next keyboard operation.
        access.failFocusedElementReadAtCount = access.focusedElementReadCount + 4

        try await target.writeKeyboardText(previousText: firstRecognizedText, with: fullRecognizedText)
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, fullRecognizedText)
        XCTAssertEqual(sender.replacementPosts, 1, "a transient read must not duplicate the replacement")
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "keyboard_state_read_retryable"
                && $0.fields["phase"] == "selection_stabilization"
        })
        XCTAssertTrue(diagnostics.contains { $0.event == "keyboard_write_acknowledged" })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
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
        XCTAssertEqual(injector.modeDescription, "safe_copy")
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
                rawText: "甲丙乙\n",
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
        XCTAssertEqual(failure.fields["ackDiffEarly0Classification"], "structural_outside")
        XCTAssertEqual(failure.fields["ackDiffFinal0Classification"], "structural_outside")
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

    func testCodexExactAXValueReceiptConfirmsWhenCoordinateReadIsUnavailable() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { text in
            access.applyAppend(text)
            access.failNextCoordinateReads = 100
            access.armPostWriteReplay()
        }
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("乙")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲乙")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertGreaterThan(access.coordinateReadCount, 0)
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(
            diagnostics.contains { $0.event == "ax_coordinate_mapping_fallback" },
            "events=\(diagnostics.map(\.event).joined(separator: ",")), reads=\(access.coordinateReadCount), remaining=\(access.failNextCoordinateReads)"
        )
        XCTAssertTrue(diagnostics.contains {
            $0.event == "ax_coordinate_mapping_resolved"
                && $0.fields["coordinateSource"] == "pendingReceiptExactAXValue"
        })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexRecoversWhenExactSingleCharacterAppendLeavesCaretAtInsertionPoint() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "那压",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { text in
            access.applyAppend(text)
            // Reproduce the report: the AX document includes the character,
            // but AXSelectedTextRange still points to the pre-write caret.
            access.selection = .init(location: 2, length: 0)
            access.editorSelection = .init(location: 2, length: 0)
            access.armPostWriteReplay()
        }
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000,
            enableExperimentalCodexCaretRecovery: true
        )

        _ = try target.capture()
        try target.paste("抑")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "那压抑")
        XCTAssertEqual(access.selection, .init(location: 3, length: 0))
        XCTAssertEqual(sender.caretRecoveryPosts, 1)
        var diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains { $0.event == "keyboard_caret_recovery_submitted" })
        XCTAssertTrue(diagnostics.contains { $0.event == "keyboard_write_acknowledged" })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })

        sender.appendOverride = nil
        try target.replaceTrailingText("抑", with: "伸展")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "那压伸展")
        XCTAssertEqual(access.selection, .init(location: 4, length: 0))
        diagnostics = target.drainDiagnostics()
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexCaretRecoveryIsDisabledByDefaultAndDoesNotRepeatText() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "那压",
            selection: .init(location: 2, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { text in
            access.applyAppend(text)
            access.selection = .init(location: 2, length: 0)
            access.editorSelection = .init(location: 2, length: 0)
            access.armPostWriteReplay()
        }
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("抑")
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("the default path must not move an unconfirmed caret")
        } catch {
            XCTAssertEqual(access.rawText, "那压抑")
            XCTAssertEqual(access.selection, .init(location: 2, length: 0))
            XCTAssertEqual(sender.totalPosts, 1)
            XCTAssertEqual(sender.caretRecoveryPosts, 0)
            let diagnostics = target.drainDiagnostics()
            XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_caret_recovery_submitted" })
            XCTAssertTrue(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
        }
    }

    func testCodexExactAXValueReceiptConfirmsWhenStaleCoordinateEndsBeforeSelection() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { text in
            access.applyAppend(text)
            // The AXValue and selection are already post-write, but the
            // coordinate range is still the pre-write snapshot. Its length
            // is now shorter than the reported caret.
            access.coordinateOverride = "甲"
        }
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲今")
        XCTAssertEqual(access.selection, .init(location: 2, length: 0))
        XCTAssertEqual(sender.totalPosts, 1)
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "ax_coordinate_mapping_resolved"
                && $0.fields["coordinateSource"] == "pendingReceiptExactAXValue"
        })
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexReportShapeConfirmsLocalStructuralAugmentationWhenCoordinateReadsStayUnavailable() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲\n乙丙丁",
            selection: .init(location: 3, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲乙丙丁"
        access.selectedTextAttributeIsSettable = true
        let sender = ReplayKeyboardEventSender(access: access)
        sender.appendOverride = { text in
            XCTAssertEqual(text, "今")
            // The real failure report has the post-write AXValue available
            // (8 UTF-16 units), while its coordinate range keeps failing.
            // The two extra LF units are local to the insertion boundary.
            access.writeSnapshots = [
                .init(
                    rawText: "甲\n乙丙\n\n今丁",
                    coordinateText: "",
                    selection: .init(location: 4, length: 0)
                )
            ]
            access.applyAppend(text)
            access.failNextCoordinateReads = 100
        }
        let target = AXTextTarget(
            access: access,
            keyboardEventSender: sender,
            acknowledgementTimeoutNanoseconds: 20_000_000
        )

        _ = try target.capture()
        try target.paste("今")
        try await target.acknowledgeKeyboardWrite()

        XCTAssertEqual(access.rawText, "甲\n乙丙\n\n今丁")
        XCTAssertEqual(access.selection, .init(location: 4, length: 0))
        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertGreaterThan(access.coordinateReadCount, 0)
        let diagnostics = target.drainDiagnostics()
        XCTAssertTrue(diagnostics.contains {
            $0.event == "ax_coordinate_mapping_resolved"
                && $0.fields["coordinateSource"] == "pendingReceiptStructuralAugmentation"
        }, "events=\(diagnostics.map(\.event).joined(separator: ","))")
        XCTAssertFalse(diagnostics.contains { $0.event == "keyboard_write_unconfirmed" })
    }

    func testCodexStructuralTransitionCandidatesPreserveCRLFAndUnicodeSeparators() async throws {
        for separator in ["\r\n", "\u{2028}", "\u{2029}"] {
            let access = ReplayAXTextTargetAccess(
                text: "甲\(separator)乙",
                selection: .init(location: 1, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = "甲\(separator)乙"
            access.writeSnapshots = [
                .init(
                    rawText: "甲今\(separator)\(separator)\(separator)乙",
                    coordinateText: "甲今乙",
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

            XCTAssertEqual(access.rawText, "甲今\(separator)\(separator)\(separator)乙", separator.debugDescription)
            XCTAssertEqual(access.coordinateText, "甲今乙", separator.debugDescription)
            XCTAssertEqual(sender.totalPosts, 1, separator.debugDescription)
            XCTAssertFalse(
                target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" },
                separator.debugDescription
            )
        }
    }

    func testCodexThreeUnitStructuralMarkerContinuationSupportsAllEncodings() async throws {
        for separator in ["\n", "\r\n", "\u{2028}", "\u{2029}"] {
            let marker = String(repeating: separator, count: 3)
            let access = ReplayAXTextTargetAccess(
                text: "甲\(separator)乙",
                selection: .init(location: 1, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = "甲\(separator)乙"
            access.writeSnapshots = [
                .init(
                    rawText: "甲今\(marker)乙",
                    coordinateText: "甲今乙",
                    selection: .init(location: 2, length: 0)
                ),
                .init(
                    rawText: "甲今天\(marker)乙",
                    coordinateText: "甲今天乙",
                    selection: .init(location: 3, length: 0)
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

            XCTAssertEqual(access.rawText, "甲今天\(marker)乙", separator.debugDescription)
            XCTAssertEqual(access.coordinateText, "甲今天乙", separator.debugDescription)
            XCTAssertEqual(access.selection, .init(location: 3, length: 0), separator.debugDescription)
            XCTAssertEqual(sender.totalPosts, 2, separator.debugDescription)
            XCTAssertFalse(
                target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" },
                separator.debugDescription
            )
        }
    }

    func testCodexUncalibratedFourUnitMarkerRunRemainsUnconfirmed() async throws {
        let access = ReplayAXTextTargetAccess(
            text: "甲\n乙",
            selection: .init(location: 1, length: 0),
            application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
        )
        access.coordinateOverride = "甲\n乙"
        access.writeSnapshots = [
            .init(
                rawText: "甲今\n\n\n\n乙",
                coordinateText: "甲今乙",
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
        do {
            try await target.acknowledgeKeyboardWrite()
            XCTFail("a marker run outside the calibrated local bound must remain unconfirmed")
        } catch { }

        XCTAssertEqual(sender.totalPosts, 1)
        XCTAssertFalse(target.drainDiagnostics().contains { $0.event == "keyboard_write_acknowledged" })
    }

    func testCodexLeadingStructuralMarkerContinuationSupportsAllEncodings() async throws {
        for separator in ["\n", "\r\n", "\u{2028}", "\u{2029}"] {
            let access = ReplayAXTextTargetAccess(
                text: "\(separator)甲",
                selection: .init(location: 0, length: 0),
                application: .init(name: "Codex", bundleIdentifier: "com.openai.codex", processIdentifier: 9001)
            )
            access.coordinateOverride = "\(separator)甲"
            access.writeSnapshots = [
                .init(
                    rawText: "今\(separator)\(separator)甲",
                    coordinateText: "今甲",
                    selection: .init(location: 1, length: 0)
                ),
                .init(
                    rawText: "今天\(separator)\(separator)甲",
                    coordinateText: "今天甲",
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

            XCTAssertEqual(access.rawText, "今天\(separator)\(separator)甲", separator.debugDescription)
            XCTAssertEqual(access.coordinateText, "今天甲", separator.debugDescription)
            XCTAssertEqual(access.selection, .init(location: 2, length: 0), separator.debugDescription)
            XCTAssertEqual(sender.totalPosts, 2, separator.debugDescription)
            XCTAssertFalse(
                target.drainDiagnostics().contains { $0.event == "keyboard_write_unconfirmed" },
                separator.debugDescription
            )
        }
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
            XCTAssertEqual(injector.modeDescription, "safe_copy")
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
        XCTAssertEqual(injector.modeDescription, "safe_copy")
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
        XCTAssertEqual(injector.modeDescription, "safe_copy")
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

private final class ReplayContinuityNode {
    let role: String
    var identifier: String?
    var subrole: String?
    var readOnly: Bool? = false
    var children: [ReplayContinuityNode] = []
    weak var parent: ReplayContinuityNode?
    var failParentRead = false
    var failAttribute: String?

    init(role: String) {
        self.role = role
    }
}

private struct ReplayAXSnapshot {
    let rawText: String
    let coordinateText: String
    let selection: ReplayTextRange
}

private struct ReplayAXTimingEvent {
    let name: String
    let time: UInt64
    let axSelection: ReplayTextRange?
    let editorSelection: ReplayTextRange?
}

@MainActor
private final class ReplayAXTextTargetAccess: AXTextTargetAccess {
    let element = AXUIElementCreateApplication(9001)
    private let otherElement = AXUIElementCreateApplication(9002)
    private let replayWebArea = AXUIElementCreateApplication(9004)
    private let replayEditorAnchor = AXUIElementCreateApplication(9005)
    var replayWindow = AXUIElementCreateApplication(9006)
    private var invalidElements: [AXUIElement] = []
    private var persistsFocusOnRebuiltElement = false
    var rebuiltTargetLeavesOldHandleValid = false
    let application: TextTargetApplication
    var currentApplicationOverride: TextTargetApplication?
    var rawText: String
    var selection: ReplayTextRange
    var editorSelection: ReplayTextRange
    var placeholderEvidenceValue: AXPlaceholderEvidence
    var failNextTextReads = 0
    var nextTextReadError: (any Error)?
    var persistentTextReadError: (any Error)?
    var nextSelectionReadError: (any Error)?
    var onTextReadFailure: (() -> Void)?
    var onTextRead: (() -> Void)?
    var alwaysFailTextReads = false
    var failNextSelectionReads = 0
    var failNextCoordinateReads = 0
    var permissionError: TextTargetError?
    var selectionRangeIsSettable = false
    var simulateAXSelectionWriteAcceptedButDoesNotMoveEditor = false
    var simulateCodexParagraphBoundaryExpansion = false
    var deferNextAXSelectionApplication = false
    var replayTime: () -> UInt64 = { 0 }
    var staleSelectionReadsAfterNextTextWrite = 0
    private var staleSelectionReadsRemaining = 0
    private var staleSelectionValue: ReplayTextRange?
    private var deferredAXSelectionApplication: ReplayTextRange?
    private(set) var timingEvents: [ReplayAXTimingEvent] = []
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
    var simulateSafariEditorLayoutRebuild = false
    var anchoredContinuityAvailable = false
    private(set) var anchoredContinuityScanCount = 0
    var safariContinuityUnavailableReadsBeforeRecovery = 0
    var safariEditableEditorCount = 1
    var replayEditorIdentifier: String? = "replay-composer-editor"
    var elementProcessIdentifier: pid_t = 9001
    var rebuiltElementProcessIdentifier: pid_t = 9001
    var rebuiltReadOnlyUnavailable = false
    var focusedElementRebuildsAfterNextWrite = 0
    private var focusedElementRebuildCount = 0
    var failFocusedElementReadAtCount: Int?
    private(set) var focusedElementReadCount = 0
    var readSnapshotsAfterNextWrite: [ReplayAXSnapshot] = []
    var queuedTextReadSnapshots: [ReplayAXSnapshot] = []
    var queuedTextInputContexts: [AXTextInputTargetContext?] = []
    var textInputContextOverride: ((AXUIElement) -> AXTextInputTargetContext?)?
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

    func recordTimingEvent(_ name: String, observedAXSelection: ReplayTextRange? = nil) {
        timingEvents.append(ReplayAXTimingEvent(
            name: name,
            time: replayTime(),
            axSelection: observedAXSelection ?? selection,
            editorSelection: editorSelection
        ))
    }

    func applyDeferredAXSelectionApplication() {
        guard let range = deferredAXSelectionApplication else { return }
        deferredAXSelectionApplication = nil
        selection = range
        editorSelection = range
        recordTimingEvent("deferred_editor_selection_applied")
    }
    private(set) var textReadCount = 0
    private(set) var coordinateReadCount = 0
    private(set) var selectionSetCalls = 0

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
        editorSelection = selection ?? .init(location: text.utf16.count, length: 0)
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
            persistsFocusOnRebuiltElement = true
            if !rebuiltTargetLeavesOldHandleValid,
               !invalidElements.contains(where: { CFEqual($0, element) }) {
                invalidElements.append(element)
            }
            return rebuiltElement
        }
        if persistsFocusOnRebuiltElement { return rebuiltElement }
        if focusedElementRebuildCount > 0 {
            focusedElementRebuildCount -= 1
            return rebuiltElement
        }
        return focusChanged ? otherElement : element
    }

    private let rebuiltElement = AXUIElementCreateApplication(9003)

    func processIdentifier(of element: AXUIElement) -> pid_t? {
        CFEqual(element, rebuiltElement) ? rebuiltElementProcessIdentifier : elementProcessIdentifier
    }

    func elementValidity(_ element: AXUIElement) -> AXTextElementValidity {
        invalidElements.contains(where: { CFEqual($0, element) }) ? .invalid : .valid
    }

    func editorContinuityEvidence(for element: AXUIElement) -> AXTextEditorContinuityEvidence? {
        if safariContinuityUnavailableReadsBeforeRecovery > 0 {
            safariContinuityUnavailableReadsBeforeRecovery -= 1
            return nil
        }
        guard simulateSafariEditorLayoutRebuild else { return nil }
        return AXTextEditorContinuityEvidence(
            webArea: replayWebArea,
            window: replayWindow,
            editorAnchor: replayEditorAnchor,
            editorAnchorRole: "AXGroup",
            rolesFromEditorToAnchor: ["AXTextArea", "AXGroup"],
            identifiersFromEditorToAnchor: [replayEditorIdentifier, nil],
            editableEditorCount: safariEditableEditorCount,
            scanComplete: true
        )
    }

    func editorContinuityEvidence(
        for element: AXUIElement,
        anchoredAt previous: AXTextEditorContinuityEvidence
    ) -> AXTextEditorContinuityEvidence? {
        anchoredContinuityScanCount += 1
        guard anchoredContinuityAvailable,
              simulateSafariEditorLayoutRebuild else {
            return nil
        }
        return AXTextEditorContinuityEvidence(
            webArea: previous.webArea,
            window: previous.window,
            editorAnchor: previous.editorAnchor,
            editorAnchorRole: previous.editorAnchorRole,
            rolesFromEditorToAnchor: ["AXTextArea", "AXGroup"],
            identifiersFromEditorToAnchor: [replayEditorIdentifier, nil],
            editableEditorCount: safariEditableEditorCount,
            scanComplete: true
        )
    }

    func textInputContext(for element: AXUIElement) -> AXTextInputTargetContext? {
        if let textInputContextOverride { return textInputContextOverride(element) }
        if rebuiltReadOnlyUnavailable, CFEqual(element, rebuiltElement) {
            return AXTextInputTargetContext(
                role: "AXTextArea", hasWebAreaAncestor: false, webURL: nil,
                isReadOnly: nil, isSecure: false, ancestorScanStatus: .readFailure
            )
        }
        if !queuedTextInputContexts.isEmpty {
            return queuedTextInputContexts.removeFirst()
        }
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
        if application.bundleIdentifier == "com.openai.codex" {
            return AXTextInputTargetContext(
                role: "AXTextArea", hasWebAreaAncestor: false, webURL: nil,
                isReadOnly: false, isSecure: false, ancestorScanStatus: .completeWithoutWebArea
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
        let value = rawText
        onTextRead?()
        onTextRead = nil
        return value
    }

    func selection(in element: AXUIElement) throws -> ReplayTextRange? {
        if staleSelectionReadsRemaining > 0, let staleSelectionValue {
            staleSelectionReadsRemaining -= 1
            recordTimingEvent("ax_selection_read_stale", observedAXSelection: staleSelectionValue)
            return staleSelectionValue
        }
        recordTimingEvent("ax_selection_read")
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
        selectionSetCalls += 1
        lastSelectionRoute = .accessibility
        recordTimingEvent("ax_selection_set_requested")
        selection = range
        if deferNextAXSelectionApplication {
            deferNextAXSelectionApplication = false
            deferredAXSelectionApplication = range
        } else if !simulateAXSelectionWriteAcceptedButDoesNotMoveEditor {
            editorSelection = range
        }
        recordTimingEvent("ax_selection_set_returned")
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
        editorSelection = selection
    }

    func applyAppend(_ text: String) {
        if staleSelectionReadsAfterNextTextWrite > 0 {
            staleSelectionValue = selection
            staleSelectionReadsRemaining = staleSelectionReadsAfterNextTextWrite
            staleSelectionReadsAfterNextTextWrite = 0
        }
        if placeholderEvidenceValue != .init() {
            rawText = text
            let coordinateLength = text
                .filter { $0 != "\n" && $0 != "\r" && $0 != "\u{2028}" && $0 != "\u{2029}" }
                .utf16.count
            selection = .init(location: coordinateLength, length: 0)
            editorSelection = selection
            placeholderEvidenceValue = .init()
            return
        }
        applyReplacement(text, range: simulateAXSelectionWriteAcceptedButDoesNotMoveEditor ? editorSelection : selection)
    }

    func applyReplacement(_ text: String, range: ReplayTextRange) {
        if !writeSnapshots.isEmpty {
            let snapshot = writeSnapshots.removeFirst()
            rawText = snapshot.rawText
            coordinateOverride = snapshot.coordinateText
            selection = snapshot.selection
            editorSelection = snapshot.selection
            return
        }
        var rawRange = rawRange(for: range)
        let rawUTF16 = Array(rawText.utf16)
        if simulateCodexParagraphBoundaryExpansion,
           range.length == 0,
           rawRange.length == 0,
           rawRange.location < rawUTF16.count,
           rawUTF16[rawRange.location] == 0x0A {
            let mutable = NSMutableString(string: rawText)
            mutable.insert(text, at: rawRange.location)
            let separatorLocation = rawRange.location + text.utf16.count
            mutable.replaceCharacters(in: NSRange(location: separatorLocation, length: 1), with: "\n\n\n")
            rawText = mutable as String
            coordinateOverride = nil
            simulateCodexParagraphBoundaryExpansion = false
            let insertedLength = text.filter {
                $0 != "\n" && $0 != "\r" && $0 != "\u{2028}" && $0 != "\u{2029}"
            }.utf16.count
            selection = .init(location: range.location + insertedLength, length: 0)
            editorSelection = selection
            placeholderEvidenceValue = .init()
            return
        }
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
        editorSelection = selection
        placeholderEvidenceValue = .init()
    }

    func armPostWriteReplay() {
        focusedElementRebuildCount = focusedElementRebuildsAfterNextWrite
        focusedElementRebuildsAfterNextWrite = 0
        if focusedElementRebuildCount > 0,
           !invalidElements.contains(where: { CFEqual($0, element) }) {
            invalidElements.append(element)
        }
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
    private(set) var caretRecoveryPosts = 0
    var dropNextSelection = false
    var keyboardSelectionOnlyUpdatesAX = false
    var appendOverride: ((String) -> Void)?
    var beforeNextAppend: (() -> Void)?
    var onReplacement: (() -> Void)?

    var totalPosts: Int { appendPosts + replacementPosts }

    init(access: ReplayAXTextTargetAccess) {
        self.access = access
    }

    func selectTrailingText(_ previousText: String, processID: pid_t?) throws {
        selectionPosts += 1
        access.markKeyboardSelectionRoute()
        let baseSelection = access.simulateAXSelectionWriteAcceptedButDoesNotMoveEditor
            ? access.editorSelection
            : access.selection
        let location = baseSelection.location - previousText.utf16.count
        pendingSelection = .init(location: location, length: previousText.utf16.count)
        if dropNextSelection {
            dropNextSelection = false
        } else {
            access.selection = pendingSelection!
            if !keyboardSelectionOnlyUpdatesAX { access.editorSelection = pendingSelection! }
        }
    }

    func replaceSelection(with text: String, processID: pid_t?) throws {
        replacementPosts += 1
        let range = keyboardSelectionOnlyUpdatesAX || (access.simulateAXSelectionWriteAcceptedButDoesNotMoveEditor
            && access.lastSelectionRoute == .accessibility
            )
            ? access.editorSelection
            : (pendingSelection ?? access.selection)
        access.applyReplacement(text, range: range)
        pendingSelection = nil
        access.armPostWriteReplay()
        onReplacement?()
        onReplacement = nil
    }

    func send(_ text: String, processID: pid_t?) throws {
        appendPosts += 1
        beforeNextAppend?()
        beforeNextAppend = nil
        if let appendOverride { appendOverride(text); return }
        access.applyAppend(text)
        access.recordTimingEvent("text_sent")
        access.armPostWriteReplay()
    }

    func advanceCaretRight(processID: pid_t?) throws {
        caretRecoveryPosts += 1
        let next = ReplayTextRange(
            location: min(access.editorSelection.location + 1, access.coordinateText.utf16.count),
            length: 0
        )
        access.selection = next
        access.editorSelection = next
        access.recordTimingEvent("caret_recovery_posted")
    }

    func replaceTrailingText(_ previousText: String, with text: String, processID: pid_t?) throws {
        selectionPosts += 1
        let range = ReplayTextRange(
            location: (access.simulateAXSelectionWriteAcceptedButDoesNotMoveEditor
                ? access.editorSelection.location
                : access.selection.location) - previousText.utf16.count,
            length: previousText.utf16.count
        )
        replacementPosts += 1
        access.applyReplacement(text, range: range)
        access.armPostWriteReplay()
    }
}
