import AppKit
import ApplicationServices
import XCTest
@testable import TencentVoiceMVP

final class InputFailureContextTests: XCTestCase {
    @MainActor
    func testAXNotificationObserverRebindsAndDropsCallbacksAfterSessionEnds() async {
        let observer = FakeInputFailureAXNotificationObserver()
        let recorder = InputFailureContextRecorder(axNotificationObserver: observer)
        let logger = SessionLogger(enabled: { false })
        recorder.setEnabled(true)
        defer { recorder.stop() }
        let sessionID = UUID()
        recorder.sessionBegan(sessionID)
        recorder.observeTarget(
            TextInputDiagnostic(
                timestamp: Date(),
                event: "input_target_captured",
                fields: ["targetElementObservationID": "target-A"]
            ),
            element: nil,
            pid: 9001,
            logger: logger
        )

        XCTAssertEqual(observer.lastTargetObservationID, "target-A")
        XCTAssertEqual(recorder.snapshot(at: Date()).collectionStatus["axNotificationIsIndependentPageEvidence"], "false")
        let delayedCallback = try! XCTUnwrap(observer.callback)
        delayedCallback("AXValueChanged", Date(), 123)
        await Task.yield()

        let beforeEnd = recorder.snapshot(at: Date())
        let notification = beforeEnd.events.first { $0.event == "ax_notification_observed" }
        XCTAssertEqual(notification?.sessionID, sessionID)
        XCTAssertEqual(notification?.fields["independentPageEvidence"], "false")
        XCTAssertEqual(notification?.monotonicTimestampNanoseconds, 123)

        let beforeCount = beforeEnd.events.count
        recorder.sessionEnded()
        delayedCallback("AXSelectedTextChanged", Date(), 124)
        await Task.yield()
        XCTAssertEqual(recorder.snapshot(at: Date()).events.count, beforeCount)
        XCTAssertGreaterThanOrEqual(observer.stopCount, 1)
    }

    @MainActor
    func testDetailedFocusProbeIncludesSafariChromeAndCodexOnly() {
        XCTAssertEqual(InputFailureContextRecorder.focusProbeApplicationBundleIdentifiers, [
            "com.apple.Safari", "com.google.Chrome", "com.openai.codex"
        ])
        XCTAssertFalse(InputFailureContextRecorder.focusProbeApplicationBundleIdentifiers.contains("com.apple.finder"))
    }

    func testLateReportRetainsFailureMinuteSeparatelyFromClickMinute() {
        let failureAt = Date(timeIntervalSince1970: 100)
        let clickAt = failureAt.addingTimeInterval(62)
        let sessionID = UUID()
        let failure = InputFailureEvidence(
            desktopContext: InputContextWindow(
                requestedStart: failureAt.addingTimeInterval(-60),
                recordingStartedAt: failureAt.addingTimeInterval(-120),
                capturedAt: failureAt,
                enabled: true,
                droppedEventCount: 0,
                events: [
                    .init(timestamp: failureAt.addingTimeInterval(-1), event: "last_success", fields: [:]),
                    .init(timestamp: failureAt, event: "failure", fields: [:])
                ]
            ),
            diagnosticEvents: [
                SessionLogEntry(timestamp: failureAt, sessionID: sessionID, event: "input_degradation")
            ],
            diagnosticEventsTruncated: false
        )

        let retained = failure.retainingFailureContext(
            reportWindowStart: clickAt.addingTimeInterval(-60),
            through: clickAt
        )
        XCTAssertEqual(retained.desktopContext.events.map(\.event), ["last_success", "failure"])
        XCTAssertEqual(retained.desktopContext.collectionStatus["associatedFailureAt"], DiagnosticReportTime.format(failureAt))
        XCTAssertEqual(retained.desktopContext.collectionStatus["timelineIncludesOlderFailureContext"], "true")
        XCTAssertEqual(retained.sessionIDs, Set([sessionID]))
    }

