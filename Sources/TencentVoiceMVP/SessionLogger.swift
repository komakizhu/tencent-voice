import Foundation

private struct LegacyDiagnosticTraceEvent: Decodable {
    let timestamp: Date
    let kind: String
    let name: String
    let sessionID: UUID?
    let fields: [String: String]
}

private struct LegacyDiagnosticTraceJournal: Decodable {
    let schemaVersion: Int
    let startedAt: Date
    let app: DiagnosticAppInfo
    let events: [LegacyDiagnosticTraceEvent]
    let droppedEventCount: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case startedAt
        case app
        case events
        case droppedEventCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        app = try container.decode(DiagnosticAppInfo.self, forKey: .app)
        events = try container.decode([LegacyDiagnosticTraceEvent].self, forKey: .events)
        droppedEventCount = try container.decodeIfPresent(Int.self, forKey: .droppedEventCount) ?? 0
    }
}

struct SessionLogEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case session
        case action
    }

    let timestamp: Date
    let sessionID: UUID
    let eventID: UUID?
    let kind: Kind
    let event: String
    let state: String?
    let injectionMode: String?
    let targetApplicationName: String?
    let targetApplicationBundleIdentifier: String?
    let targetApplicationProcessID: Int32?
    let sequence: Int?
    let sliceType: Int?
    let wireFinal: Bool?
    let segmentID: Int?
    let segmentPhase: String?
    let committedLength: Int?
    let activeLength: Int?
    let renderedLength: Int?
    let revision: UInt64?
    let writeCount: Int?
    let backspaceCount: Int?
    let deepReplacementCount: Int?
    let maximumTrailingReplacementLength: Int?
    let discardCount: Int?
    let errorCount: Int?
    let errorCode: Int?
    let failureCode: String?
    let failureMessage: String?
    let metadata: [String: String]
    let textEvidence: [DiagnosticTextEvidence]

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID
        case eventID
        case kind
        case event
        case state
        case injectionMode
        case targetApplicationName
        case targetApplicationBundleIdentifier
        case targetApplicationProcessID
        case sequence
        case sliceType
        case wireFinal
        case segmentID
        case segmentPhase
        case committedLength
        case activeLength
        case renderedLength
        case revision
        case writeCount
        case backspaceCount
        case deepReplacementCount
        case maximumTrailingReplacementLength
        case discardCount
        case errorCount
        case errorCode
        case failureCode
        case failureMessage
        case metadata
        case textEvidence
    }

    init(
        timestamp: Date = Date(),
        sessionID: UUID = UUID(),
        eventID: UUID? = UUID(),
        kind: Kind = .session,
        event: String,
        state: String? = nil,
        injectionMode: String? = nil,
        targetApplicationName: String? = nil,
        targetApplicationBundleIdentifier: String? = nil,
        targetApplicationProcessID: Int32? = nil,
        sequence: Int? = nil,
        sliceType: Int? = nil,
        wireFinal: Bool? = nil,
        segmentID: Int? = nil,
        segmentPhase: String? = nil,
        committedLength: Int? = nil,
        activeLength: Int? = nil,
        renderedLength: Int? = nil,
        revision: UInt64? = nil,
        writeCount: Int? = nil,
        backspaceCount: Int? = nil,
        deepReplacementCount: Int? = nil,
        maximumTrailingReplacementLength: Int? = nil,
        discardCount: Int? = nil,
        errorCount: Int? = nil,
        errorCode: Int? = nil,
        failureCode: String? = nil,
        failureMessage: String? = nil,
        metadata: [String: String] = [:],
        textEvidence: [DiagnosticTextEvidence] = []
    ) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.eventID = eventID
        self.kind = kind
        self.event = event
        self.state = state
        self.injectionMode = injectionMode
        self.targetApplicationName = targetApplicationName
        self.targetApplicationBundleIdentifier = targetApplicationBundleIdentifier
        self.targetApplicationProcessID = targetApplicationProcessID
        self.sequence = sequence
        self.sliceType = sliceType
        self.wireFinal = wireFinal
        self.segmentID = segmentID
        self.segmentPhase = segmentPhase
        self.committedLength = committedLength
        self.activeLength = activeLength
        self.renderedLength = renderedLength
        self.revision = revision
        self.writeCount = writeCount
        self.backspaceCount = backspaceCount
        self.deepReplacementCount = deepReplacementCount
        self.maximumTrailingReplacementLength = maximumTrailingReplacementLength
        self.discardCount = discardCount
        self.errorCount = errorCount
        self.errorCode = errorCode
        self.failureCode = failureCode
        self.failureMessage = failureMessage.map(DiagnosticLogSanitizer.failureMessage)
        self.metadata = DiagnosticLogSanitizer.fields(metadata)
        self.textEvidence = textEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        eventID = try container.decodeIfPresent(UUID.self, forKey: .eventID)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? Kind.session.rawValue
        kind = Kind(rawValue: rawKind) ?? .session
        event = try container.decode(String.self, forKey: .event)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        injectionMode = try container.decodeIfPresent(String.self, forKey: .injectionMode)
        targetApplicationName = try container.decodeIfPresent(String.self, forKey: .targetApplicationName)
        targetApplicationBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .targetApplicationBundleIdentifier
        )
        targetApplicationProcessID = try container.decodeIfPresent(Int32.self, forKey: .targetApplicationProcessID)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence)
        sliceType = try container.decodeIfPresent(Int.self, forKey: .sliceType)
        wireFinal = try container.decodeIfPresent(Bool.self, forKey: .wireFinal)
        segmentID = try container.decodeIfPresent(Int.self, forKey: .segmentID)
        segmentPhase = try container.decodeIfPresent(String.self, forKey: .segmentPhase)
        committedLength = try container.decodeIfPresent(Int.self, forKey: .committedLength)
        activeLength = try container.decodeIfPresent(Int.self, forKey: .activeLength)
        renderedLength = try container.decodeIfPresent(Int.self, forKey: .renderedLength)
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision)
        writeCount = try container.decodeIfPresent(Int.self, forKey: .writeCount)
        backspaceCount = try container.decodeIfPresent(Int.self, forKey: .backspaceCount)
        deepReplacementCount = try container.decodeIfPresent(Int.self, forKey: .deepReplacementCount)
        maximumTrailingReplacementLength = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumTrailingReplacementLength
        )
        discardCount = try container.decodeIfPresent(Int.self, forKey: .discardCount)
        errorCount = try container.decodeIfPresent(Int.self, forKey: .errorCount)
        errorCode = try container.decodeIfPresent(Int.self, forKey: .errorCode)
        failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
            .map(DiagnosticLogSanitizer.failureMessage)
        metadata = DiagnosticLogSanitizer.fields(
            try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        )
        textEvidence = try container.decodeIfPresent(
            [DiagnosticTextEvidence].self,
            forKey: .textEvidence
        ) ?? []
    }
}

