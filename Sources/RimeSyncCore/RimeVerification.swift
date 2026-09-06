import Foundation

public struct RimeVerificationResult: Equatable, Sendable {
    public let issues: [String]

    public init(issues: [String] = []) {
        self.issues = issues
    }

    public var isValid: Bool { issues.isEmpty }
}

public struct RimeVerifier {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func verify(configuration: SyncConfiguration) -> RimeVerificationResult {
        var issues: [String] = []
        if !fileManager.fileExists(atPath: configuration.localRimeDirectory.path) {
            issues.append("本地 Rime 目录不存在：\(configuration.localRimeDirectory.path)")
        }
        do {
            let installationURL = configuration.localRimeDirectory.appendingPathComponent("installation.yaml")
            guard let installation = try RimeInstallationFile.loading(from: installationURL, fileManager: fileManager) else {
                issues.append("installation.yaml 缺少 installation_id")
                throw RimeSyncError.unsupportedOperation("installation.yaml 无法解析")
            }
            if installation.installationID != configuration.installationID {
                issues.append("installation_id 不匹配：期望 \(configuration.installationID)，实际 \(installation.installationID)")
            }
            if installation.syncDirectory != configuration.sharedRoot.appendingPathComponent("rime-userdata").path {
                issues.append("sync_dir 未指向共享 userdb 快照目录")
            }
        } catch {
            if !issues.contains(where: { $0.contains("installation.yaml") }) {
                issues.append("读取 installation.yaml 失败：\(error.localizedDescription)")
            }
        }

        do {
            let manifest = try RimeManifest.loading(from: configuration.manifestURL, fileManager: fileManager)
            var nodeInventories: [String: [String: FileRecord]] = [:]
            for record in manifest.records.values where record.state == .present {
                let nodeURL = configuration.sharedConfigRoot
                    .appendingPathComponent("nodes", isDirectory: true)
                    .appendingPathComponent(record.owner, isDirectory: true)
                let fileURL = try AtomicFileStore.safeURL(root: nodeURL, relativePath: record.relativePath)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    issues.append("manifest 指向的共享节点文件缺失：\(record.relativePath)")
                    continue
                }
                if nodeInventories[record.owner] == nil {
                    let inventory = try RimeFileInventory(root: nodeURL, fileManager: fileManager).scan(owner: record.owner)
                    nodeInventories[record.owner] = Dictionary(uniqueKeysWithValues: inventory.map { ($0.relativePath, $0) })
                }
                if let actual = nodeInventories[record.owner]?[record.relativePath],
                   actual.sha256 != record.sha256 || actual.byteCount != record.byteCount {
                    issues.append("共享节点文件与 manifest 哈希不一致：\(record.relativePath)")
                }
            }
        } catch {
            issues.append("读取共享 manifest 失败：\(error.localizedDescription)")
        }
        return RimeVerificationResult(issues: issues)
    }
}
