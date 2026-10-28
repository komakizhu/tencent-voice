import XCTest
@testable import TencentVoiceMVP

@MainActor
final class DiagnosticReportTests: XCTestCase {
    func testLegacyInputFailureReportDecodesWithoutNewClockAndFrameFields() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let event = InputContextEvent(timestamp: timestamp, event: "legacy_activity", fields: [:])
        let context = InputContextWindow(
            requestedStart: timestamp.addingTimeInterval(-60),
            recordingStartedAt: nil,
            capturedAt: timestamp,
            enabled: false,
            droppedEventCount: 0,
            events: [event]
        )
        let diagnosticReport = DiagnosticReport(
            schemaVersion: 3,
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "configured"),
            settings: DiagnosticSettingsInfo(
                shortcut: "test",
                engineModelType: "test",
                persistentSessionLogEnabled: false
            ),
            events: [],
            logDirectoryPath: "/tmp/logs"
        )
        let inputFailureReport = InputFailureReport(
            schemaVersion: 3,
            id: UUID(),
            generatedAt: timestamp,
            desktopContext: context,
            diagnosticReport: diagnosticReport,
            diagnosticEventsTruncated: false,
            evidenceScopeNote: "legacy"
        )
        let encoded = try DiagnosticJSON.encoder().encode(inputFailureReport)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "windowFrameCapture")
        var desktopContext = try XCTUnwrap(root["desktopContext"] as? [String: Any])
        desktopContext.removeValue(forKey: "capturedAtMonotonicNanoseconds")
        desktopContext.removeValue(forKey: "recordingStartedAtMonotonicNanoseconds")
        var events = try XCTUnwrap(desktopContext["events"] as? [[String: Any]])
        events[0].removeValue(forKey: "monotonicTimestampNanoseconds")
        events[0].removeValue(forKey: "sessionID")
        events[0].removeValue(forKey: "operationID")
        events[0].removeValue(forKey: "targetApplicationBundleIdentifier")
        events[0].removeValue(forKey: "targetApplicationProcessID")
        desktopContext["events"] = events
        root["desktopContext"] = desktopContext

        let decoded = try DiagnosticJSON.decoder().decode(
            InputFailureReport.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertNil(decoded.windowFrameCapture)
        XCTAssertNil(decoded.desktopContext.capturedAtMonotonicNanoseconds)
        XCTAssertNil(decoded.desktopContext.recordingStartedAtMonotonicNanoseconds)
        XCTAssertNil(decoded.desktopContext.events.first?.monotonicTimestampNanoseconds)
        XCTAssertNil(decoded.desktopContext.events.first?.sessionID)
    }

    func testReportExplainsSafariContinuityScanFailureAndRendersAXStatus() {
        let event = SessionLogEntry(
            sessionID: UUID(),
            event: AXTextEditorContinuityScanDiagnostic.event,
            metadata: [
                "scanStage": "ancestor_parent",
                "reason": "read_failed",
                "axAttribute": "AXParent",
                "axStatus": "-25202",
                "depth": "2",
                "elapsedMilliseconds": "17"
            ]
        )
        let report = DiagnosticReport(
            app: appInfo(), permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "configured"),
            settings: DiagnosticSettingsInfo(
                shortcut: "test", engineModelType: "test", persistentSessionLogEnabled: true
            ),
            events: [event], logDirectoryPath: "/tmp/logs"
        )

        XCTAssertTrue(report.findings.contains { $0.code == AXTextEditorContinuityScanDiagnostic.event })
        let text = report.renderedText()
        XCTAssertTrue(text.contains("ancestor_parent"))
        XCTAssertTrue(text.contains("AXParent"))
        XCTAssertTrue(text.contains("-25202"))
        XCTAssertTrue(text.contains("不能单独证明两个对象属于同一输入框"))
    }

    func testReportSeparatesWaitSkippedFromActualTimeoutAndShowsOperationContext() throws {
        let session = UUID()
        let events = [
            SessionLogEntry(
                sessionID: session,
                event: "input_operation",
                metadata: [
                    "operationID": "7",
                    "operationType": "tail_replacement",
                    "operationStatus": "submitted",
                    "operationTrigger": "partial",
                    "segmentID": "1",
                    "revision": "88",
                    "segmentPhase": "partial",
                    "desiredLengthCharacters": "305",
                    "desiredLengthUTF16": "305",
                    "submittedLengthCharacters": "302",
                    "submittedLengthUTF16": "302",
                    "commonPrefixLengthCharacters": "199",
                    "commonPrefixLengthUTF16": "199",
                    "previousTailLengthCharacters": "103",
                    "previousTailLengthUTF16": "103",
                    "replacementTailLengthCharacters": "104",
                    "replacementTailLengthUTF16": "104",
                    "characterUnit": "Character",
                    "utf16Unit": "UTF16",
                    "operationCreatedMonotonicMilliseconds": "1000",
                    "operationQueuedMonotonicMilliseconds": "1000",
                    "dispatchStartedMonotonicMilliseconds": "1001",
                    "dispatchEndedMonotonicMilliseconds": "1002",
                    "feedbackObservedMonotonicMilliseconds": "unknown",
                    "operationCompletedMonotonicMilliseconds": "1002",
                    "plannedSelectionLocation": "302",
                    "plannedSelectionLength": "103",
                    "expectedEndLocation": "303",
                    "writeCountMeaning": "submission_call_not_target_confirmation"
                ]
            ),
            SessionLogEntry(
                sessionID: session,
                event: "keyboard_wait_skipped",
                metadata: [
                    "operationID": "7",
                    "waitClassification": "wait_skipped",
                    "waitSkippedReason": "dispatch_age_exceeded",
                    "lastDispatchAgeMilliseconds": "333.471",
                    "waitBudgetMilliseconds": "150",
                    "waitQualificationMaxAgeMilliseconds": "250",
                    "polls": "0",
                    "waitMilliseconds": "0",
                    "expectedLocation": "302",
                    "expectedLength": "0",
                    "actualLocation": "199",
                    "actualLength": "104"
                ]
            ),
            SessionLogEntry(
                sessionID: session,
                event: "keyboard_wait_timeout",
                metadata: [
                    "operationID": "6",
                    "waitClassification": "wait_timeout",
                    "lastDispatchAgeMilliseconds": "29.782",
                    "waitBudgetMilliseconds": "150",
                    "polls": "15",
                    "waitMilliseconds": "150",
                    "expectedLocation": "128",
                    "actualLocation": "127"
                ]
            )
        ]
        let report = DiagnosticReport(
            app: appInfo(), permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "configured"),
            settings: DiagnosticSettingsInfo(
                shortcut: "test", engineModelType: "test", persistentSessionLogEnabled: true
            ),
            events: events,
            logDirectoryPath: "/tmp/logs"
        )

        XCTAssertTrue(report.findings.contains { $0.code == "keyboard_wait_skipped" })
        XCTAssertTrue(report.findings.contains { $0.code == "keyboard_wait_timeout" })
        XCTAssertFalse(report.findings.contains { $0.code == "keyboard_caret_timeout" })
        let text = report.renderedText()
        XCTAssertTrue(text.contains("未进入等待"))
        XCTAssertTrue(text.contains("333.471"))
        XCTAssertTrue(text.contains("实际等待"))
        XCTAssertTrue(text.contains("operation=7"))
        XCTAssertTrue(text.contains("Character"))
        XCTAssertTrue(text.contains("UTF16"))
        XCTAssertTrue(text.contains("submission_call_not_target_confirmation"))
    }

    func testInputDiagnosticsUseUnifiedReportAndExistingPersistenceSwitch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID()
        let events = [
            SessionLogEntry(sessionID: session, event: "keyboard_caret_recovered", metadata: [
                "expectedLocation": "128", "initialLocation": "127", "actualLocation": "128",
                "waitMilliseconds": "50", "sourceBuild": "66", "recognizedText": "PRIVATE_BODY"
            ]),
            SessionLogEntry(sessionID: session, event: "ax_document_mismatch", metadata: [
                "expectedDocumentLength": "7", "actualDocumentLength": "5", "lastAXStatus": "0"
            ]),
            SessionLogEntry(sessionID: session, event: "keyboard_caret_timeout")
        ]
        var enabled = false
        let logger = SessionLogger(enabled: { enabled }, applicationSupportDirectoryURL: directory)
        for event in events { try logger.append(event) }
        XCTAssertTrue(logger.allPersistedEntries().isEmpty)
        XCTAssertEqual(logger.recentEntries().count, 3)
        enabled = true
        for event in events { try logger.append(event) }
        let report = DiagnosticReport(
            app: appInfo(), permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "configured"),
            settings: DiagnosticSettingsInfo(shortcut: "test", engineModelType: "test", persistentSessionLogEnabled: true),
            events: logger.allPersistedEntries(), logDirectoryPath: directory.path
        )
        XCTAssertEqual(report.findings.first { $0.code == "keyboard_caret_recovered" }?.level, .info)
        XCTAssertTrue(report.findings.contains { $0.code == "ax_document_mismatch" })
        XCTAssertTrue(report.findings.contains { $0.code == "keyboard_caret_timeout" })
        XCTAssertTrue(report.renderedText().contains("expectedLocation=128"))
        XCTAssertTrue(report.renderedText().contains("lastAXStatus=0"))
        let json = String(decoding: try DiagnosticJSON.encoder().encode(report), as: UTF8.self)
        XCTAssertTrue(json.contains("keyboard_caret_recovered"))
        XCTAssertTrue(json.contains("PRIVATE_BODY"))
    }

    func testReportIncludesCoordinateDiagnosticsWithoutInputText() {
        let session = UUID()
        let report = DiagnosticReport(
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "configured"),
            settings: DiagnosticSettingsInfo(
                shortcut: "test", engineModelType: "test", persistentSessionLogEnabled: true
            ),
            events: [
                SessionLogEntry(
                    sessionID: session,
                    event: "ax_coordinate_mapping_resolved",
                    metadata: [
                        "coordinateSource": "axStringForRange",
                        "axValueLengthUTF16": "8",
                        "axCoordinateLengthUTF16": "0",
                        "placeholderNormalized": "true",
                        "omittedStructuralSeparatorCount": "8"
                    ]
                ),
                SessionLogEntry(
                    sessionID: session,
                    event: "ax_coordinate_mapping_retryable",
                    metadata: [
                        "reason": "ax_value_stale_behind_selection",
                        "axValueLengthUTF16": "6",
                        "selectionLocation": "7"
                    ]
                ),
                SessionLogEntry(
                    sessionID: session,
                    event: "ax_coordinate_mapping_failed",
                    metadata: [
                        "reason": "coordinate_text_mismatch",
                        "axValueLengthUTF16": "7",
                        "selectionLocation": "6"
                    ]
                ),
                SessionLogEntry(
                    sessionID: session,
                    event: "keyboard_selection_stabilization_failed",
                    metadata: [
                        "phase": "after_set",
                        "comparison": "selection_mismatch",
                        "selectedRangeSettable": "true",
                        "selectionLocation": "3",
                        "selectionLength": "0"
                    ]
                )
            ],
            logDirectoryPath: "/tmp/logs"
        )

        XCTAssertTrue(report.findings.contains { $0.code == "ax_coordinate_mapping_resolved" })
        XCTAssertTrue(report.findings.contains { $0.code == "ax_coordinate_mapping_retryable" })
        XCTAssertTrue(report.findings.contains { $0.code == "ax_coordinate_mapping_failed" })
        XCTAssertEqual(
            report.findings.first { $0.code == "ax_coordinate_mapping_resolved" }?.level,
            .info
        )
        let rendered = report.renderedText()
        XCTAssertTrue(rendered.contains("axValueLengthUTF16=7"))
        XCTAssertTrue(rendered.contains("coordinate_text_mismatch"))
        XCTAssertTrue(rendered.contains("comparison=selection_mismatch"))
        XCTAssertTrue(rendered.contains("selectedRangeSettable=true"))
        XCTAssertFalse(rendered.contains("添加可选评论"))
    }

    func testReportExplainsSafeCopyTriggerWithoutRecognizedText() {
        let report = DiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: [
                PrivacyPermissionStatus(permission: .microphone, isGranted: true, detail: "已允许"),
                PrivacyPermissionStatus(permission: .accessibility, isGranted: true, detail: "已允许"),
                PrivacyPermissionStatus(permission: .postEvent, isGranted: true, detail: "已允许"),
                PrivacyPermissionStatus(permission: .inputMonitoring, isGranted: true, detail: "已允许")
            ]),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: false
            ),
            events: [
                SessionLogEntry(event: "started", state: "listening", injectionMode: "keyboard_live_tail"),
                SessionLogEntry(
                    event: "safe_copy",
                    state: "listening",
                    injectionMode: "safe_copy",
                    targetApplicationName: "Codex",
                    targetApplicationBundleIdentifier: "com.openai.codex",
                    targetApplicationProcessID: 42,
                    renderedLength: 4,
                    writeCount: 0,
                    errorCount: 1,
                    failureCode: "text_target_changed",
                    failureMessage: "输入目标在识别过程中发生了变化"
                ),
                SessionLogEntry(
                    event: "final",
                    state: "stopping",
                    injectionMode: "safe_copy",
                    renderedLength: 4,
                    writeCount: 0
                )
            ],
            logDirectoryPath: "/tmp/TencentVoiceMVP/sessions"
        )

        let text = report.renderedText()

        XCTAssertTrue(text.contains("safe_copy_triggered"))
        XCTAssertTrue(text.contains("text_target_changed"))
        XCTAssertTrue(text.contains("输入目标在识别过程中发生了变化"))
        XCTAssertTrue(text.contains("识别结果已经返回，但文本输入进入 safe_copy"))
        XCTAssertTrue(text.contains("target=Codex (com.openai.codex) pid=42"))
        XCTAssertTrue(text.contains("窗口内识别和目标输入框正文按原样完整保留"))
        XCTAssertFalse(text.contains("我想吃苹果"))
    }

    func testReportSeparatesStartedSessionWithoutASRResult() {
        let report = DiagnosticReport(
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: false
            ),
            events: [SessionLogEntry(event: "started", state: "listening")],
            logDirectoryPath: "/tmp/TencentVoiceMVP/sessions"
        )

        XCTAssertTrue(report.findings.contains { $0.code == "no_asr_result" })
        XCTAssertFalse(report.findings.contains { $0.code == "safe_copy_triggered" })
    }

    func testReportFlagsProcessThatPredatesInstalledAppBundle() {
        let launchDate = Date(timeIntervalSince1970: 1_700_000_000)
        let report = DiagnosticReport(
            app: DiagnosticAppInfo(
                displayName: "腾讯语音输入 MVP",
                bundleIdentifier: "local.tencent-voice-mvp",
                shortVersion: "0.2.0",
                build: "45",
                bundlePath: "/Applications/TencentVoiceMVP.app",
                executablePath: "/Applications/TencentVoiceMVP.app/Contents/MacOS/TencentVoiceMVP",
                bundleModificationDate: launchDate.addingTimeInterval(60),
                processIdentifier: 100,
                processLaunchDate: launchDate,
                currentUser: "test-user",
                operatingSystem: "macOS test",
                machineArchitecture: "arm64",
                signatureVerified: true,
                signatureDetails: "Identifier=local.tencent-voice-mvp"
            ),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: false
            ),
            events: [],
            logDirectoryPath: "/tmp/TencentVoiceMVP/sessions"
        )

        XCTAssertTrue(report.findings.contains { $0.code == "process_started_before_app_update" })
        XCTAssertTrue(report.renderedText().contains("完全退出后重新打开"))
    }

    func testBuilderIncludesPersistedEventsInTheUnifiedExport() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let writer = SessionLogger(
            enabled: { true },
            applicationSupportDirectoryURL: testDirectory
        )
        let entry = SessionLogEntry(event: "safe_copy", failureCode: "text_target_changed")
        try writer.append(entry)

        let reader = SessionLogger(
            enabled: { false },
            applicationSupportDirectoryURL: testDirectory
        )
        let settingsStore = UserDefaultsSettingsStore(
            suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"
        )
        let credentialStore = InMemoryCredentialStore(
            TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        )
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true }
        )

        let disabledReport = DiagnosticReportBuilder(
            permissionChecker: checker,
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            logger: reader,
            appInfo: appInfo()
        ).build()
        XCTAssertEqual(disabledReport.events.count, 0, "A newly created logger must report its collection gap instead of scanning old files")

        settingsStore.save(AppSettings(saveTextLogs: true))
        let enabledReport = DiagnosticReportBuilder(
            permissionChecker: checker,
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            logger: writer,
            appInfo: appInfo()
        ).build()
        XCTAssertEqual(enabledReport.events.count, 1)
        XCTAssertEqual(enabledReport.events.first?.eventID, entry.eventID)
        XCTAssertEqual(enabledReport.events.first?.failureCode, entry.failureCode)
    }

    func testBuilderUsesOnlyTheMinuteBeforeBuildAndPreservesFullUnicodeEvidence() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticReportWindow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let now = Date()
        let outside = SessionLogEntry(
            timestamp: now.addingTimeInterval(-60.001),
            event: "outside_report_window",
            textEvidence: [DiagnosticTextEvidence(kind: .axValue, source: .observed, text: "must-not-leak")]
        )
        let fullText = "e\u{301}\u{200B}😀\u{2028}保留完整正文"
        let inside = SessionLogEntry(
            timestamp: now.addingTimeInterval(-30),
            event: "inside_report_window",
            textEvidence: [
                DiagnosticTextEvidence(kind: .rawRecognition, source: .observed, text: fullText),
                DiagnosticTextEvidence(kind: .safeCopySucceeded, source: .observed, text: fullText)
            ]
        )
        let boundary = SessionLogEntry(
            timestamp: now.addingTimeInterval(-60),
            event: "inclusive_window_start"
        )
        let logger = SessionLogger(enabled: { true }, applicationSupportDirectoryURL: testDirectory)
        try logger.append(outside)
        try logger.append(inside)
        try logger.append(boundary)

        let settingsStore = UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)")
        let requestID = UUID()
        let requestedAtMonotonicNanoseconds: UInt64 = 9_876_543
        let report = DiagnosticReportBuilder(
            permissionChecker: SystemPrivacyPermissionChecker(
                microphoneStatus: { .authorized }, accessibilityStatus: { true },
                postEventStatus: { true }, inputMonitoringStatus: { true }
            ),
            credentialStore: InMemoryCredentialStore(
                TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
            ),
            settingsStore: settingsStore,
            logger: logger,
            appInfo: appInfo()
        ).build(
            requestedAt: now,
            requestID: requestID,
            requestedAtMonotonicNanoseconds: requestedAtMonotonicNanoseconds
        )

        XCTAssertEqual(report.events.map(\.event), ["inclusive_window_start", "inside_report_window"])
        XCTAssertEqual(report.events[1].textEvidence.map(\.text), [fullText, fullText])
        XCTAssertEqual(report.schemaVersion, 3)
        XCTAssertEqual(report.window?.requestID, requestID)
        XCTAssertEqual(report.window?.requestedAtMonotonicNanoseconds, requestedAtMonotonicNanoseconds)
    }

    func testEventSnapshotRecoversEvictedTextFromOnlyReferencedFileRanges() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticSnapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let historyDirectory = support.appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: 2 * 1024 * 1024)
            .write(to: historyDirectory.appendingPathComponent("2001-01-01.jsonl"))

        let now = Date()
        let logger = SessionLogger(
            enabled: { true },
            applicationSupportDirectoryURL: support,
            failureContextEventLimit: 1
        )
        logger.setFailureContextEnabled(true)
        let body = "e\u{301}\u{200B}😀\u{2028}完整恢复"
        let evicted = SessionLogEntry(timestamp: now.addingTimeInterval(-20), event: "evicted", textEvidence: [
            DiagnosticTextEvidence(kind: .rawRecognition, source: .observed, text: body),
            DiagnosticTextEvidence(kind: .axValue, source: .observed, text: body)
        ])
        let retained = SessionLogEntry(timestamp: now.addingTimeInterval(-10), event: "retained")
        try logger.append(evicted)
        try logger.append(retained)

        let result = logger.reportEventSnapshot(at: Date()).recoverPersistedEvents()
        XCTAssertEqual(result.events.map(\.event), ["evicted", "retained", "diagnostic_events_omitted"])
        XCTAssertEqual(result.events[0].textEvidence.map(\.text), [body, body])
        XCTAssertEqual(result.metrics.filesConsidered, 1)
        XCTAssertEqual(result.metrics.filesRead, 1)
        XCTAssertLessThan(result.metrics.bytesRead, 20_000)
        XCTAssertEqual(result.metrics.recordsRecovered, 2)
    }

    func testPreWindowMetadataReportsRemainDecodable() throws {
        let legacy = DiagnosticReport(
            schemaVersion: 2,
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "configured"),
            settings: DiagnosticSettingsInfo(shortcut: "test", engineModelType: "test", persistentSessionLogEnabled: true),
            events: [],
            logDirectoryPath: "/tmp/logs"
        )
        let encoded = try DiagnosticJSON.encoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "window")
        object.removeValue(forKey: "recoveryMetrics")
        object.removeValue(forKey: "stageTimings")
        let decoded = try DiagnosticJSON.decoder().decode(
            DiagnosticReport.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertNil(decoded.window)
        XCTAssertNil(decoded.recoveryMetrics)
        XCTAssertNil(decoded.stageTimings)
    }

    func testSnapshotDoesNotMixRecordsAppendedAfterTheClickCutoff() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticSnapshotBoundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let logger = SessionLogger(enabled: { true }, applicationSupportDirectoryURL: support)
        let beforeEventAt = Date()
        try logger.append(SessionLogEntry(timestamp: beforeEventAt, event: "before_click"))
        let click = Date()
        let snapshot = logger.reportEventSnapshot(at: click)
        try logger.append(SessionLogEntry(timestamp: click.addingTimeInterval(-0.5), event: "appended_after_click"))

        let result = snapshot.recoverPersistedEvents()
        XCTAssertEqual(result.events.map(\.event), ["before_click"])
        XCTAssertEqual(result.metrics.recordsDecoded, 1)
    }

    func testSnapshotReportsReplacedEvidenceFileAsMissing() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticSnapshotReplaced-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let logger = SessionLogger(
            enabled: { true },
            applicationSupportDirectoryURL: support,
            failureContextEventLimit: 1
        )
        logger.setFailureContextEnabled(true)
        let now = Date()
        try logger.append(SessionLogEntry(timestamp: now.addingTimeInterval(-10), event: "evicted_and_missing"))
        try logger.append(SessionLogEntry(timestamp: now.addingTimeInterval(-5), event: "retained_in_memory"))
        let snapshot = logger.reportEventSnapshot(at: Date())
        let reference = try XCTUnwrap(snapshot.fileReferences.first)
        try Data("replaced after snapshot".utf8).write(to: reference.fileURL, options: .atomic)

        let result = snapshot.recoverPersistedEvents()
        XCTAssertEqual(result.events.map(\.event), ["retained_in_memory", "diagnostic_events_omitted"])
        XCTAssertEqual(result.metrics.filesRead, 0)
        XCTAssertEqual(result.metrics.missingRecordCount, 1)
        XCTAssertTrue(result.metrics.failureReasons.contains { $0.hasPrefix("file_replaced_or_truncated:") })
    }

    func testSnapshotDoesNotDoubleCountAnEventMissingFromBothMemoryAndDiskIndex() {
        let eventID = UUID()
        let sessionID = UUID()
        let now = Date()
        let evicted = DiagnosticEventEvictionReference(
            timestamp: now.addingTimeInterval(-5), eventID: eventID,
            sessionID: sessionID, event: "same_missing_event", sequence: 1,
            indexedAt: now.addingTimeInterval(-5)
        )
        let snapshot = DiagnosticReportEventSnapshot(
            requestedAt: now,
            windowStart: now.addingTimeInterval(-60),
            captureStartedAt: now.addingTimeInterval(-60),
            memoryEvents: [],
            pinnedEvidenceTruncated: false,
            failureContextEvidenceTruncated: false,
            fileReferences: [],
            omittedReferenceKeys: [evicted.identityKey],
            omissionIndexOverflowed: false,
            evictedMemoryEvents: [evicted],
            memoryEvictionCountUnknown: false
        )

        let result = snapshot.recoverPersistedEvents()

        XCTAssertEqual(result.metrics.missingRecordCount, 1)
    }

    func testSnapshotExplainsUnknownMissingCountWhenOmissionIndexCapacityIsExceeded() {
        let now = Date()
        let snapshot = DiagnosticReportEventSnapshot(
            requestedAt: now,
            windowStart: now.addingTimeInterval(-60),
            captureStartedAt: now.addingTimeInterval(-60),
            memoryEvents: [],
            pinnedEvidenceTruncated: false,
            failureContextEvidenceTruncated: false,
            fileReferences: [],
            omittedReferenceKeys: [],
            omissionIndexOverflowed: true,
            evictedMemoryEvents: [],
            memoryEvictionCountUnknown: false
        )

        let result = snapshot.recoverPersistedEvents()

        XCTAssertNil(result.metrics.missingRecordCount)
        XCTAssertTrue(result.metrics.failureReasons.contains("omitted_reference_index_capacity_exceeded"))
    }

    func testReportSnapshotUsesFailureContextCaptureStartInsteadOfProcessStart() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticCaptureStart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let logger = SessionLogger(enabled: { false }, applicationSupportDirectoryURL: support)
        logger.setFailureContextEnabled(true)
        let captureStartedAt = logger.failureContextRecordingStartedAt

        let snapshot = logger.reportEventSnapshot(at: Date())

        XCTAssertEqual(snapshot.captureStartedAt, captureStartedAt)
    }

    func testReportSnapshotMakesPinnedEvidenceCapacityLossExplicitWithinTheWindow() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-PinnedEvidenceOverflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let logger = SessionLogger(
            enabled: { false },
            applicationSupportDirectoryURL: support,
            failureContextEventLimit: 500
        )
        logger.setFailureContextEnabled(true)
        let now = Date()
        let anomaly = try XCTUnwrap(DiagnosticAnomaly.events.sorted().first)
        for index in 0..<129 {
            try logger.append(SessionLogEntry(
                timestamp: now.addingTimeInterval(-30 + Double(index) / 10),
                sessionID: UUID(),
                event: anomaly
            ))
        }

        let snapshot = logger.reportEventSnapshot(at: now)

        XCTAssertTrue(snapshot.pinnedEvidenceTruncated)
        let omission = try XCTUnwrap(snapshot.memoryEvents.first { $0.event == "diagnostic_session_pins_omitted" })
        XCTAssertEqual(omission.metadata["omittedSessionCount"], "1")
        XCTAssertEqual(omission.metadata["countScope"], "click_window")
        XCTAssertFalse(logger.failureContextEventsTruncated)
    }

    @MainActor
    func testDroppedPinnedEvidenceFromOutsideTheClickWindowIsExcluded() throws {
        let logger = SessionLogger(enabled: { false }, failureContextEventLimit: 500)
        logger.setFailureContextEnabled(true)
        let now = Date()
        let anomaly = try XCTUnwrap(DiagnosticAnomaly.events.sorted().first)
        for index in 0..<129 {
            try logger.append(SessionLogEntry(
                timestamp: now.addingTimeInterval(-120 + Double(index) / 10),
                sessionID: UUID(),
                event: anomaly
            ))
        }

        let snapshot = logger.reportEventSnapshot(at: now)

        XCTAssertFalse(snapshot.pinnedEvidenceTruncated)
        XCTAssertFalse(snapshot.memoryEvents.contains { $0.event == "diagnostic_session_pins_omitted" })
    }

    @MainActor
    func testFailureContextEvictionIsReportedOnlyWhenItIntersectsTheClickWindow() throws {
        let logger = SessionLogger(enabled: { false }, failureContextEventLimit: 2)
        logger.setFailureContextEnabled(true)
        let origin = Date()
        for (offset, name) in [(0.0, "outside"), (70.0, "evicted_in_window"), (80.0, "keep_a"), (100.0, "keep_b")] {
            try logger.append(SessionLogEntry(timestamp: origin.addingTimeInterval(offset), event: name))
        }

        let snapshot = logger.reportEventSnapshot(at: origin.addingTimeInterval(100))

        XCTAssertTrue(snapshot.failureContextEvidenceTruncated)
        let omission = try XCTUnwrap(snapshot.memoryEvents.first { $0.event == "diagnostic_events_omitted" })
        XCTAssertEqual(omission.metadata["droppedEventCount"], "1")
        XCTAssertEqual(omission.metadata["countScope"], "click_window")
    }

    @MainActor
    func testFailureContextEvictionsOutsideTheClickWindowAreNotReportedAsCurrentLoss() throws {
        let logger = SessionLogger(enabled: { false }, failureContextEventLimit: 1)
        logger.setFailureContextEnabled(true)
        let origin = Date()
        for (offset, name) in [(0.0, "old_a"), (1.0, "old_b"), (2.0, "old_c")] {
            try logger.append(SessionLogEntry(timestamp: origin.addingTimeInterval(offset), event: name))
        }

        let snapshot = logger.reportEventSnapshot(at: origin.addingTimeInterval(100))

        XCTAssertFalse(snapshot.failureContextEvidenceTruncated)
        XCTAssertFalse(snapshot.memoryEvents.contains { $0.event == "diagnostic_events_omitted" })
    }

    func testReportCaptureStartTracksPersistenceAvailabilityAndMarksUnknownStart() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticPersistenceStart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        var persistenceEnabled = false
        let logger = SessionLogger(enabled: { persistenceEnabled }, applicationSupportDirectoryURL: support)

        XCTAssertNil(logger.reportCaptureStartedAt)
        XCTAssertEqual(DiagnosticReportWindow(
            requestedAt: Date(), startAt: Date().addingTimeInterval(-60),
            captureStartedAt: logger.reportCaptureStartedAt, captureEnabled: true
        ).coverageStatus, "采集起点未知；已按请求前60秒筛选，不能保证窗口完整")

        persistenceEnabled = true
        let firstPersistedAt = Date()
        try logger.append(SessionLogEntry(timestamp: firstPersistedAt, event: "first_persisted"))
        XCTAssertEqual(logger.reportCaptureStartedAt, firstPersistedAt)

        persistenceEnabled = false
        try logger.append(SessionLogEntry(timestamp: Date(), event: "not_persisted"))
        XCTAssertNil(logger.reportCaptureStartedAt)
    }

    func testAsyncReportAssemblyLeavesMainActorResponsiveForProgressUpdates() async {
        let now = Date()
        let sessionID = UUID()
        let events = (0..<30_000).map { index in
            SessionLogEntry(
                timestamp: now.addingTimeInterval(-Double(index % 60)),
                sessionID: sessionID,
                event: "partial",
                sequence: index,
                renderedLength: 1
            )
        }
        let loggerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-ReportResponsiveness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: loggerDirectory) }
        let settingsStore = UserDefaultsSettingsStore(suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)")
        let builder = DiagnosticReportBuilder(
            permissionChecker: SystemPrivacyPermissionChecker(
                microphoneStatus: { .authorized }, accessibilityStatus: { true },
                postEventStatus: { true }, inputMonitoringStatus: { true }
            ),
            credentialStore: InMemoryCredentialStore(
                TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
            ),
            settingsStore: settingsStore,
            logger: SessionLogger(enabled: { false }, applicationSupportDirectoryURL: loggerDirectory),
            appInfo: appInfo()
        )
        let buildTask = Task.detached(priority: .userInitiated) {
            await builder.buildAsync(
                events: events,
                requestedAt: now,
                captureStartedAt: now.addingTimeInterval(-60),
                captureEnabled: true,
                recoveryMetrics: DiagnosticEventRecoveryMetrics()
            )
        }
        let progressProbe = Task.detached(priority: .userInitiated) {
            var maximumSchedulingMilliseconds = 0.0
            for _ in 0..<100 {
                let probeStarted = DispatchTime.now().uptimeNanoseconds
                await MainActor.run {}
                maximumSchedulingMilliseconds = max(
                    maximumSchedulingMilliseconds,
                    Double(DispatchTime.now().uptimeNanoseconds - probeStarted) / 1_000_000
                )
                try? await Task.sleep(for: .milliseconds(10))
            }
            return maximumSchedulingMilliseconds
        }

        let report = await buildTask.value
        let mainActorSchedulingMilliseconds = await progressProbe.value

        XCTAssertEqual(report.events.count, events.count)
        XCTAssertGreaterThan(report.stageTimings?.assemblyMilliseconds ?? 0, 100)
        XCTAssertLessThan(mainActorSchedulingMilliseconds, 100)
    }

    func testBuilderExportsAllInWindowEventsWithoutARecentEventCap() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let logger = SessionLogger(
            enabled: { true },
            applicationSupportDirectoryURL: testDirectory
        )
        for index in 0..<161 {
            try logger.append(SessionLogEntry(
                timestamp: Date().addingTimeInterval(Double(index - 160)),
                event: "session_event",
                sequence: index
            ))
        }

        let settingsStore = UserDefaultsSettingsStore(
            suiteName: "TencentVoiceMVPTests.\(UUID().uuidString)"
        )
        let credentialStore = InMemoryCredentialStore(
            TencentCredentials(appID: "app", secretID: "id", secretKey: "key")
        )
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true }
        )

        let report = DiagnosticReportBuilder(
            permissionChecker: checker,
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            logger: logger,
            appInfo: appInfo()
        ).build()

        XCTAssertEqual(report.events.count, 60)
        XCTAssertEqual(report.events.first?.sequence, 101)
        XCTAssertEqual(report.events.last?.sequence, 160)
    }

    func testReportPreservesFailureDetailsAndRemovesCredentialValues() {
        let report = DiagnosticReport(
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: false
            ),
            events: [SessionLogEntry(
                event: "safe_copy",
                failureCode: "unexpected_error_type",
                failureMessage: "SecretKey=do-not-export"
            )],
            logDirectoryPath: "/tmp/TencentVoiceMVP/sessions"
        )

        let text = report.renderedText()
        XCTAssertTrue(text.contains("SecretKey=[已移除凭据]"))
        XCTAssertFalse(text.contains("do-not-export"))
    }

    func testFindingsAreScopedToIndividualSessions() {
        let noResultSessionID = UUID()
        let successfulSessionID = UUID()
        let report = DiagnosticReport(
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: false
            ),
            events: [
                SessionLogEntry(sessionID: noResultSessionID, event: "started", state: "listening"),
                SessionLogEntry(sessionID: successfulSessionID, event: "started", state: "listening"),
                SessionLogEntry(
                    sessionID: successfulSessionID,
                    event: "final",
                    state: "listening",
                    renderedLength: 4,
                    writeCount: 1
                )
            ],
            logDirectoryPath: "/tmp/TencentVoiceMVP/sessions"
        )

        XCTAssertEqual(report.findings.filter { $0.code == "no_asr_result" }.count, 1)
        XCTAssertFalse(report.findings.contains { $0.code == "recognized_without_write" })
    }

    func testReportIncludesFinishFailure() {
        let report = DiagnosticReport(
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: false
            ),
            events: [SessionLogEntry(
                event: "finish_error",
                failureCode: "text_target_write_failed",
                failureMessage: "不应直接信任这段原始消息"
            )],
            logDirectoryPath: "/tmp/TencentVoiceMVP/sessions"
        )

        XCTAssertTrue(report.findings.contains { $0.code == "text_target_write_failed" })
        XCTAssertTrue(report.renderedText().contains("不应直接信任这段原始消息"))
    }

    func testReportRecognizesSafeCopyInLegacyFinishedEvent() {
        let report = DiagnosticReport(
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: true
            ),
            events: [SessionLogEntry(
                event: "finished",
                injectionMode: "safe_copy",
                renderedLength: 5,
                writeCount: 0
            )],
            logDirectoryPath: "/tmp/TencentVoiceMVP/sessions"
        )

        XCTAssertTrue(report.findings.contains { $0.code == "safe_copy_triggered" })
        XCTAssertTrue(report.renderedText().contains("触发原因未记录"))
    }

    func testLegacyReportExplainsInputFailureWithoutSafeCopy() {
        let report = DiagnosticReport(
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: false,
                alwaysSaveVoiceContent: false
            ),
            events: [SessionLogEntry(
                event: "input_error",
                injectionMode: "disabled_after_error",
                failureCode: "text_target_changed"
            )],
            logDirectoryPath: "/tmp/TencentVoiceMVP/sessions"
        )

        XCTAssertTrue(report.findings.contains { $0.code == "input_error" })
        XCTAssertFalse(report.findings.contains { $0.code == "safe_copy_triggered" })
        XCTAssertTrue(report.renderedText().contains("旧版会话在输入失败后没有启用自动保存回退"))
    }

    func testSettingsInfoReadsReportsCreatedBeforeSafeCopyFlag() throws {
        let data = Data("""
        {
            "shortcut": "⌘0",
            "engineModelType": "16k_zh",
            "persistentSessionLogEnabled": false
        }
        """.utf8)

        let settings = try JSONDecoder().decode(DiagnosticSettingsInfo.self, from: data)

        XCTAssertFalse(settings.alwaysSaveVoiceContent)
    }

    func testSettingsInfoReadsLegacySafeCopyField() throws {
        let data = Data("""
        {
            "shortcut": "⌘0",
            "engineModelType": "16k_zh",
            "persistentSessionLogEnabled": false,
            "safeCopyEnabled": true
        }
        """.utf8)

        let settings = try JSONDecoder().decode(DiagnosticSettingsInfo.self, from: data)

        XCTAssertTrue(settings.alwaysSaveVoiceContent)
    }

    func testLoggerKeepsRecentEntriesWhenPersistentLoggingIsDisabled() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let logger = SessionLogger(
            enabled: { false },
            applicationSupportDirectoryURL: testDirectory
        )
        let entry = SessionLogEntry(event: "safe_copy", failureCode: "text_target_write_failed")

        try logger.append(entry)

        XCTAssertEqual(logger.recentEntries(), [entry])
        XCTAssertTrue(logger.recentPersistedEntries().isEmpty)
    }

    func testLoggerPersistsDiagnosticActionsIntoTheUnifiedExportLog() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let logger = SessionLogger(
            enabled: { true },
            applicationSupportDirectoryURL: testDirectory
        )
        logger.recordDiagnosticAction(
            "connection_test_finished",
            fields: [
                "engineModelType": "16k_zh",
                "errorCode": "text_target_changed",
                "errorMessage": "SecretKey=must-not-be-exported"
            ]
        )

        let entries = logger.recentPersistedEntries(limit: 10)
        let action = try XCTUnwrap(entries.first)
        XCTAssertEqual(action.kind, .action)
        XCTAssertEqual(action.event, "connection_test_finished")
        XCTAssertEqual(action.metadata["engineModelType"], "16k_zh")
        XCTAssertEqual(action.metadata["errorCode"], "text_target_changed")
        XCTAssertEqual(action.metadata["errorMessage"], "SecretKey=[已移除凭据]")
    }

    func testLoggerMigratesLegacyInterruptedDiagnosticJournal() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let journalURL = testDirectory
            .appendingPathComponent("TencentVoiceMVP/diagnostics/active.json")
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let app = String(
            decoding: try DiagnosticJSON.encoder().encode(appInfo()),
            as: UTF8.self
        )
        let sessionID = UUID()
        let journal = """
        {
          "schemaVersion": 1,
          "startedAt": "2026-09-07T05:00:00.000Z",
          "app": \(app),
          "events": [
            {
              "timestamp": "2026-09-07T05:01:00.000Z",
              "kind": "session",
              "name": "safe_copy",
              "sessionID": "\(sessionID.uuidString)",
              "fields": {
                "failureCode": "text_target_changed",
                "renderedLength": "3",
                "writeCount": "0"
              }
            }
          ],
          "droppedEventCount": 2
        }
        """
        try Data(journal.utf8).write(to: journalURL, options: .atomic)

        let logger = SessionLogger(
            enabled: { false },
            applicationSupportDirectoryURL: testDirectory
        )
        let entries = logger.allPersistedEntries()
        let migratedEvent = try XCTUnwrap(entries.first { $0.event == "safe_copy" })
        let migrationEvent = try XCTUnwrap(
            entries.first { $0.event == "legacy_diagnostic_journal_migrated" }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(migratedEvent.sessionID, sessionID)
        XCTAssertEqual(migratedEvent.failureCode, "text_target_changed")
        XCTAssertEqual(migratedEvent.renderedLength, 3)
        XCTAssertEqual(migratedEvent.writeCount, 0)
        XCTAssertEqual(migrationEvent.metadata["droppedEventCount"], "2")
    }

    func testUnifiedLogSanitizesFailureMessagesBeforeExport() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let logger = SessionLogger(
            enabled: { true },
            applicationSupportDirectoryURL: testDirectory
        )
        try logger.append(SessionLogEntry(
            event: "error",
            failureCode: "text_target_changed",
            failureMessage: "SecretKey=must-not-be-exported"
        ))

        let data = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: testDirectory.appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true),
                includingPropertiesForKeys: nil
            ).first.flatMap { try? Data(contentsOf: $0) }
        )
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("SecretKey=must-not-be-exported"))
        XCTAssertTrue(json.contains("text_target_changed"))
    }

    func testLegacySessionEntriesDecodeAsSessionEvents() throws {
        let sessionID = UUID()
        let data = Data("""
        {
          "timestamp": "2026-09-07T05:00:00.000Z",
          "sessionID": "\(sessionID.uuidString)",
          "event": "started",
          "state": "listening"
        }
        """.utf8)

        let entry = try DiagnosticJSON.decoder().decode(SessionLogEntry.self, from: data)

        XCTAssertEqual(entry.sessionID, sessionID)
        XCTAssertEqual(entry.kind, .session)
        XCTAssertEqual(entry.metadata, [:])
    }

    func testFailureSummarySeparatesObservedMismatchFromUnprovenCause() throws {
        let failure = SessionLogEntry(
            event: "keyboard_write_unconfirmed",
            metadata: ["failureCode": "documentMismatch"],
            textEvidence: [
                DiagnosticTextEvidence(
                    kind: .expectedDocument, source: .expected, text: "上一句，那必"
                ),
                DiagnosticTextEvidence(
                    kind: .axValue, source: .observed, text: "上一句必，那"
                )
            ]
        )

        let summary = try XCTUnwrap(DiagnosticSessionSummary.make(from: [failure]).first)
        let encoded = try JSONEncoder().encode(summary)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let assessment = try XCTUnwrap(object["causeAssessment"] as? [String: Any])
        XCTAssertEqual(assessment["observableFailure"] as? String, "正文与预期正文不一致")
        XCTAssertEqual(assessment["status"] as? String, "原因未唯一确定")
        XCTAssertTrue((assessment["candidateCauses"] as? [String] ?? []).contains("编辑器实际选区移动"))
        XCTAssertTrue((assessment["candidateCauses"] as? [String] ?? []).contains("AX 读数滞后"))
        XCTAssertTrue((assessment["missingEvidence"] as? [String] ?? []).contains("独立于 AX 的页面正文或选区状态"))
    }

    func testSchemaFiveSummaryWithoutCauseAssessmentStillDecodes() throws {
        let summary = DiagnosticSessionSummary(
            sessionID: UUID(),
            firstAnomaly: nil,
            lastSuccessBeforeAnomaly: nil,
            recognitionEventsAfterAnomaly: 0,
            finalSafeCopy: nil,
            fullTextEvidenceCount: 0,
            screenEvidenceStatus: "not_captured"
        )
        let encoded = try DiagnosticJSON.encoder().encode(summary)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "causeAssessment")

        let decoded = try DiagnosticJSON.decoder().decode(
            DiagnosticSessionSummary.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.causeAssessment)
        XCTAssertEqual(decoded.screenEvidenceStatus, "not_captured")
    }

    private func appInfo() -> DiagnosticAppInfo {
        DiagnosticAppInfo(
            displayName: "腾讯语音输入 MVP",
            bundleIdentifier: "local.tencent-voice-mvp",
            shortVersion: "0.2.0",
            build: "45",
            bundlePath: "/Applications/TencentVoiceMVP.app",
            executablePath: "/Applications/TencentVoiceMVP.app/Contents/MacOS/TencentVoiceMVP",
            bundleModificationDate: nil,
            processIdentifier: 100,
            processLaunchDate: nil,
            currentUser: "test-user",
            operatingSystem: "macOS test",
            machineArchitecture: "arm64",
            signatureVerified: true,
            signatureDetails: "Identifier=local.tencent-voice-mvp"
        )
    }
}