@MainActor
final class SessionLogger {
    var evidenceObserver: ((SessionLogEntry) -> Void)?
    private let enabled: () -> Bool
    private let fileManager = FileManager.default
    private let applicationSupportDirectoryURL: URL
    private let loggerStartedAt = Date()
    private var persistenceCaptureStartedAt: Date?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var inMemoryEntries: [SessionLogEntry] = []
    private let diagnosticActionSessionID = UUID()
    private let inMemoryLimit = 300
    private let reportReferenceLimit = 200_000
    private var reportFileReferences: [DiagnosticEventFileReference] = []
    private var reportReferenceHead = 0
    private var droppedReportReferences: [DiagnosticEventEvictionReference] = []
    private var droppedReportReferenceHead = 0
    private var droppedReportReferenceOverflowRange: [Date]?
    private var evictedMemoryEvents: [DiagnosticEventEvictionReference] = []
    private var memoryEvictionHead = 0
    private var memoryEvictionOverflowAt: Date?
    private var failureContextEnabled = false
    private var failureContextEvents: DiagnosticEventBuffer
    private(set) var failureContextEventsTruncated = false
    private var failureContextDroppedEventTimes: [Date] = []
    private var failureContextDroppedEventHead = 0
    private var failureContextDroppedOverflowRange: [Date]?
    private let failureContextDropIndexLimit = 200_000
    private var failureContextStartedAt: Date?
    var failureContextRecordingStartedAt: Date? { failureContextStartedAt }
    var reportCaptureStartedAt: Date? {
        var starts: [Date] = []
        if failureContextEnabled, let failureContextStartedAt { starts.append(failureContextStartedAt) }
        if enabled(), let persistenceCaptureStartedAt { starts.append(persistenceCaptureStartedAt) }
        return starts.min()
    }
    private var persistenceFailures = 0
    private var lastPersistenceError: String?
    private struct PinnedSessionEvidence {
        var lastSuccess: SessionLogEntry?
        var firstAnomaly: SessionLogEntry?
        var finalCopy: SessionLogEntry?
    }
    private var pinnedSessions: [UUID: PinnedSessionEvidence] = [:]
    private var pinnedSessionOrder: [UUID] = []
    private struct PinnedSessionDropReference {
        let sessionID: UUID
        let evidenceTimestamps: [Date]
    }
    private var droppedPinnedSessionReferences: [PinnedSessionDropReference] = []
    private var droppedPinnedSessionHead = 0
    private var droppedPinnedSessionOverflowRange: [Date]?
    private let droppedPinnedSessionIndexLimit = 200_000

