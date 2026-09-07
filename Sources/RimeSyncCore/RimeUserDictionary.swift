import CryptoKit
import Foundation

public struct RimeUserDictionaryEntry: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let code: String
    public let commitCount: Int
    public let decay: Double
    public let tick: Int64

    public init(text: String, code: String, commitCount: Int, decay: Double = 0, tick: Int64 = 0) {
        self.text = text
        self.code = code
        // Negative c values are librime deletion tombstones.  They are
        // intentionally retained so the audit layer can remove a learned
        // entry without replacing the live userdb wholesale.
        self.commitCount = commitCount
        self.decay = decay
        self.tick = tick
    }

    public var identity: String { Self.identity(for: text, code: code) }
    public var isTombstone: Bool { commitCount < 0 }

    public static func identity(for text: String, code: String) -> String {
        let normalizedText = text
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let normalizedCode = code
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let data = Data((normalizedText + "\u{001F}" + normalizedCode).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RimeUserDictionarySnapshot: Equatable, Sendable {
    public let sourceInstallationID: String
    public let dictionaryName: String
    public let rimeVersion: String?
    public let tick: Int64?
    public let digest: String
    public let entries: [RimeUserDictionaryEntry]

    public init(
        sourceInstallationID: String,
        dictionaryName: String = "rime_ice",
        rimeVersion: String? = nil,
        tick: Int64? = nil,
        digest: String = "",
        entries: [RimeUserDictionaryEntry]
    ) {
        self.sourceInstallationID = sourceInstallationID
        self.dictionaryName = dictionaryName
        self.rimeVersion = rimeVersion
        self.tick = tick
        self.digest = digest
        self.entries = entries
    }

    public func serializedData() -> Data {
        var lines = [
            "# Rime user dictionary snapshot",
            "#@/db_name\t\(dictionaryName)",
            "#@/db_type\tuserdb"
        ]
        if let rimeVersion, !rimeVersion.isEmpty {
            lines.append("#@/rime_version\t\(rimeVersion)")
        }
        if let tick {
            lines.append("#@/tick\t\(tick)")
        }
        lines.append("#@/user_id\t\(sourceInstallationID)")
        lines.append(contentsOf: entries.sorted { lhs, rhs in
            if lhs.code != rhs.code { return lhs.code < rhs.code }
            return lhs.text < rhs.text
        }.map { entry in
            "\(entry.code)\t\(entry.text)\tc=\(entry.commitCount) d=\(formatDecimal(entry.decay)) t=\(entry.tick)"
        })
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func formatDecimal(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public struct RimeSnapshotParseReport: Equatable, Sendable {
    public let snapshot: RimeUserDictionarySnapshot
    public let ignoredRowCount: Int
    public let invalidHeaderCount: Int

    public init(snapshot: RimeUserDictionarySnapshot, ignoredRowCount: Int = 0, invalidHeaderCount: Int = 0) {
        self.snapshot = snapshot
        self.ignoredRowCount = ignoredRowCount
        self.invalidHeaderCount = invalidHeaderCount
    }
}

public enum RimeSnapshotParserError: LocalizedError, Equatable {
    case invalidEncoding
    case missingDatabaseHeader
    case wrongDatabase(String)
    case wrongDatabaseType(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "Rime 快照不是有效的 UTF-8"
        case .missingDatabaseHeader: return "Rime 快照缺少数据库表头"
        case let .wrongDatabase(name): return "不支持的 Rime 用户库：\(name)"
        case let .wrongDatabaseType(type): return "Rime 快照数据库类型无效：\(type)"
        }
    }
}

public struct RimeSnapshotParser: Sendable {
    public init() {}

    public func parse(data: Data, sourceInstallationID: String) throws -> RimeSnapshotParseReport {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RimeSnapshotParserError.invalidEncoding
        }

        var databaseName: String?
        var databaseType: String?
        var rimeVersion: String?
        var tick: Int64?
        var invalidHeaderCount = 0
        var ignoredRowCount = 0
        var entries: [RimeUserDictionaryEntry] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard !line.isEmpty, !line.hasPrefix("#") else {
                if line.hasPrefix("#@/") {
                    parseHeader(line, databaseName: &databaseName, databaseType: &databaseType, rimeVersion: &rimeVersion, tick: &tick, invalidHeaderCount: &invalidHeaderCount)
                }
                continue
            }

            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                ignoredRowCount += 1
                continue
            }
            let code = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let metadata = String(fields[2])
            guard RimeUserDictionaryValidator.isValidCode(code), !value.isEmpty,
                  let commitCount = integerValue(named: "c", in: metadata),
                  let decay = decimalValue(named: "d", in: metadata), decay.isFinite,
                  let rowTick = integerValue(named: "t", in: metadata) else {
                ignoredRowCount += 1
                continue
            }
            entries.append(RimeUserDictionaryEntry(text: value, code: code, commitCount: commitCount, decay: decay, tick: Int64(rowTick)))
        }

        guard let databaseName else { throw RimeSnapshotParserError.missingDatabaseHeader }
        guard databaseName == "rime_ice" || databaseName == "rime_ice.userdb" else { throw RimeSnapshotParserError.wrongDatabase(databaseName) }
        if let databaseType, databaseType != "userdb" {
            throw RimeSnapshotParserError.wrongDatabaseType(databaseType)
        }
        let digest = Self.digest(data)
        let snapshot = RimeUserDictionarySnapshot(
            sourceInstallationID: sourceInstallationID,
            dictionaryName: databaseName,
            rimeVersion: rimeVersion,
            tick: tick,
            digest: digest,
            entries: deduplicate(entries)
        )
        return RimeSnapshotParseReport(snapshot: snapshot, ignoredRowCount: ignoredRowCount, invalidHeaderCount: invalidHeaderCount)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func parseHeader(
        _ line: String,
        databaseName: inout String?,
        databaseType: inout String?,
        rimeVersion: inout String?,
        tick: inout Int64?,
        invalidHeaderCount: inout Int
    ) {
        let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2 else {
            invalidHeaderCount += 1
            return
        }
        let key = String(fields[0])
        let value = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "#@/db_name": databaseName = value
        case "#@/db_type": databaseType = value
        case "#@/rime_version": rimeVersion = value
        case "#@/tick":
            if let parsed = Int64(value) { tick = parsed } else { invalidHeaderCount += 1 }
        default: break
        }
    }

    private func deduplicate(_ entries: [RimeUserDictionaryEntry]) -> [RimeUserDictionaryEntry] {
        var result: [String: RimeUserDictionaryEntry] = [:]
        for entry in entries {
            if let old = result[entry.identity] {
                let oldRank = (abs(old.commitCount), old.tick)
                let newRank = (abs(entry.commitCount), entry.tick)
                if oldRank >= newRank { continue }
            }
            result[entry.identity] = entry
        }
        return result.values.sorted { lhs, rhs in
            if lhs.text != rhs.text { return lhs.text < rhs.text }
            return lhs.code < rhs.code
        }
    }

    private func integerValue(named name: String, in metadata: String) -> Int? {
        guard let value = value(named: name, in: metadata) else { return nil }
        return Int(value)
    }

    private func decimalValue(named name: String, in metadata: String) -> Double? {
        guard let value = value(named: name, in: metadata) else { return nil }
        return Double(value)
    }

    private func value(named name: String, in metadata: String) -> String? {
        let prefix = "\(name)="
        for token in metadata.split(whereSeparator: { $0 == " " || $0 == "\t" }) where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

}

public struct RimeManagedEntry: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let code: String
    public let frequency: Int

    public init(text: String, code: String, frequency: Int) {
        self.text = text
        self.code = code
        self.frequency = min(RimeManagedDictionary.maximumFrequency, max(1, frequency))
    }

    public var identity: String { RimeUserDictionaryEntry.identity(for: text, code: code) }
}

public struct RimeManagedEntryState: Codable, Equatable, Sendable {
    public let text: String
    public let code: String
    public var sourceFrequencies: [String: Int]

    public init(text: String, code: String, sourceFrequencies: [String: Int] = [:]) {
        self.text = text
        self.code = code
        self.sourceFrequencies = sourceFrequencies.mapValues { min(RimeManagedDictionary.maximumFrequency, max(0, $0)) }
    }

    public var identity: String { RimeUserDictionaryEntry.identity(for: text, code: code) }
    public var frequency: Int {
        // A static managed dictionary records membership, not historical
        // learning strength.  The live userdb remains the only source of
        // dynamic ranking, so duplicate observations are never summed here.
        sourceFrequencies.values.map { max(0, $0) }.max() ?? 1
    }
}

public struct RimeReviewState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var initialized: Bool
    public var entries: [String: RimeManagedEntryState]
    public var lastAppliedSnapshotDigests: [String: String]
    public var nodeObservations: [String: [String: RimeAuditObservation]]
    public var actions: [String: RimeAuditActionRecord]
    public var permanentIgnoredIDs: Set<String>
    public var pendingActions: [String: RimePendingAuditAction]
    public var proposals: [String: [RimeAuditProposal]]
    public var completedActions: [String: RimeCompletedAuditAction]
    public var replacementRecords: [String: RimeAuditReplacementRecord]
    public var backupIDs: [String]
    public var migration: RimeReviewMigration

    public init(
        schemaVersion: Int = 2,
        initialized: Bool = false,
        entries: [String: RimeManagedEntryState] = [:],
        lastAppliedSnapshotDigests: [String: String] = [:],
        nodeObservations: [String: [String: RimeAuditObservation]] = [:],
        actions: [String: RimeAuditActionRecord] = [:],
        permanentIgnoredIDs: Set<String> = [],
        pendingActions: [String: RimePendingAuditAction] = [:],
        proposals: [String: [RimeAuditProposal]] = [:],
        completedActions: [String: RimeCompletedAuditAction] = [:],
        replacementRecords: [String: RimeAuditReplacementRecord] = [:],
        backupIDs: [String] = [],
        migration: RimeReviewMigration = RimeReviewMigration()
    ) {
        self.schemaVersion = max(2, schemaVersion)
        self.initialized = initialized
        self.entries = entries
        self.lastAppliedSnapshotDigests = lastAppliedSnapshotDigests
        self.nodeObservations = nodeObservations
        self.actions = actions
        self.permanentIgnoredIDs = permanentIgnoredIDs
        self.pendingActions = pendingActions
        self.proposals = proposals
        self.completedActions = completedActions
        self.replacementRecords = replacementRecords
        self.backupIDs = backupIDs
        self.migration = migration
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, initialized, entries, lastAppliedSnapshotDigests
        case nodeObservations, actions, permanentIgnoredIDs, pendingActions
        case proposals, completedActions, replacementRecords, backupIDs, migration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let legacyEntries = try container.decodeIfPresent([String: RimeManagedEntryState].self, forKey: .entries) ?? [:]
        let legacyDigests = try container.decodeIfPresent([String: String].self, forKey: .lastAppliedSnapshotDigests) ?? [:]
        self.schemaVersion = 2
        self.initialized = try container.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
        self.entries = legacyEntries
        self.lastAppliedSnapshotDigests = legacyDigests
        self.nodeObservations = try container.decodeIfPresent([String: [String: RimeAuditObservation]].self, forKey: .nodeObservations) ?? [:]
        self.actions = try container.decodeIfPresent([String: RimeAuditActionRecord].self, forKey: .actions) ?? [:]
        self.permanentIgnoredIDs = try container.decodeIfPresent(Set<String>.self, forKey: .permanentIgnoredIDs) ?? []
        self.pendingActions = try container.decodeIfPresent([String: RimePendingAuditAction].self, forKey: .pendingActions) ?? [:]
        self.proposals = try container.decodeIfPresent([String: [RimeAuditProposal]].self, forKey: .proposals) ?? [:]
        self.completedActions = try container.decodeIfPresent([String: RimeCompletedAuditAction].self, forKey: .completedActions) ?? [:]
        self.replacementRecords = try container.decodeIfPresent([String: RimeAuditReplacementRecord].self, forKey: .replacementRecords) ?? [:]
        self.backupIDs = try container.decodeIfPresent([String].self, forKey: .backupIDs) ?? []
        var migration = try container.decodeIfPresent(RimeReviewMigration.self, forKey: .migration) ?? RimeReviewMigration()
        if version < 2 { migration.migratedFromSchemaVersion = version }
        self.migration = migration
    }
}

