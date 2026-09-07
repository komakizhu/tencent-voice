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
    case replaceEntry = "replace_entry"
    case deleteLearned = "delete_learned"
    case skipOnce = "skip_once"
    case ignorePermanent = "ignore_permanent"
    case reviewManually = "review_manually"

    public var displayName: String {
        switch self {
        case .keepDynamic: return "保留动态学习"
        case .promotePermanent: return "加入长期记忆"
        case .replaceEntry: return "替换词条"
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
    public let replacementText: String?
    public let replacementCode: String?

    public init(
        action: RimeAuditAction,
        targetSourceIDs: [String],
        approvedCommitCounts: [String: Int] = [:],
        batchID: String,
        snapshotDigest: String,
        createdAt: Date = Date(),
        replacementText: String? = nil,
        replacementCode: String? = nil
    ) {
        self.action = action
        self.targetSourceIDs = Array(Set(targetSourceIDs)).sorted()
        self.approvedCommitCounts = approvedCommitCounts
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.createdAt = createdAt
        self.replacementText = replacementText
        self.replacementCode = replacementCode
    }
}

public enum RimeAuditExecutionStatus: String, Codable, Sendable {
    case completed
    case failed
}

public struct RimeAuditReplacementRecord: Codable, Equatable, Sendable {
    public let oldEntryID: String
    public let oldText: String
    public let oldCode: String
    public let replacementEntryID: String
    public let replacementText: String
    public let replacementCode: String
    public let sourceEntries: [String: RimeUserDictionaryEntry]
    public let batchID: String
    public let snapshotDigest: String
    public let backupID: String?
    public let executedAt: Date
    public let status: RimeAuditExecutionStatus
    public let errorMessage: String?

    public init(
        oldEntryID: String,
        oldText: String,
        oldCode: String,
        replacementText: String,
        replacementCode: String,
        sourceEntries: [String: RimeUserDictionaryEntry],
        batchID: String,
        snapshotDigest: String,
        backupID: String? = nil,
        executedAt: Date = Date(),
        status: RimeAuditExecutionStatus = .completed,
        errorMessage: String? = nil
    ) {
        self.oldEntryID = oldEntryID
        self.oldText = oldText
        self.oldCode = oldCode
        self.replacementEntryID = RimeUserDictionaryEntry.identity(for: replacementText, code: replacementCode)
        self.replacementText = replacementText
        self.replacementCode = replacementCode
        self.sourceEntries = sourceEntries
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.backupID = backupID
        self.executedAt = executedAt
        self.status = status
        self.errorMessage = errorMessage
    }
}

public struct RimeCompletedAuditAction: Codable, Equatable, Sendable {
    public let action: RimeAuditAction
    public let nodeID: String
    public let backupID: String?
    public let completedAt: Date
    public let status: RimeAuditExecutionStatus
    public let oldEntryID: String?
    public let oldText: String?
    public let oldCode: String?
    public let targetText: String?
    public let targetCode: String?
    public let errorMessage: String?

    public init(
        action: RimeAuditAction,
        nodeID: String,
        backupID: String? = nil,
        completedAt: Date = Date(),
        status: RimeAuditExecutionStatus = .completed,
        oldEntryID: String? = nil,
        oldText: String? = nil,
        oldCode: String? = nil,
        targetText: String? = nil,
        targetCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.action = action
        self.nodeID = nodeID
        self.backupID = backupID
        self.completedAt = completedAt
        self.status = status
        self.oldEntryID = oldEntryID
        self.oldText = oldText
        self.oldCode = oldCode
        self.targetText = targetText
        self.targetCode = targetCode
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case action, nodeID, backupID, completedAt, status
        case oldEntryID, oldText, oldCode, targetText, targetCode, errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(RimeAuditAction.self, forKey: .action)
        self.nodeID = try container.decode(String.self, forKey: .nodeID)
        self.backupID = try container.decodeIfPresent(String.self, forKey: .backupID)
        self.completedAt = try container.decode(Date.self, forKey: .completedAt)
        self.status = try container.decodeIfPresent(RimeAuditExecutionStatus.self, forKey: .status) ?? .completed
        self.oldEntryID = try container.decodeIfPresent(String.self, forKey: .oldEntryID)
        self.oldText = try container.decodeIfPresent(String.self, forKey: .oldText)
        self.oldCode = try container.decodeIfPresent(String.self, forKey: .oldCode)
        self.targetText = try container.decodeIfPresent(String.self, forKey: .targetText)
        self.targetCode = try container.decodeIfPresent(String.self, forKey: .targetCode)
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
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
    public let generatedByReplaceEntry: Bool?

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
        isStale: Bool = false,
        generatedByReplaceEntry: Bool? = nil
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
        self.generatedByReplaceEntry = generatedByReplaceEntry
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
    public let source: String
    public let action: RimeAuditAction
    public let confidence: Double
    public let reason: String
    public let replacementText: String?
    public let replacementCode: String?

    public init(
        schemaVersion: Int = 2,
        batchID: String,
        snapshotDigest: String,
        entryID: String,
        source: String = "ai",
        action: RimeAuditAction,
        confidence: Double,
        reason: String,
        replacementText: String? = nil,
        replacementCode: String? = nil
    ) throws {
        guard action.isProposalAction else {
            throw RimeSyncError.unsupportedOperation("AI 提案不允许使用本次跳过")
        }
        guard (0...1).contains(confidence) else {
            throw RimeSyncError.unsupportedOperation("AI 置信度必须在 0 到 1 之间")
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RimeSyncError.unsupportedOperation("AI 提案来源不能为空")
        }
        if action == .replaceEntry {
            let text = replacementText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = replacementCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard RimeUserDictionaryValidator.isValidWord(text) else {
                throw RimeSyncError.unsupportedOperation("replace_entry 的 replacementText 不能为空，且不能包含换行或制表符")
            }
            guard RimeUserDictionaryValidator.isValidCode(code) else {
                throw RimeSyncError.unsupportedOperation("replace_entry 的 replacementCode 格式无效")
            }
            self.replacementText = text
            self.replacementCode = code
        } else {
            self.replacementText = replacementText
            self.replacementCode = replacementCode
        }
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.entryID = entryID
        self.source = source
        self.action = action
        self.confidence = confidence
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, batchID, snapshotDigest, entryID, source, action, confidence, reason
        case replacementText, replacementCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        self.batchID = try container.decode(String.self, forKey: .batchID)
        self.snapshotDigest = try container.decode(String.self, forKey: .snapshotDigest)
        self.entryID = try container.decode(String.self, forKey: .entryID)
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "ai"
        self.action = try container.decode(RimeAuditAction.self, forKey: .action)
        self.confidence = try container.decode(Double.self, forKey: .confidence)
        self.reason = try container.decode(String.self, forKey: .reason)
        self.replacementText = try container.decodeIfPresent(String.self, forKey: .replacementText)
        self.replacementCode = try container.decodeIfPresent(String.self, forKey: .replacementCode)
    }
}

public struct RimeAuditReplacementPreview: Codable, Equatable, Sendable {
    public let entryID: String
    public let oldText: String
    public let oldCode: String
    public let replacementText: String
    public let replacementCode: String
    public let sourceEntries: [String: RimeUserDictionaryEntry]
    public let targetExists: Bool
    public let willBecomePermanent: Bool
    public let generatedByReplaceEntry: Bool

    public init(
        entryID: String,
        oldText: String,
        oldCode: String,
        replacementText: String,
        replacementCode: String,
        sourceEntries: [String: RimeUserDictionaryEntry],
        targetExists: Bool,
        willBecomePermanent: Bool = true,
        generatedByReplaceEntry: Bool = true
    ) {
        self.entryID = entryID
        self.oldText = oldText
        self.oldCode = oldCode
        self.replacementText = replacementText
        self.replacementCode = replacementCode
        self.sourceEntries = sourceEntries
        self.targetExists = targetExists
        self.willBecomePermanent = willBecomePermanent
        self.generatedByReplaceEntry = generatedByReplaceEntry
    }
}

public struct RimeAuditPreview: Codable, Equatable, Sendable {
    public let batchID: String
    public let snapshotDigest: String
    public let countsByAction: [String: Int]
    public let proposalCount: Int
    public let stale: Bool
    public let replacements: [RimeAuditReplacementPreview]

    public init(
        batchID: String,
        snapshotDigest: String,
        countsByAction: [String: Int],
        proposalCount: Int,
        stale: Bool,
        replacements: [RimeAuditReplacementPreview] = []
    ) {
        self.batchID = batchID
        self.snapshotDigest = snapshotDigest
        self.countsByAction = countsByAction
        self.proposalCount = proposalCount
        self.stale = stale
        self.replacements = replacements
    }

    private enum CodingKeys: String, CodingKey {
        case batchID, snapshotDigest, countsByAction, proposalCount, stale, replacements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.batchID = try container.decode(String.self, forKey: .batchID)
        self.snapshotDigest = try container.decode(String.self, forKey: .snapshotDigest)
        self.countsByAction = try container.decode([String: Int].self, forKey: .countsByAction)
        self.proposalCount = try container.decode(Int.self, forKey: .proposalCount)
        self.stale = try container.decode(Bool.self, forKey: .stale)
        self.replacements = try container.decodeIfPresent([RimeAuditReplacementPreview].self, forKey: .replacements) ?? []
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
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let main = root.appendingPathComponent("rime_ice.dict.yaml")
        guard fileManager.fileExists(atPath: main.path) else { return [] }
        var result: [URL] = []
        var pending = [main]
        var visited = Set<String>()
        while let file = pending.popLast() {
            let canonicalURL = file.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalURL.path.hasPrefix(root.path + "/") else { continue }
            let canonical = canonicalURL.path
            guard visited.insert(canonical).inserted else { continue }
            guard canonicalURL.lastPathComponent != RimeManagedDictionary.fileName,
                  fileManager.fileExists(atPath: canonicalURL.path) else { continue }
            result.append(canonicalURL)
            guard let content = try? String(contentsOf: canonicalURL, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { continue }
                let importedName = trimmed.dropFirst(2).split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !importedName.isEmpty, !importedName.contains("rime_managed") else { continue }
                let imported = importedName.hasSuffix(".dict.yaml")
                    ? root.appendingPathComponent(importedName)
                    : root.appendingPathComponent(importedName).appendingPathExtension("dict.yaml")
                let canonicalImported = imported.standardizedFileURL.resolvingSymlinksInPath()
                guard canonicalImported.path.hasPrefix(root.path + "/"),
                      fileManager.fileExists(atPath: canonicalImported.path) else { continue }
                pending.append(canonicalImported)
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

// MARK: - Audit export

public enum RimeAuditExportFormat: String, CaseIterable, Codable, Sendable {
    case csv
    case txt
    case markdown
    case json

    public var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .txt: return "TXT"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        default: return rawValue
        }
    }
}

public protocol RimeAuditExporting {
    func export(
        batch: RimeAuditBatch,
        entries: [RimeAuditEntry],
        format: RimeAuditExportFormat
    ) throws -> Data
}

public struct RimeAuditExporter: RimeAuditExporting {
    public init() {}

    public func export(
        batch: RimeAuditBatch,
        entries: [RimeAuditEntry],
        format: RimeAuditExportFormat
    ) throws -> Data {
        try Self.export(batch: batch, entries: entries, format: format)
    }

    public static func export(
        batch: RimeAuditBatch,
        entries: [RimeAuditEntry],
        format: RimeAuditExportFormat
    ) throws -> Data {
        let sortedEntries = entries.sorted { $0.id < $1.id }
        switch format {
        case .csv:
            return RimeAuditCSV.export(batch: batch, entries: sortedEntries)
        case .txt:
            return Data(text(batch: batch, entries: sortedEntries).utf8)
        case .markdown:
            return Data(markdown(batch: batch, entries: sortedEntries).utf8)
        case .json:
            let document = JSONDocument(
                schemaVersion: batch.schemaVersion,
                batchID: batch.batchID,
                snapshotDigest: batch.snapshotDigest,
                snapshotDigests: batch.snapshotDigests,
                entries: sortedEntries
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(document)
        }
    }

    private struct JSONDocument: Encodable {
        let schemaVersion: Int
        let batchID: String
        let snapshotDigest: String
        let snapshotDigests: [String: String]
        let entries: [RimeAuditEntry]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case batchID = "batch_id"
            case snapshotDigest = "snapshot_digest"
            case snapshotDigests = "snapshot_digests"
            case entries
        }
    }

    private static func text(batch: RimeAuditBatch, entries: [RimeAuditEntry]) -> String {
        var lines = [
            "schema_version: \(batch.schemaVersion)",
            "batch_id: \(batch.batchID)",
            "snapshot_digest: \(batch.snapshotDigest)",
            "词条\t编码\tc\td\tt\t有效衰减\t有效热度\t基础词典\t首次发现\t最近活动\t状态\t来源账户"
        ]
        lines.append(contentsOf: entries.map { entry in
            [
                entry.text, entry.code, "\(entry.commitCount)", format(entry.decay), "\(entry.tick)",
                format(entry.effectiveDecay), format(entry.rimeScore), entry.inBaseDictionary ? "true" : "false",
                iso(entry.firstSeenAt), iso(entry.lastActivityAt), entry.currentStatus.rawValue,
                entry.sourceNodes.joined(separator: ";")
            ].joined(separator: "\t")
        })
        return lines.joined(separator: "\n") + "\n"
    }

    private static func markdown(batch: RimeAuditBatch, entries: [RimeAuditEntry]) -> String {
        var lines = [
            "# Rime 词库审核导出",
            "",
            "- schema_version: `\(batch.schemaVersion)`",
            "- batch_id: `\(batch.batchID)`",
            "- snapshot_digest: `\(batch.snapshotDigest)`",
            "",
            "| 词条 | 编码 | c | d | t | 有效衰减 | 有效热度 | 基础词典 | 首次发现 | 最近活动 | 状态 | 来源账户 |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- |"
        ]
        lines.append(contentsOf: entries.map { entry in
            let fields = [
                escape(entry.text), escape(entry.code), "\(entry.commitCount)", format(entry.decay), "\(entry.tick)",
                format(entry.effectiveDecay), format(entry.rimeScore), entry.inBaseDictionary ? "是" : "否",
                iso(entry.firstSeenAt), iso(entry.lastActivityAt), escape(entry.currentStatus.rawValue),
                escape(entry.sourceNodes.joined(separator: "、"))
            ]
            return "| " + fields.joined(separator: " | ") + " |"
        })
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func iso(_ date: Date?) -> String {
        date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - CSV interchange

public enum RimeAuditCSV {
    public static let headers = [
        "schema_version", "batch_id", "snapshot_digest", "entry_id", "text", "code", "sources",
        "c", "d", "t", "effective_decay", "rime_score", "in_base_dictionary", "first_seen_at",
        "last_activity_at", "current_status"
    ]
    public static let proposalHeaders = [
        "schema_version", "batch_id", "snapshot_digest", "entry_id", "action", "confidence", "reason",
        "replacement_text", "replacement_code"
    ]
    private static let legacyProposalHeaders = ["schema_version", "batch_id", "snapshot_digest", "entry_id", "action", "confidence", "reason"]

    public static func export(batch: RimeAuditBatch, entries: [RimeAuditEntry]? = nil) -> Data {
        var rows = [headers]
        for entry in (entries ?? batch.entries).sorted(by: { $0.id < $1.id }) {
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
            [
                "\(proposal.schemaVersion)", proposal.batchID, proposal.snapshotDigest, proposal.entryID,
                proposal.action.rawValue, format(proposal.confidence), proposal.reason,
                proposal.replacementText ?? "", proposal.replacementCode ?? ""
            ]
        })
        return Data(rows.map(encodeRow).joined(separator: "\r\n").appending("\r\n").utf8)
    }

    public static func importProposals(data: Data, batch: RimeAuditBatch) throws -> [RimeAuditProposal] {
        guard let text = String(data: data, encoding: .utf8) else { throw RimeSyncError.unsupportedOperation("AI 提案不是有效的 UTF-8 CSV") }
        let rows = try decode(text)
        guard let rawHeader = rows.first else { throw RimeSyncError.unsupportedOperation("AI 提案 CSV 缺少表头") }
        let header = rawHeader.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let isLegacy = header == legacyProposalHeaders
        guard isLegacy || header == proposalHeaders else { throw RimeSyncError.unsupportedOperation("AI 提案 CSV 表头不匹配") }
        let validIDs = Set(batch.entries.map(\.id))
        var seen = Set<String>()
        var result: [RimeAuditProposal] = []
        for row in rows.dropFirst() {
            let expectedCount = isLegacy ? legacyProposalHeaders.count : proposalHeaders.count
            guard row.count == expectedCount else { throw RimeSyncError.unsupportedOperation("AI 提案 CSV 字段数错误") }
            guard Int(row[0]) == batch.schemaVersion, row[1] == batch.batchID, row[2] == batch.snapshotDigest else { throw RimeSyncError.unsupportedOperation("AI 提案批次或快照已过期") }
            guard validIDs.contains(row[3]) else { throw RimeSyncError.unsupportedOperation("AI 提案包含未知词条 ID") }
            guard seen.insert(row[3]).inserted else { throw RimeSyncError.unsupportedOperation("AI 提案包含重复词条 ID") }
            guard let action = RimeAuditAction(rawValue: row[4]), action.isProposalAction else { throw RimeSyncError.unsupportedOperation("AI 提案动作无效") }
            guard let confidence = Double(row[5]), (0...1).contains(confidence) else { throw RimeSyncError.unsupportedOperation("AI 提案置信度无效") }
            let replacementText = isLegacy || row[7].isEmpty ? nil : row[7]
            let replacementCode = isLegacy || row[8].isEmpty ? nil : row[8]
            result.append(try RimeAuditProposal(
                batchID: batch.batchID,
                snapshotDigest: batch.snapshotDigest,
                entryID: row[3],
                action: action,
                confidence: confidence,
                reason: row[6],
                replacementText: replacementText,
                replacementCode: replacementCode
            ))
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
        var endedWithRow = false
        var index = 0
        func finishField() {
            rows[rows.count - 1].append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            endedWithRow = false
        }
        func finishRow() {
            finishField()
            rows.append([])
            endedWithRow = true
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
                    endedWithRow = false
                    index += 1
                }
            }
        }
        guard !quoted else { throw RimeSyncError.unsupportedOperation("CSV 引号未闭合") }
        if endedWithRow {
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
    public let replacedCount: Int

    public init(
        importedCount: Int,
        skippedCount: Int,
        backupID: String,
        initialRuntimeRebuilt: Bool,
        ordinarySync: SyncReport?,
        deletedCount: Int = 0,
        ignoredCount: Int = 0,
        replacedCount: Int = 0
    ) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.backupID = backupID
        self.initialRuntimeRebuilt = initialRuntimeRebuilt
        self.ordinarySync = ordinarySync
        self.deletedCount = deletedCount
        self.ignoredCount = ignoredCount
        self.replacedCount = replacedCount
    }
}

public struct RimeUserDictionarySyncRecord: Codable, Equatable, Sendable {
    public let installationID: String
    public let nodeID: String
    public let synchronizedAt: Date
    public let backupID: String
    public let snapshotDigests: [String: String]

    public init(
        installationID: String,
        nodeID: String,
        synchronizedAt: Date,
        backupID: String,
        snapshotDigests: [String: String]
    ) {
        self.installationID = installationID
        self.nodeID = nodeID
        self.synchronizedAt = synchronizedAt
        self.backupID = backupID
        self.snapshotDigests = snapshotDigests
    }
}

public struct RimeUserDictionarySyncMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var records: [String: RimeUserDictionarySyncRecord]

    public init(
        schemaVersion: Int = 1,
        records: [String: RimeUserDictionarySyncRecord] = [:]
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.records = records
    }

    public var latestRecord: RimeUserDictionarySyncRecord? {
        records.values.max {
            if $0.synchronizedAt != $1.synchronizedAt {
                return $0.synchronizedAt < $1.synchronizedAt
            }
            return $0.nodeID < $1.nodeID
        }
    }
}

public struct RimeUserDictionarySyncMetadataStore {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func load() throws -> RimeUserDictionarySyncMetadata {
        guard fileManager.fileExists(atPath: url.path) else {
            return RimeUserDictionarySyncMetadata()
        }
        do {
            return try JSONDecoder.rimeDecoder.decode(
                RimeUserDictionarySyncMetadata.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw RimeSyncError.unsupportedOperation("Rime 词库同步记录无法读取：\(error.localizedDescription)")
        }
    }

    public func save(_ metadata: RimeUserDictionarySyncMetadata) throws {
        try AtomicFileStore.write(
            JSONEncoder.rimeEncoder.encode(metadata),
            to: url,
            fileManager: fileManager
        )
        try SharedDirectoryLayout.makeGroupWritable(url, fileManager: fileManager)
    }
}

public struct RimeUserDictionarySyncReport: Equatable, Sendable {
    public let backupID: String
    public let synchronizedAt: Date
    public let snapshotDigests: [String: String]
    public let auditBatchID: String
    public let entryCount: Int

    public init(
        backupID: String,
        synchronizedAt: Date,
        snapshotDigests: [String: String],
        auditBatchID: String,
        entryCount: Int
    ) {
        self.backupID = backupID
        self.synchronizedAt = synchronizedAt
        self.snapshotDigests = snapshotDigests
        self.auditBatchID = auditBatchID
        self.entryCount = entryCount
    }
}

public protocol RimeUserDictionaryMaintaining {
    /// Publish only the current account's dictionary snapshot.  This is a
    /// protocol requirement so an existential cannot bypass the concrete
    /// `--backup` implementation through a protocol-extension dispatch.
    func backupUserDictionary(in rimeDirectory: URL) throws
    func captureUserDictionarySnapshot(in rimeDirectory: URL) throws
    func restoreUserDictionarySnapshot(from snapshot: URL, in rimeDirectory: URL) throws
}

public extension RimeUserDictionaryMaintaining {
    /// Compatibility fallback for older test doubles and clients.
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
    private let syncMetadataStore: RimeUserDictionarySyncMetadataStore
    private let backupManager: RimeBackupManager
    private let retentionStore: RimeBackupRetentionStore
    private let baseDictionaryCache: RimeBaseDictionaryIndexCache
    private let now: () -> Date

    public init(
        configuration: SyncConfiguration,
        maintenance: any RimeUserDictionaryMaintaining,
        reloader: any NativeRimeMaintaining,
        ordinarySync: any RimeSyncEngine,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        retentionStore: RimeBackupRetentionStore = RimeBackupRetentionStore()
    ) {
        self.configuration = configuration
        self.maintenance = maintenance
        self.reloader = reloader
        self.ordinarySync = ordinarySync
        self.fileManager = fileManager
        self.now = now
        reviewStore = RimeReviewStore(url: configuration.sharedRoot.appendingPathComponent("config/rime-review-state.json"), fileManager: fileManager)
        batchStore = RimeAuditBatchStore(url: configuration.sharedRoot.appendingPathComponent("config/rime-audit-batch.json"), fileManager: fileManager)
        syncMetadataStore = RimeUserDictionarySyncMetadataStore(url: configuration.sharedRoot.appendingPathComponent("config/rime-userdata-sync.json"), fileManager: fileManager)
        backupManager = RimeBackupManager(fileManager: fileManager)
        self.retentionStore = retentionStore
        baseDictionaryCache = RimeBaseDictionaryIndexCache(fileManager: fileManager)
    }

    public func prepareAudit() throws -> RimeAuditBatch {
        try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
        // This synchronizes ordinary YAML/resources only.  Its inventory
        // excludes userdb and the generated managed dictionary.
        _ = try ordinarySync.sync(dryRun: false)
        try maintenance.backupUserDictionary(in: configuration.localRimeDirectory)
        try publishCurrentSnapshot()
        return try refreshAuditFromPublishedSnapshots()
    }

    /// Synchronize stable Rime resources without touching live userdb data.
    /// Passing a path set limits the operation to those resources; nil means
    /// all resources allowed by the ordinary sync policy.
    @discardableResult
    public func syncConfiguration(paths: Set<String>? = nil) throws -> SyncReport {
        if let paths {
            return try ordinarySync.sync(paths: paths, dryRun: false)
        }
        return try ordinarySync.sync(dryRun: false)
    }

    /// Rebuild the audit cache from snapshots that already exist in the
    /// shared directory.  This intentionally does not stop Squirrel, invoke
    /// `--sync`, create a runtime backup, or run ordinary resource sync.
    public func refreshAuditFromPublishedSnapshots() throws -> RimeAuditBatch {
        try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
        let snapshots = try loadSnapshots()
        guard !snapshots.isEmpty else { throw RimeSyncError.unsupportedOperation("没有找到 rime_ice.userdb 快照，请先生成当前用户库备份") }
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        return try lock.withLock {
            try rebuildAuditLocked(snapshots: snapshots, observedAt: now(), backupIDToRecord: nil)
        }
    }

    /// Run the user-facing equivalent of Squirrel's “同步用户数据”.  The
    /// native userdb is merged immediately; the audit manager remains an
    /// optional observer rather than a gate in this path.
    public func syncUserDictionary() throws -> RimeUserDictionarySyncReport {
        try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
        let synchronizedAt = now()
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        return try lock.withLock {
            let backupID = try backupManager.createBackup(configuration: configuration, retention: retentionStore.current)
            do {
                try reloader.syncUserData()
                // Capture the merged local userdb after native sync so the
                // other account and the audit cache see the same snapshot.
                try maintenance.backupUserDictionary(in: configuration.localRimeDirectory)
                try publishCurrentSnapshot()
                let snapshots = try loadSnapshots()
                guard !snapshots.isEmpty else {
                    throw RimeSyncError.unsupportedOperation("同步完成后没有找到 rime_ice.userdb 快照")
                }
                let batch = try rebuildAuditLocked(
                    snapshots: snapshots,
                    observedAt: synchronizedAt,
                    backupIDToRecord: backupID
                )
                var metadata = try syncMetadataStore.load()
                let digests = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceInstallationID, $0.digest) })
                metadata.records[configuration.nodeID] = RimeUserDictionarySyncRecord(
                    installationID: configuration.installationID,
                    nodeID: configuration.nodeID,
                    synchronizedAt: synchronizedAt,
                    backupID: backupID,
                    snapshotDigests: digests
                )
                try syncMetadataStore.save(metadata)
                return RimeUserDictionarySyncReport(
                    backupID: backupID,
                    synchronizedAt: synchronizedAt,
                    snapshotDigests: digests,
                    auditBatchID: batch.batchID,
                    entryCount: batch.entries.count
                )
            } catch {
                if let rollbackError = rollbackError(backupID: backupID, originalError: error) {
                    throw rollbackError
                }
                throw error
            }
        }
    }

    private func rebuildAuditLocked(
        snapshots: [RimeUserDictionarySnapshot],
        observedAt timestamp: Date,
        backupIDToRecord: String?
    ) throws -> RimeAuditBatch {
        var state = try normalizedState()
        let wasInitialized = state.initialized
        var pendingBackupID: String?
        do {
            ingest(snapshots, into: &state, baseline: !wasInitialized, observedAt: timestamp)
            state.initialized = true
            pendingBackupID = try applyPendingActionsLocked(state: &state, snapshots: snapshots)
            if let backupIDToRecord {
                recordBackupID(backupIDToRecord, in: &state)
            }
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
        } catch {
            if let pendingBackupID, let rollbackError = rollbackError(backupID: pendingBackupID, originalError: error) {
                throw rollbackError
            }
            throw error
        }
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
        guard !actions.values.contains(.replaceEntry) else {
            throw RimeSyncError.unsupportedOperation("replace_entry 必须通过包含替换目标的审核提案执行")
        }
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
            let backupID = try backupManager.createBackup(configuration: configuration, retention: retentionStore.current)
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
                    if action != .deleteLearned && action != .ignorePermanent {
                        state.pendingActions[id]?.targetSourceIDs.removeAll { $0 == configuration.installationID }
                    }
                    switch action {
                    case .keepDynamic:
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        state.entries.removeValue(forKey: id)
                    case .promotePermanent:
                        guard !state.permanentIgnoredIDs.contains(id) else {
                            throw RimeSyncError.unsupportedOperation("永久忽略的词条不能直接加入长期记忆，请先从备份恢复")
                        }
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        let frequencies = Dictionary(uniqueKeysWithValues: entry.observations.map { ($0.key, max(0, $0.value.commitCount)) })
                        state.entries[id] = RimeManagedEntryState(text: entry.text, code: entry.code, sourceFrequencies: frequencies.isEmpty ? ["manual": 1] : frequencies)
                        promoted += 1
                    case .replaceEntry:
                        throw RimeSyncError.unsupportedOperation("replace_entry 必须通过包含 replacementText 和 replacementCode 的提案执行")
                    case .deleteLearned:
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        state.entries.removeValue(forKey: id)
                        let pending = RimePendingAuditAction(action: action, targetSourceIDs: sourceIDs, approvedCommitCounts: entry.observations.mapValues(\.commitCount), batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, createdAt: now())
                        state.pendingActions[id] = pending
                        tombstones.append(RimeUserDictionaryEntry(text: entry.text, code: entry.code, commitCount: -tombstoneMagnitude(state: state, batch: batch), decay: 0, tick: max(entry.tick, 1)))
                        deleted += 1
                    case .ignorePermanent:
                        state.actions[id] = RimeAuditActionRecord(action: action, sourceNode: configuration.nodeID, batchID: batch.batchID, snapshotDigest: batch.snapshotDigest, recordedAt: now(), backupID: backupID, commitCounts: entry.observations.mapValues(\.commitCount))
                        state.entries.removeValue(forKey: id)
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
                recordBackupID(backupID, in: &state)
                try writeManagedDictionary(from: state)
                try reviewStore.save(state)
                return (backupID, promoted, skipped, deleted, ignored)
            } catch {
                // Nothing is written before the tombstone merge and generated
                // files have a complete backup.  Restore only if a mutation
                // has already started; the operation is still atomic from
                // the user's point of view.
                if let rollbackError = rollbackError(backupID: backupID, originalError: error) {
                    throw rollbackError
                }
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
        } catch let originalError {
            // A configuration sync or reload can still fail after the audit
            // state was written. Restore the complete backup, including the
            // shared review state, while holding the shared lock so another
            // account cannot write between the failure and the rollback.
            do {
                try rollbackWithSharedLock(backupID: applied.backupID, originalError: originalError)
            } catch let recoveryError {
                throw recoveryError
            }
            throw originalError
        }
    }

    /// Apply the persisted proposal shape so a replacement keeps its target
    /// text and code all the way to the core.  The legacy action-only API
    /// intentionally remains available for the original review actions.
    public func apply(proposals: [RimeAuditProposal], for batch: RimeAuditBatch) throws -> RimeReviewApplyReport {
        try validateProposals(proposals, for: batch)
        let replacementProposals = proposals.filter { $0.action == .replaceEntry }
        let ordinaryProposals = proposals.filter { $0.action != .replaceEntry }

        var replacementReport: RimeReviewApplyReport?
        if !replacementProposals.isEmpty {
            replacementReport = try applyReplacementProposals(replacementProposals, for: batch)
        }

        guard !ordinaryProposals.isEmpty else {
            return replacementReport ?? RimeReviewApplyReport(
                importedCount: 0,
                skippedCount: 0,
                backupID: "",
                initialRuntimeRebuilt: false,
                ordinarySync: nil
            )
        }

        let ordinaryReport = try apply(
            batch: batch,
            actions: Dictionary(uniqueKeysWithValues: ordinaryProposals.map { ($0.entryID, $0.action) })
        )
        guard let replacementReport else { return ordinaryReport }
        return RimeReviewApplyReport(
            importedCount: replacementReport.importedCount + ordinaryReport.importedCount,
            skippedCount: replacementReport.skippedCount + ordinaryReport.skippedCount,
            backupID: ordinaryReport.backupID.isEmpty ? replacementReport.backupID : ordinaryReport.backupID,
            initialRuntimeRebuilt: replacementReport.initialRuntimeRebuilt || ordinaryReport.initialRuntimeRebuilt,
            ordinarySync: ordinaryReport.ordinarySync ?? replacementReport.ordinarySync,
            deletedCount: replacementReport.deletedCount + ordinaryReport.deletedCount,
            ignoredCount: replacementReport.ignoredCount + ordinaryReport.ignoredCount,
            replacedCount: replacementReport.replacedCount + ordinaryReport.replacedCount
        )
    }

    private func applyReplacementProposals(
        _ proposals: [RimeAuditProposal],
        for batch: RimeAuditBatch
    ) throws -> RimeReviewApplyReport {
        let snapshots = try loadSnapshots()
        try validateSnapshotDigest(snapshots, for: batch)

        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        var failedBackupID: String?
        let applied: (backupID: String, replaced: Int) = try {
            do {
                return try lock.withLock {
                    let lockedSnapshots = try loadSnapshots()
                    try validateSnapshotDigest(lockedSnapshots, for: batch)
                    var state = try normalizedState()
                    let actionable = proposals.filter { proposal in
                        state.completedActions[completionKey(batchID: batch.batchID, entryID: proposal.entryID)]?.status != .completed
                    }
                    if actionable.isEmpty {
                        let backupID = proposals.compactMap {
                            state.completedActions[completionKey(batchID: batch.batchID, entryID: $0.entryID)]?.backupID
                        }.first ?? ""
                        return (backupID, 0)
                    }

                    try validateReplacementTargets(actionable, batch: batch, snapshots: lockedSnapshots, state: state)
                    let backupID = try backupManager.createBackup(configuration: configuration, retention: retentionStore.current)
                    failedBackupID = backupID
                    do {
                        var mutationEntries: [RimeUserDictionaryEntry] = []
                        let snapshotBySource = Dictionary(uniqueKeysWithValues: lockedSnapshots.map { ($0.sourceInstallationID, $0) })
                        var completedRecords: [(proposal: RimeAuditProposal, old: RimeAuditEntry, sourceEntries: [String: RimeUserDictionaryEntry], replacementID: String)] = []

                        for proposal in actionable {
                            guard let old = batch.entries.first(where: { $0.id == proposal.entryID }),
                                  let replacementText = proposal.replacementText,
                                  let replacementCode = proposal.replacementCode else {
                                throw RimeSyncError.unsupportedOperation("replace_entry 提案缺少替换目标")
                            }
                            let replacementID = RimeUserDictionaryEntry.identity(for: replacementText, code: replacementCode)
                            let sourceEntries = migratedSourceEntries(
                                for: old,
                                snapshots: snapshotBySource
                            )

                            for (sourceID, observation) in old.observations {
                                var observations = state.nodeObservations[sourceID] ?? [:]
                                observations.removeValue(forKey: old.id)
                                observations[replacementID] = RimeAuditObservation(
                                    text: replacementText,
                                    code: replacementCode,
                                    commitCount: observation.commitCount,
                                    decay: observation.decay,
                                    tick: observation.tick,
                                    effectiveDecay: observation.effectiveDecay,
                                    rimeScore: observation.rimeScore,
                                    snapshotDigest: observation.snapshotDigest,
                                    firstSeenAt: observation.firstSeenAt,
                                    lastObservedAt: observation.lastObservedAt,
                                    lastActivityAt: observation.lastActivityAt
                                )
                                state.nodeObservations[sourceID] = observations
                            }

                            state.entries.removeValue(forKey: old.id)
                            state.pendingActions.removeValue(forKey: old.id)
                            let frequencies = sourceEntries.mapValues { max(0, $0.commitCount) }
                            state.entries[replacementID] = RimeManagedEntryState(
                                text: replacementText,
                                code: replacementCode,
                                sourceFrequencies: frequencies.isEmpty ? ["replacement": 1] : frequencies
                            )
                            state.actions[old.id] = RimeAuditActionRecord(
                                action: .replaceEntry,
                                sourceNode: configuration.nodeID,
                                batchID: batch.batchID,
                                snapshotDigest: batch.snapshotDigest,
                                recordedAt: now(),
                                backupID: backupID,
                                commitCounts: old.observations.mapValues(\.commitCount)
                            )
                            let remoteSourceIDs = lockedSnapshots.map(\.sourceInstallationID).filter {
                                $0 != configuration.installationID
                            }
                            if !remoteSourceIDs.isEmpty {
                                state.pendingActions[old.id] = RimePendingAuditAction(
                                    action: .replaceEntry,
                                    targetSourceIDs: remoteSourceIDs,
                                    approvedCommitCounts: old.observations.mapValues(\.commitCount),
                                    batchID: batch.batchID,
                                    snapshotDigest: batch.snapshotDigest,
                                    createdAt: now(),
                                    replacementText: replacementText,
                                    replacementCode: replacementCode
                                )
                            }

                            if let current = sourceEntries[configuration.installationID] {
                                mutationEntries.append(
                                    RimeUserDictionaryEntry(
                                        text: replacementText,
                                        code: replacementCode,
                                        commitCount: current.commitCount,
                                        decay: current.decay,
                                        tick: current.tick
                                    )
                                )
                                mutationEntries.append(
                                    RimeUserDictionaryEntry(
                                        text: old.text,
                                        code: old.code,
                                        commitCount: -tombstoneMagnitude(state: state, batch: batch),
                                        decay: 0,
                                        tick: max(current.tick, 1)
                                    )
                                )
                            }
                            completedRecords.append((proposal, old, sourceEntries, replacementID))
                        }

                        if !mutationEntries.isEmpty {
                            try restoreUserDictionaryEntries(
                                mutationEntries,
                                tick: lockedSnapshots.compactMap(\.tick).max() ?? 1,
                                filePrefix: "replace"
                            )
                        }

                        for record in completedRecords {
                            state.replacementRecords[record.old.id] = RimeAuditReplacementRecord(
                                oldEntryID: record.old.id,
                                oldText: record.old.text,
                                oldCode: record.old.code,
                                replacementText: record.proposal.replacementText ?? "",
                                replacementCode: record.proposal.replacementCode ?? "",
                                sourceEntries: record.sourceEntries,
                                batchID: batch.batchID,
                                snapshotDigest: batch.snapshotDigest,
                                backupID: backupID,
                                executedAt: now(),
                                status: .completed
                            )
                            state.completedActions[completionKey(batchID: batch.batchID, entryID: record.old.id)] = RimeCompletedAuditAction(
                                action: .replaceEntry,
                                nodeID: configuration.nodeID,
                                backupID: backupID,
                                completedAt: now(),
                                status: .completed,
                                oldEntryID: record.old.id,
                                oldText: record.old.text,
                                oldCode: record.old.code,
                                targetText: record.proposal.replacementText,
                                targetCode: record.proposal.replacementCode
                            )
                        }
                        recordBackupID(backupID, in: &state)
                        try writeManagedDictionary(from: state)
                        try reviewStore.save(state)
                        return (backupID, completedRecords.count)
                    } catch {
                        if let rollbackError = rollbackError(backupID: backupID, originalError: error) {
                            throw rollbackError
                        }
                        throw error
                    }
                }
            } catch {
                if let failedBackupID {
                    try? persistReplacementFailures(proposals, batch: batch, backupID: failedBackupID, error: error)
                }
                throw error
            }
        }()

        if applied.replaced == 0 {
            return RimeReviewApplyReport(
                importedCount: 0,
                skippedCount: 0,
                backupID: applied.backupID,
                initialRuntimeRebuilt: false,
                ordinarySync: nil,
                replacedCount: 0
            )
        }

        do {
            let syncReport = try ordinarySync.sync(dryRun: false)
            try reloader.reload()
            return RimeReviewApplyReport(
                importedCount: 0,
                skippedCount: 0,
                backupID: applied.backupID,
                initialRuntimeRebuilt: false,
                ordinarySync: syncReport,
                replacedCount: applied.replaced
            )
        } catch let originalError {
            try rollbackWithSharedLock(backupID: applied.backupID, originalError: originalError)
            try? persistReplacementFailures(proposals, batch: batch, backupID: applied.backupID, error: originalError)
            throw originalError
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
            let backupID = try backupManager.createBackup(configuration: configuration, retention: retentionStore.current)
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
        } catch let originalError {
            do {
                try rollbackWithSharedLock(backupID: backupID, originalError: originalError)
            } catch let recoveryError {
                throw recoveryError
            }
            throw originalError
        }
    }

    public func submitProposals(_ proposals: [RimeAuditProposal], for batch: RimeAuditBatch) throws -> RimeAuditPreview {
        try validateProposals(proposals, for: batch)
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        try lock.withLock {
            let current = try loadSnapshots()
            let currentDigest = aggregateDigest(
                Dictionary(uniqueKeysWithValues: current.map { ($0.sourceInstallationID, $0.digest) })
            )
            guard currentDigest == batch.snapshotDigest else {
                throw RimeSyncError.unsupportedOperation("AI 提案对应的 Rime 快照已变化，请重新导出和分析")
            }
            var state = try normalizedState()
            state.proposals[batch.batchID] = proposals
            try reviewStore.save(state)
        }
        return try previewProposals(for: batch)
    }

    public func previewProposals(for batch: RimeAuditBatch) throws -> RimeAuditPreview {
        let state = try normalizedState()
        let proposals = state.proposals[batch.batchID] ?? []
        let current = try loadSnapshots()
        let digest = aggregateDigest(Dictionary(uniqueKeysWithValues: current.map { ($0.sourceInstallationID, $0.digest) }))
        return preview(
            proposals: proposals,
            batch: batch,
            stale: digest != batch.snapshotDigest,
            snapshots: current,
            state: state
        )
    }

    public func latestBatch() throws -> RimeAuditBatch? { try batchStore.load() }
    public func reviewState() throws -> RimeReviewState { try normalizedState() }
    public func syncMetadata() throws -> RimeUserDictionarySyncMetadata { try syncMetadataStore.load() }
    public var backupRetentionLimit: Int { retentionStore.current.limit }

    @discardableResult
    public func updateBackupRetentionLimit(_ limit: Int) throws -> Int {
        try retentionStore.update(limit: limit).limit
    }

    public func listBackups() throws -> [RimeBackupDescriptor] {
        try backupManager.listBackups(configuration: configuration)
    }

    public func export(batch: RimeAuditBatch, entries: [RimeAuditEntry]? = nil) -> Data {
        RimeAuditCSV.export(batch: batch, entries: entries)
    }

    public func export(
        batch: RimeAuditBatch,
        entries: [RimeAuditEntry],
        format: RimeAuditExportFormat
    ) throws -> Data {
        try RimeAuditExporter.export(batch: batch, entries: entries, format: format)
    }

    public func importProposalCSV(data: Data, for batch: RimeAuditBatch) throws -> RimeAuditPreview {
        let proposals = try RimeAuditCSV.importProposals(data: data, batch: batch)
        return try submitProposals(proposals, for: batch)
    }

    public func restore(backupID: String) throws {
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        try lock.withLock {
            try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
            let rollbackBackupID = try backupManager.createBackup(
                configuration: configuration,
                retention: retentionStore.current,
                pruneAfterCreation: false
            )
            do {
                try backupManager.restore(backupID: backupID, configuration: configuration)
                try reloader.reload()
                try backupManager.pruneBackups(configuration: configuration, retention: retentionStore.current)
            } catch {
                if let rollbackError = rollbackError(backupID: rollbackBackupID, originalError: error) {
                    throw rollbackError
                }
                throw error
            }
        }
    }

    private func validateProposals(_ proposals: [RimeAuditProposal], for batch: RimeAuditBatch) throws {
        let IDs = Set(batch.entries.map(\.id))
        var seen = Set<String>()
        for proposal in proposals {
            guard proposal.schemaVersion == batch.schemaVersion, proposal.batchID == batch.batchID, proposal.snapshotDigest == batch.snapshotDigest else { throw RimeSyncError.unsupportedOperation("AI 提案批次或快照已过期") }
            guard IDs.contains(proposal.entryID) else { throw RimeSyncError.unsupportedOperation("AI 提案包含未知词条 ID") }
            guard seen.insert(proposal.entryID).inserted else { throw RimeSyncError.unsupportedOperation("AI 提案包含重复词条 ID") }
            if proposal.action == .replaceEntry {
                guard let text = proposal.replacementText,
                      let code = proposal.replacementCode,
                      RimeUserDictionaryValidator.isValidWord(text),
                      RimeUserDictionaryValidator.isValidCode(code) else {
                    throw RimeSyncError.unsupportedOperation("replace_entry 提案必须包含有效的 replacementText 和 replacementCode")
                }
            }
        }
    }

    private func validateSnapshotDigest(_ snapshots: [RimeUserDictionarySnapshot], for batch: RimeAuditBatch) throws {
        let digests = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceInstallationID, $0.digest) })
        guard digests == batch.snapshotDigests else {
            throw RimeSyncError.unsupportedOperation("审核期间 Rime 快照已变化，请重新预览后再确认")
        }
    }

    private func validateReplacementTargets(
        _ proposals: [RimeAuditProposal],
        batch: RimeAuditBatch,
        snapshots: [RimeUserDictionarySnapshot],
        state: RimeReviewState
    ) throws {
        let existingIDs = Set(snapshots.flatMap { $0.entries.map(\.identity) })
            .union(state.entries.keys)
            .union(state.nodeObservations.values.flatMap { $0.keys })
        var targetIDs = Set<String>()
        for proposal in proposals {
            guard let old = batch.entries.first(where: { $0.id == proposal.entryID }),
                  let replacementText = proposal.replacementText,
                  let replacementCode = proposal.replacementCode else {
                throw RimeSyncError.unsupportedOperation("replace_entry 提案缺少旧词或替换目标")
            }
            guard old.commitCount >= 0 else {
                throw RimeSyncError.unsupportedOperation("已删除的词条不能作为 replace_entry 的旧词")
            }
            let targetID = RimeUserDictionaryEntry.identity(for: replacementText, code: replacementCode)
            guard targetID != old.id else {
                throw RimeSyncError.unsupportedOperation("replace_entry 的新旧词条身份相同")
            }
            let targetExistsInStaticDictionary = (try? baseDictionaryCache.index(for: configuration.localRimeDirectory).contains(text: replacementText, code: replacementCode)) ?? false
            guard !existingIDs.contains(targetID), !targetExistsInStaticDictionary else {
                throw RimeSyncError.unsupportedOperation("replace_entry 目标词条已存在，请人工审核后再处理")
            }
            guard targetIDs.insert(targetID).inserted else {
                throw RimeSyncError.unsupportedOperation("多个 replace_entry 提案使用了同一个目标词条")
            }
        }
    }

    private func migratedSourceEntries(
        for old: RimeAuditEntry,
        snapshots: [String: RimeUserDictionarySnapshot]
    ) -> [String: RimeUserDictionaryEntry] {
        var result: [String: RimeUserDictionaryEntry] = [:]
        for (sourceID, observation) in old.observations {
            if let raw = snapshots[sourceID]?.entries.first(where: { $0.identity == old.id }) {
                result[sourceID] = raw
            } else {
                result[sourceID] = RimeUserDictionaryEntry(
                    text: old.text,
                    code: old.code,
                    commitCount: observation.commitCount,
                    decay: observation.decay,
                    tick: observation.tick
                )
            }
        }
        return result
    }

    private func preview(
        proposals: [RimeAuditProposal],
        batch: RimeAuditBatch,
        stale: Bool,
        snapshots: [RimeUserDictionarySnapshot] = [],
        state: RimeReviewState? = nil
    ) -> RimeAuditPreview {
        var counts: [String: Int] = [:]
        for proposal in proposals { counts[proposal.action.rawValue, default: 0] += 1 }
        let snapshotBySource = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceInstallationID, $0) })
        let existingIDs = Set(snapshots.flatMap { $0.entries.map(\.identity) })
            .union(state.map { Set($0.entries.keys) } ?? [])
            .union(state.map { Set($0.nodeObservations.values.flatMap { $0.keys }) } ?? [])
        let replacements = proposals.compactMap { proposal -> RimeAuditReplacementPreview? in
            guard proposal.action == .replaceEntry,
                  let old = batch.entries.first(where: { $0.id == proposal.entryID }),
                  let replacementText = proposal.replacementText,
                  let replacementCode = proposal.replacementCode else { return nil }
            return RimeAuditReplacementPreview(
                entryID: old.id,
                oldText: old.text,
                oldCode: old.code,
                replacementText: replacementText,
                replacementCode: replacementCode,
                sourceEntries: migratedSourceEntries(for: old, snapshots: snapshotBySource),
                targetExists: existingIDs.contains(RimeUserDictionaryEntry.identity(for: replacementText, code: replacementCode))
                    || ((try? baseDictionaryCache.index(for: configuration.localRimeDirectory).contains(text: replacementText, code: replacementCode)) ?? false),
                willBecomePermanent: true,
                generatedByReplaceEntry: true
            )
        }
        return RimeAuditPreview(
            batchID: batch.batchID,
            snapshotDigest: batch.snapshotDigest,
            countsByAction: counts,
            proposalCount: proposals.count,
            stale: stale,
            replacements: replacements
        )
    }

    private func normalizedState() throws -> RimeReviewState {
        var state = try reviewStore.load()
        let managedURL = configuration.localRimeDirectory.appendingPathComponent(RimeManagedDictionary.fileName)
        if fileManager.fileExists(atPath: managedURL.path) {
            let legacyEntries = RimeManagedDictionary.parse(data: try Data(contentsOf: managedURL))
            var importedCount = 0
            for entry in legacyEntries where state.entries[entry.identity] == nil && !state.permanentIgnoredIDs.contains(entry.identity) {
                state.entries[entry.identity] = RimeManagedEntryState(text: entry.text, code: entry.code, sourceFrequencies: ["legacy-managed": 1])
                importedCount += 1
            }
            if importedCount > 0 || (!legacyEntries.isEmpty && !state.initialized) {
                state.migration.legacyManagedEntries = max(state.migration.legacyManagedEntries, legacyEntries.count)
                state.initialized = true
            }
        }
        return state
    }

    private func ingest(_ snapshots: [RimeUserDictionarySnapshot], into state: inout RimeReviewState, baseline: Bool, observedAt: Date) {
        for snapshot in snapshots {
            var observations = state.nodeObservations[snapshot.sourceInstallationID] ?? [:]
            for entry in snapshot.entries {
                let replacement = state.replacementRecords[entry.identity]
                if replacement?.status == .completed, entry.isTombstone {
                    continue
                }
                let observedID = replacement?.status == .completed ? replacement?.replacementEntryID ?? entry.identity : entry.identity
                if let replacement,
                   replacement.status == .completed,
                   let original = replacement.sourceEntries[snapshot.sourceInstallationID],
                   let existing = observations[observedID],
                   entry.commitCount <= original.commitCount {
                    // The shared snapshot can still contain the pre-replace
                    // row until this installation publishes again. Do not
                    // let that stale old key overwrite the migrated target.
                    _ = existing
                    continue
                }
                let metrics = RimeScoring.metrics(for: entry, snapshotTick: snapshot.tick)
                let previous = observations[observedID]
                let activity: Date?
                if baseline { activity = previous?.lastActivityAt }
                else if previous == nil || entry.commitCount > (previous?.commitCount ?? Int.min) { activity = observedAt }
                else { activity = previous?.lastActivityAt }
                observations[observedID] = RimeAuditObservation(
                    text: replacement?.status == .completed ? replacement?.replacementText ?? entry.text : entry.text,
                    code: replacement?.status == .completed ? replacement?.replacementCode ?? entry.code : entry.code,
                    commitCount: entry.commitCount, decay: entry.decay, tick: entry.tick,
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
                isNoise: asciiNoise, isStale: stale,
                generatedByReplaceEntry: state.replacementRecords.values.contains {
                    $0.status == .completed && $0.replacementEntryID == id
                } ? true : nil
            )
        }.sorted { lhs, rhs in
            if lhs.rimeScore != rhs.rimeScore { return lhs.rimeScore > rhs.rimeScore }
            return lhs.id < rhs.id
        }
    }

    private func applyPendingActionsLocked(state: inout RimeReviewState, snapshots: [RimeUserDictionarySnapshot]) throws -> String? {
        let currentID = configuration.installationID
        var mutationEntries: [RimeUserDictionaryEntry] = []
        var pendingIDs: [String] = []
        var replacementIDs: [String] = []
        var appliedBackupID: String?
        for (id, pending) in state.pendingActions {
            if pending.action == .ignorePermanent {
                // A persistent ignore is mutually exclusive with the
                // generated long-term dictionary, including after a legacy
                // state merge or a later re-learning event.
                state.entries.removeValue(forKey: id)
            }
            let isContinuousIgnore = pending.action == .ignorePermanent && state.permanentIgnoredIDs.contains(id)
            guard pending.targetSourceIDs.contains(currentID) || isContinuousIgnore else { continue }

            if pending.action == .replaceEntry {
                guard let replacementText = pending.replacementText,
                      let replacementCode = pending.replacementCode,
                      RimeUserDictionaryValidator.isValidWord(replacementText),
                      RimeUserDictionaryValidator.isValidCode(replacementCode) else {
                    throw RimeSyncError.unsupportedOperation("待同步的 replace_entry 缺少有效替换目标")
                }
                let currentDigest = aggregateDigest(
                    Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sourceInstallationID, $0.digest) })
                )
                guard currentDigest == pending.snapshotDigest else {
                    throw RimeSyncError.unsupportedOperation("replace_entry 批次或快照已过期，请重新生成审核批次")
                }
                guard let current = snapshots
                    .first(where: { $0.sourceInstallationID == currentID })?
                    .entries
                    .first(where: { $0.identity == id }) else {
                    state.pendingActions[id]?.targetSourceIDs.removeAll { $0 == currentID }
                    continue
                }
                let replacementID = RimeUserDictionaryEntry.identity(for: replacementText, code: replacementCode)
                let targetExists = snapshots.contains { snapshot in
                    snapshot.entries.contains { $0.identity == replacementID }
                }
                let targetWasGeneratedByThisReplacement = state.replacementRecords[id].map {
                    $0.status == .completed && $0.replacementEntryID == replacementID
                } ?? false
                guard (!targetExists || targetWasGeneratedByThisReplacement), replacementID != id else {
                    throw RimeSyncError.unsupportedOperation("replace_entry 目标词条已存在，请人工审核后再处理")
                }
                if state.entries[replacementID] == nil {
                    state.entries[replacementID] = RimeManagedEntryState(
                        text: replacementText,
                        code: replacementCode,
                        sourceFrequencies: [currentID: max(0, current.commitCount)]
                    )
                }
                mutationEntries.append(RimeUserDictionaryEntry(
                    text: replacementText,
                    code: replacementCode,
                    commitCount: current.commitCount,
                    decay: current.decay,
                    tick: current.tick
                ))
                mutationEntries.append(RimeUserDictionaryEntry(
                    text: current.text,
                    code: current.code,
                    commitCount: -tombstoneMagnitude(state: state, batch: nil),
                    decay: 0,
                    tick: max(current.tick, 1)
                ))
                replacementIDs.append(id)
                continue
            }

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
            mutationEntries.append(RimeUserDictionaryEntry(text: current.text, code: current.code, commitCount: -tombstoneMagnitude(state: state, batch: nil), decay: 0, tick: max(current.tick, 1)))
            pendingIDs.append(id)
        }
        if !mutationEntries.isEmpty {
            let backupID = try backupManager.createBackup(configuration: configuration, retention: retentionStore.current)
            appliedBackupID = backupID
            do {
                try restoreUserDictionaryEntries(mutationEntries, tick: snapshots.compactMap(\.tick).max() ?? 1, filePrefix: "pending")
                recordBackupID(backupID, in: &state)
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
                for id in replacementIDs {
                    guard let pending = state.pendingActions[id],
                          let replacementText = pending.replacementText,
                          let replacementCode = pending.replacementCode else { continue }
                    state.pendingActions[id]?.targetSourceIDs.removeAll { $0 == currentID }
                    state.actions[id] = RimeAuditActionRecord(
                        action: .replaceEntry,
                        sourceNode: configuration.nodeID,
                        batchID: pending.batchID,
                        snapshotDigest: pending.snapshotDigest,
                        recordedAt: now(),
                        backupID: backupID,
                        commitCounts: pending.approvedCommitCounts
                    )
                    state.completedActions["\(pending.batchID):\(configuration.nodeID):\(id)"] = RimeCompletedAuditAction(
                        action: .replaceEntry,
                        nodeID: configuration.nodeID,
                        backupID: backupID,
                        completedAt: now(),
                        status: .completed,
                        oldEntryID: id,
                        targetText: replacementText,
                        targetCode: replacementCode
                    )
                }
            } catch {
                if let rollbackError = rollbackError(backupID: backupID, originalError: error) {
                    throw rollbackError
                }
                throw error
            }
            do {
                try reloader.reload()
            } catch {
                // The tombstone has already been merged at this point.  A
                // failed reload is still an apply failure, so put the live
                // Rime directory back before allowing the caller to retry.
                if let rollbackError = rollbackError(backupID: backupID, originalError: error) {
                    throw rollbackError
                }
                throw error
            }
        }
        state.pendingActions = state.pendingActions.filter { !$0.value.targetSourceIDs.isEmpty || $0.value.action == .ignorePermanent }
        return appliedBackupID
    }

    private func restoreUserDictionaryEntries(
        _ entries: [RimeUserDictionaryEntry],
        tick: Int64,
        filePrefix: String
    ) throws {
        let url = configuration.localRimeDirectory.deletingLastPathComponent().appendingPathComponent(".rime-\(filePrefix)-\(UUID().uuidString).userdb.txt")
        defer { try? fileManager.removeItem(at: url) }
        let snapshot = RimeUserDictionarySnapshot(sourceInstallationID: configuration.installationID, rimeVersion: nil, tick: tick, entries: entries)
        try AtomicFileStore.write(snapshot.serializedData(), to: url, fileManager: fileManager)
        try maintenance.restoreUserDictionarySnapshot(from: url, in: configuration.localRimeDirectory)
    }

    private func restoreTombstones(_ entries: [RimeUserDictionaryEntry], tick: Int64) throws {
        try restoreUserDictionaryEntries(entries, tick: tick, filePrefix: "tombstone")
    }

    private func completionKey(batchID: String, entryID: String) -> String {
        "\(batchID):\(configuration.nodeID):\(entryID)"
    }

    private func persistReplacementFailures(
        _ proposals: [RimeAuditProposal],
        batch: RimeAuditBatch,
        backupID: String,
        error: Error
    ) throws {
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        try lock.withLock {
            var state = try normalizedState()
            let snapshotBySource = Dictionary(uniqueKeysWithValues: ((try? loadSnapshots()) ?? []).map { ($0.sourceInstallationID, $0) })
            for proposal in proposals {
                guard let old = batch.entries.first(where: { $0.id == proposal.entryID }),
                      let replacementText = proposal.replacementText,
                      let replacementCode = proposal.replacementCode else { continue }
                let sourceEntries = migratedSourceEntries(for: old, snapshots: snapshotBySource)
                state.replacementRecords[old.id] = RimeAuditReplacementRecord(
                    oldEntryID: old.id,
                    oldText: old.text,
                    oldCode: old.code,
                    replacementText: replacementText,
                    replacementCode: replacementCode,
                    sourceEntries: sourceEntries,
                    batchID: batch.batchID,
                    snapshotDigest: batch.snapshotDigest,
                    backupID: backupID,
                    executedAt: now(),
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
                state.completedActions[completionKey(batchID: batch.batchID, entryID: old.id)] = RimeCompletedAuditAction(
                    action: .replaceEntry,
                    nodeID: configuration.nodeID,
                    backupID: backupID,
                    completedAt: now(),
                    status: .failed,
                    oldEntryID: old.id,
                    oldText: old.text,
                    oldCode: old.code,
                    targetText: replacementText,
                    targetCode: replacementCode,
                    errorMessage: error.localizedDescription
                )
            }
            try reviewStore.save(state)
        }
    }

    private func tombstoneMagnitude(state: RimeReviewState, batch: RimeAuditBatch?) -> Int {
        let stateMaximum = state.nodeObservations.values.flatMap { $0.values }.map { abs($0.commitCount) }.max() ?? 0
        let batchMaximum = batch?.entries.map { abs($0.commitCount) }.max() ?? 0
        return max(1_000_000, max(stateMaximum, batchMaximum) + 1)
    }

    private func recordBackupID(_ backupID: String, in state: inout RimeReviewState) {
        var uniqueIDs: [String] = []
        for id in ([backupID] + state.backupIDs) where !uniqueIDs.contains(id) {
            uniqueIDs.append(id)
        }
        state.backupIDs = Array(uniqueIDs.prefix(retentionStore.current.limit))
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

    /// Restore the complete pre-mutation snapshot and reload Rime.  Returning
    /// a combined error keeps a failed recovery visible instead of silently
    /// leaving a partially applied user dictionary behind.
    private func rollbackError(backupID: String, originalError: Error) -> RimeSyncError? {
        do {
            try backupManager.restore(backupID: backupID, configuration: configuration)
            try reloader.reload()
            return nil
        } catch {
            return .unsupportedOperation(
                "Rime 操作失败：\(originalError.localizedDescription)；回滚也失败：\(error.localizedDescription)；请使用备份 \(backupID) 恢复"
            )
        }
    }

    private func rollbackWithSharedLock(backupID: String, originalError: Error) throws {
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        try lock.withLock {
            if let recoveryError = rollbackError(backupID: backupID, originalError: originalError) {
                throw recoveryError
            }
        }
    }
}