    private func recordPinnedSessionDrop(sessionID: UUID, evidence: PinnedSessionEvidence, fallbackTimestamp: Date) {
        let timestamps = [evidence.lastSuccess, evidence.firstAnomaly, evidence.finalCopy]
            .compactMap { $0?.timestamp }
        droppedPinnedSessionReferences.append(PinnedSessionDropReference(
            sessionID: sessionID,
            evidenceTimestamps: timestamps.isEmpty ? [fallbackTimestamp] : timestamps
        ))
        while droppedPinnedSessionReferences.count - droppedPinnedSessionHead > droppedPinnedSessionIndexLimit {
            let omittedTimestamps = droppedPinnedSessionReferences[droppedPinnedSessionHead].evidenceTimestamps
            let rangeMinimum = omittedTimestamps.min() ?? fallbackTimestamp
            let rangeMaximum = omittedTimestamps.max() ?? fallbackTimestamp
            let previous = droppedPinnedSessionOverflowRange ?? [rangeMinimum, rangeMaximum]
            droppedPinnedSessionOverflowRange = [
                min(previous.min() ?? rangeMinimum, rangeMinimum),
                max(previous.max() ?? rangeMaximum, rangeMaximum)
            ]
            droppedPinnedSessionHead += 1
        }
        if droppedPinnedSessionHead >= 1024 && droppedPinnedSessionHead * 2 >= droppedPinnedSessionReferences.count {
            droppedPinnedSessionReferences.removeFirst(droppedPinnedSessionHead)
            droppedPinnedSessionHead = 0
        }
    }

    private func pinnedSessionDropSummary(from start: Date, through end: Date) -> (count: Int?, truncated: Bool) {
        let retainedSessionIDs = Set(droppedPinnedSessionReferences[droppedPinnedSessionHead...].compactMap { reference in
            reference.evidenceTimestamps.contains { $0 >= start && $0 <= end } ? reference.sessionID : nil
        })
        let overflowIntersectsWindow: Bool = {
            guard let range = droppedPinnedSessionOverflowRange,
                  let earliest = range.min(), let latest = range.max() else { return false }
            return latest >= start && earliest <= end
        }()
        if overflowIntersectsWindow { return (nil, true) }
        return (retainedSessionIDs.count, !retainedSessionIDs.isEmpty)
    }

    private func recordFailureContextDrops(_ entries: [SessionLogEntry]) {
        failureContextDroppedEventTimes.append(contentsOf: entries.map(\.timestamp))
        while failureContextDroppedEventTimes.count - failureContextDroppedEventHead > failureContextDropIndexLimit {
            let omittedTimestamp = failureContextDroppedEventTimes[failureContextDroppedEventHead]
            let previous = failureContextDroppedOverflowRange ?? [omittedTimestamp, omittedTimestamp]
            failureContextDroppedOverflowRange = [
                min(previous.min() ?? omittedTimestamp, omittedTimestamp),
                max(previous.max() ?? omittedTimestamp, omittedTimestamp)
            ]
            failureContextDroppedEventHead += 1
        }
        if failureContextDroppedEventHead >= 1024
            && failureContextDroppedEventHead * 2 >= failureContextDroppedEventTimes.count {
            failureContextDroppedEventTimes.removeFirst(failureContextDroppedEventHead)
            failureContextDroppedEventHead = 0
        }
    }

