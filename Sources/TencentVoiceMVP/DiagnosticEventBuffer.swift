import Foundation

extension SessionLogEntry {
    var estimatedDiagnosticBytes: Int {
        512 + metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + textEvidence.reduce(0) { $0 + 256 + $1.text.utf8.count }
            + (failureMessage?.utf8.count ?? 0)
    }
}

// Release evicted payloads immediately, amortizing storage compaction instead of
// moving a large array for every observation on the input thread.
struct DiagnosticEventBuffer {
    private var slots: [(entry: SessionLogEntry, bytes: Int)?] = []
    private var head = 0
    private(set) var bytes = 0
    private(set) var lastEvictedEntries: [SessionLogEntry] = []
    let eventLimit: Int
    let byteLimit: Int
    var count: Int { slots.count - head }
    var entries: [SessionLogEntry] { slots[head...].compactMap { $0?.entry } }

    init(eventLimit: Int, byteLimit: Int = 32 * 1024 * 1024) {
        self.eventLimit = max(1, eventLimit)
        self.byteLimit = max(1, byteLimit)
    }

    mutating func append(_ entry: SessionLogEntry) -> Int {
        lastEvictedEntries = []
        let size = entry.estimatedDiagnosticBytes
        slots.append((entry, size))
        bytes += size
        var removed = 0
        while count > eventLimit || bytes > byteLimit {
            if let evicted = slots[head]?.entry { lastEvictedEntries.append(evicted) }
            bytes -= slots[head]?.bytes ?? 0
            slots[head] = nil
            head += 1
            removed += 1
        }
        if head >= 1024 && head * 2 >= slots.count {
            slots.removeFirst(head)
            head = 0
        }
        return removed
    }

    mutating func removeAll() {
        slots = []
        head = 0
        bytes = 0
        lastEvictedEntries = []
    }
}

/// A body-free pointer to one already-persisted JSONL record. These references
/// are retained only for the active report window, independently of the
/// in-memory text-evidence buffer.
struct DiagnosticEventFileReference: Equatable, Sendable {
    let fileURL: URL
    let fileIdentity: String?
    let offset: UInt64
    let length: Int
    let timestamp: Date
    let eventID: UUID?
    let sessionID: UUID
    let event: String
    let sequence: Int?
    let indexedAt: Date

    var identityKey: String {
        if let eventID { return "event:\(eventID.uuidString)" }
        let milliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
        return "legacy:\(sessionID.uuidString)|\(milliseconds)|\(event)|\(sequence ?? -1)"
    }
}

struct DiagnosticEventEvictionReference: Equatable, Sendable {
    let timestamp: Date
    let eventID: UUID?
    let sessionID: UUID
    let event: String
    let sequence: Int?
    let indexedAt: Date

    var identityKey: String {
        if let eventID { return "event:\(eventID.uuidString)" }
        let milliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
        return "legacy:\(sessionID.uuidString)|\(milliseconds)|\(event)|\(sequence ?? -1)"
    }
}

struct DiagnosticEventRecoveryMetrics: Codable, Equatable, Sendable {
    var filesConsidered = 0
    var filesRead = 0
    var bytesRead: UInt64 = 0
    var recordsDecoded = 0
    var recordsRecovered = 0
    var missingRecordCount: Int?
    var failureReasons: [String] = []
}

struct DiagnosticEventRecoveryResult: Sendable {
    let events: [SessionLogEntry]
    let metrics: DiagnosticEventRecoveryMetrics
}

struct DiagnosticReportEventSnapshot: Sendable {
    let requestedAt: Date
    let windowStart: Date
    let captureStartedAt: Date?
    let memoryEvents: [SessionLogEntry]
    let pinnedEvidenceTruncated: Bool
    let failureContextEvidenceTruncated: Bool
    let fileReferences: [DiagnosticEventFileReference]
    let omittedReferenceKeys: Set<String>
    let omissionIndexOverflowed: Bool
    let evictedMemoryEvents: [DiagnosticEventEvictionReference]
    let memoryEvictionCountUnknown: Bool

