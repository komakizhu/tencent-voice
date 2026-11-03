import Foundation
import XCTest
@testable import TencentVoiceMVP

final class ASRFinalizationEvidenceTests: XCTestCase {
    func testCollectionIsOptInAndDisablingClearsAndRejectsLateEvents() throws {
        let buffer = ASRFinalizationEvidenceBuffer()
        let first = makeEvent(at: Date(timeIntervalSince1970: 1_800_000_000))

        buffer.append(first, at: first.recordedAt)
        XCTAssertFalse(buffer.snapshot(at: first.recordedAt).evidence.enabled)
        XCTAssertTrue(buffer.snapshot(at: first.recordedAt).evidence.events.isEmpty)

        buffer.setEnabled(true, at: first.recordedAt)
        buffer.append(first, at: first.recordedAt)
        XCTAssertEqual(buffer.snapshot(at: first.recordedAt).evidence.events.count, 1)

        buffer.setEnabled(false, at: first.recordedAt.addingTimeInterval(1))
        buffer.append(makeEvent(at: first.recordedAt.addingTimeInterval(2)), at: first.recordedAt.addingTimeInterval(2))
        let disabled = buffer.snapshot(at: first.recordedAt.addingTimeInterval(2)).evidence
        XCTAssertFalse(disabled.enabled)
        XCTAssertTrue(disabled.events.isEmpty)
        XCTAssertEqual(disabled.omittedEventCount, 0)
    }

    func testEachEventExpiresAfterThirtyMinutes() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let buffer = ASRFinalizationEvidenceBuffer()
        buffer.setEnabled(true, at: start)
        buffer.append(makeEvent(at: start), at: start)
        buffer.append(makeEvent(at: start.addingTimeInterval(10)), at: start.addingTimeInterval(10))

        let evidence = buffer.snapshot(at: start.addingTimeInterval(1_805)).evidence