    func testLaterFailureDoesNotDiscardFirstFailureProbe() {
        var buffer = InputContextBuffer()
        let start = Date(timeIntervalSince1970: 1000)
        buffer.start(at: start)
        buffer.freezeFailure(at: start)
        buffer.freezeFailure(at: start.addingTimeInterval(0.1), probeStatus: "not_requested_no_target_handle")
        buffer.appendFailureProbe(.init(timestamp: start.addingTimeInterval(0.2), event: "input_editor_probe", fields: [:]), failureAt: start)
        XCTAssertEqual(buffer.firstFailure?.collectionStatus["failureProbeStatus"], "completed")
        XCTAssertEqual(buffer.firstFailure?.events.last?.event, "input_editor_probe")
        XCTAssertEqual(buffer.latestFailure?.collectionStatus["failureProbeStatus"], "not_requested_no_target_handle")
    }

    func testBufferRetainsFullEnabledWindowAndClearsWhenDisabled() {
        let start = Date(timeIntervalSince1970: 1000)
        var buffer = InputContextBuffer()
        buffer.start(at: start)
        buffer.append(.init(timestamp: start, event: "old", fields: [:]), now: start)
        buffer.append(.init(timestamp: start.addingTimeInterval(61), event: "fork", fields: [:]), now: start.addingTimeInterval(61))
        let report = buffer.snapshot(at: start.addingTimeInterval(62))
        XCTAssertEqual(report.events.map(\.event), ["old", "fork"])
        XCTAssertEqual(report.requestedStart, start)
        buffer.stop()
        buffer.append(.init(timestamp: start.addingTimeInterval(63), event: "ignored", fields: [:]), now: start.addingTimeInterval(63))
        XCTAssertFalse(buffer.snapshot(at: start.addingTimeInterval(63)).enabled)
        XCTAssertTrue(buffer.events.isEmpty)
    }

    func testInputTimelinePairsMonotonicTimeWithSessionOperationAndTarget() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let sessionID = UUID()
        var buffer = InputContextBuffer()
        buffer.start(at: start)
        buffer.append(InputContextEvent(
            timestamp: start.addingTimeInterval(0.25),
            event: "input_editor_probe",
            fields: ["phase": "keyboard_write_acknowledged"],
            monotonicTimestampNanoseconds: 98_765,
            sessionID: sessionID,
            operationID: 17,
            targetApplicationBundleIdentifier: "com.apple.Safari",
            targetApplicationProcessID: 123
        ), now: start.addingTimeInterval(0.25))

        let snapshot = buffer.snapshot(at: start.addingTimeInterval(0.5))
        XCTAssertEqual(snapshot.events.first?.sessionID, sessionID)
        XCTAssertEqual(snapshot.events.first?.operationID, 17)
        XCTAssertEqual(snapshot.events.first?.targetApplicationBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(snapshot.events.first?.targetApplicationProcessID, 123)
        XCTAssertEqual(snapshot.events.first?.monotonicTimestampNanoseconds, 98_765)
        XCTAssertNotNil(snapshot.capturedAtMonotonicNanoseconds)
        XCTAssertNotNil(snapshot.recordingStartedAtMonotonicNanoseconds)

        let oldEvent = try JSONDecoder().decode(InputContextEvent.self, from: Data(
            "{\"timestamp\":0,\"event\":\"legacy\",\"fields\":{}}".utf8
        ))
        XCTAssertNil(oldEvent.sessionID)
        XCTAssertNil(oldEvent.monotonicTimestampNanoseconds)
    }

    func testInputTimelineUsesMonotonicOrderWhenWallClockMovesBackward() {
        let start = Date(timeIntervalSince1970: 2_000)
        var buffer = InputContextBuffer()
        buffer.start(at: start)
        buffer.append(.init(
            timestamp: start.addingTimeInterval(2), event: "later_monotonic",
            fields: [:], monotonicTimestampNanoseconds: 200
        ), now: start.addingTimeInterval(2))
        buffer.append(.init(
            timestamp: start.addingTimeInterval(1), event: "earlier_monotonic",
            fields: [:], monotonicTimestampNanoseconds: 100
        ), now: start.addingTimeInterval(2))

        XCTAssertEqual(buffer.snapshot(at: start.addingTimeInterval(3)).events.map(\.event), [
            "earlier_monotonic", "later_monotonic"
        ])
    }

