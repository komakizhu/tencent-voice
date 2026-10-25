import XCTest
@testable import TencentVoiceMVP

final class DiagnosticTextEvidenceTests: XCTestCase {
    @MainActor
    func testPersistedUnicodeSeparatorsAreNotJSONLRecordBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = SessionLogger(enabled: { true }, applicationSupportDirectoryURL: root)
        let text = "甲\u{85}乙\u{2028}丙\u{2029}丁\r\n👩🏽‍💻e\u{301}"
        try logger.append(.init(event: "partial", textEvidence: [.init(kind: .rawRecognition, source: .observed, text: text)]))
        let entries = logger.allPersistedEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.textEvidence.first?.text, text)
    }

    func testByteBudgetEvictsWholeEventsWithoutTruncatingTheirText() {
        var buffer = DiagnosticEventBuffer(eventLimit: 1000, byteLimit: 3000)
        let text = String(repeating: "字", count: 500)
        XCTAssertEqual(buffer.append(.init(event: "first", textEvidence: [.init(kind: .axValue, source: .observed, text: text)])), 0)
        XCTAssertEqual(buffer.append(.init(event: "second", textEvidence: [.init(kind: .axValue, source: .observed, text: text)])), 1)
        XCTAssertEqual(buffer.lastEvictedEntries.map(\.event), ["first"])
        XCTAssertLessThanOrEqual(buffer.bytes, 3000)
        XCTAssertEqual(buffer.entries.first?.textEvidence.first?.text, text)
        XCTAssertEqual(buffer.entries.first?.event, "second")
    }

    @MainActor
    func testOutOfOrderFailureKeepsEarliestTimestampRatherThanAppendOrder() throws {
        let memoryLogger = SessionLogger(enabled: { false }, failureContextEventLimit: 2)
        memoryLogger.setFailureContextEnabled(true)
        let session = UUID()
        let date = Date()
        for (event, offset) in [("keyboard_write_acknowledged", 0.0), ("input_error", 2.0),
                                ("keyboard_write_unconfirmed", 1.0), ("final", 3.0), ("finished", 4.0)] {
            try memoryLogger.append(.init(timestamp: date.addingTimeInterval(offset), sessionID: session, event: event))
        }
        let summary = DiagnosticSessionSummary.make(from: memoryLogger.failureEvents(at: date.addingTimeInterval(5), recoverPersisted: false))
            .first { $0.sessionID == session }
        XCTAssertEqual(summary?.firstAnomaly?.event, "keyboard_write_unconfirmed")
        XCTAssertEqual(summary?.lastSuccessBeforeAnomaly?.event, "keyboard_write_acknowledged")
    }

    @MainActor
    func testOverflowPreservesFirstAnomalyLastSuccessAndFinalSafeCopy() throws {
        let logger = SessionLogger(enabled: { false }, failureContextEventLimit: 2)
        logger.setFailureContextEnabled(true)
        let session = UUID()
        let start = Date()
        for (index, event) in ["keyboard_write_acknowledged", "keyboard_state_change_observed",
                                "mixed_input_ambiguous", "partial", "final", "safe_copy_updated", "finished"].enumerated() {
            try logger.append(.init(timestamp: start.addingTimeInterval(Double(index)), sessionID: session,
                event: event, textEvidence: event == "safe_copy_updated" ? [
                    .init(kind: .safeCopySucceeded, source: .observed, text: "完整正文")
                ] : []))
        }
        let events = logger.failureEvents(at: start.addingTimeInterval(10))
        let summary = try XCTUnwrap(DiagnosticSessionSummary.make(from: events).first { $0.sessionID == session })
        XCTAssertEqual(summary.firstAnomaly?.event, "keyboard_state_change_observed")
        XCTAssertEqual(summary.lastSuccessBeforeAnomaly?.event, "keyboard_write_acknowledged")
        XCTAssertEqual(summary.finalSafeCopy?.textEvidence.first?.text, "完整正文")
        XCTAssertEqual(events.first { $0.event == "diagnostic_events_omitted" }?.metadata["droppedEventCount"], "5")
    }

    func testErrorDetailsRetainExplanationButRemoveWholeCredentialValues() {
        let message = #"server rejected; "SecretKey": "two words"; Authorization: Bearer token-value; retry later"#
        let result = DiagnosticLogSanitizer.failureMessage(message)
        XCTAssertTrue(result.contains("server rejected"))
        XCTAssertTrue(result.contains("retry later"))
        XCTAssertFalse(result.contains("two words"))
        XCTAssertFalse(result.contains("token-value"))
    }
    func testSummaryPinsFirstAnomalyLastSuccessAndFinalCopyWithoutGuessingCause() {
        let session = UUID()
        let time = Date(timeIntervalSince1970: 1000)
        let events = [
            SessionLogEntry(timestamp: time, sessionID: session, event: "keyboard_write_acknowledged"),
            SessionLogEntry(timestamp: time.addingTimeInterval(0.072), sessionID: session, event: "keyboard_state_change_observed"),
            SessionLogEntry(timestamp: time.addingTimeInterval(1), sessionID: session, event: "mixed_input_ambiguous"),
            SessionLogEntry(timestamp: time.addingTimeInterval(2), sessionID: session, event: "final"),
            SessionLogEntry(timestamp: time.addingTimeInterval(3), sessionID: session, event: "safe_copy_updated",
                textEvidence: [.init(kind: .safeCopySucceeded, source: .observed, text: "完整结果👩🏽‍💻")])
        ]
        let summary = DiagnosticSessionSummary.make(from: events).first
        XCTAssertEqual(summary?.firstAnomaly?.eventID, events[1].eventID)
        XCTAssertEqual(summary?.lastSuccessBeforeAnomaly?.eventID, events[0].eventID)
        XCTAssertEqual(summary?.recognitionEventsAfterAnomaly, 1)
        XCTAssertEqual(summary?.finalSafeCopy?.textEvidence.first?.text, "完整结果👩🏽‍💻")
        XCTAssertEqual(summary?.screenEvidenceStatus, "not_captured_AX_text_is_not_screen_evidence")
    }

    @MainActor
    func testCorruptPersistedLineIsReportedInsteadOfSilentlyDiscarded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = SessionLogger(enabled: { true }, applicationSupportDirectoryURL: root)
        try logger.append(.init(event: "partial", textEvidence: [
            .init(kind: .rawRecognition, source: .observed, text: String(repeating: "正文", count: 500))
        ]))
        let directory = root.appendingPathComponent("TencentVoiceMVP/sessions")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("broken json\n".utf8))
        try handle.close()
        let entries = logger.allPersistedEntries()
        XCTAssertEqual(entries.first { $0.event == "partial" }?.textEvidence.first?.text.count, 1000)
        XCTAssertEqual(entries.first { $0.event == "diagnostic_decode_failed" }?.metadata["missingEventCount"], "1")
    }

    func testFullTextEvidenceSurvivesJSONRoundTripWithoutNormalizationOrTruncation() throws {
        let body = String(repeating: "甲\u{200B}👩🏽‍💻e\u{301}\r\n", count: 80)
        let evidence = DiagnosticTextEvidence(
            kind: .axValue,
            source: .observed,
            text: body,
            revision: 52,
            operationID: "39",
            targetApplicationBundleIdentifier: "com.openai.codex",
            targetApplicationProcessID: 82118,
            selectionLocationUTF16: 139,
            selectionLengthUTF16: 0,
            monotonicMilliseconds: 8_112_004
        )
        let entry = SessionLogEntry(
            event: "keyboard_write_acknowledged",
            textEvidence: [evidence]
        )

        let data = try DiagnosticJSON.encoder().encode(entry)
        let decoded = try DiagnosticJSON.decoder().decode(SessionLogEntry.self, from: data)

        XCTAssertEqual(decoded.textEvidence, [evidence])
        XCTAssertEqual(decoded.textEvidence.first?.text.utf16.count, body.utf16.count)
        XCTAssertEqual(decoded.metadata, [:])
    }

    func testMetadataNoLongerTruncatesOrMistakesContextForText() {
        let detail = String(repeating: "错误详情", count: 80)
        let fields = DiagnosticLogSanitizer.fields(["contextEnabled": "true", "errorDetail": detail])
        XCTAssertEqual(fields["contextEnabled"], "true")
        XCTAssertEqual(fields["errorDetail"], detail)
    }

    func testFailureReportRendersFullEvidenceAndLabelsItsSource() throws {
        let body = String(repeating: "识别正文乙", count: 60)
        let report = DiagnosticReport(
            app: DiagnosticAppInfo(
                displayName: "Rime Voice", bundleIdentifier: "local.test", shortVersion: "0.4.3", build: "197",
                bundlePath: "/tmp/Test.app", executablePath: "/tmp/Test.app/Contents/MacOS/Test",
                bundleModificationDate: nil, processIdentifier: 1, processLaunchDate: nil,
                currentUser: "test", operatingSystem: "test", machineArchitecture: "arm64",
                signatureVerified: true, signatureDetails: "test"
            ),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "configured"),
            settings: DiagnosticSettingsInfo(shortcut: "F5", engineModelType: "test", persistentSessionLogEnabled: true),
            events: [SessionLogEntry(event: "partial", textEvidence: [
                DiagnosticTextEvidence(kind: .rawRecognition, source: .observed, text: body)
            ])],
            logDirectoryPath: "/tmp/logs"
        )

        let rendered = report.renderedText()
        XCTAssertTrue(rendered.contains("原始识别/观测"))
        XCTAssertTrue(rendered.contains(body))
        XCTAssertTrue(rendered.contains("窗口内识别和目标输入框正文按原样完整保留"))
    }
}