        XCTAssertEqual(evidence.maximumRetentionSeconds, 1_800)
        XCTAssertEqual(evidence.events.count, 1)
        XCTAssertEqual(evidence.events[0].recordedAt, start.addingTimeInterval(10))
        XCTAssertEqual(evidence.coverageStartedAt, start.addingTimeInterval(10))
    }

    func testExpiryTimerClearsMemoryWithoutReadingOrAppending() async throws {
        let buffer = ASRFinalizationEvidenceBuffer(retentionSeconds: 1)
        buffer.setEnabled(true)
        buffer.append(makeEvent(at: Date()))
        XCTAssertEqual(buffer.retainedEventCount, 1)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(buffer.retainedEventCount, 0)
    }

    func testCapacityDropsOldestEventsAndCountsOmissions() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let buffer = ASRFinalizationEvidenceBuffer(maximumEventCount: 2)
        buffer.setEnabled(true, at: start)
        for offset in 0..<3 {
            buffer.append(
                makeEvent(
                    at: start.addingTimeInterval(Double(offset)),
                    elapsedMilliseconds: UInt64(offset)
                ),
                at: start
            )
        }

        let evidence = buffer.snapshot(at: start.addingTimeInterval(2)).evidence

        XCTAssertEqual(evidence.events.count, 2)
        XCTAssertEqual(evidence.events.map(\.elapsedMilliseconds), [1, 2])
        XCTAssertEqual(evidence.omittedEventCount, 1)
    }

    func testByteLimitDropsEventsThatDoNotFit() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let buffer = ASRFinalizationEvidenceBuffer(maximumByteCount: 1)
        buffer.setEnabled(true, at: start)
        buffer.append(makeEvent(at: start), at: start)

        let evidence = buffer.snapshot(at: start).evidence

        XCTAssertTrue(evidence.events.isEmpty)
        XCTAssertEqual(evidence.omittedEventCount, 1)
        XCTAssertEqual(evidence.maximumByteCount, 1)
    }

    func testExportDropsCapturedEvidenceIfCollectionWasDisabledBeforeWrite() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let buffer = ASRFinalizationEvidenceBuffer()
        buffer.setEnabled(true, at: start)
        buffer.append(makeEvent(at: start), at: start)
        let snapshot = buffer.exportToken(at: start)
        buffer.setEnabled(false, at: start.addingTimeInterval(1))

        let exported = buffer.currentEvidence(for: snapshot, at: start.addingTimeInterval(1))

        XCTAssertNil(exported)
    }

    func testExportTokenDoesNotHoldEvidencePastCollectionDisable() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let buffer = ASRFinalizationEvidenceBuffer()
        buffer.setEnabled(true, at: start)
        buffer.append(makeEvent(at: start), at: start)
        let token = buffer.exportToken(at: start)
        buffer.setEnabled(false, at: start.addingTimeInterval(1))

        let exported = buffer.currentEvidence(for: token, at: start.addingTimeInterval(1))

        XCTAssertNil(exported)
    }

    func testOldRecorderCannotWriteAfterDisableAndReenable() {
        let buffer = ASRFinalizationEvidenceBuffer()
        buffer.setEnabled(true)
        let recorder = buffer.makeRecorder()
        recorder(makeEvent(at: Date()))
        buffer.setEnabled(false)
        buffer.setEnabled(true)
        recorder(makeEvent(at: Date()))
        XCTAssertTrue(buffer.snapshot().evidence.events.isEmpty)
        buffer.makeRecorder()(makeEvent(at: Date()))
        XCTAssertEqual(buffer.snapshot().evidence.events.count, 1)
    }

    func testPreparedExportMustBeRebuiltWithoutEvidenceAfterDisable() throws {
        let now = Date()
        let buffer = ASRFinalizationEvidenceBuffer()
        buffer.setEnabled(true, at: now)
        buffer.append(makeEvent(at: now), at: now)
        let token = buffer.exportToken(at: now)
        let prepared = buffer.currentEvidence(for: token, at: now)
        buffer.setEnabled(false, at: now)
        var published = false
        XCTAssertFalse(buffer.publishIfCurrent(prepared, for: token, at: now) { published = true })
        XCTAssertFalse(published)
        XCTAssertTrue(buffer.publishIfCurrent(nil, for: token, at: now) { published = true })
        XCTAssertTrue(published)
    }

    func testPreparedExportCannotPublishExpiredEvidence() {
        let now = Date()
        let buffer = ASRFinalizationEvidenceBuffer()
        buffer.setEnabled(true, at: now)
        buffer.append(makeEvent(at: now), at: now)
        let token = buffer.exportToken(at: now)
        let prepared = buffer.currentEvidence(for: token, at: now)
        XCTAssertFalse(buffer.publishIfCurrent(prepared, for: token, at: now.addingTimeInterval(1_800)) {
            XCTFail("Expired evidence must never be published")
        })
    }

    func testSummaryDoesNotMixSuccessfulOldSessionWithFailedNewSession() {
        let now = Date()
        let buffer = ASRFinalizationEvidenceBuffer()
        buffer.setEnabled(true, at: now)
        let oldID = UUID()
        let newID = UUID()
        buffer.append(makeEvent(at: now, sessionID: oldID, kind: .serviceFinalSignalReceived), at: now)
        buffer.append(makeEvent(at: now, sessionID: oldID, kind: .textDeliveryResult, textDeliveryStatus: .confirmed), at: now)
        buffer.append(makeEvent(at: now, sessionID: newID, kind: .sessionStarted), at: now)
        buffer.append(makeEvent(at: now, sessionID: newID, kind: .receiveFailed), at: now)
        let evidence = buffer.snapshot(at: now).evidence
        XCTAssertEqual(evidence.summarySessionID, newID)
        XCTAssertEqual(evidence.serviceConfirmedComplete, false)
        XCTAssertNil(evidence.textDeliveryStatus)
    }

    func testEvidenceContainsOnlyWhitelistedMetadataAndReportsThreeCompletionStages() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = UUID()
        let buffer = ASRFinalizationEvidenceBuffer()
        buffer.setEnabled(true, at: start)
        buffer.append(makeEvent(
            at: start,
            sessionID: sessionID,
            kind: .audioUploadCompleted,
            stage: .waitingForService,
            audioProgress: .init(
                capturedChunkCount: 5,
                uploadedChunkCount: 5,
                capturedDurationMilliseconds: 500,
                uploadedDurationMilliseconds: 500,
                recognitionUpdateCount: 3
            )
        ), at: start)
        buffer.append(makeEvent(
            at: start.addingTimeInterval(1),
            sessionID: sessionID,
            kind: .serviceFinalSignalReceived,
            stage: .writingText
        ), at: start)
        buffer.append(makeEvent(
            at: start.addingTimeInterval(2),
            sessionID: sessionID,
            kind: .textDeliveryResult,
            stage: .completed,
            textDeliveryStatus: .confirmed
        ), at: start)

        let evidence = buffer.snapshot(at: start.addingTimeInterval(2)).evidence
        let encoded = try DiagnosticJSON.encoder().encode(evidence)
        let rendered = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(evidence.audioUploadCompleted, true)
        XCTAssertEqual(evidence.serviceConfirmedComplete, true)
        XCTAssertEqual(evidence.textWriteConfirmed, true)
        XCTAssertFalse(rendered.contains("识别正文秘密"))
        XCTAssertFalse(rendered.contains("原始报文秘密"))
        XCTAssertFalse(rendered.contains("凭证秘密"))
        XCTAssertFalse(rendered.contains("音频秘密"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let eventObjects = try XCTUnwrap(object["events"] as? [[String: Any]])
        let allowed: Set<String> = [
            "recordedAt", "elapsedMilliseconds", "sessionID", "operationGeneration", "kind", "stage",
            "audioProgress", "recognitionSequence", "recognitionPhase", "recognizedCharacterCount",
            "finalSignalReceived", "failureCategory", "errorCode", "textDeliveryStatus"
        ]
        for event in eventObjects {
            XCTAssertTrue(Set(event.keys).isSubset(of: allowed))
            if let progress = event["audioProgress"] as? [String: Any] {
                XCTAssertEqual(Set(progress.keys), [
                    "capturedChunkCount", "uploadedChunkCount", "capturedDurationMilliseconds",
                    "uploadedDurationMilliseconds", "recognitionUpdateCount"
                ])
                XCTAssertTrue(progress.values.allSatisfy { $0 is NSNumber })
            }
        }
    }

    private func makeEvent(
        at date: Date,
        sessionID: UUID = UUID(),
        kind: ASRFinalizationEvidenceEvent.Kind = .recognitionUpdate,
        stage: ASRFinalizationEvidenceEvent.Stage = .recording,
        audioProgress: ASRFinalizationAudioProgress? = nil,
        elapsedMilliseconds: UInt64 = 0,
        textDeliveryStatus: ASRFinalizationEvidenceEvent.TextDeliveryStatus? = nil
    ) -> ASRFinalizationEvidenceEvent {
        ASRFinalizationEvidenceEvent(
            recordedAt: date,
            elapsedMilliseconds: elapsedMilliseconds,
            sessionID: sessionID,
            operationGeneration: 1,
            kind: kind,
            stage: stage,
            audioProgress: audioProgress,
            recognitionSequence: nil,
            recognitionPhase: nil,
            recognizedCharacterCount: nil,
            finalSignalReceived: nil,
            failureCategory: nil,
            errorCode: nil,
            textDeliveryStatus: textDeliveryStatus
        )
    }
}
