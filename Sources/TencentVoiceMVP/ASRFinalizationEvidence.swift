import Foundation

struct ASRFinalizationAudioProgress: Codable, Equatable, Sendable {
    let capturedChunkCount: Int
    let uploadedChunkCount: Int
    let capturedDurationMilliseconds: Int
    let uploadedDurationMilliseconds: Int
    let recognitionUpdateCount: Int
}

struct ASRFinalizationEvidenceEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case sessionStarted
        case audioCaptured
        case stopRequested
        case audioUploaded
        case audioUploadCompleted
        case audioUploadFailed
        case audioUploadIncomplete
        case finishMarkerRequested
        case finishMarkerSent
        case finishMarkerFailed
        case recognitionUpdate
        case serviceFinalSignalReceived
        case streamClosedWithoutFinal
        case receiveFailed
        case noProgressWarning
        case userEndedWait
        case textDeliveryResult
        case sessionCancelled
    }

    enum Stage: String, Codable, Sendable {
        case recording
        case stoppingCapture
        case uploadingTail
        case waitingForService
        case writingText
        case completed
        case failed
        case userEnded
        case cancelled
    }

    enum FailureCategory: String, Codable, Sendable {
        case audioUpload
        case finishMarkerSend
        case asrReceive
        case streamClosedWithoutFinal
        case textDelivery
    }

    enum TextDeliveryStatus: String, Codable, Sendable {
        case confirmed
        case safeCopy
        case waitingForTarget
        case failed
        case notAttempted
        case submittedUnconfirmed
    }

    let recordedAt: Date
    let elapsedMilliseconds: UInt64
    let sessionID: UUID
    let operationGeneration: UInt64
    let kind: Kind
    let stage: Stage
    let audioProgress: ASRFinalizationAudioProgress?
    let recognitionSequence: Int?
    let recognitionPhase: ASRSegmentPhase?
    let recognizedCharacterCount: Int?
    let finalSignalReceived: Bool?
    let failureCategory: FailureCategory?
    let errorCode: Int?
    let textDeliveryStatus: TextDeliveryStatus?

    var encodedByteCount: Int {
        (try? JSONEncoder().encode(self).count) ?? Int.max
    }
}

struct ASRFinalizationEvidence: Codable, Equatable, Sendable {
    static let scopeDescription = "本部分独立于主报告的60秒现场窗口，最多覆盖最近30分钟；容量不足时删除最旧记录并报告遗漏数量。汇总状态仅对应summarySessionID，其他会话请按事件中的sessionID分别查看。开启采集后从新会话记录，关闭后旧会话不能补写。仅记录收尾状态、会话代次、相对时间、采音与上传计数、识别序号/阶段/字符数、整段完成信号、错误类别/数字代码和文字交付状态；不包含原始音频、识别内容、凭证、服务原始报文或错误原文。服务确认完成不能证明句尾已被麦克风采集。"

    let enabled: Bool
    let scopeNote: String
    let capturedAt: Date
    let coverageStartedAt: Date?
    let coverageEndedAt: Date?
    let maximumRetentionSeconds: Int
    let maximumEventCount: Int
    let maximumByteCount: Int
    let omittedEventCount: Int
    /// The three summary values below belong to this session only.
    let summarySessionID: UUID?
    let audioUploadCompleted: Bool?
    let serviceConfirmedComplete: Bool?
    let textDeliveryStatus: ASRFinalizationEvidenceEvent.TextDeliveryStatus?
    let events: [ASRFinalizationEvidenceEvent]

    var textWriteConfirmed: Bool? {
        guard let textDeliveryStatus else { return nil }
        return textDeliveryStatus == .confirmed
    }

    static func empty(
        enabled: Bool,
        capturedAt: Date,
        maximumRetentionSeconds: Int = ASRFinalizationEvidenceBuffer.defaultRetentionSeconds,
        maximumEventCount: Int = ASRFinalizationEvidenceBuffer.defaultMaximumEventCount,
        maximumByteCount: Int = ASRFinalizationEvidenceBuffer.defaultMaximumByteCount
    ) -> Self {
        Self(
            enabled: enabled,
            scopeNote: scopeDescription,
            capturedAt: capturedAt,
            coverageStartedAt: nil,
            coverageEndedAt: nil,
            maximumRetentionSeconds: maximumRetentionSeconds,
            maximumEventCount: maximumEventCount,
            maximumByteCount: maximumByteCount,
            omittedEventCount: 0,
            summarySessionID: nil,
            audioUploadCompleted: nil,
            serviceConfirmedComplete: nil,
            textDeliveryStatus: nil,
            events: []
        )
    }
}

