import Foundation
import XCTest
@testable import TencentVoiceMVP

final class DiagnosticWindowFrameTests: XCTestCase {
    func testWindowChangeReasonsDistinguishCountIdentifierFocusAndFingerprint() throws {
        let expected: UInt32 = 20
        func reason(
            count: Int = 1,
            windowID: UInt32? = expected,
            focus: DiagnosticWindowFrameVerification.FocusState = .available,
            matches: Bool = true
        ) -> String? {
            DiagnosticWindowFrameVerification.failureReason(
                candidateWindowCount: count,
                candidateWindowID: windowID,
                expectedWindowID: expected,
                focusState: focus,
                fingerprintMatches: matches
            )
        }
        XCTAssertEqual(reason(count: 0), "candidate_window_count_mismatch")
        XCTAssertEqual(reason(count: 2), "candidate_window_count_mismatch")
        XCTAssertEqual(reason(windowID: 21), "window_identifier_changed")
        XCTAssertEqual(reason(focus: .unavailable), "focused_window_unavailable")
        XCTAssertEqual(reason(focus: .windowMismatch), "window_information_mismatch")
        XCTAssertEqual(reason(matches: false), "window_information_mismatch")
        XCTAssertNil(reason())

        let encoded = try JSONEncoder().encode(DiagnosticWindowFrameEvidence(
            enabled: true,
            status: "target_window_changed",
            permissionGranted: true,
            sessionID: UUID(),
            targetPID: 42,
            targetBundleIdentifier: "com.example.editor",
            targetWindowID: expected,
            startedAt: Date(timeIntervalSince1970: 1),
            stoppedAt: Date(timeIntervalSince1970: 2),
            maximumFramesPerSecond: 5,
            ringDurationSeconds: 60,
            memoryLimitBytes: 80 * 1_024 * 1_024,
            ringMemoryLimitBytes: 80 * 1_024 * 1_024,
            retainedFrameCount: 0,
            droppedFrameCount: 0,
            retainedBytes: 0,
            frames: [],
            archiveStatus: "not_included",
            stopReason: "window_identifier_changed"
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "target_window_changed")
        XCTAssertEqual(object["stopReason"] as? String, "window_identifier_changed")
    }

    func testCapturePolicyRequiresOptInActiveSessionPermissionAndNoSecureInput() {
        XCTAssertTrue(DiagnosticWindowFrameCapturePolicy.mayCapture(
            enabled: true,
            sessionIsActive: true,
            permissionGranted: true,
            secureInputActive: false
        ))
        XCTAssertFalse(DiagnosticWindowFrameCapturePolicy.mayCapture(
            enabled: false,
            sessionIsActive: true,
            permissionGranted: true,
            secureInputActive: false
        ))
        XCTAssertFalse(DiagnosticWindowFrameCapturePolicy.mayCapture(
            enabled: true,
            sessionIsActive: false,
            permissionGranted: true,
            secureInputActive: false
        ))
        XCTAssertFalse(DiagnosticWindowFrameCapturePolicy.mayCapture(
            enabled: true,
            sessionIsActive: true,
            permissionGranted: false,
            secureInputActive: false
        ))
        XCTAssertFalse(DiagnosticWindowFrameCapturePolicy.mayCapture(
            enabled: true,
            sessionIsActive: true,
            permissionGranted: true,
            secureInputActive: true
        ))
    }

    func testRingEnforcesDurationFrameCountAndMemoryBounds() {
        var ring = DiagnosticWindowFrameRing()
        let start = Date(timeIntervalSince1970: 1_000)
        ring.append(
            jpegData: Data(repeating: 1, count: 6),
            timestamp: start,
            monotonicNanoseconds: 1,
            now: start,
            maximumFrameCount: 2,
            maximumBytes: 10
        )
        ring.append(
            jpegData: Data(repeating: 2, count: 6),
            timestamp: start.addingTimeInterval(1),
            monotonicNanoseconds: 2,
            now: start.addingTimeInterval(1),
            maximumFrameCount: 2,
            maximumBytes: 10
        )
        XCTAssertEqual(ring.frames.map(\.jpegData.count), [6])
        XCTAssertEqual(ring.droppedFrameCount, 1)
        XCTAssertLessThanOrEqual(ring.retainedBytes, 10)

        ring.append(
            jpegData: Data(repeating: 3, count: 4),
            timestamp: start.addingTimeInterval(62),
            monotonicNanoseconds: 3,
            now: start.addingTimeInterval(62),
            maximumFrameCount: 2,
            maximumBytes: 10
        )
        XCTAssertEqual(ring.frames.count, 1)
        XCTAssertEqual(ring.frames[0].jpegData, Data(repeating: 3, count: 4))
        XCTAssertEqual(ring.droppedFrameCount, 1)
    }

    func testArchiveContainsReportFrameIndexAndFrames() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticFrameTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let destination = temporaryRoot.appendingPathComponent("report.zip")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let asset = DiagnosticWindowFrameAsset(
            relativePath: "frames/000001.jpg",
            timestamp: timestamp,
            monotonicNanoseconds: 123,
            jpegData: Data([0xff, 0xd8, 0xff, 0xd9])
        )
        let reference = DiagnosticWindowFrameReference(
            relativePath: asset.relativePath,
            timestamp: timestamp,
            monotonicNanoseconds: 123,
            byteCount: asset.jpegData.count
        )
        let evidence = DiagnosticWindowFrameEvidence(
            enabled: true,
            status: "target_window_changed",
            permissionGranted: true,
            sessionID: UUID(),
            targetPID: 42,
            targetBundleIdentifier: "com.example.editor",
            targetWindowID: 7,
            startedAt: timestamp,
            stoppedAt: timestamp,
            maximumFramesPerSecond: 5,
            ringDurationSeconds: 60,
            memoryLimitBytes: 80 * 1_024 * 1_024,
            ringMemoryLimitBytes: 80 * 1_024 * 1_024,
            retainedFrameCount: 1,
            droppedFrameCount: 0,
            retainedBytes: asset.jpegData.count,
            frames: [reference],
            archiveStatus: "included",
            stopReason: "window_information_mismatch"
        )
        let snapshot = DiagnosticWindowFrameSnapshot(evidence: evidence, assets: [asset])

        try DiagnosticWindowFrameArchiveWriter.write(
            reportData: try JSONEncoder().encode(snapshot.evidence),
            snapshot: snapshot,
            destination: destination
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", destination.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let listing = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(listing.contains("/report.json"))
        XCTAssertTrue(listing.contains("/frames/index.json"))
        XCTAssertTrue(listing.contains("/frames/000001.jpg"))

        let reportMember = try XCTUnwrap(listing
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { $0.hasSuffix("/report.json") })
        let reportProcess = Process()
        reportProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        reportProcess.arguments = ["-p", destination.path, reportMember]
        let reportOutput = Pipe()
        reportProcess.standardOutput = reportOutput
        try reportProcess.run()
        reportProcess.waitUntilExit()
        XCTAssertEqual(reportProcess.terminationStatus, 0)
        let archivedReport = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reportOutput.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
        )
        XCTAssertEqual(archivedReport["status"] as? String, "target_window_changed")
        XCTAssertEqual(archivedReport["stopReason"] as? String, "window_information_mismatch")
    }
}
