import Foundation

struct SessionLogEntry: Codable, Equatable, Sendable {
    let timestamp: Date
    let sessionID: UUID
    let eventID: UUID?
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

    init(
        timestamp: Date = Date(),
        sessionID: UUID = UUID(),
        eventID: UUID? = UUID(),
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
        failureMessage: String? = nil
    ) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.eventID = eventID
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
        self.failureMessage = failureMessage
    }
}

@MainActor
final class SessionLogger {
    private let enabled: () -> Bool
    private let fileManager = FileManager.default
    private let applicationSupportDirectoryURL: URL
    private let diagnosticExportDirectoryURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var inMemoryEntries: [SessionLogEntry] = []
    private var diagnosticRecorder: DiagnosticSessionRecorder?
    private let inMemoryLimit = 300

    init(
        enabled: @escaping () -> Bool,
        applicationSupportDirectoryURL: URL? = nil,
        diagnosticExportDirectoryURL: URL? = nil
    ) {
        self.enabled = enabled
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.diagnosticExportDirectoryURL = diagnosticExportDirectoryURL
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
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
    }

    func append(_ entry: SessionLogEntry) throws {
        inMemoryEntries.append(entry)
        if inMemoryEntries.count > inMemoryLimit {
            inMemoryEntries.removeFirst(inMemoryEntries.count - inMemoryLimit)
        }
        diagnosticRecorder?.recordSessionEntry(entry)
        guard enabled() else { return }
        let directory = applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let fileURL = directory.appendingPathComponent("\(formatter.string(from: entry.timestamp)).jsonl")
        var line = try encoder.encode(entry)
        line.append(0x0A)
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }

    func recentEntries(limit: Int = 120) -> [SessionLogEntry] {
        Array(inMemoryEntries.suffix(max(0, limit)))
    }

    func recentPersistedEntries(limit: Int = 120) -> [SessionLogEntry] {
        guard limit > 0 else { return [] }
        let directory = applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

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
                  let content = String(data: data, encoding: .utf8) else { continue }
            let lines = content.split(whereSeparator: \.isNewline).reversed()
            for line in lines {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(SessionLogEntry.self, from: lineData) else { continue }
                entries.append(entry)
                if entries.count >= limit { return Array(entries.reversed()) }
            }
        }
        return Array(entries.reversed())
    }

    var persistenceDirectoryURL: URL {
        applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
    }

    var isDiagnosticRecording: Bool {
        diagnosticRecorder?.isRecording == true
    }

    func startDiagnosticRecording(appInfo: DiagnosticAppInfo? = nil) throws {
        guard diagnosticRecorder?.isRecording != true else {
            throw DiagnosticRecordingError.alreadyRecording
        }
        let recorder = DiagnosticSessionRecorder(
            exportDirectoryURL: diagnosticExportDirectoryURL,
            journalURL: diagnosticJournalURL
        )
        try recorder.start(appInfo: appInfo ?? AppRuntimeInspector.inspect())
        diagnosticRecorder = recorder
    }

    func recordDiagnosticAction(
        _ name: String,
        sessionID: UUID? = nil,
        fields: [String: String] = [:]
    ) {
        diagnosticRecorder?.recordAction(
            name: name,
            sessionID: sessionID,
            fields: fields
        )
    }

    func stopDiagnosticRecordingAndExport(appInfo: DiagnosticAppInfo? = nil) throws -> URL {
        guard let diagnosticRecorder else {
            throw DiagnosticRecordingError.notRecording
        }
        let url = try diagnosticRecorder.stopAndExport(
            appInfo: appInfo ?? AppRuntimeInspector.inspect()
        )
        self.diagnosticRecorder = nil
        return url
    }

    @discardableResult
    func recoverInterruptedDiagnosticRecording(
        appInfo: DiagnosticAppInfo? = nil
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: diagnosticJournalURL.path) else {
            return nil
        }
        let recorder = DiagnosticSessionRecorder(
            exportDirectoryURL: diagnosticExportDirectoryURL,
            journalURL: diagnosticJournalURL
        )
        return try recorder.recoverInterruptedRecording(
            appInfo: appInfo ?? AppRuntimeInspector.inspect()
        )
    }

    private var diagnosticJournalURL: URL {
        applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/diagnostics/active.json")
    }
}
