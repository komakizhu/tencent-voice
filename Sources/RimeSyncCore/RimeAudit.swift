import CryptoKit
import Foundation

// MARK: - librime scoring

/// The two dynamics functions used by librime's user dictionary.  Keeping
/// these functions in the core makes the UI's “有效热度” an observation of
/// Rime's own values rather than a second, unrelated ranking algorithm.
public enum RimeScoring {
    public static func formulaD(d: Double, t: Double, da: Double, ta: Double) -> Double {
        guard d.isFinite, da.isFinite, t.isFinite, ta.isFinite else { return 0 }
        let result = d + da * exp((ta - t) / 200.0)
        return result.isFinite ? max(0, result) : 0
    }

    public static func formulaP(s: Double, u: Double, t: Double, d: Double) -> Double {
        guard s.isFinite, u.isFinite, t.isFinite, d.isFinite else { return 0 }
        let kM = 1.0 / (1.0 - exp(-0.005))
        let m = s - (s - u) * pow(1.0 - exp(-t / 10_000.0), 10.0)
        let result: Double
        if d < 20 {
            result = m + (0.5 - m) * (d / kM)
        } else {
            result = m + (1.0 - m) * (pow(4.0, d / kM) - 1.0) / 3.0
        }
        return result.isFinite ? max(0, result) : 0
    }

    public static func metrics(for entry: RimeUserDictionaryEntry, snapshotTick: Int64?) -> (effectiveDecay: Double, rimeScore: Double) {
        guard !entry.isTombstone else { return (0, 0) }
        let tick = max(1, snapshotTick ?? entry.tick)
        let effectiveDecay = formulaD(
            d: 0,
            t: Double(tick),
            da: entry.decay,
            ta: Double(entry.tick)
        )
        let score = formulaP(
            s: 0,
            u: Double(entry.commitCount) / Double(tick),
            t: Double(tick),
            d: effectiveDecay
        )
        return (effectiveDecay, score)
    }
}

// MARK: - Review state

public enum RimeAuditAction: String, Codable, CaseIterable, Sendable {
    case keepDynamic = "keep_dynamic"
    case promotePermanent = "promote_permanent"
    case deleteLearned = "delete_learned"
    case skipOnce = "skip_once"
    case ignorePermanent = "ignore_permanent"
    case reviewManually = "review_manually"

    public var displayName: String {
        switch self {
        case .keepDynamic: return "保留动态学习"
        case .promotePermanent: return "加入长期记忆"
        case .deleteLearned: return "删除错误学习"
        case .skipOnce: return "本次跳过"
        case .ignorePermanent: return "永久忽略"
        case .reviewManually: return "需要人工确认"
        }
    }

    public var isProposalAction: Bool { self != .skipOnce }
}

public enum RimeAuditStatus: String, Codable, Sendable {
    case dynamic
    case newRecord = "new"
    case changed
    case permanent
    case ignored
    case pending
    case manualReview = "manual_review"
    case deleted
}

public struct RimeAuditObservation: Codable, Equatable, Sendable {
    public let text: String
    public let code: String
    public var commitCount: Int
    public var decay: Double
    public var tick: Int64
    public var effectiveDecay: Double
    public var rimeScore: Double
    public var snapshotDigest: String
    public var firstSeenAt: Date?
    public var lastObservedAt: Date
    public var lastActivityAt: Date?

    public init(
        text: String,
        code: String,
        commitCount: Int,
        decay: Double,
        tick: Int64,
        effectiveDecay: Double,
        rimeScore: Double,
        snapshotDigest: String,
        firstSeenAt: Date? = nil,
        lastObservedAt: Date = Date(),
        lastActivityAt: Date? = nil
    ) {
        self.text = text
        self.code = code
        self.commitCount = commitCount
        self.decay = decay
        self.tick = tick
        self.effectiveDecay = effectiveDecay
        self.rimeScore = rimeScore
        self.snapshotDigest = snapshotDigest
        self.firstSeenAt = firstSeenAt
        self.lastObservedAt = lastObservedAt
        self.lastActivityAt = lastActivityAt
    }
}

public struct RimeAuditActionRecord: Codable, Equatable, Sendable {
    public let action: RimeAuditAction
    public let sourceNode: String
    public let batchID: String
    public let snapshotDigest: String
    public let recordedAt: Date
    public let backupID: String?
    public let commitCounts: [String: Int]

    public init(
        action: RimeAuditAction,
        sourceNode: String,
        batchID: String,
        snapshotDigest: String,
        recordedAt: Date = Date(),
        backupID: String? = nil,
        commitCounts: [String: Int] = [:]
    ) {
        self.action = action
        self.sourceNode = sourceNode
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.recordedAt = recordedAt
        self.backupID = backupID
        self.commitCounts = commitCounts
    }

    private enum CodingKeys: String, CodingKey {
        case action, sourceNode, batchID, snapshotDigest, recordedAt, backupID, commitCounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(RimeAuditAction.self, forKey: .action)
        self.sourceNode = try container.decode(String.self, forKey: .sourceNode)
        self.batchID = try container.decode(String.self, forKey: .batchID)
        self.snapshotDigest = try container.decode(String.self, forKey: .snapshotDigest)
        self.recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        self.backupID = try container.decodeIfPresent(String.self, forKey: .backupID)
        self.commitCounts = try container.decodeIfPresent([String: Int].self, forKey: .commitCounts) ?? [:]
    }
}

public struct RimePendingAuditAction: Codable, Equatable, Sendable {
    public let action: RimeAuditAction
    public var targetSourceIDs: [String]
    public var approvedCommitCounts: [String: Int]
    public let batchID: String
    public let snapshotDigest: String
    public let createdAt: Date

    public init(
        action: RimeAuditAction,
        targetSourceIDs: [String],
        approvedCommitCounts: [String: Int] = [:],
        batchID: String,
        snapshotDigest: String,
        createdAt: Date = Date()
    ) {
        self.action = action
        self.targetSourceIDs = Array(Set(targetSourceIDs)).sorted()
        self.approvedCommitCounts = approvedCommitCounts
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.createdAt = createdAt
    }
}

public struct RimeCompletedAuditAction: Codable, Equatable, Sendable {
    public let action: RimeAuditAction
    public let nodeID: String
    public let backupID: String?
    public let completedAt: Date

    public init(action: RimeAuditAction, nodeID: String, backupID: String? = nil, completedAt: Date = Date()) {
        self.action = action
        self.nodeID = nodeID
        self.backupID = backupID
        self.completedAt = completedAt
    }
}

public struct RimeReviewMigration: Codable, Equatable, Sendable {
    public var migratedFromSchemaVersion: Int?
    public var legacyManagedEntries: Int

    public init(migratedFromSchemaVersion: Int? = nil, legacyManagedEntries: Int = 0) {
        self.migratedFromSchemaVersion = migratedFromSchemaVersion
        self.legacyManagedEntries = legacyManagedEntries
    }
}

