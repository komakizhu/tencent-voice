import CryptoKit
import Foundation

public enum FileState: String, Codable, Equatable, Sendable {
    case present
    case tombstone
}

public struct FileRecord: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String
    public let state: FileState
    public let modifiedNanoseconds: Int64
    public let byteCount: Int64
    public let sha256: String?
    public let owner: String

    public init(
        relativePath: String,
        state: FileState,
        modifiedNanoseconds: Int64,
        byteCount: Int64,
        sha256: String?,
        owner: String
    ) {
        self.relativePath = relativePath
        self.state = state
        self.modifiedNanoseconds = modifiedNanoseconds
        self.byteCount = byteCount
        self.sha256 = sha256
        self.owner = owner
    }

    public static func present(
        path: String,
        modifiedNanoseconds: Int64,
        byteCount: Int64,
        sha256: String,
        owner: String
    ) -> FileRecord {
        FileRecord(
            relativePath: path,
            state: .present,
            modifiedNanoseconds: modifiedNanoseconds,
            byteCount: byteCount,
            sha256: sha256,
            owner: owner
        )
    }

    public static func tombstone(path: String, modifiedNanoseconds: Int64, owner: String) -> FileRecord {
        FileRecord(
            relativePath: path,
            state: .tombstone,
            modifiedNanoseconds: modifiedNanoseconds,
            byteCount: 0,
            sha256: nil,
            owner: owner
        )
    }

    public var contentIdentity: String {
        "\(state.rawValue):\(byteCount):\(sha256 ?? "")"
    }

    public func changingOwner(to owner: String) -> FileRecord {
        FileRecord(
            relativePath: relativePath,
            state: state,
            modifiedNanoseconds: modifiedNanoseconds,
            byteCount: byteCount,
            sha256: sha256,
            owner: owner
        )
    }
}

public enum RimeConflictReason: String, Codable, Equatable, Sendable {
    case overlappingEdits
    case missingBaseline
    case baselineMismatch
    case deletionConflict
    case historical
    case firstSync
    case missingData

    public var displayName: String {
        switch self {
        case .overlappingEdits: return "双方修改重叠，需要选择"
        case .missingBaseline: return "缺少共同历史，需要首次对齐"
        case .baselineMismatch: return "共同基线与记录不一致，需要确认"
        case .deletionConflict: return "删除与修改冲突，需要选择"
        case .historical: return "历史冲突，需要确认"
        case .firstSync: return "首次同步，需要选择"
        case .missingData: return "冲突来源缺失，需要确认"
        }
    }
}

/// Durable conflict information. It is optional in the manifest so older
/// shared directories remain readable and can be upgraded conservatively.
public struct RimeConflictRecord: Codable, Equatable, Sendable {
    public let relativePath: String
    public var nodeRecords: [String: FileRecord]
    public var sharedRecord: FileRecord?
    public var baselineRecord: FileRecord?
    public var reason: RimeConflictReason
    public var artifactID: String?
    public var createdAt: Date?

    public init(
        relativePath: String,
        nodeRecords: [String: FileRecord] = [:],
        sharedRecord: FileRecord? = nil,
        baselineRecord: FileRecord? = nil,
        reason: RimeConflictReason,
        artifactID: String? = nil,
        createdAt: Date? = Date()
    ) {
        self.relativePath = relativePath
        self.nodeRecords = nodeRecords
        self.sharedRecord = sharedRecord
        self.baselineRecord = baselineRecord
        self.reason = reason
        self.artifactID = artifactID
        self.createdAt = createdAt
    }
}

public struct RimeConflictSummary: Equatable, Sendable {
    public let relativePath: String
    public let nodeIDs: [String]
    public let reason: RimeConflictReason
    public let hasBaseline: Bool

    public init(
        relativePath: String,
        nodeIDs: [String],
        reason: RimeConflictReason,
        hasBaseline: Bool
    ) {
        self.relativePath = relativePath
        self.nodeIDs = nodeIDs.sorted()
        self.reason = reason
        self.hasBaseline = hasBaseline
    }
}

public struct RimeConflictVariant: Equatable, Sendable {
    public let nodeID: String
    public let record: FileRecord
    public let text: String?

    public init(nodeID: String, record: FileRecord, text: String?) {
        self.nodeID = nodeID
        self.record = record
        self.text = text
    }
}

public struct RimeConflictPreview: Equatable, Sendable {
    public let relativePath: String
    public let reason: RimeConflictReason
    public let variants: [RimeConflictVariant]
    public let localRecord: FileRecord?
    public let sharedRecord: FileRecord?
    public let baselineRecord: FileRecord?
    public let localText: String?
    public let sharedText: String?
    public let suggestedMerge: String?
    public let versionToken: String