struct ASRFinalizationEvidenceSnapshot: Sendable {
    let evidence: ASRFinalizationEvidence
    fileprivate let generation: UInt64
}

struct ASRFinalizationEvidenceExportToken: Sendable {
    let enabledAtRequest: Bool
    let capturedAt: Date
    fileprivate let generation: UInt64
}

/// Bounded metadata only. The event type has no fields for audio, text, credentials, or raw service messages.
final class ASRFinalizationEvidenceBuffer: @unchecked Sendable {
    static let defaultMaximumEventCount = 2_048
    static let defaultMaximumByteCount = 512 * 1_024
    static let defaultRetentionSeconds = 30 * 60

    private struct StoredEvent {
        let event: ASRFinalizationEvidenceEvent
        let byteCount: Int
    }

    private let lock = NSLock()
    private let maximumEventCount: Int
    private let maximumByteCount: Int
    private let retentionInterval: TimeInterval
    private var isEnabled = false
    private var generation: UInt64 = 0
    private var events: [StoredEvent] = []
    private var storedByteCount = 0
    private var omittedEventCount = 0
    private var expiryTimer: DispatchSourceTimer?

    deinit { expiryTimer?.cancel() }

    init(
        maximumEventCount: Int = defaultMaximumEventCount,
        maximumByteCount: Int = defaultMaximumByteCount,
        retentionSeconds: Int = defaultRetentionSeconds
    ) {
        self.maximumEventCount = max(1, maximumEventCount)
        self.maximumByteCount = max(1, maximumByteCount)
        self.retentionInterval = TimeInterval(max(1, retentionSeconds))
    }