    func testDiagnosticSessionTimelineUsesMonotonicOrderWhenWallClockMovesBackward() {
        let laterWallClock = SessionLogEntry(
            timestamp: Date(timeIntervalSince1970: 2_002),
            monotonicTimestampNanoseconds: 200,
            event: "later_monotonic"
        )
        let earlierWallClock = SessionLogEntry(
            timestamp: Date(timeIntervalSince1970: 2_001),
            monotonicTimestampNanoseconds: 100,
            event: "earlier_monotonic"
        )

        XCTAssertEqual(orderedDiagnosticSessionEntries([laterWallClock, earlierWallClock]).map(\.event), [
            "earlier_monotonic", "later_monotonic"
        ])
    }

    @MainActor
    func testRecorderKeepsSelectionMilestoneIDAndExplainsInteractionCoverage() {
        let recorder = InputFailureContextRecorder()
        let logger = SessionLogger(enabled: { false })
        recorder.setEnabled(true)
        defer { recorder.stop() }
        let eventID = UUID()
        let diagnostic = TextInputDiagnostic(
            eventID: eventID,
            timestamp: Date(),
            event: "keyboard_selection_stabilized",
            fields: ["operationID": "17", "inputSessionGeneration": "3"]
        )

        recorder.observeTarget(diagnostic, element: nil, pid: nil, logger: logger)

        let snapshot = recorder.snapshot(at: Date())
        let selectionEvent = snapshot.events.first { $0.event == "keyboard_selection_stabilized" }
        XCTAssertEqual(selectionEvent?.eventID, eventID)
        XCTAssertEqual(selectionEvent?.operationID, 17)
        XCTAssertNotNil(snapshot.collectionStatus["keyboardActivityThrottledCount"])
        XCTAssertNotNil(snapshot.collectionStatus["secureInputFilteredCount"])
        XCTAssertEqual(snapshot.collectionStatus["axNotificationNoCallbackMeaning"], "no_callback_is_not_evidence_of_no_change")
    }

    func testFrozenFailureSurvivesLateReportAndClearsWhenDisabled() {
        let start = Date(timeIntervalSince1970: 1000)
        var buffer = InputContextBuffer()
        buffer.start(at: start)
        buffer.append(.init(timestamp: start, event: "capture", fields: ["documentLength": "81"]), now: start)
        let failure = start.addingTimeInterval(5)
        buffer.append(.init(timestamp: failure, event: "keyboard_write_unconfirmed", fields: ["operationID": "1"]), now: failure)
        buffer.freezeFailure(at: failure)
        XCTAssertEqual(buffer.latestFailure?.collectionStatus["failureProbeStatus"], "pending")
        buffer.appendFailureProbe(.init(timestamp: failure.addingTimeInterval(1), event: "input_editor_probe", fields: ["targetID": "2"]), failureAt: failure)
        XCTAssertEqual(buffer.latestFailure?.collectionStatus["failureProbeStatus"], "completed")
        XCTAssertEqual(buffer.snapshot(at: start.addingTimeInterval(600)).events.map(\.event), ["capture", "keyboard_write_unconfirmed"])
        XCTAssertEqual(buffer.latestFailure?.events.map(\.event), ["capture", "keyboard_write_unconfirmed", "input_editor_probe"])
        let nextFailure = start.addingTimeInterval(601)
        buffer.freezeFailure(at: nextFailure)
        buffer.appendFailureProbe(.init(timestamp: failure, event: "stale_probe", fields: [:]), failureAt: failure)
        XCTAssertFalse(buffer.latestFailure?.events.contains { $0.event == "stale_probe" } ?? true)
        buffer.stop()
        XCTAssertNil(buffer.latestFailure)
        buffer.freezeFailure(at: nextFailure)
        XCTAssertNil(buffer.latestFailure)
    }

