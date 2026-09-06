import Foundation

struct DiagnosticTraceEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let kind: String
    let name: String
    let sessionID: UUID?
    let fields: [String: String]

    init(
        timestamp: Date = Date(),
        kind: String,
        name: String,
        sessionID: UUID? = nil,
        fields: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.name = name
        self.sessionID = sessionID
        self.fields = Self.sanitizedFields(fields)
    }

    private static let sensitiveKeyFragments = [
        "text", "audio", "secret", "credential", "appid", "clipboard", "payload", "url", "raw", "message"
    ]

    private static func sanitizedFields(_ fields: [String: String]) -> [String: String] {
        fields.reduce(into: [String: String]()) { result, field in
            let normalizedKey = field.key.lowercased()
            if sensitiveKeyFragments.contains(where: { normalizedKey.contains($0) }) {
                result[field.key] = "已隐藏"
            } else {
                result[field.key] = String(field.value.prefix(200))
            }
        }
    }
}

struct DiagnosticTraceDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let startedAt: Date
    let endedAt: Date
    let app: DiagnosticAppInfo
    let events: [DiagnosticTraceEvent]
}

struct DiagnosticTraceJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let startedAt: Date
    let app: DiagnosticAppInfo
    let events: [DiagnosticTraceEvent]
    let droppedEventCount: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case startedAt
        case app
        case events
        case droppedEventCount
    }

    init(
        schemaVersion: Int,
        startedAt: Date,
        app: DiagnosticAppInfo,
        events: [DiagnosticTraceEvent],
        droppedEventCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.startedAt = startedAt
        self.app = app
        self.events = events
        self.droppedEventCount = droppedEventCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        app = try container.decode(DiagnosticAppInfo.self, forKey: .app)
        events = try container.decode([DiagnosticTraceEvent].self, forKey: .events)
        droppedEventCount = try container.decodeIfPresent(Int.self, forKey: .droppedEventCount) ?? 0
    }
}

enum DiagnosticJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 timestamp"
                )
            }
            return date
        }
        return decoder
    }
}

enum DiagnosticRecordingError: Error, LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case exportFailed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "故障诊断已经在记录中"
        case .notRecording:
            return "当前没有正在进行的故障诊断记录"
        case .exportFailed:
            return "故障诊断 JSON 导出失败"
        case .unavailable:
            return "故障诊断功能当前不可用"
        }
    }
}

@MainActor
final class DiagnosticSessionRecorder {
    private let fileManager: FileManager
    private let exportDirectoryURL: URL
    private let journalURL: URL?
    private var startedAt: Date?
    private var recordingAppInfo: DiagnosticAppInfo?
    private var events: [DiagnosticTraceEvent] = []
    private var droppedEventCount = 0

    private let maxEventCount = 5_000

    private(set) var isRecording = false

    init(
        exportDirectoryURL: URL? = nil,
        journalURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.exportDirectoryURL = exportDirectoryURL ?? Self.defaultExportDirectory(fileManager: fileManager)
        self.journalURL = journalURL
    }

    func start(appInfo: DiagnosticAppInfo, at date: Date = Date()) throws {
        guard !isRecording else { throw DiagnosticRecordingError.alreadyRecording }
        startedAt = date
        recordingAppInfo = appInfo
        events.removeAll(keepingCapacity: true)
        droppedEventCount = 0
        isRecording = true
        appendEvent(DiagnosticTraceEvent(
            timestamp: date,
            kind: "lifecycle",
            name: "diagnostic_started",
            fields: [
                "bundleIdentifier": appInfo.bundleIdentifier,
                "version": "\(appInfo.shortVersion) (build \(appInfo.build))"
            ]
        ))
        do {
            try persistJournal()
        } catch {
            clear()
            throw DiagnosticRecordingError.unavailable
        }
    }

    func recordAction(
        name: String,
        sessionID: UUID? = nil,
        fields: [String: String] = [:],
        at date: Date = Date()
    ) {
        guard isRecording else { return }
        appendEvent(DiagnosticTraceEvent(
            timestamp: date,
            kind: "action",
            name: name,
            sessionID: sessionID,
            fields: fields
        ))
        try? persistJournal()
    }