    private func failureContextDropSummary(from start: Date, through end: Date) -> (count: Int?, truncated: Bool) {
        let retainedCount = failureContextDroppedEventTimes[failureContextDroppedEventHead...]
            .filter { $0 >= start && $0 <= end }.count
        let overflowIntersectsWindow: Bool = {
            guard let range = failureContextDroppedOverflowRange,
                  let earliest = range.min(), let latest = range.max() else { return false }
            return latest >= start && earliest <= end
        }()
        if overflowIntersectsWindow { return (nil, true) }
        return (retainedCount, retainedCount > 0)
    }

    func failureContextEvidenceTruncated(at date: Date) -> Bool {
        failureContextDropSummary(from: date.addingTimeInterval(-60), through: date).truncated
    }

    func setFailureContextEnabled(_ enabled: Bool) {
        failureContextEnabled = enabled
        failureContextEvents.removeAll()
        failureContextEventsTruncated = false
        failureContextDroppedEventTimes = []
        failureContextDroppedEventHead = 0
        failureContextDroppedOverflowRange = nil
        failureContextStartedAt = enabled ? Date() : nil
        pinnedSessions = [:]
        pinnedSessionOrder = []
        droppedPinnedSessionReferences = []
        droppedPinnedSessionHead = 0
        droppedPinnedSessionOverflowRange = nil
    }