public struct RimeAuditEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let code: String
    public let observations: [String: RimeAuditObservation]
    public let commitCount: Int
    public let decay: Double
    public let tick: Int64
    public let effectiveDecay: Double
    public let rimeScore: Double
    public let inBaseDictionary: Bool
    public let firstSeenAt: Date?
    public let lastActivityAt: Date?
    public let currentStatus: RimeAuditStatus
    public let isNoise: Bool
    public let isStale: Bool

    public init(
        id: String,
        text: String,
        code: String,
        observations: [String: RimeAuditObservation],
        commitCount: Int,
        decay: Double,
        tick: Int64,
        effectiveDecay: Double,
        rimeScore: Double,
        inBaseDictionary: Bool,
        firstSeenAt: Date?,
        lastActivityAt: Date?,
        currentStatus: RimeAuditStatus,
        isNoise: Bool = false,
        isStale: Bool = false
    ) {
        self.id = id
        self.text = text
        self.code = code
        self.observations = observations
        self.commitCount = commitCount
        self.decay = decay
        self.tick = tick
        self.effectiveDecay = effectiveDecay
        self.rimeScore = rimeScore
        self.inBaseDictionary = inBaseDictionary
        self.firstSeenAt = firstSeenAt
        self.lastActivityAt = lastActivityAt
        self.currentStatus = currentStatus
        self.isNoise = isNoise
        self.isStale = isStale
    }

    public var sourceNodes: [String] { observations.keys.sorted() }
    public var sourceInstallationIDs: [String] { sourceNodes }
    public var isTombstone: Bool { commitCount < 0 }
}

public struct RimeAuditBatch: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let batchID: String
    public let snapshotDigest: String
    public let snapshotDigests: [String: String]
    public let entries: [RimeAuditEntry]
    public let createdAt: Date
    public let isInitialBaseline: Bool

    public init(
        schemaVersion: Int = 2,
        batchID: String = UUID().uuidString,
        snapshotDigest: String,
        snapshotDigests: [String: String],
        entries: [RimeAuditEntry],
        createdAt: Date = Date(),
        isInitialBaseline: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.snapshotDigests = snapshotDigests
        self.entries = entries
        self.createdAt = createdAt
        self.isInitialBaseline = isInitialBaseline
    }

    /// Computes the digest used by both the coordinator and the read-only
    /// MCP server. Sorting source IDs makes it independent of directory order.
    public static func aggregateSnapshotDigest(_ digests: [String: String]) -> String {
        let data = digests.keys.sorted().map { "\($0)=\(digests[$0] ?? "")" }.joined(separator: "\n")
        return SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RimeAuditProposal: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let batchID: String
    public let snapshotDigest: String
    public let entryID: String
    public let action: RimeAuditAction
    public let confidence: Double
    public let reason: String

    public init(
        schemaVersion: Int = 2,
        batchID: String,
        snapshotDigest: String,
        entryID: String,
        action: RimeAuditAction,
        confidence: Double,
        reason: String
    ) throws {
        guard action.isProposalAction else {
            throw RimeSyncError.unsupportedOperation("AI 提案不允许使用本次跳过")
        }
        guard (0...1).contains(confidence) else {
            throw RimeSyncError.unsupportedOperation("AI 置信度必须在 0 到 1 之间")
        }
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.entryID = entryID
        self.action = action
        self.confidence = confidence
        self.reason = reason
    }
}

public struct RimeAuditPreview: Codable, Equatable, Sendable {
    public let batchID: String
    public let snapshotDigest: String
    public let countsByAction: [String: Int]
    public let proposalCount: Int
    public let stale: Bool

    public init(batchID: String, snapshotDigest: String, countsByAction: [String: Int], proposalCount: Int, stale: Bool) {
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.countsByAction = countsByAction
        self.proposalCount = proposalCount
        self.stale = stale
    }
}

// MARK: - Query and cached filtering

public enum RimeAuditView: String, Codable, CaseIterable, Sendable {
    case recommendations
    case recent
    case noise
    case permanent
    case ignored
    case all

    public var displayName: String {
        switch self {
        case .recommendations: return "建议处理"
        case .recent: return "最近活动"
        case .noise: return "疑似噪音"
        case .permanent: return "长期记忆"
        case .ignored: return "永久忽略"
        case .all: return "全部记录"
        }
    }
}

public enum RimeCommitCountBand: String, Codable, CaseIterable, Sendable {
    case all
    case atLeast3 = "3"
    case atLeast10 = "10"
    case atLeast30 = "30"
    case atLeast100 = "100"

    public var minimum: Int {
        switch self {
        case .all: return 0
        case .atLeast3: return 3
        case .atLeast10: return 10
        case .atLeast30: return 30
        case .atLeast100: return 100
        }
    }
}

public enum RimeHeatBand: String, Codable, CaseIterable, Sendable {
    case all
    case top50 = "top_50"
    case top25 = "top_25"
    case top10 = "top_10"
    case top1 = "top_1"

    public var percentile: Double? {
        switch self {
        case .all: return nil
        case .top50: return 0.50
        case .top25: return 0.75
        case .top10: return 0.90
        case .top1: return 0.99
        }
    }
}

public enum RimeRecentActivityBand: String, Codable, CaseIterable, Sendable {
    case all
    case year
    case sixMonths = "six_months"
    case month
    case week

    public func cutoff(from date: Date) -> Date? {
        let seconds: TimeInterval
        switch self {
        case .all: return nil
        case .year: seconds = 365 * 24 * 60 * 60
        case .sixMonths: seconds = 182 * 24 * 60 * 60
        case .month: seconds = 30 * 24 * 60 * 60
        case .week: seconds = 7 * 24 * 60 * 60
        }
        return date.addingTimeInterval(-seconds)
    }
}

public enum RimeAuditSortKey: String, Codable, CaseIterable, Sendable {
    case heat
    case commitCount
    case activity
    case text
    case code
}

public struct RimeAuditQuery: Codable, Equatable, Sendable {
    public var view: RimeAuditView
    public var commitBand: RimeCommitCountBand
    public var heatBand: RimeHeatBand
    public var activityBand: RimeRecentActivityBand
    public var search: String
    public var sortKey: RimeAuditSortKey
    public var ascending: Bool
    public var offset: Int
    public var limit: Int?
    public var includeStale: Bool

    public init(
        view: RimeAuditView = .recommendations,
        commitBand: RimeCommitCountBand = .all,
        heatBand: RimeHeatBand = .all,
        activityBand: RimeRecentActivityBand = .all,
        search: String = "",
        sortKey: RimeAuditSortKey = .heat,
        ascending: Bool = false,
        offset: Int = 0,
        limit: Int? = nil,
        includeStale: Bool = false
    ) {
        self.view = view
        self.commitBand = commitBand
        self.heatBand = heatBand
        self.activityBand = activityBand
        self.search = search
        self.sortKey = sortKey
        self.ascending = ascending
        self.offset = max(0, offset)
        self.limit = limit.map { max(0, $0) }
        self.includeStale = includeStale
    }
}

public struct RimeAuditFilterResult: Equatable, Sendable {
    public let entries: [RimeAuditEntry]
    public let heatThreshold: Double?
    public let totalBeforePaging: Int

    public init(entries: [RimeAuditEntry], heatThreshold: Double?, totalBeforePaging: Int) {
        self.entries = entries
        self.heatThreshold = heatThreshold
        self.totalBeforePaging = totalBeforePaging
    }
}