    func recordSessionEntry(_ entry: SessionLogEntry) {
        guard isRecording else { return }
        var fields: [String: String] = ["event": entry.event]
        if let state = entry.state { fields["state"] = state }
        if let mode = entry.injectionMode { fields["injectionMode"] = mode }
        if let eventID = entry.eventID { fields["eventID"] = eventID.uuidString }
        if let name = entry.targetApplicationName { fields["targetApplicationName"] = name }
        if let bundleID = entry.targetApplicationBundleIdentifier {
            fields["targetApplicationBundleIdentifier"] = bundleID
        }
        if let processID = entry.targetApplicationProcessID {
            fields["targetApplicationProcessID"] = String(processID)
        }
        if let sequence = entry.sequence { fields["sequence"] = String(sequence) }
        if let sliceType = entry.sliceType { fields["sliceType"] = String(sliceType) }
        if let wireFinal = entry.wireFinal { fields["wireFinal"] = String(wireFinal) }
        if let segmentID = entry.segmentID { fields["segmentID"] = String(segmentID) }
        if let phase = entry.segmentPhase { fields["segmentPhase"] = phase }
        if let committedLength = entry.committedLength {
            fields["committedLength"] = String(committedLength)
        }
        if let activeLength = entry.activeLength { fields["activeLength"] = String(activeLength) }
        if let renderedLength = entry.renderedLength { fields["renderedLength"] = String(renderedLength) }
        if let revision = entry.revision { fields["revision"] = String(revision) }
        if let writeCount = entry.writeCount { fields["writeCount"] = String(writeCount) }
        if let backspaceCount = entry.backspaceCount {
            fields["backspaceCount"] = String(backspaceCount)
        }
        if let deepReplacementCount = entry.deepReplacementCount {
            fields["deepReplacementCount"] = String(deepReplacementCount)
        }
        if let maximumTrailingReplacementLength = entry.maximumTrailingReplacementLength {
            fields["maximumTrailingReplacementLength"] = String(maximumTrailingReplacementLength)
        }
        if let discardCount = entry.discardCount { fields["discardCount"] = String(discardCount) }
        if let errorCount = entry.errorCount { fields["errorCount"] = String(errorCount) }
        if let errorCode = entry.errorCode { fields["errorCode"] = String(errorCode) }
        if let failureCode = entry.failureCode {
            fields["failureCode"] = failureCode
            fields["failure"] = DiagnosticErrorFormatter.canonicalMessage(for: failureCode)
                ?? "详细错误已隐藏"
        }

        appendEvent(DiagnosticTraceEvent(
            timestamp: entry.timestamp,
            kind: "session",
            name: entry.event,
            sessionID: entry.sessionID,
            fields: fields
        ))
        try? persistJournal()
    }

    func stopAndExport(
        appInfo: DiagnosticAppInfo,
        at date: Date = Date()
    ) throws -> URL {
        guard isRecording, let startedAt else {
            throw DiagnosticRecordingError.notRecording
        }

        var stoppedFields: [String: String] = [:]
        if droppedEventCount > 0 {
            stoppedFields["droppedEventCount"] = String(droppedEventCount)
        }
        let stoppedEvent = DiagnosticTraceEvent(
            timestamp: date,
            kind: "lifecycle",
            name: "diagnostic_stopped",
            fields: stoppedFields
        )
        let document = DiagnosticTraceDocument(
            schemaVersion: 1,
            startedAt: startedAt,
            endedAt: date,
            app: appInfo,
            events: events + [stoppedEvent]
        )

        do {
            try fileManager.createDirectory(
                at: exportDirectoryURL,
                withIntermediateDirectories: true
            )
            let data = try DiagnosticJSON.encoder().encode(document)
            let url = nextExportURL(for: date)
            try data.write(to: url, options: .atomic)
            clear()
            return url
        } catch {
            throw DiagnosticRecordingError.exportFailed
        }
    }

    func recoverInterruptedRecording(
        appInfo: DiagnosticAppInfo,
        at date: Date = Date()
    ) throws -> URL? {
        guard let journalURL, fileManager.fileExists(atPath: journalURL.path) else {
            return nil
        }

        let journal: DiagnosticTraceJournal
        do {
            journal = try DiagnosticJSON.decoder().decode(
                DiagnosticTraceJournal.self,
                from: Data(contentsOf: journalURL)
            )
        } catch {
            throw DiagnosticRecordingError.unavailable
        }

        let recoveredEvent = DiagnosticTraceEvent(
            timestamp: date,
            kind: "lifecycle",
            name: "diagnostic_recovered_after_unexpected_termination",
            fields: [
                "previousProcessID": String(journal.app.processIdentifier),
                "currentProcessID": String(appInfo.processIdentifier),
                "currentVersion": "\(appInfo.shortVersion) (build \(appInfo.build))",
                "droppedEventCount": String(journal.droppedEventCount)
            ]
        )
        let document = DiagnosticTraceDocument(
            schemaVersion: journal.schemaVersion,
            startedAt: journal.startedAt,
            endedAt: date,
            app: journal.app,
            events: journal.events + [recoveredEvent]
        )

        do {
            try fileManager.createDirectory(
                at: exportDirectoryURL,
                withIntermediateDirectories: true
            )
            let data = try DiagnosticJSON.encoder().encode(document)
            let url = nextExportURL(for: date)
            try data.write(to: url, options: .atomic)
            try? fileManager.removeItem(at: journalURL)
            return url
        } catch {
            throw DiagnosticRecordingError.exportFailed
        }
    }

    private func clear() {
        isRecording = false
        startedAt = nil
        recordingAppInfo = nil
        droppedEventCount = 0
        events.removeAll(keepingCapacity: true)
        if let journalURL {
            try? fileManager.removeItem(at: journalURL)
        }
    }

    private func persistJournal() throws {
        guard let journalURL, let startedAt, let recordingAppInfo else { return }
        let journal = DiagnosticTraceJournal(
            schemaVersion: 1,
            startedAt: startedAt,
            app: recordingAppInfo,
            events: events,
            droppedEventCount: droppedEventCount
        )
        try fileManager.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try DiagnosticJSON.encoder().encode(journal)
        try data.write(to: journalURL, options: .atomic)
    }

    private func appendEvent(_ event: DiagnosticTraceEvent) {
        events.append(event)
        let overflow = events.count - maxEventCount
        guard overflow > 0 else { return }
        events.removeFirst(overflow)
        droppedEventCount += overflow
    }

    private func nextExportURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "TencentVoiceMVP-Diagnostic-\(formatter.string(from: date))"
        var url = exportDirectoryURL.appendingPathComponent("\(stem).json")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = exportDirectoryURL.appendingPathComponent("\(stem)-\(suffix).json")
            suffix += 1
        }
        return url
    }

    private static func defaultExportDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