    public init(
        relativePath: String,
        reason: RimeConflictReason,
        variants: [RimeConflictVariant],
        localRecord: FileRecord?,
        sharedRecord: FileRecord?,
        baselineRecord: FileRecord?,
        localText: String?,
        sharedText: String?,
        suggestedMerge: String?,
        versionToken: String
    ) {
        self.relativePath = relativePath
        self.reason = reason
        self.variants = variants.sorted { $0.nodeID < $1.nodeID }
        self.localRecord = localRecord
        self.sharedRecord = sharedRecord
        self.baselineRecord = baselineRecord
        self.localText = localText
        self.sharedText = sharedText
        self.suggestedMerge = suggestedMerge
        self.versionToken = versionToken
    }

    public var summary: RimeConflictSummary {
        RimeConflictSummary(
            relativePath: relativePath,
            nodeIDs: variants.map(\.nodeID),
            reason: reason,
            hasBaseline: baselineRecord != nil
        )
    }
}

public enum RimeConflictResolution: Equatable, Sendable {
    case keepLocal
    case keepShared
    case merge(String)
}

public enum SyncOperationKind: String, Equatable, Hashable, Sendable {
    case upload
    case download
    case merge
    case deleteLocal
    case deleteShared

    public var displayName: String {
        switch self {
        case .upload: return "上传"
        case .download: return "下载"
        case .merge: return "合并"
        case .deleteLocal: return "删除本地"
        case .deleteShared: return "删除共享"
        }
    }
}

public struct SyncFileOperation: Equatable, Sendable {
    public let relativePath: String
    public let kind: SyncOperationKind

    public init(relativePath: String, kind: SyncOperationKind) {
        self.relativePath = relativePath
        self.kind = kind
    }
}

public enum RimeResourcePolicy {
    public static let skinConfigurationPath = "squirrel.custom.yaml"

    private static let excludedTopLevelNames: Set<String> = [
        "build", "trash", "sync", "weasel.yaml", "installation.yaml", "user.yaml"
    ]
    private static let credentialNameTokens: Set<String> = [
        "credential", "credentials", "secret", "secrets", "token", "tokens",
        "password", "passwords", "passwd", "auth", "authentication", "authorization", "oauth"
    ]
    private static let credentialNameCompounds: Set<String> = [
        "apikey", "accesskey", "privatekey", "sshkey", "clientsecret"
    ]

    public static func isAllowed(relativePath: String) -> Bool {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            return false
        }

        let components = path.split(separator: "/").map(String.init)
        let canonicalComponents = components.map(canonicalResourceName)
        guard let topLevel = canonicalComponents.first else { return false }
        guard !canonicalComponents.contains(where: isCredentialPathComponent) else { return false }
        guard !excludedTopLevelNames.contains(where: { canonicalResourceName($0) == topLevel }) else { return false }
        guard !canonicalComponents.contains(where: { $0 == ".ds_store" || $0.hasSuffix(".userdb") }) else {
            return false
        }
        let canonicalPath = canonicalComponents.joined(separator: "/")
        guard !canonicalPath.hasSuffix(".userdb.txt") else { return false }
        guard !canonicalPath.hasSuffix(".log") else { return false }
        // This file is generated from the shared audit state.  Letting the
        // ordinary configuration sync manage it would race with the audit
        // coordinator and could silently resurrect a rejected entry.
        guard canonicalPath != canonicalResourceName("rime_managed.dict.yaml") else { return false }

        if ["cn_dicts", "en_dicts", "wanxiang_dicts", "lua", "opencc", "rime-mate-config"].contains(topLevel) {
            return true
        }
        if topLevel == canonicalResourceName("Rime配置助手.command") {
            return components.count == 1
        }
        if topLevel == canonicalResourceName("wanxiang-lts-zh-hans.gram") {
            return components.count == 1
        }
        guard components.count == 1 else { return false }
        return topLevel.hasSuffix(".yaml") || topLevel.hasSuffix(".dict.yaml") || topLevel.hasSuffix(".txt")
    }

    private static func canonicalResourceName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func isCredentialPathComponent(_ component: String) -> Bool {
        let tokens = component.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else { return false }
        if tokens.contains(where: { credentialNameTokens.contains($0) }) { return true }
        let compact = tokens.joined()
        return credentialNameCompounds.contains(where: { compact.contains($0) })
    }
}

