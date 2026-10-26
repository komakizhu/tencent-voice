import Foundation
import XCTest
@testable import TencentVoiceMVP

final class DiagnosticWindowFrameTests: XCTestCase {
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
            status: "session_ended",
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
            archiveStatus: "included"
        )
        let snapshot = DiagnosticWindowFrameSnapshot(evidence: evidence, assets: [asset])

        try DiagnosticWindowFrameArchiveWriter.write(
            reportData: Data("{}".utf8),
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
    }
}