public struct RimeReviewStore {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> RimeReviewState {
        guard fileManager.fileExists(atPath: url.path) else { return RimeReviewState() }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder.rimeDecoder.decode(RimeReviewState.self, from: data)
        } catch {
            // A malformed state is safer as an explicit error than as an
            // empty state, which could make the manager appear to forget
            // permanent ignores.
            throw RimeSyncError.unsupportedOperation("Rime 审核状态无法读取：\(error.localizedDescription)")
        }
    }

    public func save(_ state: RimeReviewState) throws {
        try AtomicFileStore.write(JSONEncoder.rimeEncoder.encode(state), to: url, fileManager: fileManager)
        try SharedDirectoryLayout.makeGroupWritable(url, fileManager: fileManager)
    }
}

public enum RimeManagedDictionary {
    public static let fileName = "rime_managed.dict.yaml"
    public static let maximumFrequency = 10_000

    public static func entries(from state: RimeReviewState) -> [RimeManagedEntry] {
        state.entries.values.map { RimeManagedEntry(text: $0.text, code: $0.code, frequency: 1) }
            .sorted { lhs, rhs in
                if lhs.code != rhs.code { return lhs.code < rhs.code }
                return lhs.text < rhs.text
            }
    }

    public static func serializedData(from state: RimeReviewState) -> Data {
        var lines = [
            "# Rime managed dictionary",
            "# Generated by Rime Voice; edit through the Rime dictionary manager.",
            "---",
            "name: rime_managed",
            "version: \"1\"",
            "sort: by_weight",
            "..."
        ]
        lines.append(contentsOf: entries(from: state).map { "\($0.text)\t\($0.code)\t1" })
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func parse(data: Data) -> [RimeManagedEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [String: RimeManagedEntry] = [:]
        for line in text.components(separatedBy: .newlines) where !line.isEmpty && !line.hasPrefix("#") && line != "---" && line != "..." && !line.hasPrefix("name:") && !line.hasPrefix("version:") && !line.hasPrefix("sort:") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let word = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let code = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let frequency = fields.count >= 3 ? Int(fields[2]) ?? 1 : 1
            guard RimeUserDictionaryValidator.isValidWord(word), RimeUserDictionaryValidator.isValidCode(code) else { continue }
            let entry = RimeManagedEntry(text: word, code: code, frequency: frequency)
            if let old = result[entry.identity], old.frequency >= entry.frequency { continue }
            result[entry.identity] = entry
        }
        return result.values.sorted { $0.identity < $1.identity }
    }
}

public enum RimeUserDictionaryValidator {
    public static func isValidWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("\t") && !trimmed.contains("\n") && !trimmed.contains("\r")
    }

    public static func isValidCode(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\t"), !trimmed.contains("\n"), !trimmed.contains("\r") else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in isCodeScalar(scalar) }
    }

    private static func isCodeScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return scalar == " " || scalar == "'" || scalar == "_" || scalar == "-" || scalar == "ü" || scalar == "Ü"
        }
    }

    public static func frequency(_ value: Int?) throws -> Int {
        let result = value ?? 1
        guard result > 0, result <= RimeManagedDictionary.maximumFrequency else {
            throw RimeSyncError.unsupportedOperation("词条频率必须在 1 到 10000 之间")
        }
        return result
    }
}