    func testOverflowAndFullCoverageRemainVisible() {
        let start = Date(timeIntervalSince1970: 1000)
        var buffer = InputContextBuffer(capacity: 2)
        buffer.start(at: start)
        for index in 0..<3 {
            let now = start.addingTimeInterval(Double(index))
            buffer.append(.init(timestamp: now, event: String(index), fields: [:]), now: now)
        }
        let report = buffer.snapshot(at: start.addingTimeInterval(3))
        XCTAssertEqual(report.recordingStartedAt, start)
        XCTAssertEqual(report.droppedEventCount, 1)
        XCTAssertEqual(report.events.map(\.event), ["1", "2"])
        XCTAssertEqual(buffer.snapshot(at: start.addingTimeInterval(63)).droppedEventCount, 1)
        XCTAssertEqual(buffer.events.map(\.event), ["1", "2"])
    }

    func testRestrictedContextCountsDroppedEventsOnlyInsideTheReportWindow() {
        let start = Date(timeIntervalSince1970: 1000)
        var buffer = InputContextBuffer(capacity: 2)
        buffer.start(at: start)
        for (offset, name) in [(0.0, "old"), (70.0, "recent_drop"), (80.0, "keep_a"), (100.0, "keep_b")] {
            let timestamp = start.addingTimeInterval(offset)
            buffer.append(.init(timestamp: timestamp, event: name, fields: [:]), now: timestamp)
        }

        let report = buffer.snapshot(at: start.addingTimeInterval(100))
            .restricted(to: start.addingTimeInterval(40), through: start.addingTimeInterval(100))

        XCTAssertEqual(report.droppedEventCount, 1)
        XCTAssertEqual(report.collectionStatus["droppedEventCountScope"], "report_window")
        XCTAssertEqual(report.events.map(\.event), ["keep_a", "keep_b"])
    }