public enum RimeAuditFilter {
    public static func filter(_ entries: [RimeAuditEntry], query: RimeAuditQuery, now: Date = Date()) -> RimeAuditFilterResult {
        let needle = query.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = entries.filter { entry in
            switch query.view {
            case .recommendations:
                guard entry.currentStatus == .newRecord || entry.currentStatus == .changed || entry.currentStatus == .pending || entry.currentStatus == .manualReview else { return false }
                guard !entry.isNoise else { return false }
            case .recent:
                guard entry.lastActivityAt != nil else { return false }
            case .noise:
                guard entry.isNoise || entry.isStale else { return false }
            case .permanent:
                guard entry.currentStatus == .permanent else { return false }
            case .ignored:
                guard entry.currentStatus == .ignored else { return false }
            case .all: break
            }
            guard query.commitBand == .all || entry.commitCount >= query.commitBand.minimum else { return false }
            if let cutoff = query.activityBand.cutoff(from: now) {
                guard let activity = entry.lastActivityAt, activity >= cutoff else { return false }
            }
            if !query.includeStale, query.view != .noise, entry.isStale { return false }
            guard needle.isEmpty || entry.text.lowercased().contains(needle) || entry.code.lowercased().contains(needle) else { return false }
            return true
        }

        let distribution = result.map(\.rimeScore).sorted()
        let threshold = query.heatBand.percentile.flatMap { percentileValue($0, in: distribution) }
        if let threshold {
            result = result.filter { $0.rimeScore >= threshold }
        }
        result.sort { lhs, rhs in
            let comparison: ComparisonResult
            switch query.sortKey {
            case .heat: comparison = lhs.rimeScore.compare(to: rhs.rimeScore)
            case .commitCount: comparison = lhs.commitCount.compare(to: rhs.commitCount)
            case .activity: comparison = (lhs.lastActivityAt ?? .distantPast).compare(to: rhs.lastActivityAt ?? .distantPast)
            case .text: comparison = lhs.text.compare(to: rhs.text)
            case .code: comparison = lhs.code.compare(to: rhs.code)
            }
            if comparison == .orderedSame { return lhs.id < rhs.id }
            return query.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        let total = result.count
        let start = min(query.offset, result.count)
        let end = query.limit.map { min(result.count, start + $0) } ?? result.count
        return RimeAuditFilterResult(entries: Array(result[start..<end]), heatThreshold: threshold, totalBeforePaging: total)
    }

    private static func percentileValue(_ percentile: Double, in sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = percentile * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

private extension Comparable {
    func compare(to other: Self) -> ComparisonResult {
        if self < other { return .orderedAscending }
        if self > other { return .orderedDescending }
        return .orderedSame
    }
}

// MARK: - Static dictionary index

public struct RimeBaseDictionaryIndex: Equatable, Sendable {
    public let sourceDigest: String
    private let identities: Set<String>

    public init(sourceDigest: String, identities: Set<String>) {
        self.sourceDigest = sourceDigest
        self.identities = identities
    }

    public func contains(text: String, code: String) -> Bool {
        identities.contains(RimeUserDictionaryEntry.identity(for: text, code: code))
    }

    public var count: Int { identities.count }

    public static func sourceDigest(
        from rimeDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let files = try dictionaryFiles(from: rimeDirectory, fileManager: fileManager)
        return try digest(files: files, fileManager: fileManager)
    }

    public static func build(from rimeDirectory: URL, fileManager: FileManager = .default) throws -> RimeBaseDictionaryIndex {
        let files = try dictionaryFiles(from: rimeDirectory, fileManager: fileManager)
        var identities = Set<String>()
        var digestData = Data()
        for file in files {
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            digestData.append(Data(file.path.utf8))
            digestData.append(data)
            guard let content = String(data: data, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) {
                guard !line.isEmpty, !line.hasPrefix("#"), line != "---", line != "...",
                      !line.hasPrefix("name:"), !line.hasPrefix("version:"), !line.hasPrefix("sort:"),
                      !line.hasPrefix("import_tables:") else { continue }
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 2 else { continue }
                let word = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let code = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard RimeUserDictionaryValidator.isValidWord(word), RimeUserDictionaryValidator.isValidCode(code) else { continue }
                identities.insert(RimeUserDictionaryEntry.identity(for: word, code: code))
            }
        }
        let digest = digest(data: digestData)
        return RimeBaseDictionaryIndex(sourceDigest: digest, identities: identities)
    }

    private static func digest(files: [URL], fileManager: FileManager) throws -> String {
        var digestData = Data()
        for file in files {
            digestData.append(Data(file.path.utf8))
            digestData.append(try Data(contentsOf: file, options: [.mappedIfSafe]))
        }
        return digest(data: digestData)
    }

    private static func digest(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func dictionaryFiles(from root: URL, fileManager: FileManager) throws -> [URL] {
        let main = root.appendingPathComponent("rime_ice.dict.yaml")
        guard fileManager.fileExists(atPath: main.path) else { return [] }
        var result: [URL] = []
        var pending = [main]
        var visited = Set<String>()
        while let file = pending.popLast() {
            let canonical = file.standardizedFileURL.path
            guard visited.insert(canonical).inserted else { continue }
            guard file.lastPathComponent != RimeManagedDictionary.fileName,
                  fileManager.fileExists(atPath: file.path) else { continue }
            result.append(file)
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { continue }
                let importedName = trimmed.dropFirst(2).split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !importedName.isEmpty, !importedName.contains("rime_managed") else { continue }
                let imported = importedName.hasSuffix(".dict.yaml")
                    ? root.appendingPathComponent(importedName)
                    : root.appendingPathComponent(importedName).appendingPathExtension("dict.yaml")
                if fileManager.fileExists(atPath: imported.path) { pending.append(imported) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}

public final class RimeBaseDictionaryIndexCache: @unchecked Sendable {
    private let fileManager: FileManager
    private var cachedDirectory: URL?
    private var cachedSourceDigest: String?
    private var cachedIndex: RimeBaseDictionaryIndex?
    private let lock = NSLock()

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func index(for directory: URL) throws -> RimeBaseDictionaryIndex {
        lock.lock(); defer { lock.unlock() }
        let normalizedDirectory = directory.standardizedFileURL
        let sourceDigest = try RimeBaseDictionaryIndex.sourceDigest(
            from: normalizedDirectory,
            fileManager: fileManager
        )
        if cachedDirectory == normalizedDirectory,
           cachedSourceDigest == sourceDigest,
           let cachedIndex
        {
            return cachedIndex
        }
        let index = try RimeBaseDictionaryIndex.build(from: directory, fileManager: fileManager)
        cachedDirectory = normalizedDirectory
        cachedSourceDigest = sourceDigest
        cachedIndex = index
        return index
    }
}

// MARK: - CSV interchange

public enum RimeAuditCSV {
    public static let headers = [
        "schema_version", "batch_id", "snapshot_digest", "entry_id", "text", "code", "sources",
        "c", "d", "t", "effective_decay", "rime_score", "in_base_dictionary", "first_seen_at",
        "last_activity_at", "current_status"
    ]
    public static let proposalHeaders = ["schema_version", "batch_id", "snapshot_digest", "entry_id", "action", "confidence", "reason"]

    public static func export(batch: RimeAuditBatch) -> Data {
        var rows = [headers]
        for entry in batch.entries.sorted(by: { $0.id < $1.id }) {
            rows.append([
                "\(batch.schemaVersion)", batch.batchID, batch.snapshotDigest, entry.id, entry.text, entry.code,
                entry.sourceNodes.joined(separator: ";"), "\(entry.commitCount)", format(entry.decay), "\(entry.tick)",
                format(entry.effectiveDecay), format(entry.rimeScore), entry.inBaseDictionary ? "true" : "false",
                iso(entry.firstSeenAt), iso(entry.lastActivityAt), entry.currentStatus.rawValue
            ])
        }
        return Data(rows.map(encodeRow).joined(separator: "\r\n").appending("\r\n").utf8)
    }

    public static func exportProposals(_ proposals: [RimeAuditProposal]) -> Data {
        var rows = [proposalHeaders]
        rows.append(contentsOf: proposals.map { proposal in
            ["\(proposal.schemaVersion)", proposal.batchID, proposal.snapshotDigest, proposal.entryID, proposal.action.rawValue, format(proposal.confidence), proposal.reason]
        })
        return Data(rows.map(encodeRow).joined(separator: "\r\n").appending("\r\n").utf8)
    }

    public static func importProposals(data: Data, batch: RimeAuditBatch) throws -> [RimeAuditProposal] {
        guard let text = String(data: data, encoding: .utf8) else { throw RimeSyncError.unsupportedOperation("AI 提案不是有效的 UTF-8 CSV") }
        let rows = try decode(text)
        guard let rawHeader = rows.first else { throw RimeSyncError.unsupportedOperation("AI 提案 CSV 缺少表头") }
        let header = rawHeader.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard header == proposalHeaders else { throw RimeSyncError.unsupportedOperation("AI 提案 CSV 表头不匹配") }
        let validIDs = Set(batch.entries.map(\.id))
        var seen = Set<String>()
        var result: [RimeAuditProposal] = []
        for row in rows.dropFirst() {
            guard row.count == proposalHeaders.count else { throw RimeSyncError.unsupportedOperation("AI 提案 CSV 字段数错误") }
            guard Int(row[0]) == batch.schemaVersion, row[1] == batch.batchID, row[2] == batch.snapshotDigest else { throw RimeSyncError.unsupportedOperation("AI 提案批次或快照已过期") }
            guard validIDs.contains(row[3]) else { throw RimeSyncError.unsupportedOperation("AI 提案包含未知词条 ID") }
            guard seen.insert(row[3]).inserted else { throw RimeSyncError.unsupportedOperation("AI 提案包含重复词条 ID") }
            guard let action = RimeAuditAction(rawValue: row[4]), action.isProposalAction else { throw RimeSyncError.unsupportedOperation("AI 提案动作无效") }
            guard let confidence = Double(row[5]), (0...1).contains(confidence) else { throw RimeSyncError.unsupportedOperation("AI 提案置信度无效") }
            result.append(try RimeAuditProposal(batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, entryID: row[3], action: action, confidence: confidence, reason: row[6]))
        }
        return result
    }

    private static func encodeRow(_ fields: [String]) -> String {
        fields.map { field in
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return (escaped.contains(",") || escaped.contains("\"") || escaped.contains("\r") || escaped.contains("\n")) ? "\"\(escaped)\"" : escaped
        }.joined(separator: ",")
    }

    private static func decode(_ text: String) throws -> [[String]] {
        let bytes = Array(text.utf8)
        var rows: [[String]] = [[]]
        var field = Data()
        var quoted = false
        var index = 0
        func finishField() {
            rows[rows.count - 1].append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func finishRow() {
            finishField()
            rows.append([])
        }
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 34 {
                    if index + 1 < bytes.count, bytes[index + 1] == 34 {
                        field.append(34)
                        index += 2
                    } else {
                        quoted = false
                        index += 1
                    }
                } else {
                    field.append(byte)
                    index += 1
                }
            } else {
                switch byte {
                case 34 where field.isEmpty:
                    quoted = true
                    index += 1
                case 44:
                    finishField()
                    index += 1
                case 13:
                    finishRow()
                    index += (index + 1 < bytes.count && bytes[index + 1] == 10) ? 2 : 1
                case 10:
                    finishRow()
                    index += 1
                default:
                    field.append(byte)
                    index += 1
                }
            }
        }
        guard !quoted else { throw RimeSyncError.unsupportedOperation("CSV 引号未闭合") }
        if rows.last?.isEmpty == true {
            rows.removeLast()
        } else if !rows[rows.count - 1].isEmpty || !field.isEmpty {
            finishField()
        }
        return rows
    }

    private static func format(_ value: Double) -> String { String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func iso(_ date: Date?) -> String { date.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
}

// MARK: - Shared batch storage

public struct RimeAuditBatchStore {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) { self.url = url; self.fileManager = fileManager }

    public func load() throws -> RimeAuditBatch? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.rimeDecoder.decode(RimeAuditBatch.self, from: Data(contentsOf: url))
    }

    public func save(_ batch: RimeAuditBatch) throws {
        try AtomicFileStore.write(JSONEncoder.rimeEncoder.encode(batch), to: url, fileManager: fileManager)
        try SharedDirectoryLayout.makeGroupWritable(url, fileManager: fileManager)
    }
}

// MARK: - Legacy compatibility and coordinator

public enum RimeReviewChangeKind: String, Codable, Sendable {
    case new
    case changed
    case unchanged
}

public struct RimeReviewCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let code: String
    public let incomingEntries: [String: RimeUserDictionaryEntry]
    public let currentFrequency: Int
    public let changeKind: RimeReviewChangeKind
    public let effectiveDecay: Double
    public let rimeScore: Double

    public init(
        text: String,
        code: String,
        incomingEntries: [String: RimeUserDictionaryEntry],
        currentFrequency: Int,
        changeKind: RimeReviewChangeKind,
        effectiveDecay: Double = 0,
        rimeScore: Double = 0
    ) {
        self.id = RimeUserDictionaryEntry.identity(for: text, code: code)
        self.text = text
        self.code = code
        self.incomingEntries = incomingEntries
        self.currentFrequency = currentFrequency
        self.changeKind = changeKind
        self.effectiveDecay = effectiveDecay
        self.rimeScore = rimeScore
    }

    public var sourceInstallationIDs: [String] { incomingEntries.keys.sorted() }
    public var incomingFrequency: Int { incomingEntries.values.map(\.commitCount).max() ?? 0 }
}

public struct RimeReviewSession: Equatable, Sendable {
    public let isInitial: Bool
    public let candidates: [RimeReviewCandidate]
    public let snapshotDigests: [String: String]
    public let batchID: String

    public init(isInitial: Bool, candidates: [RimeReviewCandidate], snapshotDigests: [String: String], batchID: String = "") {
        self.isInitial = isInitial
        self.candidates = candidates
        self.snapshotDigests = snapshotDigests
        self.batchID = batchID
    }
}

public struct RimeReviewApplyReport: Equatable, Sendable {
    public let importedCount: Int
    public let skippedCount: Int
    public let backupID: String
    public let initialRuntimeRebuilt: Bool
    public let ordinarySync: SyncReport?
    public let deletedCount: Int
    public let ignoredCount: Int

    public init(importedCount: Int, skippedCount: Int, backupID: String, initialRuntimeRebuilt: Bool, ordinarySync: SyncReport?, deletedCount: Int = 0, ignoredCount: Int = 0) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.backupID = backupID
        self.initialRuntimeRebuilt = initialRuntimeRebuilt
        self.ordinarySync = ordinarySync
        self.deletedCount = deletedCount
        self.ignoredCount = ignoredCount
    }
}

public protocol RimeUserDictionaryMaintaining {
    func captureUserDictionarySnapshot(in rimeDirectory: URL) throws
    func restoreUserDictionarySnapshot(from snapshot: URL, in rimeDirectory: URL) throws
}

public extension RimeUserDictionaryMaintaining {
    /// Kept as a separate semantic operation even for older test doubles.
    /// SquirrelMaintenance overrides it with `rime_dict_manager --backup`.
    func backupUserDictionary(in rimeDirectory: URL) throws {
        try captureUserDictionarySnapshot(in: rimeDirectory)
    }
}

public final class RimeReviewSyncCoordinator: @unchecked Sendable {
    public let configuration: SyncConfiguration
    private let maintenance: any RimeUserDictionaryMaintaining
    private let reloader: any NativeRimeMaintaining
    private let ordinarySync: any RimeSyncEngine
    private let fileManager: FileManager
    private let parser = RimeSnapshotParser()
    private let reviewStore: RimeReviewStore
    private let batchStore: RimeAuditBatchStore
    private let backupManager: RimeBackupManager
    private let baseDictionaryCache: RimeBaseDictionaryIndexCache
    private let now: () -> Date

    public init(
        configuration: SyncConfiguration,
        maintenance: any RimeUserDictionaryMaintaining,
        reloader: any NativeRimeMaintaining,
        ordinarySync: any RimeSyncEngine,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.maintenance = maintenance
        self.reloader = reloader
        self.ordinarySync = ordinarySync
        self.fileManager = fileManager
        self.now = now
        reviewStore = RimeReviewStore(url: configuration.sharedRoot.appendingPathComponent("config/rime-review-state.json"), fileManager: fileManager)
        batchStore = RimeAuditBatchStore(url: configuration.sharedRoot.appendingPathComponent("config/rime-audit-batch.json"), fileManager: fileManager)
        backupManager = RimeBackupManager(fileManager: fileManager)
        baseDictionaryCache = RimeBaseDictionaryIndexCache(fileManager: fileManager)
    }

    public func prepareAudit() throws -> RimeAuditBatch {
        try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
        // This synchronizes ordinary YAML/resources only.  Its inventory
        // excludes userdb and the generated managed dictionary.
        _ = try ordinarySync.sync(dryRun: false)
        try maintenance.backupUserDictionary(in: configuration.localRimeDirectory)
        try publishCurrentSnapshot()
        let snapshots = try loadSnapshots()
        guard !snapshots.isEmpty else { throw RimeSyncError.unsupportedOperation("没有找到 rime_ice.userdb 快照，请先生成当前用户库备份") }

        var state = try normalizedState()
        let wasInitialized = state.initialized
        let timestamp = now()
        ingest(snapshots, into: &state, baseline: !wasInitialized, observedAt: timestamp)
        state.initialized = true
        try reviewStore.save(state)
        try applyPendingActionsIfNeeded(state: &state, snapshots: snapshots)
        // Pending actions may have been removed because the target already
        // contained a tombstone or no longer contained the entry. Save
        // unconditionally so those transitions are not lost.
        try reviewStore.save(state)
        try ensureManagedDictionaryImported()
        try writeManagedDictionary(from: state)

        let baseIndex = try? baseDictionaryCache.index(for: configuration.localRimeDirectory)
        let entries = makeAuditEntries(state: state, baseIndex: baseIndex)
        let digests = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceInstallationID, $0.digest) })
        let batch = RimeAuditBatch(
            snapshotDigest: aggregateDigest(digests),
            snapshotDigests: digests,
            entries: entries,
            createdAt: timestamp,
            isInitialBaseline: !wasInitialized
        )
        try batchStore.save(batch)
        return batch
    }

    /// Compatibility API for the first UI prototype.  New code should use
    /// `prepareAudit`, which does not present every historical row as an
    /// import checkbox.
    public func prepareReview() throws -> RimeReviewSession {
        let batch = try prepareAudit()
        let snapshots = try loadSnapshots()
        let byID = Dictionary(uniqueKeysWithValues: snapshots.flatMap { snapshot in
            snapshot.entries.map { ($0.identity + "\u{0000}" + snapshot.sourceInstallationID, $0) }
        }.map { ($0.0, $0.1) })
        let candidates = batch.entries.map { entry in
            let incoming = Dictionary(uniqueKeysWithValues: batch.snapshotDigests.keys.compactMap { source in
                byID[entry.id + "\u{0000}" + source].map { (source, $0) }
            })
            let kind: RimeReviewChangeKind
            switch entry.currentStatus {
            case .newRecord: kind = .new
            case .changed, .pending, .manualReview: kind = .changed
            default: kind = .unchanged
            }
            return RimeReviewCandidate(text: entry.text, code: entry.code, incomingEntries: incoming, currentFrequency: entry.commitCount, changeKind: kind, effectiveDecay: entry.effectiveDecay, rimeScore: entry.rimeScore)
        }
        return RimeReviewSession(isInitial: batch.isInitialBaseline, candidates: candidates, snapshotDigests: batch.snapshotDigests, batchID: batch.batchID)
    }

    public func apply(batch: RimeAuditBatch, actions: [String: RimeAuditAction]) throws -> RimeReviewApplyReport {
        let snapshots = try loadSnapshots()
        let digests = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceInstallationID, $0.digest) })
        guard digests == batch.snapshotDigests else { throw RimeSyncError.unsupportedOperation("审核期间 Rime 快照已变化，请重新预览后再确认") }
        let knownIDs = Set(batch.entries.map(\.id))
        guard actions.keys.allSatisfy({ knownIDs.contains($0) }) else { throw RimeSyncError.unsupportedOperation("审核动作包含未知词条 ID") }

        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        let applied: (backupID: String, promoted: Int, skipped: Int, deleted: Int, ignored: Int) = try lock.withLock {
            let lockedSnapshots = try loadSnapshots()
            let lockedDigests = Dictionary(uniqueKeysWithValues: lockedSnapshots.map { ($0.sourceInstallationID, $0.digest) })
            guard lockedDigests == batch.snapshotDigests else { throw RimeSyncError.unsupportedOperation("审核期间 Rime 快照已变化，请重新预览后再确认") }
            let backupID = try backupManager.createBackup(configuration: configuration)
            do {
                var state = try normalizedState()
                try ensureManagedDictionaryImported()
                let sourceIDs = lockedSnapshots.map(\.sourceInstallationID)
                var tombstones: [RimeUserDictionaryEntry] = []
                var promoted = 0
                var skipped = 0
                var deleted = 0
                var ignored = 0
                for (id, action) in actions {
                    guard let entry = batch.entries.first(where: { $0.id == id }) else { continue }
                    switch action {
                    case .keepDynamic:
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        state.entries.removeValue(forKey: id)
                    case .promotePermanent:
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        let frequencies = Dictionary(uniqueKeysWithValues: entry.observations.map { ($0.key, max(0, $0.value.commitCount)) })
                        state.entries[id] = RimeManagedEntryState(text: entry.text, code: entry.code, sourceFrequencies: frequencies.isEmpty ? ["manual": 1] : frequencies)
                        promoted += 1
                    case .deleteLearned:
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        state.entries.removeValue(forKey: id)
                        let pending = RimePendingAuditAction(action: action, targetSourceIDs: sourceIDs, approvedCommitCounts: entry.observations.mapValues(\.commitCount), batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, createdAt: now())
                        state.pendingActions[id] = pending
                        tombstones.append(RimeUserDictionaryEntry(text: entry.text, code: entry.code, commitCount: -tombstoneMagnitude(state: state, batch: batch), decay: 0, tick: max(entry.tick, 1)))
                        deleted += 1
                    case .ignorePermanent:
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        state.permanentIgnoredIDs.insert(id)
                        let pending = RimePendingAuditAction(action: action, targetSourceIDs: sourceIDs, approvedCommitCounts: entry.observations.mapValues(\.commitCount), batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, createdAt: now())
                        state.pendingActions[id] = pending
                        tombstones.append(RimeUserDictionaryEntry(text: entry.text, code: entry.code, commitCount: -tombstoneMagnitude(state: state, batch: batch), decay: 0, tick: max(entry.tick, 1)))
                        ignored += 1
                    case .skipOnce:
                        state.actions.removeValue(forKey: id)
                        skipped += 1
                    case .reviewManually:
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        // Persist the fact that this item still needs a human
                        // decision, while leaving the live dictionary alone.
                        break
                    }
                }
                if !tombstones.isEmpty { try restoreTombstones(tombstones, tick: lockedSnapshots.compactMap(\.tick).max() ?? 1) }
                state.pendingActions = state.pendingActions.mapValues { pending in
                    var copy = pending
                    copy.targetSourceIDs.removeAll { $0 == configuration.installationID }
                    return copy
                }
                state.pendingActions = state.pendingActions.filter { !$0.value.targetSourceIDs.isEmpty || $0.value.action == .ignorePermanent }
                for (id, action) in actions {
                    state.completedActions["\(batch.batchID):\(configuration.nodeID):\(id)"] = RimeCompletedAuditAction(
                        action: action,
                        nodeID: configuration.nodeID,
                        backupID: backupID,
                        completedAt: now()
                    )
                }
                state.backupIDs = ([backupID] + state.backupIDs).prefix(3).map { $0 }
                try writeManagedDictionary(from: state)
                try reviewStore.save(state)
                return (backupID, promoted, skipped, deleted, ignored)
            } catch {
                // Nothing is written before the tombstone merge and generated
                // files have a complete backup.  Restore only if a mutation
                // has already started; the operation is still atomic from
                // the user's point of view.
                try? backupManager.restore(backupID: backupID, configuration: configuration)
                throw error
            }
        }
        do {
            let syncReport = try ordinarySync.sync(dryRun: false)
            try reloader.reload()
            return RimeReviewApplyReport(
                importedCount: applied.promoted,
                skippedCount: applied.skipped,
                backupID: applied.backupID,
                initialRuntimeRebuilt: false,
                ordinarySync: syncReport,
                deletedCount: applied.deleted,
                ignoredCount: applied.ignored
            )
        } catch {
            // A configuration sync or reload can still fail after the audit
            // state was written. Restore the pre-apply snapshot before
            // returning the error so the UI never leaves a half-applied
            // dictionary behind.
            try? backupManager.restore(backupID: applied.backupID, configuration: configuration)
            try? reloader.reload()
            throw error
        }
    }

    public func apply(session: RimeReviewSession, selectedIDs: Set<String>) throws -> RimeReviewApplyReport {
        guard let actualBatch = try batchStore.load(), actualBatch.batchID == session.batchID || session.batchID.isEmpty else { throw RimeSyncError.unsupportedOperation("审核批次不存在，请重新读取") }
        var actions: [String: RimeAuditAction] = [:]
        for candidate in session.candidates where candidate.changeKind != .unchanged {
            actions[candidate.id] = selectedIDs.contains(candidate.id) ? .promotePermanent : .skipOnce
        }
        return try apply(batch: actualBatch, actions: actions)
    }

    @discardableResult
    public func addManualEntry(text: String, code: String, frequency: Int? = nil) throws -> RimeReviewApplyReport {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinyin = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RimeUserDictionaryValidator.isValidWord(word) else { throw RimeSyncError.unsupportedOperation("手动词条不能为空，且不能包含换行或制表符") }
        guard RimeUserDictionaryValidator.isValidCode(pinyin) else { throw RimeSyncError.unsupportedOperation("全拼编码格式无效") }
        _ = try RimeUserDictionaryValidator.frequency(frequency)
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        let backupID = try lock.withLock { () throws -> String in
            let backupID = try backupManager.createBackup(configuration: configuration)
            var state = try normalizedState()
            let id = RimeUserDictionaryEntry.identity(for: word, code: pinyin)
            state.entries[id] = RimeManagedEntryState(text: word, code: pinyin, sourceFrequencies: ["manual": 1])
            state.initialized = true
            state.actions[id] = RimeAuditActionRecord(action: .promotePermanent, sourceNode: configuration.nodeID, batchID: "manual", snapshotDigest: "", recordedAt: now(), backupID: backupID)
            try ensureManagedDictionaryImported()
            try writeManagedDictionary(from: state)
            try reviewStore.save(state)
            return backupID
        }
        do {
            let syncReport = try ordinarySync.sync(dryRun: false)
            try reloader.reload()
            return RimeReviewApplyReport(
                importedCount: 1,
                skippedCount: 0,
                backupID: backupID,
                initialRuntimeRebuilt: false,
                ordinarySync: syncReport
            )
        } catch {
            try? backupManager.restore(backupID: backupID, configuration: configuration)
            try? reloader.reload()
            throw error
        }
    }

    public func submitProposals(_ proposals: [RimeAuditProposal], for batch: RimeAuditBatch) throws -> RimeAuditPreview {
        try validateProposals(proposals, for: batch)
        let current = try loadSnapshots()
        let currentDigest = aggregateDigest(
            Dictionary(uniqueKeysWithValues: current.map { ($0.sourceInstallationID, $0.digest) })
        )
        guard currentDigest == batch.snapshotDigest else {
            throw RimeSyncError.unsupportedOperation("AI 提案对应的 Rime 快照已变化，请重新导出和分析")
        }
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        try lock.withLock {
            var state = try normalizedState()
            state.proposals[batch.batchID] = proposals
            try reviewStore.save(state)
        }
        return preview(proposals: proposals, batch: batch, stale: false)
    }

    public func previewProposals(for batch: RimeAuditBatch) throws -> RimeAuditPreview {
        let state = try normalizedState()
        let proposals = state.proposals[batch.batchID] ?? []
        let current = try loadSnapshots()
        let digest = aggregateDigest(Dictionary(uniqueKeysWithValues: current.map { ($0.sourceInstallationID, $0.digest) }))
        return preview(proposals: proposals, batch: batch, stale: digest != batch.snapshotDigest)
    }

    public func latestBatch() throws -> RimeAuditBatch? { try batchStore.load() }
    public func reviewState() throws -> RimeReviewState { try normalizedState() }
    public func export(batch: RimeAuditBatch) -> Data { RimeAuditCSV.export(batch: batch) }

    public func importProposalCSV(data: Data, for batch: RimeAuditBatch) throws -> RimeAuditPreview {
        let proposals = try RimeAuditCSV.importProposals(data: data, batch: batch)
        return try submitProposals(proposals, for: batch)
    }

    public func restore(backupID: String) throws {
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        try lock.withLock {
            try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
            _ = try backupManager.createBackup(configuration: configuration)
            try backupManager.restore(backupID: backupID, configuration: configuration)
            try reloader.reload()
        }
    }

    private func validateProposals(_ proposals: [RimeAuditProposal], for batch: RimeAuditBatch) throws {
        let IDs = Set(batch.entries.map(\.id))
        var seen = Set<String>()
        for proposal in proposals {
            guard proposal.schemaVersion == batch.schemaVersion, proposal.batchID == batch.batchID, proposal.snapshotDigest == batch.snapshotDigest else { throw RimeSyncError.unsupportedOperation("AI 提案批次或快照已过期") }
            guard IDs.contains(proposal.entryID) else { throw RimeSyncError.unsupportedOperation("AI 提案包含未知词条 ID") }
            guard seen.insert(proposal.entryID).inserted else { throw RimeSyncError.unsupportedOperation("AI 提案包含重复词条 ID") }
        }
    }

    private func preview(proposals: [RimeAuditProposal], batch: RimeAuditBatch, stale: Bool) -> RimeAuditPreview {
        var counts: [String: Int] = [:]
        for proposal in proposals { counts[proposal.action.rawValue, default: 0] += 1 }
        return RimeAuditPreview(batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, countsByAction: counts, proposalCount: proposals.count, stale: stale)
    }

    private func normalizedState() throws -> RimeReviewState {
        var state = try reviewStore.load()
        let managedURL = configuration.localRimeDirectory.appendingPathComponent(RimeManagedDictionary.fileName)
        if state.entries.isEmpty, fileManager.fileExists(atPath: managedURL.path) {
            let legacyEntries = RimeManagedDictionary.parse(data: try Data(contentsOf: managedURL))
            for entry in legacyEntries { state.entries[entry.identity] = RimeManagedEntryState(text: entry.text, code: entry.code, sourceFrequencies: ["legacy-managed": 1]) }
            if !legacyEntries.isEmpty {
                state.migration.legacyManagedEntries = legacyEntries.count
                state.initialized = true
            }
        }
        return state
    }

    private func ingest(_ snapshots: [RimeUserDictionarySnapshot], into state: inout RimeReviewState, baseline: Bool, observedAt: Date) {
        for snapshot in snapshots {
            var observations = state.nodeObservations[snapshot.sourceInstallationID] ?? [:]
            for entry in snapshot.entries {
                let metrics = RimeScoring.metrics(for: entry, snapshotTick: snapshot.tick)
                let previous = observations[entry.identity]
                let activity: Date?
                if baseline { activity = previous?.lastActivityAt }
                else if previous == nil || entry.commitCount > (previous?.commitCount ?? Int.min) { activity = observedAt }
                else { activity = previous?.lastActivityAt }
                observations[entry.identity] = RimeAuditObservation(
                    text: entry.text, code: entry.code, commitCount: entry.commitCount, decay: entry.decay, tick: entry.tick,
                    effectiveDecay: metrics.effectiveDecay, rimeScore: metrics.rimeScore, snapshotDigest: snapshot.digest,
                    firstSeenAt: previous?.firstSeenAt ?? (baseline ? nil : observedAt), lastObservedAt: observedAt, lastActivityAt: activity
                )
            }
            state.nodeObservations[snapshot.sourceInstallationID] = observations
            state.lastAppliedSnapshotDigests[snapshot.sourceInstallationID] = snapshot.digest
        }
    }

    private func makeAuditEntries(state: RimeReviewState, baseIndex: RimeBaseDictionaryIndex?) -> [RimeAuditEntry] {
        var allIDs = Set(state.entries.keys).union(state.permanentIgnoredIDs)
        for observations in state.nodeObservations.values { allIDs.formUnion(observations.keys) }
        let raw: [(id: String, observations: [String: RimeAuditObservation])] = allIDs.compactMap { id in
            let observations = state.nodeObservations.compactMapValues { $0[id] }
            let fallback = state.entries[id].map { legacy -> RimeAuditObservation in
                RimeAuditObservation(text: legacy.text, code: legacy.code, commitCount: legacy.frequency, decay: 0, tick: 0, effectiveDecay: 0, rimeScore: 0, snapshotDigest: "")
            }
            guard let sample = observations.values.max(by: { abs($0.commitCount) < abs($1.commitCount) }) ?? fallback else { return nil }
            return (id, observations.isEmpty ? ["managed": sample] : observations)
        }
        let activeDecays = raw.flatMap { $0.observations.values }.filter { $0.commitCount >= 0 }.map(\.effectiveDecay).sorted()
        let medianDecay = activeDecays.isEmpty ? 0 : activeDecays[activeDecays.count / 2]
        return raw.map { id, observations in
            let primary = observations.values.max { lhs, rhs in
                if lhs.commitCount != rhs.commitCount { return lhs.commitCount < rhs.commitCount }
                return lhs.effectiveDecay < rhs.effectiveDecay
            }!
            let activity = observations.values.compactMap(\.lastActivityAt).max()
            let firstSeen = observations.values.compactMap(\.firstSeenAt).min()
            let status: RimeAuditStatus
            if state.permanentIgnoredIDs.contains(id) { status = .ignored }
            else if state.entries[id] != nil { status = .permanent }
            else if state.actions[id]?.action == .reviewManually {
                status = .manualReview
            }
            else if state.pendingActions[id].map({ !$0.targetSourceIDs.isEmpty }) == true {
                status = .pending
            }
            else if let action = state.actions[id] {
                switch action.action {
                case .reviewManually: status = .manualReview
                case .deleteLearned: status = .deleted
                default:
                    let grew = observations.contains { source, value in value.commitCount > (action.commitCounts[source] ?? Int.min) }
                    status = grew ? .changed : .dynamic
                }
            } else if primary.commitCount < 0 { status = .deleted }
            else if activity != nil { status = .newRecord }
            else { status = .dynamic }
            let asciiNoise = primary.text.count == 1 && primary.text.unicodeScalars.allSatisfy { $0.value < 128 && CharacterSet.letters.contains($0) }
            let stale = primary.commitCount <= 1 && primary.effectiveDecay <= medianDecay
            return RimeAuditEntry(
                id: id, text: primary.text, code: primary.code, observations: observations,
                commitCount: primary.commitCount, decay: primary.decay, tick: primary.tick,
                effectiveDecay: primary.effectiveDecay, rimeScore: primary.rimeScore,
                inBaseDictionary: baseIndex?.contains(text: primary.text, code: primary.code) ?? false,
                firstSeenAt: firstSeen, lastActivityAt: activity, currentStatus: status,
                isNoise: asciiNoise, isStale: stale
            )
        }.sorted { lhs, rhs in
            if lhs.rimeScore != rhs.rimeScore { return lhs.rimeScore > rhs.rimeScore }
            return lhs.id < rhs.id
        }
    }

    private func applyPendingActionsIfNeeded(state: inout RimeReviewState, snapshots: [RimeUserDictionarySnapshot]) throws {
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        try lock.withLock {
            try applyPendingActionsLocked(state: &state, snapshots: snapshots)
        }
    }

    private func applyPendingActionsLocked(state: inout RimeReviewState, snapshots: [RimeUserDictionarySnapshot]) throws {
        let currentID = configuration.installationID
        var tombstones: [RimeUserDictionaryEntry] = []
        var pendingIDs: [String] = []
        for (id, pending) in state.pendingActions {
            let isContinuousIgnore = pending.action == .ignorePermanent && state.permanentIgnoredIDs.contains(id)
            guard pending.targetSourceIDs.contains(currentID) || isContinuousIgnore else { continue }
            let current = state.nodeObservations[currentID]?[id]
            guard let current else {
                state.pendingActions[id]?.targetSourceIDs.removeAll { $0 == currentID }
                continue
            }
            if current.commitCount < 0 {
                state.pendingActions[id]?.targetSourceIDs.removeAll { $0 == currentID }
                continue
            }
            if pending.action == .deleteLearned,
               let approved = pending.approvedCommitCounts[currentID], current.commitCount > approved {
                state.actions[id] = RimeAuditActionRecord(action: .reviewManually, sourceNode: configuration.nodeID, batchID: pending.batchID, snapshotDigest: pending.snapshotDigest, recordedAt: now())
                continue
            }
            guard pending.action == .deleteLearned || pending.action == .ignorePermanent else { continue }
            tombstones.append(RimeUserDictionaryEntry(text: current.text, code: current.code, commitCount: -tombstoneMagnitude(state: state, batch: nil), decay: 0, tick: max(current.tick, 1)))
            pendingIDs.append(id)
        }
        if !tombstones.isEmpty {
            let backupID = try backupManager.createBackup(configuration: configuration)
            do {
                try restoreTombstones(tombstones, tick: snapshots.compactMap(\.tick).max() ?? 1)
                state.backupIDs = ([backupID] + state.backupIDs).prefix(3).map { $0 }
                for id in pendingIDs {
                    guard let pending = state.pendingActions[id] else { continue }
                    state.pendingActions[id]?.targetSourceIDs.removeAll { $0 == currentID }
                    state.completedActions["\(pending.batchID):\(configuration.nodeID):\(id)"] = RimeCompletedAuditAction(
                        action: pending.action,
                        nodeID: configuration.nodeID,
                        backupID: backupID,
                        completedAt: now()
                    )
                }
            } catch {
                try? backupManager.restore(backupID: backupID, configuration: configuration)
                throw error
            }
            try reloader.reload()
        }
        state.pendingActions = state.pendingActions.filter { !$0.value.targetSourceIDs.isEmpty || $0.value.action == .ignorePermanent }
    }

    private func restoreTombstones(_ entries: [RimeUserDictionaryEntry], tick: Int64) throws {
        let url = configuration.localRimeDirectory.deletingLastPathComponent().appendingPathComponent(".rime-tombstone-\(UUID().uuidString).userdb.txt")
        defer { try? fileManager.removeItem(at: url) }
        let snapshot = RimeUserDictionarySnapshot(sourceInstallationID: configuration.installationID, rimeVersion: nil, tick: tick, entries: entries)
        try AtomicFileStore.write(snapshot.serializedData(), to: url, fileManager: fileManager)
        try maintenance.restoreUserDictionarySnapshot(from: url, in: configuration.localRimeDirectory)
    }

    private func tombstoneMagnitude(state: RimeReviewState, batch: RimeAuditBatch?) -> Int {
        let stateMaximum = state.nodeObservations.values.flatMap { $0.values }.map { abs($0.commitCount) }.max() ?? 0
        let batchMaximum = batch?.entries.map { abs($0.commitCount) }.max() ?? 0
        return max(1_000_000, max(stateMaximum, batchMaximum) + 1)
    }

    private func writeManagedDictionary(from state: RimeReviewState) throws {
        try AtomicFileStore.write(RimeManagedDictionary.serializedData(from: state), to: configuration.localRimeDirectory.appendingPathComponent(RimeManagedDictionary.fileName), fileManager: fileManager)
    }

    private func ensureManagedDictionaryImported() throws {
        let url = configuration.localRimeDirectory.appendingPathComponent("rime_ice.dict.yaml")
        guard fileManager.fileExists(atPath: url.path) else { return }
        let original = try String(contentsOf: url, encoding: .utf8)
        var lines = original.components(separatedBy: .newlines)
        guard let importIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "import_tables:" }) else { return }
        lines.removeAll { line in line.trimmingCharacters(in: .whitespaces).hasPrefix("- rime_managed") }
        guard let newImportIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "import_tables:" }) else { return }
        var insertion = newImportIndex + 1
        while insertion < lines.count {
            let trimmed = lines[insertion].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty || trimmed.hasPrefix("-") { insertion += 1; continue }
            break
        }
        lines.insert("  - rime_managed     # 审核后的长期记忆，始终位于静态词库之后", at: insertion)
        if lines != original.components(separatedBy: .newlines) { try AtomicFileStore.write(Data(lines.joined(separator: "\n").utf8), to: url, fileManager: fileManager) }
        _ = importIndex
    }

    private func writeManagedDictionaryIfNeeded(_ state: RimeReviewState) throws { try writeManagedDictionary(from: state) }

    private func publishCurrentSnapshot() throws {
        let local = configuration.localRimeDirectory.appendingPathComponent("sync", isDirectory: true).appendingPathComponent(configuration.installationID, isDirectory: true).appendingPathComponent("rime_ice.userdb.txt")
        let shared = configuration.sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true).appendingPathComponent(configuration.installationID, isDirectory: true).appendingPathComponent("rime_ice.userdb.txt")
        if fileManager.fileExists(atPath: local.path), local.standardizedFileURL != shared.standardizedFileURL { try AtomicFileStore.copyItem(from: local, to: shared, fileManager: fileManager) }
        if fileManager.fileExists(atPath: shared.path) { try SharedDirectoryLayout.makeGroupWritable(shared, fileManager: fileManager) }
    }

    private func loadSnapshots() throws -> [RimeUserDictionarySnapshot] {
        let root = configuration.sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true)
        var urls: [String: URL] = [:]
        if let directories = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for directory in directories where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let url = directory.appendingPathComponent("rime_ice.userdb.txt")
                if fileManager.fileExists(atPath: url.path) { urls[directory.lastPathComponent] = url }
            }
        }
        let local = configuration.localRimeDirectory.appendingPathComponent("sync", isDirectory: true).appendingPathComponent(configuration.installationID, isDirectory: true).appendingPathComponent("rime_ice.userdb.txt")
        if fileManager.fileExists(atPath: local.path), urls[configuration.installationID] == nil { urls[configuration.installationID] = local }
        return try urls.keys.sorted().compactMap { sourceID in
            guard let url = urls[sourceID] else { return nil }
            return try parser.parse(data: Data(contentsOf: url), sourceInstallationID: sourceID).snapshot
        }
    }

    private func aggregateDigest(_ digests: [String: String]) -> String {
        RimeAuditBatch.aggregateSnapshotDigest(digests)
    }
}
