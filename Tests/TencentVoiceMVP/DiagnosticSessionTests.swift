import Foundation
import XCTest
@testable import TencentVoiceMVP

@MainActor
final class DiagnosticSessionTests: XCTestCase {
    func testRecorderExportsStructuredTraceAndRedactsSensitiveFields() throws {
        let exportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: exportDirectory) }

        let recorder = DiagnosticSessionRecorder(exportDirectoryURL: exportDirectory)
        let sessionID = UUID()
        let app = appInfo()

        try recorder.start(appInfo: app)
        recorder.recordAction(
            name: "recognized_result",
            sessionID: sessionID,
            fields: [
                "resultLength": "6",
                "recognizedText": "这段文字不能导出",
                "secretKey": "SecretKey=should-not-export"
            ]
        )
        let eventID = UUID()
        recorder.recordSessionEntry(SessionLogEntry(
            sessionID: sessionID,
            eventID: eventID,
            event: "safe_copy",
            sliceType: 1,
            wireFinal: true,
            failureCode: "text_target_changed",
            failureMessage: "SecretKey=should-not-export"
        ))

        let url = try recorder.stopAndExport(appInfo: app)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(url.path.hasPrefix(exportDirectory.path))
        XCTAssertEqual(url.pathExtension, "json")

        let data = try Data(contentsOf: url)
        let document = try DiagnosticJSON.decoder().decode(DiagnosticTraceDocument.self, from: data)
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.app.bundleIdentifier, app.bundleIdentifier)
        XCTAssertTrue(document.events.contains { $0.name == "diagnostic_started" })
        XCTAssertTrue(document.events.contains { $0.name == "recognized_result" })
        XCTAssertTrue(document.events.contains { $0.name == "safe_copy" })
        let sessionEvent = try XCTUnwrap(document.events.first { $0.name == "safe_copy" })
        XCTAssertEqual(sessionEvent.fields["eventID"], eventID.uuidString)
        XCTAssertEqual(sessionEvent.fields["sliceType"], "1")
        XCTAssertEqual(sessionEvent.fields["wireFinal"], "true")

        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("这段文字不能导出"))
        XCTAssertFalse(json.contains("SecretKey=should-not-export"))
        XCTAssertTrue(json.contains("text_target_changed"))
    }

    func testRecorderKeepsTraceWhenExportFailsSoExportCanBeRetried() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)

        let recorder = DiagnosticSessionRecorder(
            exportDirectoryURL: blocker.appendingPathComponent("exports", isDirectory: true)
        )
        try recorder.start(appInfo: appInfo())

        XCTAssertThrowsError(try recorder.stopAndExport(appInfo: appInfo())) { error in
            XCTAssertEqual(error as? DiagnosticRecordingError, .exportFailed)
        }
        XCTAssertTrue(recorder.isRecording)
    }

    func testInterruptedJournalIsRecoveredAfterUnexpectedTermination() throws {
        let root = temporaryDirectory()
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let journalURL = root.appendingPathComponent("active.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = DiagnosticSessionRecorder(
            exportDirectoryURL: exportDirectory,
            journalURL: journalURL
        )
        try recorder.start(appInfo: appInfo())
        recorder.recordAction(name: "recording_started")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let nextLaunchRecorder = DiagnosticSessionRecorder(
            exportDirectoryURL: exportDirectory,
            journalURL: journalURL
        )
        let url = try XCTUnwrap(
            nextLaunchRecorder.recoverInterruptedRecording(appInfo: appInfo())
        )
        let document = try DiagnosticJSON.decoder().decode(
            DiagnosticTraceDocument.self,
            from: Data(contentsOf: url)
        )

        XCTAssertTrue(document.events.contains { $0.name == "recording_started" })
        XCTAssertTrue(document.events.contains {
            $0.name == "diagnostic_recovered_after_unexpected_termination"
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRecorderBoundsLongTraceAndReportsDroppedEvents() throws {
        let exportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: exportDirectory) }
        let recorder = DiagnosticSessionRecorder(exportDirectoryURL: exportDirectory)

        try recorder.start(appInfo: appInfo())
        for index in 0..<5_001 {
            recorder.recordAction(name: "heartbeat", fields: ["index": String(index)])
        }
        let url = try recorder.stopAndExport(appInfo: appInfo())
        let document = try DiagnosticJSON.decoder().decode(
            DiagnosticTraceDocument.self,
            from: Data(contentsOf: url)
        )
        let stoppedEvent = try XCTUnwrap(document.events.last)

        XCTAssertEqual(document.events.count, 5_001)
        XCTAssertEqual(stoppedEvent.name, "diagnostic_stopped")
        XCTAssertEqual(stoppedEvent.fields["droppedEventCount"], "2")
    }

    func testRecorderRejectsInvalidStartAndStopTransitions() throws {
        let exportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: exportDirectory) }

        let recorder = DiagnosticSessionRecorder(exportDirectoryURL: exportDirectory)
        let app = appInfo()

        XCTAssertThrowsError(try recorder.stopAndExport(appInfo: app))
        try recorder.start(appInfo: app)
        XCTAssertThrowsError(try recorder.start(appInfo: app))
        _ = try recorder.stopAndExport(appInfo: app)
        XCTAssertThrowsError(try recorder.stopAndExport(appInfo: app))
    }

    func testSessionLoggerBridgesSessionEventsAndActionsWhilePersistentLoggingIsDisabled() throws {
        let root = temporaryDirectory()
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = SessionLogger(
            enabled: { false },
            applicationSupportDirectoryURL: root,
            diagnosticExportDirectoryURL: exportDirectory
        )
        let sessionID = UUID()
        try logger.startDiagnosticRecording(appInfo: appInfo())
        logger.recordDiagnosticAction(
            "settings_saved",
            fields: ["safeCopyEnabled": "true", "recognizedText": "不可导出"]
        )
        try logger.append(SessionLogEntry(
            sessionID: sessionID,
            event: "partial",
            renderedLength: 6,
            writeCount: 1,
            failureCode: "text_target_changed",
            failureMessage: "不应进入诊断文件"
        ))

        let url = try logger.stopDiagnosticRecordingAndExport(appInfo: appInfo())
        let document = try DiagnosticJSON.decoder().decode(
            DiagnosticTraceDocument.self,
            from: Data(contentsOf: url)
        )

        XCTAssertFalse(logger.isDiagnosticRecording)
        XCTAssertTrue(logger.recentPersistedEntries().isEmpty)
        XCTAssertTrue(document.events.contains { $0.name == "settings_saved" })
        XCTAssertTrue(document.events.contains { $0.name == "partial" && $0.sessionID == sessionID })
        let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(json.contains("不可导出"))
        XCTAssertFalse(json.contains("不应进入诊断文件"))
        XCTAssertTrue(json.contains("text_target_changed"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TencentVoiceMVP-DiagnosticSessionTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func appInfo() -> DiagnosticAppInfo {
        DiagnosticAppInfo(
            displayName: "腾讯语音输入 MVP",
            bundleIdentifier: "local.tencent-voice-mvp",
            shortVersion: "0.2.1",
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