    func testFrozenEvidenceRoundTripsWithAuthorizedFullText() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var buffer = InputContextBuffer()
        buffer.start(at: now)
        buffer.append(.init(timestamp: now, event: "keyboard_write_unconfirmed",
            fields: DiagnosticLogSanitizer.fields(["documentLength": "81", "text": "私密草稿"])), now: now)
        buffer.freezeFailure(at: now)
        let evidence = InputFailureEvidence(desktopContext: try XCTUnwrap(buffer.latestFailure),
            diagnosticEvents: [], diagnosticEventsTruncated: false)
        let data = try DiagnosticJSON.encoder().encode(evidence)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("私密草稿"))
        let decoded = try DiagnosticJSON.decoder().decode(InputFailureEvidence.self, from: data)
        XCTAssertEqual(decoded.desktopContext.events.first?.fields["documentLength"], "81")
        XCTAssertEqual(decoded.desktopContext.collectionStatus["failureProbeStatus"], "pending")
    }

    func testKeyboardDiagnosticDiffFieldsRoundTripWithoutContent() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let expected = KeyboardDocumentState(
            text: "甲乙",
            selection: .init(location: 2, length: 0),
            rawText: "甲\n乙"
        )
        let observed = KeyboardDocumentState(
            text: "甲乙",
            selection: .init(location: 2, length: 0),
            rawText: "甲乙\n"
        )
        let summary = KeyboardDiagnosticDiffCalculator.compare(
            expected: expected,
            observed: observed,
            operation: .init(
                coordinateRange: .init(location: 1, length: 0),
                insertedLengthUTF16: 1,
                operationGeneration: 7
            ),
            mappingValid: true
        )
        var buffer = InputContextBuffer()
        buffer.start(at: now)
        buffer.append(
            .init(
                timestamp: now,
                event: "keyboard_write_unconfirmed",
                fields: DiagnosticLogSanitizer.fields(
                    summary.fields(prefix: "ackDiffFinal0")
                )
            ),
            now: now
        )
        buffer.freezeFailure(at: now)
        let evidence = InputFailureEvidence(
            desktopContext: try XCTUnwrap(buffer.latestFailure),
            diagnosticEvents: [],
            diagnosticEventsTruncated: false
        )
        let data = try DiagnosticJSON.encoder().encode(evidence)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("structural_local"))
        XCTAssertFalse(encoded.contains("私密正文"))
        let decoded = try DiagnosticJSON.decoder().decode(InputFailureEvidence.self, from: data)
        XCTAssertEqual(
            decoded.desktopContext.events.first?.fields["ackDiffFinal0Classification"],
            "structural_local"
        )
        XCTAssertEqual(
            decoded.desktopContext.events.first?.fields["ackDiffFinal0SeparatorDifferenceBoundaryCount"],
            "2"
        )
    }

    @MainActor
    func testAXWriteUnconfirmedFreezesTheEarliestDiagnosticEvidence() throws {
        let recorder = InputFailureContextRecorder()
        let logger = SessionLogger(enabled: { false })
        logger.setFailureContextEnabled(true)
        recorder.setEnabled(true)
        defer { recorder.stop() }
        let now = Date()
        try logger.append(.init(
            timestamp: now,
            event: "ax_write_submitted",
            metadata: ["operationID": "7", "axWriteStatus": "0"]
        ))
        let diagnostic = TextInputDiagnostic(
            timestamp: now.addingTimeInterval(0.1),
            event: "ax_write_unconfirmed",
            fields: DiagnosticLogSanitizer.fields([
                "operationID": "7",
                "axExpectedValueLengthUTF16": "1070",
                "axFinalAXValueLengthUTF16": "1068",
                "axFinalCandidateMatches": "false",
                "text": "private draft"
            ])
        )
        recorder.observeTarget(
            diagnostic,
            element: AXUIElementCreateApplication(9001),
            pid: 9001,
            logger: logger
        )

        let evidence = try XCTUnwrap(recorder.latestFailure)
        XCTAssertEqual(evidence.desktopContext.events.last?.event, "ax_write_unconfirmed")
        XCTAssertEqual(evidence.desktopContext.events.last?.fields["axFinalAXValueLengthUTF16"], "1068")
        XCTAssertTrue(evidence.desktopContext.events.last?.fields.values.contains("private draft") ?? false)
        XCTAssertEqual(evidence.diagnosticEvents.first?.event, "ax_write_submitted")
    }

    func testProbeSeparatesReportedFocusFromAnotherEditorThatActuallyClaimsFocus() throws {
        let window = AXUIElementCreateApplication(9102)
        let draft = AXUIElementCreateApplication(9103)
        let sidebar = AXUIElementCreateApplication(9104)
        let probe = InputContextAXProbe(isTrusted: { true }, secureInputActive: { false }, readAttribute: { name, node in
            switch name {
            case "AXFocusedWindow": return (.success, window)
            case "AXFocusedUIElement": return (.success, draft)
            case "AXChildren": return (.success, (CFEqual(node, window) ? [draft, sidebar] : []) as CFArray)
            case "AXRole": return (.success, (CFEqual(node, window) ? "AXWindow" : "AXTextArea") as CFString)
            case "AXSubrole": return (.success, "" as CFString)
            case "AXFocused": return (.success, NSNumber(value: CFEqual(node, sidebar)))
            case "AXValue": return (.success, (CFEqual(node, sidebar) ? "甲" : String(repeating: "私", count: 81)) as CFString)
            case "AXNumberOfCharacters": return (.success, NSNumber(value: CFEqual(node, sidebar) ? 1 : 81))
            case "AXSelectedTextRange":
                var range = CFRange(location: CFEqual(node, sidebar) ? 1 : 81, length: 0)
                return (.success, AXValueCreate(.cfRange, &range))
            default: return (.noValue, nil)
            }
        })
        let sample = probe.sample(pid: 9101, target: draft, includeEditors: true)
        XCTAssertEqual(sample["targetMatchesSystemFocus"], "true")
        XCTAssertEqual(sample["target.axValueLengthUTF16"], "81")
        XCTAssertEqual(sample["target.AXFocused"], "0")
        XCTAssertEqual(sample["structure.ancestorRoles"], "AXTextArea")
        XCTAssertEqual(sample["structure.evidence"], "unknown")
        XCTAssertEqual(sample["editorCount"], "2")
        XCTAssertEqual(sample["editor0.AXFocused"], "1")
        XCTAssertEqual(sample["editor0.axValueLengthUTF16"], "1")
        XCTAssertNotEqual(sample["editor0.elementID"], sample["targetID"])
        XCTAssertEqual(sample["editorTraversalTruncated"], "false")
        let next = probe.sample(pid: 9101, target: draft, includeEditors: true)
        XCTAssertEqual(next["editor0.elementID"], sample["editor0.elementID"])
        XCTAssertEqual(next["targetID"], sample["targetID"])
        let encoded = try JSONSerialization.data(withJSONObject: sample)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("私私"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("甲"))
    }

    func testProbeSkipsSecureBodyAndPreservesExactReadError() {
        let field = AXUIElementCreateApplication(9201)
        var reads: [String] = []
        let probe = InputContextAXProbe(isTrusted: { true }, secureInputActive: { false }, readAttribute: { name, _ in
            reads.append(name)
            switch name {
            case "AXFocusedUIElement": return (.success, field)
            case "AXRole": return (.success, "AXTextField" as CFString)
            case "AXSubrole": return (.success, "AXSecureTextField" as CFString)
            case "AXFocusedWindow": return (.invalidUIElement, nil)
            default: return (.noValue, nil)
            }
        })
        let sample = probe.sample(pid: 9201, includeEditors: true)
        XCTAssertFalse(reads.contains("AXValue"))
        XCTAssertFalse(reads.contains("AXSelectedTextRange"))
        XCTAssertTrue(sample.values.contains("-25202"))
    }

    func testEditorWalkReachesDeepComposerBeforeLongConversationConsumesBudget() {
        var walk = InputContextEditorWalk(root: 0)
        var foundComposer = false
        while let node = walk.next(children: { node in
            if node < 20 { return [node + 1] }
            if node == 20 { return Array(100...500) + [999] }
            return []
        }) {
            if node == 999 { foundComposer = true }
        }
        XCTAssertTrue(foundComposer, "Codex exposes the composer below deep containers, after conversation content")
        XCTAssertLessThanOrEqual(walk.visitedCount, 160)
        XCTAssertTrue(walk.truncated)
    }

    func testEditorWalkFindsSiblingInputsAndBoundsWideAndDeepTrees() {
        let children = [0: [1, 2], 1: [3], 2: [4], 3: [], 4: []]
        var walk = InputContextEditorWalk(root: 0)
        var nodes: [Int] = []
        while let node = walk.next(children: { children[$0] ?? [] }) { nodes.append(node) }
        XCTAssertEqual(nodes, [0, 2, 4, 1, 3])
        XCTAssertFalse(walk.truncated)
        var wide = InputContextEditorWalk(root: 0, nodeLimit: 3)
        var wideNodes: [Int] = []
        while let node = wide.next(children: { $0 == 0 ? Array(1...1000) : [] }) { wideNodes.append(node) }
        XCTAssertEqual(wideNodes, [0, 1000, 999])
        XCTAssertTrue(wide.truncated)
        var deep = InputContextEditorWalk(root: 0, depthLimit: 2)
        var deepNodes: [Int] = []
        while let node = deep.next(children: { [$0 + 1] }) { deepNodes.append(node) }
        XCTAssertEqual(deepNodes, [0, 1, 2])
        XCTAssertTrue(deep.truncated)
    }

    func testKeyFilterRecordsForkWithoutOrdinaryOrUnknownModifiedTyping() {
        XCTAssertEqual(InputContextKeyFilter.shortcut(keyCode: 45, flags: [.command, .option]), "Option+Command+N")
        XCTAssertNil(InputContextKeyFilter.shortcut(keyCode: 0, flags: []))
        XCTAssertNil(InputContextKeyFilter.shortcut(keyCode: 0, flags: [.shift]))
        XCTAssertNil(InputContextKeyFilter.shortcut(keyCode: 1, flags: [.command]))
        XCTAssertNil(InputContextKeyFilter.shortcut(keyCode: 1, flags: [.option]))
    }

    @MainActor
    func testFailureWindowRetainsMoreThanOrdinaryJournalAndNeedsNoDiskLogging() throws {
        let logger = SessionLogger(enabled: { false })
        logger.setFailureContextEnabled(true)
        let now = Date()
        for index in 0..<400 {
            try logger.append(.init(timestamp: now.addingTimeInterval(-1), event: "receipt_\(index)", metadata: ["text": "private draft"]))
        }
        try logger.append(.init(timestamp: now.addingTimeInterval(-61), event: "old"))
        let events = logger.failureEvents(at: now)
        XCTAssertEqual(events.count, 400)
        XCTAssertEqual(logger.recentEntries(limit: 400).count, 300)
        XCTAssertTrue(String(decoding: try DiagnosticJSON.encoder().encode(events), as: UTF8.self).contains("private draft"))
        logger.setFailureContextEnabled(false)
        XCTAssertTrue(logger.failureEvents(at: now).isEmpty)
    }

    func testReportDesktopContextExcludesEventsOutsideTheClickWindow() {
        let end = Date()
        let start = end.addingTimeInterval(-60)
        let context = InputContextWindow(
            requestedStart: start.addingTimeInterval(-100),
            recordingStartedAt: start.addingTimeInterval(-100),
            capturedAt: end.addingTimeInterval(10),
            enabled: true,
            droppedEventCount: 0,
            events: [
                InputContextEvent(timestamp: start.addingTimeInterval(-0.01), event: "before", fields: [:]),
                InputContextEvent(timestamp: start, event: "boundary", fields: [:]),
                InputContextEvent(timestamp: end, event: "at_click", fields: [:]),
                InputContextEvent(timestamp: end.addingTimeInterval(0.01), event: "after", fields: [:])
            ]
        )

        let restricted = context.restricted(to: start, through: end)
        XCTAssertEqual(restricted.events.map(\.event), ["boundary", "at_click"])
        XCTAssertEqual(restricted.requestedStart, start)
        XCTAssertEqual(restricted.capturedAt, end)
        XCTAssertEqual(restricted.collectionStatus["outOfWindowEventsExcluded"], "true")
    }

    @MainActor
    func testReportMenuInvokesCallbacksAndShowsRecorderState() throws {
        _ = NSApplication.shared
        let menuController = StatusMenuController()
        let menu = menuController.makeMenu()
        var toggles = 0
        var reports = 0
        var opens = 0
        menuController.configure(onSettings: {}, onToggleRecording: {}, onToggleAutoStart: {},
            onSelectRimeTheme: { _ in }, onManageRimeDictionary: {}, onExportRimeConfiguration: {},
            onImportRimeConfiguration: {}, onToggleFailureContext: { toggles += 1 },
            onReportInputFailure: { reports += 1 }, onOpenFailureReports: { opens += 1 })
        for title in ["记录浏览器与 Codex 故障前操作", "报告输入失效", "打开失效报告目录"] {
            let index = try XCTUnwrap(menu.items.firstIndex { $0.title == title })
            menu.performActionForItem(at: index)
        }
        XCTAssertEqual(toggles, 1)
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(opens, 1)
        menuController.update(failureContextEnabled: true)
        XCTAssertEqual(menu.items.first { $0.title == "记录浏览器与 Codex 故障前操作" }?.state, .on)
    }
}

@MainActor
private final class FakeInputFailureAXNotificationObserver: InputFailureAXNotificationObserving {
    private(set) var lastTargetObservationID: String?
    private(set) var stopCount = 0
    private(set) var callback: (@Sendable (String, Date, UInt64) -> Void)?

    func start(
        processID: pid_t,
        target: AXUIElement?,
        targetObservationID: String?,
        onNotification: @escaping @Sendable (String, Date, UInt64) -> Void
    ) -> [String: String] {
        lastTargetObservationID = targetObservationID
        callback = onNotification
        return [
            "state": "active",
            "selectedTextChanged": "registered",
            "valueChanged": "registered",
            "evidenceSource": "test_AX_callback"
        ]
    }

    func stop() {
        stopCount += 1
        callback = nil
    }
}
