import XCTest
@testable import TencentVoiceMVP

@MainActor
final class DiagnosticReportTests: XCTestCase {
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
        XCTAssertTrue(text.contains("不包含密钥、录音或识别正文"))
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
        XCTAssertEqual(disabledReport.events.count, 1)
        XCTAssertEqual(disabledReport.events.first?.eventID, entry.eventID)

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

    func testBuilderExportsAllPersistedEventsWithoutARecentEventCap() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let logger = SessionLogger(
            enabled: { true },
            applicationSupportDirectoryURL: testDirectory
        )
        for index in 0..<161 {
            try logger.append(SessionLogEntry(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
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

        XCTAssertEqual(report.events.count, 161)
        XCTAssertEqual(report.events.first?.sequence, 0)
        XCTAssertEqual(report.events.last?.sequence, 160)
    }

    func testReportHidesUnrecognizedFailureMessages() {
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
        XCTAssertTrue(text.contains("详细错误已隐藏"))
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
        XCTAssertTrue(report.renderedText().contains("无法写入当前输入框"))
        XCTAssertFalse(report.renderedText().contains("不应直接信任"))
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

    func testReportExplainsInputFailureWhenSafeCopyIsDisabled() {
        let report = DiagnosticReport(
            app: appInfo(),
            permissions: PrivacyPermissionReport(statuses: []),
            credentials: DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）"),
            settings: DiagnosticSettingsInfo(
                shortcut: "⌘0",
                engineModelType: "16k_zh",
                persistentSessionLogEnabled: false,
                safeCopyEnabled: false
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
        XCTAssertTrue(report.renderedText().contains("Safe Copy 已关闭"))
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

        XCTAssertFalse(settings.safeCopyEnabled)
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
        XCTAssertEqual(action.metadata["errorMessage"], "已隐藏")
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