    func recoverPersistedEvents() -> DiagnosticEventRecoveryResult {
        let eligible = fileReferences.filter {
            $0.timestamp >= windowStart && $0.timestamp <= requestedAt && $0.indexedAt <= requestedAt
        }
        var metrics = DiagnosticEventRecoveryMetrics()
        let grouped = Dictionary(grouping: eligible, by: { $0.fileURL.standardizedFileURL.path })
        metrics.filesConsidered = grouped.count
        var recovered: [SessionLogEntry] = []
        var missingReferenceKeys = Set<String>()
        let decoder = DiagnosticJSON.decoder()

        for references in grouped.values {
            guard let first = references.first else { continue }
            guard let handle = try? FileHandle(forReadingFrom: first.fileURL) else {
                metrics.failureReasons.append("file_unavailable:\(first.fileURL.lastPathComponent)")
                missingReferenceKeys.formUnion(references.map(\.identityKey))
                continue
            }
            defer { try? handle.close() }
            let attributes = try? FileManager.default.attributesOfItem(atPath: first.fileURL.path)
            let currentIdentity = (attributes?[.systemFileNumber] as? NSNumber)?.stringValue
            let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value
            var didReadFile = false

            let sortedReferences = references.sorted { $0.offset < $1.offset }
            var contiguousRanges: [[DiagnosticEventFileReference]] = []
            for reference in sortedReferences {
                if let lastIndex = contiguousRanges.indices.last,
                   let previous = contiguousRanges[lastIndex].last,
                   previous.offset + UInt64(previous.length) == reference.offset {
                    contiguousRanges[lastIndex].append(reference)
                } else {
                    contiguousRanges.append([reference])
                }
            }

            for range in contiguousRanges {
                let identityMatches = range.allSatisfy {
                    $0.fileIdentity == nil || currentIdentity == $0.fileIdentity
                }
                guard identityMatches else {
                    metrics.failureReasons.append("file_replaced_or_truncated:\(first.fileURL.lastPathComponent)")
                    missingReferenceKeys.formUnion(range.map(\.identityKey))
                    continue
                }
                guard let fileSize else {
                    metrics.failureReasons.append("file_size_unavailable:\(first.fileURL.lastPathComponent)")
                    missingReferenceKeys.formUnion(range.map(\.identityKey))
                    continue
                }
                var readable: [DiagnosticEventFileReference] = []
                var unreadable: [DiagnosticEventFileReference] = []
                for reference in range {
                    if reference.offset <= fileSize && UInt64(reference.length) <= fileSize - reference.offset {
                        readable.append(reference)
                    } else {
                        unreadable.append(reference)
                    }
                }
                if !unreadable.isEmpty {
                    metrics.failureReasons.append("file_replaced_or_truncated:\(first.fileURL.lastPathComponent)")
                    missingReferenceKeys.formUnion(unreadable.map(\.identityKey))
                }
                guard let rangeFirst = readable.first, let rangeLast = readable.last else { continue }
                let startOffset = rangeFirst.offset
                let endOffset = rangeLast.offset + UInt64(rangeLast.length)
                let readLength64 = endOffset - startOffset
                guard readLength64 <= UInt64(Int.max) else {
                    metrics.failureReasons.append("range_too_large:\(first.fileURL.lastPathComponent)")
                    missingReferenceKeys.formUnion(readable.map(\.identityKey))
                    continue
                }
                do {
                    try handle.seek(toOffset: startOffset)
                    let readLength = Int(readLength64)
                    guard let rangeData = try handle.read(upToCount: readLength), rangeData.count == readLength else {
                        metrics.failureReasons.append("short_read:\(first.fileURL.lastPathComponent)")
                        missingReferenceKeys.formUnion(readable.map(\.identityKey))
                        continue
                    }
                    if !didReadFile {
                        metrics.filesRead += 1
                        didReadFile = true
                    }
                    metrics.bytesRead += UInt64(rangeData.count)
                    for reference in readable {
                        let lower = Int(reference.offset - startOffset)
                        let upper = lower + reference.length
                        let recordData = rangeData.subdata(in: lower..<upper)
                        guard let entry = try? decoder.decode(SessionLogEntry.self, from: recordData),
                              reference.eventID == nil || entry.eventID == reference.eventID else {
                            metrics.failureReasons.append("record_decode_or_identity_mismatch:\(first.fileURL.lastPathComponent)")
                            missingReferenceKeys.insert(reference.identityKey)
                            continue
                        }
                        metrics.recordsDecoded += 1
                        recovered.append(entry)
                    }
                } catch {
                    metrics.failureReasons.append("read_failed:\(first.fileURL.lastPathComponent)")
                    missingReferenceKeys.formUnion(readable.map(\.identityKey))
                }
            }
        }

        metrics.recordsRecovered = recovered.count
        let referenceKeys = Set(eligible.map(\.identityKey))
        let memoryKeys = Set(memoryEvents.map { entry in
            DiagnosticEventEvictionReference(
                timestamp: entry.timestamp, eventID: entry.eventID,
                sessionID: entry.sessionID, event: entry.event, sequence: entry.sequence,
                indexedAt: requestedAt
            ).identityKey
        })
        let missingUnavailableKeys = missingReferenceKeys.subtracting(memoryKeys)
        let relevantEvictions = evictedMemoryEvents.filter {
            $0.timestamp >= windowStart && $0.timestamp <= requestedAt && $0.indexedAt <= requestedAt
        }
        let unpersistedEvictionKeys = Set(relevantEvictions.filter {
            !referenceKeys.contains($0.identityKey)
        }.map(\.identityKey))
        if omissionIndexOverflowed {
            metrics.failureReasons.append("omitted_reference_index_capacity_exceeded")
            metrics.missingRecordCount = nil
        } else if !memoryEvictionCountUnknown {
            metrics.missingRecordCount = omittedReferenceKeys
                .union(missingUnavailableKeys)
                .union(unpersistedEvictionKeys)
                .count
        } else {
            metrics.missingRecordCount = nil
        }
        var seen = memoryKeys
        let uniqueRecovered = recovered.filter { entry in
            let key = DiagnosticEventEvictionReference(
                timestamp: entry.timestamp, eventID: entry.eventID,
                sessionID: entry.sessionID, event: entry.event, sequence: entry.sequence,
                indexedAt: requestedAt
            ).identityKey
            return seen.insert(key).inserted
        }
        return DiagnosticEventRecoveryResult(
            events: (memoryEvents + uniqueRecovered).sorted { $0.timestamp < $1.timestamp },
            metrics: metrics
        )
    }
}
