import Foundation

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
        metadata: [String: String] = [:]
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
        self.failureMessage = failureMessage.map {
            DiagnosticLogSanitizer.value($0, forKey: "failureMessage")
        }
        self.metadata = DiagnosticLogSanitizer.fields(metadata)
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
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage).map {
            DiagnosticLogSanitizer.value($0, forKey: "failureMessage")
        }
        metadata = DiagnosticLogSanitizer.fields(
            try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        )
    }
}

@MainActor
final class SessionLogger {
    private let enabled: () -> Bool
    private let fileManager = FileManager.default
    private let applicationSupportDirectoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var inMemoryEntries: [SessionLogEntry] = []
    private let diagnosticActionSessionID = UUID()
    private let inMemoryLimit = 300

    init(
        enabled: @escaping () -> Bool,
        applicationSupportDirectoryURL: URL? = nil
    ) {
        self.enabled = enabled
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        DiagnosticJSON.configureDateEncoding(for: encoder)
        DiagnosticJSON.configureDateDecoding(for: decoder)
    }

    func append(_ entry: SessionLogEntry) throws {
        inMemoryEntries.append(entry)
        if inMemoryEntries.count > inMemoryLimit {
            inMemoryEntries.removeFirst(inMemoryEntries.count - inMemoryLimit)
        }
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
        persistedEntries(limit: limit)
    }

    func allPersistedEntries() -> [SessionLogEntry] {
        persistedEntries(limit: nil)
    }

    private func persistedEntries(limit: Int?) -> [SessionLogEntry] {
        if let limit, limit <= 0 { return [] }
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
                if let limit, entries.count >= limit { return Array(entries.reversed()) }
            }
        }
        return Array(entries.reversed())
    }

    var persistenceDirectoryURL: URL {
        applicationSupportDirectoryURL
            .appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
    }

    func recordDiagnosticAction(
        _ name: String,
        sessionID: UUID? = nil,
        fields: [String: String] = [:]
    ) {
        let metadata = DiagnosticLogSanitizer.fields(fields)
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