    func failureEvents(at date: Date, recoverPersisted: Bool = true) -> [SessionLogEntry] {
        let windowStart = date.addingTimeInterval(-60)
        var events = failureContextEvents.entries.filter { $0.timestamp >= windowStart && $0.timestamp <= date }
        var retainedIDs = Set(events.compactMap(\.eventID))
        for pin in pinnedSessions.values {
            for entry in [pin.lastSuccess, pin.firstAnomaly, pin.finalCopy].compactMap({ $0 })
            where entry.timestamp >= windowStart && entry.timestamp <= date {
                if let id = entry.eventID, retainedIDs.insert(id).inserted { events.append(entry) }
            }
        }
        let pinDropSummary = pinnedSessionDropSummary(from: windowStart, through: date)
        if pinDropSummary.truncated {
            events.append(SessionLogEntry(timestamp: date, event: "diagnostic_session_pins_omitted", metadata: [
                "omittedSessionCount": pinDropSummary.count.map(String.init) ?? "unknown",
                "countScope": pinDropSummary.count == nil ? "click_window_unknown_due_capacity" : "click_window",
                "reason": "pinned_session_count_or_16MiB_capacity"
            ]))
        }
        if recoverPersisted, enabled() {
            let snapshot = reportEventSnapshot(at: date, captureStartedAt: failureContextStartedAt)
            let memoryIDs = Set(events.compactMap(\.eventID))
            let recovered = snapshot.recoverPersistedEvents().events
            events += recovered.filter { $0.eventID.map { !memoryIDs.contains($0) } ?? true }
        }
        if persistenceFailures > 0 {
            events.append(SessionLogEntry(timestamp: date, event: "diagnostic_persistence_failed", metadata: [
                "failedEventCount": String(persistenceFailures),
                "errorDetail": lastPersistenceError ?? "unknown",
                "memoryEvidenceMayRemainAvailable": "true"
            ]))
        }
        let failureDropSummary = failureContextDropSummary(from: windowStart, through: date)
        if failureDropSummary.truncated {
            events.append(SessionLogEntry(timestamp: date, event: "diagnostic_events_omitted", metadata: [
                "droppedEventCount": failureDropSummary.count.map(String.init) ?? "unknown",
                "countScope": failureDropSummary.count == nil ? "click_window_unknown_due_capacity" : "click_window",
                "reason": "failure_context_memory_capacity",
                "countMeaning": "evicted_records_in_click_window",
                "byteLimit": String(failureContextEvents.byteLimit),
                "diskRecoveryAttempted": String(recoverPersisted && enabled() && failureContextStartedAt != nil),
                "windowStart": DiagnosticReportTime.format(windowStart),
                "windowEnd": DiagnosticReportTime.format(date)
            ]))
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    func reportEventSnapshot(
        at date: Date,
        captureStartedAt: Date? = nil,
        windowDuration: TimeInterval = 60
    ) -> DiagnosticReportEventSnapshot {
        let windowStart = date.addingTimeInterval(-max(0, windowDuration))
        while memoryEvictionHead < evictedMemoryEvents.count,
              evictedMemoryEvents[memoryEvictionHead].indexedAt < date.addingTimeInterval(-60) {
            memoryEvictionHead += 1
        }
        let omittedReferenceKeys = Set(droppedReportReferences[droppedReportReferenceHead...].filter {
            $0.timestamp >= windowStart && $0.timestamp <= date && $0.indexedAt <= date
        }.map(\.identityKey))
        let omissionIndexOverflowed: Bool = {
            guard let range = droppedReportReferenceOverflowRange,
                  let earliest = range.min(), let latest = range.max() else { return false }
            return latest >= windowStart && earliest <= date
        }()
        var sourceEntries = failureContextEnabled
            ? failureContextEvents.entries + pinnedSessions.values.flatMap {
                [$0.lastSuccess, $0.firstAnomaly, $0.finalCopy].compactMap { $0 }
            }
            : inMemoryEntries
        let failureDropSummary = failureContextDropSummary(from: windowStart, through: date)
        if failureDropSummary.truncated {
            sourceEntries.append(SessionLogEntry(timestamp: date, event: "diagnostic_events_omitted", metadata: [
                "droppedEventCount": failureDropSummary.count.map(String.init) ?? "unknown",
                "countScope": failureDropSummary.count == nil ? "click_window_unknown_due_capacity" : "click_window",
                "reason": "failure_context_memory_capacity",
                "countMeaning": "memory_evictions_not_proven_remaining_gaps",
                "remainingMissingEventCount": "unknown",
                "diskRecoveryAttempted": String(enabled())
            ]))
        }
        let pinDropSummary = pinnedSessionDropSummary(from: windowStart, through: date)
        if pinDropSummary.truncated {
            sourceEntries.append(SessionLogEntry(timestamp: date, event: "diagnostic_session_pins_omitted", metadata: [
                "omittedSessionCount": pinDropSummary.count.map(String.init) ?? "unknown",
                "countScope": pinDropSummary.count == nil ? "click_window_unknown_due_capacity" : "click_window",
                "reason": "pinned_session_count_or_16MiB_capacity"
            ]))
        }
        var seen = Set<String>()
        let memory = sourceEntries.filter { entry in
            guard entry.timestamp >= windowStart && entry.timestamp <= date else { return false }
            let key = entry.eventID.map { "event:\($0.uuidString)" }
                ?? "legacy:\(entry.sessionID.uuidString)|\(entry.timestamp.timeIntervalSince1970)|\(entry.event)|\(entry.sequence ?? -1)"
            return seen.insert(key).inserted
        }.sorted { $0.timestamp < $1.timestamp }
        return DiagnosticReportEventSnapshot(
            requestedAt: date,
            windowStart: windowStart,
            captureStartedAt: captureStartedAt ?? reportCaptureStartedAt,
            memoryEvents: memory,
            pinnedEvidenceTruncated: pinDropSummary.truncated,
            failureContextEvidenceTruncated: failureDropSummary.truncated,
            fileReferences: reportFileReferences[reportReferenceHead...].filter {
                $0.timestamp >= windowStart && $0.timestamp <= date && $0.indexedAt <= date
            },
            omittedReferenceKeys: omittedReferenceKeys,
            omissionIndexOverflowed: omissionIndexOverflowed,
            evictedMemoryEvents: evictedMemoryEvents[memoryEvictionHead...].filter {
                $0.timestamp >= windowStart && $0.timestamp <= date && $0.indexedAt <= date
            },
            memoryEvictionCountUnknown: memoryEvictionOverflowAt.map {
                $0 >= date.addingTimeInterval(-60) && $0 <= date
            } ?? false
        )
    }

    init(
        enabled: @escaping () -> Bool,
        applicationSupportDirectoryURL: URL? = nil,
        failureContextEventLimit: Int = 100_000
    ) {
        self.enabled = enabled
        self.failureContextEvents = DiagnosticEventBuffer(eventLimit: failureContextEventLimit)
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if enabled() { self.persistenceCaptureStartedAt = loggerStartedAt }
        DiagnosticJSON.configureDateEncoding(for: encoder)
        DiagnosticJSON.configureDateDecoding(for: decoder)
        try? migrateLegacyDiagnosticJournal()
    }

    func append(_ entry: SessionLogEntry) throws {
        if failureContextEnabled {
            if entry.kind == .session && (DiagnosticAnomaly.events.contains(entry.event)
                || ["keyboard_write_acknowledged", "ax_write_acknowledged"].contains(entry.event)
                || entry.textEvidence.contains(where: { $0.kind == .safeCopySucceeded })) {
                if pinnedSessions[entry.sessionID] == nil {
                    pinnedSessionOrder.append(entry.sessionID)
                    if pinnedSessionOrder.count > 128 {
                        let droppedSessionID = pinnedSessionOrder.removeFirst()
                        if let droppedEvidence = pinnedSessions.removeValue(forKey: droppedSessionID) {
                            recordPinnedSessionDrop(
                                sessionID: droppedSessionID,
                                evidence: droppedEvidence,
                                fallbackTimestamp: entry.timestamp
                            )
                        }
                    }
                }
                var pin = pinnedSessions[entry.sessionID] ?? PinnedSessionEvidence()
                if DiagnosticAnomaly.events.contains(entry.event), entry.timestamp < (pin.firstAnomaly?.timestamp ?? .distantFuture) {
                    pin.firstAnomaly = entry
                    pin.lastSuccess = (failureContextEvents.entries + [pin.lastSuccess].compactMap { $0 })
                        .filter { $0.sessionID == entry.sessionID && $0.timestamp <= entry.timestamp
                            && ["keyboard_write_acknowledged", "ax_write_acknowledged"].contains($0.event) }
                        .max { $0.timestamp < $1.timestamp }
                } else if ["keyboard_write_acknowledged", "ax_write_acknowledged"].contains(entry.event),
                          entry.timestamp <= (pin.firstAnomaly?.timestamp ?? .distantFuture),
                          entry.timestamp >= (pin.lastSuccess?.timestamp ?? .distantPast) {
                    pin.lastSuccess = entry
                }
                if entry.textEvidence.contains(where: { $0.kind == .safeCopySucceeded }),
                   entry.timestamp >= (pin.finalCopy?.timestamp ?? .distantPast) { pin.finalCopy = entry }
                pinnedSessions[entry.sessionID] = pin
                func pinnedBytes() -> Int {
                    pinnedSessions.values.reduce(0) { total, item in
                        total + [item.lastSuccess, item.firstAnomaly, item.finalCopy].compactMap { $0 }
                            .reduce(0) { $0 + $1.estimatedDiagnosticBytes }
                    }
                }
                while pinnedBytes() > 16 * 1024 * 1024, !pinnedSessionOrder.isEmpty {
                    let droppedSessionID = pinnedSessionOrder.removeFirst()
                    if let droppedEvidence = pinnedSessions.removeValue(forKey: droppedSessionID) {
                        recordPinnedSessionDrop(
                            sessionID: droppedSessionID,
                            evidence: droppedEvidence,
                            fallbackTimestamp: entry.timestamp
                        )
                    }
                }
            }
            let overflow = failureContextEvents.append(entry)
            if overflow > 0 {
                failureContextEventsTruncated = true
                recordFailureContextDrops(failureContextEvents.lastEvictedEntries)
            }
        }
        inMemoryEntries.append(entry)
        if inMemoryEntries.count > inMemoryLimit {
            let removedCount = inMemoryEntries.count - inMemoryLimit
            let removed = inMemoryEntries.prefix(removedCount)
            let indexedAt = Date()
            while memoryEvictionHead < evictedMemoryEvents.count,
                  evictedMemoryEvents[memoryEvictionHead].indexedAt < indexedAt.addingTimeInterval(-60) {
                memoryEvictionHead += 1
            }
            evictedMemoryEvents.append(contentsOf: removed.map {
                DiagnosticEventEvictionReference(
                    timestamp: $0.timestamp,
                    eventID: $0.eventID,
                    sessionID: $0.sessionID,
                    event: $0.event,
                    sequence: $0.sequence,
                    indexedAt: indexedAt
                )
            })
            if evictedMemoryEvents.count - memoryEvictionHead > 200_000 {
                memoryEvictionHead += evictedMemoryEvents.count - memoryEvictionHead - 200_000
                memoryEvictionOverflowAt = indexedAt
            }
            if memoryEvictionHead >= 1024 && memoryEvictionHead * 2 >= evictedMemoryEvents.count {
                evictedMemoryEvents.removeFirst(memoryEvictionHead)
                memoryEvictionHead = 0
            }
            inMemoryEntries.removeFirst(removedCount)
        }
        evidenceObserver?(entry)
        let persistenceEnabled = enabled()
        if persistenceEnabled {
            if persistenceCaptureStartedAt == nil { persistenceCaptureStartedAt = entry.timestamp }
        } else {
            persistenceCaptureStartedAt = nil
        }
        guard persistenceEnabled else { return }
        do {
            let reference = try persist(entry)
            let indexedAt = reference.indexedAt
            let lowerBound = indexedAt.addingTimeInterval(-60)
            while reportReferenceHead < reportFileReferences.count,
                  reportFileReferences[reportReferenceHead].indexedAt < lowerBound {
                reportReferenceHead += 1
            }
            reportReferenceHead = min(reportReferenceHead, reportFileReferences.count)
            reportFileReferences.append(reference)
            while reportFileReferences.count - reportReferenceHead > reportReferenceLimit {
                let omitted = reportFileReferences[reportReferenceHead]
                droppedReportReferences.append(DiagnosticEventEvictionReference(
                    timestamp: omitted.timestamp,
                    eventID: omitted.eventID,
                    sessionID: omitted.sessionID,
                    event: omitted.event,
                    sequence: omitted.sequence,
                    indexedAt: omitted.indexedAt
                ))
                if droppedReportReferences.count - droppedReportReferenceHead > reportReferenceLimit {
                    let omittedTimestamp = droppedReportReferences[droppedReportReferenceHead].timestamp
                    let previous = droppedReportReferenceOverflowRange ?? [omittedTimestamp, omittedTimestamp]
                    droppedReportReferenceOverflowRange = [
                        min(previous.min() ?? omittedTimestamp, omittedTimestamp),
                        max(previous.max() ?? omittedTimestamp, omittedTimestamp)
                    ]
                    droppedReportReferenceHead += 1
                }
                if droppedReportReferenceHead >= 1024
                    && droppedReportReferenceHead * 2 >= droppedReportReferences.count {
                    droppedReportReferences.removeFirst(droppedReportReferenceHead)
                    droppedReportReferenceHead = 0
                }
                reportReferenceHead += 1
            }
            if reportReferenceHead >= 1024 && reportReferenceHead * 2 >= reportFileReferences.count {
                reportFileReferences.removeFirst(reportReferenceHead)
                reportReferenceHead = 0
            }
        } catch {
            persistenceFailures += 1
            lastPersistenceError = DiagnosticLogSanitizer.failureMessage(error.localizedDescription)
            throw error
        }
    }

    private func persist(_ entry: SessionLogEntry) throws -> DiagnosticEventFileReference {
        let directory = applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let fileURL = directory.appendingPathComponent("\(formatter.string(from: entry.timestamp)).jsonl")
        var line = try encoder.encode(entry)
        line.append(0x0A)
        let offset: UInt64
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            offset = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: fileURL, options: .atomic)
            offset = 0
        }
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let identity = (attributes?[.systemFileNumber] as? NSNumber)?.stringValue
        return DiagnosticEventFileReference(
            fileURL: fileURL,
            fileIdentity: identity,
            offset: offset,
            length: line.count,
            timestamp: entry.timestamp,
            eventID: entry.eventID,
            sessionID: entry.sessionID,
            event: entry.event,
            sequence: entry.sequence,
            indexedAt: Date()
        )
    }