    var isCollectionEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEnabled
    }

    var retainedEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func setEnabled(_ enabled: Bool, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled != isEnabled else {
            purgeExpired(at: now)
            return
        }
        isEnabled = enabled
        generation &+= 1
        clearEvents()
    }

    /// A recorder belongs to one opt-in epoch; turning collection off invalidates it permanently.
    func makeRecorder() -> @Sendable (ASRFinalizationEvidenceEvent) -> Void {
        lock.lock()
        let epoch = generation
        let enabled = isEnabled
        lock.unlock()
        return { [weak self] event in
            guard enabled else { return }
            self?.append(event, generation: epoch)
        }
    }

    func append(
        _ event: ASRFinalizationEvidenceEvent,
        at now: Date = Date(),
        generation expectedGeneration: UInt64? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled, expectedGeneration == nil || expectedGeneration == generation else { return }
        purgeExpired(at: now)
        guard event.recordedAt > now.addingTimeInterval(-retentionInterval) else { return }
        let byteCount = event.encodedByteCount + 128
        guard byteCount <= maximumByteCount else {
            omittedEventCount += 1
            return
        }
        events.append(StoredEvent(event: event, byteCount: byteCount))
        storedByteCount += byteCount
        while events.count > maximumEventCount || storedByteCount > maximumByteCount {
            let removed = events.removeFirst()
            storedByteCount -= removed.byteCount
            omittedEventCount += 1
        }
        scheduleExpiry(at: now)
    }

    func snapshot(at now: Date = Date()) -> ASRFinalizationEvidenceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: now)
        return makeSnapshot(capturedAt: now)
    }

    func exportToken(at now: Date = Date()) -> ASRFinalizationEvidenceExportToken {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: now)
        return ASRFinalizationEvidenceExportToken(
            enabledAtRequest: isEnabled,
            capturedAt: now,
            generation: generation
        )
    }

    private func makeSnapshot(capturedAt: Date) -> ASRFinalizationEvidenceSnapshot {
        let orderedEvents = events.enumerated().sorted {
            let lhs = $0.element.event.recordedAt
            let rhs = $1.element.event.recordedAt
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element.event)
            .filter { $0.recordedAt <= capturedAt }
        let summarySessionID = orderedEvents.last(where: { $0.kind == .sessionStarted })?.sessionID
            ?? orderedEvents.last?.sessionID
        let summaryEvents = orderedEvents.filter { $0.sessionID == summarySessionID }
        let terminalUpload = summaryEvents.last {
            $0.kind == .audioUploadCompleted
                || $0.kind == .audioUploadFailed
                || $0.kind == .audioUploadIncomplete
        }
        let serviceFailureOccurred = summaryEvents.contains {
            $0.kind == .audioUploadFailed
                || $0.kind == .audioUploadIncomplete
                || $0.kind == .finishMarkerFailed
                || $0.kind == .streamClosedWithoutFinal
                || $0.kind == .receiveFailed
                || $0.kind == .userEndedWait
                || $0.kind == .sessionCancelled
        }
        let textDelivery = summaryEvents.last(where: { $0.kind == .textDeliveryResult })?.textDeliveryStatus
        let evidence = ASRFinalizationEvidence(
            enabled: isEnabled,
            scopeNote: ASRFinalizationEvidence.scopeDescription,
            capturedAt: capturedAt,
            coverageStartedAt: orderedEvents.first?.recordedAt,
            coverageEndedAt: orderedEvents.last?.recordedAt,
            maximumRetentionSeconds: Int(retentionInterval),
            maximumEventCount: maximumEventCount,
            maximumByteCount: maximumByteCount,
            omittedEventCount: omittedEventCount,
            summarySessionID: summarySessionID,
            audioUploadCompleted: terminalUpload.map { $0.kind == .audioUploadCompleted },
            serviceConfirmedComplete: summaryEvents.contains(where: { $0.kind == .serviceFinalSignalReceived })
                ? true
                : (serviceFailureOccurred ? false : nil),
            textDeliveryStatus: textDelivery,
            events: orderedEvents
        )
        return ASRFinalizationEvidenceSnapshot(evidence: evidence, generation: generation)
    }

    func currentEvidence(
        for token: ASRFinalizationEvidenceExportToken,
        at now: Date = Date()
    ) -> ASRFinalizationEvidence? {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: now)
        if token.enabledAtRequest && (!isEnabled || token.generation != generation) {
            return nil
        } else if token.enabledAtRequest {
            return makeSnapshot(capturedAt: token.capturedAt).evidence
        } else {
            return .empty(enabled: false, capturedAt: token.capturedAt)
        }
    }

    /// Only the final same-volume rename runs under the lock, never encoding or archiving.
    /// If opt-in changed or any exported event expired, the caller rebuilds without evidence.
    func publishIfCurrent(
        _ evidence: ASRFinalizationEvidence?,
        for token: ASRFinalizationEvidenceExportToken,
        at now: Date = Date(),
        publish: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(at: now)
        if let evidence, evidence.enabled {
            guard isEnabled, token.generation == generation,
                  evidence.events.allSatisfy({ $0.recordedAt > now.addingTimeInterval(-retentionInterval) })
            else { return false }
        }
        try publish()
        return true
    }

    private func purgeExpired(at now: Date) {
        let expirationDate = now.addingTimeInterval(-retentionInterval)
        let expired = events.filter { $0.event.recordedAt <= expirationDate }
        guard !expired.isEmpty else { return }
        events.removeAll { $0.event.recordedAt <= expirationDate }
        storedByteCount -= expired.reduce(0) { $0 + $1.byteCount }
    }

    private func scheduleExpiry(at now: Date) {
        expiryTimer?.cancel()
        expiryTimer = nil
        guard let oldest = events.map(\.event.recordedAt).min() else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0.001, oldest.addingTimeInterval(retentionInterval).timeIntervalSince(now)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.purgeExpired(at: Date())
            self.scheduleExpiry(at: Date())
        }
        expiryTimer = timer
        timer.resume()
    }

    private func clearEvents() {
        expiryTimer?.cancel()
        expiryTimer = nil
        events.removeAll(keepingCapacity: false)
        storedByteCount = 0
        omittedEventCount = 0
    }
}
