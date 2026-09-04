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
}

public enum RimeResourcePolicy {
    private static let excludedTopLevelNames: Set<String> = [
        "build", "trash", "sync", "weasel.yaml", "installation.yaml", "user.yaml"
    ]

    public static func isAllowed(relativePath: String) -> Bool {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            return false
        }

        let components = path.split(separator: "/").map(String.init)
        guard let topLevel = components.first else { return false }
        guard !excludedTopLevelNames.contains(topLevel) else { return false }
        guard !components.contains(where: { $0 == ".DS_Store" || $0.hasSuffix(".userdb") }) else {
            return false
        }
        guard !path.hasSuffix(".userdb.txt") else { return false }
        guard !path.hasSuffix(".log") else { return false }

        if ["cn_dicts", "en_dicts", "wanxiang_dicts", "lua", "opencc", "rime-mate-config"].contains(topLevel) {
            return true
        }
        if topLevel == "Rime配置助手.command" {
            return components.count == 1
        }
        if topLevel == "wanxiang-lts-zh-hans.gram" {
            return components.count == 1
        }
        guard components.count == 1 else { return false }
        return topLevel.hasSuffix(".yaml") || topLevel.hasSuffix(".dict.yaml") || topLevel.hasSuffix(".txt")
    }
}

public enum RimeSyncError: LocalizedError, Equatable {
    case invalidRelativePath(String)
    case missingDirectory(URL)
    case commandFailed(String)
    case backupNotFound(String)
    case lockUnavailable(URL)
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path): return "非法相对路径：\(path)"
        case let .missingDirectory(url): return "目录不存在：\(url.path)"
        case let .commandFailed(message): return "命令执行失败：\(message)"
        case let .backupNotFound(id): return "备份不存在：\(id)"
        case let .lockUnavailable(url): return "同步锁不可用：\(url.path)"
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

    public init(
        schemaVersion: Int = 1,
        records: [String: FileRecord] = [:],
        nodes: [String: [String: FileRecord]] = [:],
        pausedPaths: Set<String> = []
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.nodes = nodes
        self.pausedPaths = pausedPaths
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
    case conflict
}

public enum LastWriterWinsResolver {
    public static func resolve(local: FileRecord?, shared: FileRecord?, baseline: FileRecord?) -> SyncDecision {
        guard let local, let shared else {
            return local == nil && shared == nil ? .unchanged : (local == nil ? .shared : .local)
        }
        if local.contentIdentity == shared.contentIdentity { return .unchanged }

        let localChanged = baseline.map { $0.contentIdentity != local.contentIdentity } ?? true
        let sharedChanged = baseline.map { $0.contentIdentity != shared.contentIdentity } ?? true
        if localChanged && !sharedChanged { return .local }
        if sharedChanged && !localChanged { return .shared }
        if local.modifiedNanoseconds > shared.modifiedNanoseconds { return .local }
        if shared.modifiedNanoseconds > local.modifiedNanoseconds { return .shared }
        return .conflict
    }
}