public enum RimeSyncError: LocalizedError, Equatable {
    case invalidRelativePath(String)
    case missingDirectory(URL)
    case commandFailed(String)
    case backupNotFound(String)
    case lockUnavailable(URL)
    case conflictNotFound(String)
    case conflictChanged(String)
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path): return "非法相对路径：\(path)"
        case let .missingDirectory(url): return "目录不存在：\(url.path)"
        case let .commandFailed(message): return "命令执行失败：\(message)"
        case let .backupNotFound(id): return "备份不存在：\(id)"
        case let .lockUnavailable(url): return "同步锁不可用：\(url.path)"
        case let .conflictNotFound(path): return "没有找到待处理冲突：\(path)"
        case let .conflictChanged(path): return "冲突内容已变化，请刷新预览后再应用：\(path)"
        case let .unsupportedOperation(message): return message
        }
    }
}

public struct RimeFileInventory {
    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    public func scan(owner: String) throws -> [FileRecord] {
        var records: [FileRecord] = []
        guard fileManager.fileExists(atPath: root.path) else {
            throw RimeSyncError.missingDirectory(root)
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            let resolvedURL = url.resolvingSymlinksInPath()
            let relativePath = resolvedURL.path.replacingOccurrences(of: root.path + "/", with: "")
            guard RimeResourcePolicy.isAllowed(relativePath: relativePath) else {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isDirectory != true, values.isSymbolicLink != true else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let modifiedNanoseconds = Int64(((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000_000_000).rounded())
            records.append(
                FileRecord.present(
                    path: relativePath,
                    modifiedNanoseconds: modifiedNanoseconds,
                    byteCount: Int64(values.fileSize ?? data.count),
                    sha256: digest,
                    owner: owner
                )
            )
        }

        return records.sorted { $0.relativePath < $1.relativePath }
    }
}

public struct RimeManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var records: [String: FileRecord]
    public var nodes: [String: [String: FileRecord]]
    public var pausedPaths: Set<String>
    public var conflicts: [String: RimeConflictRecord]

    public init(
        schemaVersion: Int = 2,
        records: [String: FileRecord] = [:],
        nodes: [String: [String: FileRecord]] = [:],
        pausedPaths: Set<String> = [],
        conflicts: [String: RimeConflictRecord] = [:]
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.records = records
        self.nodes = nodes
        self.pausedPaths = pausedPaths
        self.conflicts = conflicts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, records, nodes, pausedPaths, conflicts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = max(1, try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1)
        self.records = try container.decodeIfPresent([String: FileRecord].self, forKey: .records) ?? [:]
        self.nodes = try container.decodeIfPresent([String: [String: FileRecord]].self, forKey: .nodes) ?? [:]
        self.pausedPaths = try container.decodeIfPresent(Set<String>.self, forKey: .pausedPaths) ?? []
        self.conflicts = try container.decodeIfPresent([String: RimeConflictRecord].self, forKey: .conflicts) ?? [:]
    }

    public func saving(to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.rimeEncoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func loading(from url: URL, fileManager: FileManager = .default) throws -> RimeManifest {
        guard fileManager.fileExists(atPath: url.path) else { return RimeManifest() }
        return try JSONDecoder.rimeDecoder.decode(RimeManifest.self, from: Data(contentsOf: url))
    }
}

public extension JSONEncoder {
    static var rimeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var rimeDecoder: JSONDecoder { JSONDecoder() }
}

public enum SyncDecision: Equatable, Sendable {
    case unchanged
    case local
    case shared
    case merge
    case conflict
}

public enum ThreeWayMergeResolver {
    public static func resolve(local: FileRecord?, shared: FileRecord?, baseline: FileRecord?) -> SyncDecision {
        guard let local, let shared else {
            return local == nil && shared == nil ? .unchanged : (local == nil ? .shared : .local)
        }
        let localChanged = baseline.map { $0.contentIdentity != local.contentIdentity } ?? true
        let sharedChanged = baseline.map { $0.contentIdentity != shared.contentIdentity } ?? true
        if local.contentIdentity == shared.contentIdentity {
            return .unchanged
        }
        if localChanged && !sharedChanged { return .local }
        if sharedChanged && !localChanged { return .shared }
        guard baseline != nil else { return .conflict }
        if local.modifiedNanoseconds != shared.modifiedNanoseconds {
            return .merge
        }
        return .conflict
    }
}

/// Compatibility name for clients built against the earlier resolver API.
public typealias LastWriterWinsResolver = ThreeWayMergeResolver
