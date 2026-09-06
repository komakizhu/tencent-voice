import Foundation

struct SessionLogEntry: Encodable, Sendable {
    let timestamp: Date
    let sessionID: UUID
    let event: String
    let state: String?
    let injectionMode: String?
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
}

final class SessionLogger {
    private let enabled: () -> Bool
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()

    init(enabled: @escaping () -> Bool) {
        self.enabled = enabled
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
    }

    func append(_ entry: SessionLogEntry) throws {
        guard enabled() else { return }
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = baseURL.appendingPathComponent("TencentVoiceMVP/sessions", isDirectory: true)
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
}
