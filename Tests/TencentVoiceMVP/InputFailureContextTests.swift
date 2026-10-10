import AppKit
import XCTest
@testable import TencentVoiceMVP

final class InputFailureContextTests: XCTestCase {
    func testBufferRetainsOnlyMinuteBeforeReportAndClearsWhenDisabled() {
        let start = Date(timeIntervalSince1970: 1000)
        var buffer = InputContextBuffer()
        buffer.start(at: start)
        buffer.append(.init(timestamp: start, event: "old", fields: [:]), now: start)
        buffer.append(.init(timestamp: start.addingTimeInterval(61), event: "fork", fields: [:]), now: start.addingTimeInterval(61))
        let report = buffer.snapshot(at: start.addingTimeInterval(62))
        XCTAssertEqual(report.events.map(\.event), ["fork"])
        XCTAssertEqual(report.requestedStart, start.addingTimeInterval(2))
        buffer.stop()
        buffer.append(.init(timestamp: start.addingTimeInterval(63), event: "ignored", fields: [:]), now: start.addingTimeInterval(63))
        XCTAssertFalse(buffer.snapshot(at: start.addingTimeInterval(63)).enabled)
        XCTAssertTrue(buffer.events.isEmpty)
    }

    func testOverflowAndShortCoverageAreVisibleAndExpire() {
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
        XCTAssertEqual(buffer.snapshot(at: start.addingTimeInterval(63)).droppedEventCount, 0)
        XCTAssertTrue(buffer.events.isEmpty)
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
        XCTAssertFalse(String(decoding: try DiagnosticJSON.encoder().encode(events), as: UTF8.self).contains("private draft"))
        logger.setFailureContextEnabled(false)
        XCTAssertTrue(logger.failureEvents(at: now).isEmpty)
    }

    @MainActor
    func testReportMenuInvokesCallbacksAndShowsRecorderState() throws {
        let menuController = StatusMenuController()
        let menu = menuController.makeMenu()
        var toggles = 0
        var reports = 0
        var opens = 0
        menuController.configure(onSettings: {}, onToggleRecording: {}, onToggleAutoStart: {},
            onSelectRimeTheme: { _ in }, onManageRimeDictionary: {}, onExportRimeConfiguration: {},
            onImportRimeConfiguration: {}, onToggleFailureContext: { toggles += 1 },
            onReportInputFailure: { reports += 1 }, onOpenFailureReports: { opens += 1 })
        for title in ["记录 Codex 故障前一分钟操作", "报告输入失效", "打开失效报告目录"] {
            let index = try XCTUnwrap(menu.items.firstIndex { $0.title == title })
            menu.performActionForItem(at: index)
        }
        XCTAssertEqual(toggles, 1)
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(opens, 1)
        menuController.update(failureContextEnabled: true)
        XCTAssertEqual(menu.items.first { $0.title == "记录 Codex 故障前一分钟操作" }?.state, .on)
    }
}