    func recentEntries(limit: Int = 120) -> [SessionLogEntry] {
        Array(inMemoryEntries.suffix(max(0, limit)))
    }

    func recentPersistedEntries(limit: Int = 120) -> [SessionLogEntry] {
        persistedEntries(limit: limit)
    }

    func allPersistedEntries() -> [SessionLogEntry] {
        persistedEntries(limit: nil)
    }

    private func persistedEntries(limit: Int?) -> [SessionLogEntry] {
        if let limit, limit <= 0 { return [] }
        let directory = applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
            )
        } catch {
            return [SessionLogEntry(event: "diagnostic_read_failed", metadata: [
                "stage": "directory", "errorDetail": DiagnosticLogSanitizer.failureMessage(error.localizedDescription)
            ])]
        }

        var entries: [SessionLogEntry] = []
        let sortedURLs = urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
            }

        for url in sortedURLs {
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                entries.append(SessionLogEntry(event: "diagnostic_read_failed", metadata: [
                    "file": url.lastPathComponent, "stage": "file_or_utf8", "missingEventCount": "unknown"
                ]))
                continue
            }
            // JSONL records use LF. U+0085/U+2028/U+2029 can occur literally
            // inside JSON strings and must not split a full-text record.
            let lines = content.split(separator: "\n").reversed()
            var corruptLines = 0
            for line in lines {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(SessionLogEntry.self, from: lineData) else {
                    corruptLines += 1
                    continue
                }
                entries.append(entry)
                if let limit, entries.count >= limit { return Array(entries.reversed()) }
            }
            if corruptLines > 0 {
                entries.append(SessionLogEntry(event: "diagnostic_decode_failed", metadata: [
                    "file": url.lastPathComponent, "missingEventCount": String(corruptLines)
                ]))
            }
        }
        return Array(entries.reversed())
    }

    private func migrateLegacyDiagnosticJournal() throws {
        let journalURL = applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/diagnostics/active.json")
        guard fileManager.fileExists(atPath: journalURL.path) else { return }

        let journal = try decoder.decode(
            LegacyDiagnosticTraceJournal.self,
            from: Data(contentsOf: journalURL)
        )
        let fallbackSessionID = UUID()
        let entries = journal.events.map { event in
            let fields = event.fields
            return SessionLogEntry(
                timestamp: event.timestamp,
                sessionID: event.sessionID ?? fallbackSessionID,
                eventID: nil,
                kind: SessionLogEntry.Kind(rawValue: event.kind) ?? .session,
                event: event.name,
                state: fields["state"],
                injectionMode: fields["injectionMode"],
                targetApplicationName: fields["targetApplicationName"],
                targetApplicationBundleIdentifier: fields["targetApplicationBundleIdentifier"],
                targetApplicationProcessID: Self.integer(fields["targetApplicationProcessID"]).map(Int32.init),
                sequence: Self.integer(fields["sequence"]),
                sliceType: Self.integer(fields["sliceType"]),
                wireFinal: fields["wireFinal"].flatMap(Bool.init),
                segmentID: Self.integer(fields["segmentID"]),
                segmentPhase: fields["segmentPhase"],
                committedLength: Self.integer(fields["committedLength"]),
                activeLength: Self.integer(fields["activeLength"]),
                renderedLength: Self.integer(fields["renderedLength"]),
                revision: fields["revision"].flatMap(UInt64.init),
                writeCount: Self.integer(fields["writeCount"]),
                backspaceCount: Self.integer(fields["backspaceCount"]),
                deepReplacementCount: Self.integer(fields["deepReplacementCount"]),
                maximumTrailingReplacementLength: Self.integer(fields["maximumTrailingReplacementLength"]),
                discardCount: Self.integer(fields["discardCount"]),
                errorCount: Self.integer(fields["errorCount"]),
                errorCode: Self.integer(fields["errorCode"]),
                failureCode: fields["failureCode"],
                metadata: fields
            )
        }
        for entry in entries {
            _ = try persist(entry)
        }
        _ = try persist(SessionLogEntry(
            timestamp: Date(),
            sessionID: fallbackSessionID,
            eventID: nil,
            kind: .action,
            event: "legacy_diagnostic_journal_migrated",
            metadata: [
                "schemaVersion": String(journal.schemaVersion),
                "eventCount": String(journal.events.count),
                "droppedEventCount": String(journal.droppedEventCount),
                "previousVersion": journal.app.shortVersion,
                "previousBuild": journal.app.build
            ]
        ))
        try fileManager.removeItem(at: journalURL)
    }

    private static func integer(_ value: String?) -> Int? {
        value.flatMap(Int.init)
    }

    var persistenceDirectoryURL: URL {
        applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
    }

    static var defaultPersistenceDirectoryURL: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
    }

    var diagnosticExportDirectoryURL: URL {
        fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func recordDiagnosticAction(
        _ name: String,
        sessionID: UUID? = nil,
        fields: [String: String] = [:]
    ) {
        let metadata = fields.reduce(into: [String: String]()) { result, field in
            let key = field.key.lowercased()
            if key.contains("error") || key.contains("message") || key.contains("detail") {
                result[field.key] = DiagnosticLogSanitizer.failureMessage(field.value)
            } else {
                result.merge(DiagnosticLogSanitizer.fields([field.key: field.value])) { _, new in new }
            }
        }
        let entry = SessionLogEntry(
            sessionID: sessionID ?? diagnosticActionSessionID,
            kind: .action,
            event: name,
            failureCode: metadata["errorCode"],
            metadata: metadata
        )
        try? append(entry)
    }
}
