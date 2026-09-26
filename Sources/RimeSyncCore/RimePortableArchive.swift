import CryptoKit
import Foundation

public struct RimePortableArchiveFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
    public let isExecutable: Bool

    public init(relativePath: String, byteCount: Int64, sha256: String, isExecutable: Bool = false) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.isExecutable = isExecutable
    }
}

public struct RimePortableArchiveInspection: Equatable, Sendable {
    public let files: [RimePortableArchiveFile]
    public let totalBytes: Int64
    public let archiveSHA256: String

    public init(files: [RimePortableArchiveFile], totalBytes: Int64, archiveSHA256: String) {
        self.files = files
        self.totalBytes = totalBytes
        self.archiveSHA256 = archiveSHA256
    }
}

public struct RimePortableArchiveExportPreview: Equatable, Sendable {
    public let files: [RimePortableArchiveFile]
    public let totalBytes: Int64

    public init(files: [RimePortableArchiveFile], totalBytes: Int64) {
        self.files = files.sorted { $0.relativePath < $1.relativePath }
        self.totalBytes = totalBytes
    }
}

public enum RimePortableImportChange: String, Codable, Hashable, Sendable {
    case add
    case replace
    case unchanged
}

public struct RimePortableImportItem: Equatable, Sendable {
    public let relativePath: String
    public let change: RimePortableImportChange
    public let byteCount: Int64
    public let targetSHA256: String?

    public init(relativePath: String, change: RimePortableImportChange, byteCount: Int64, targetSHA256: String? = nil) {
        self.relativePath = relativePath
        self.change = change
        self.byteCount = byteCount
        self.targetSHA256 = targetSHA256
    }
}

public struct RimePortableImportPreview: Equatable, Sendable {
    public let archiveSHA256: String
    public let items: [RimePortableImportItem]

    public init(archiveSHA256: String, items: [RimePortableImportItem]) {
        self.archiveSHA256 = archiveSHA256
        self.items = items.sorted { $0.relativePath < $1.relativePath }
    }

    public var additions: [RimePortableImportItem] { items.filter { $0.change == .add } }
    public var replacements: [RimePortableImportItem] { items.filter { $0.change == .replace } }
    public var unchanged: [RimePortableImportItem] { items.filter { $0.change == .unchanged } }
    public var changedCount: Int { additions.count + replacements.count }
}

public struct RimePortableImportReport: Equatable, Sendable {
    public let backupID: String
    public let addedFiles: [String]
    public let replacedFiles: [String]
    public let unchangedFiles: [String]

    public init(backupID: String, addedFiles: [String], replacedFiles: [String], unchangedFiles: [String]) {
        self.backupID = backupID
        self.addedFiles = addedFiles.sorted()
        self.replacedFiles = replacedFiles.sorted()
        self.unchangedFiles = unchangedFiles.sorted()
    }
}

public struct RimePortableImportRecovery: Equatable, Sendable, Identifiable {
    public let id: String
    public let filePaths: [String]
    public let problem: String?

    public init(id: String, filePaths: [String], problem: String? = nil) {
        self.id = id
        self.filePaths = filePaths.sorted()
        self.problem = problem
    }
}

public enum RimePortableArchiveError: LocalizedError, Equatable {
    case noPortableFiles
    case invalidArchive(String)
    case unsupportedVersion(Int)
    case invalidPath(String)
    case symbolicLink(String)
    case sourceChanged(String)
    case archiveChanged
    case targetChanged
    case recoveryConflict(String)
    case writeFailed(String, String)
    case deploymentFailed(String, String)
    case recoveryFailed(String, String, String)
    case backupNotFound(String)
    case incompleteRollback(String)

    public var errorDescription: String? {
        switch self {
        case .noPortableFiles: return "当前 Rime 目录没有可导出的配置文件"
        case let .invalidArchive(message): return "配置存档无效：\(message)"
        case let .unsupportedVersion(version): return "不支持的配置存档版本：\(version)"
        case let .invalidPath(path): return "存档包含不允许的路径：\(path)"
        case let .symbolicLink(path): return "配置目录中存在符号链接，无法安全处理：\(path)"
        case let .sourceChanged(path): return "导出期间文件发生变化，请重新导出：\(path)"
        case .archiveChanged: return "确认后存档内容发生变化，请重新选择并预览"
        case .targetChanged: return "确认后目标配置发生变化，请重新预览后再导入"
        case let .recoveryConflict(path): return "恢复已暂停：\(path) 在导入后又发生变化。为避免覆盖新内容，文件未被回滚；请保留备份并人工核对。"
        case let .writeFailed(message, backupPath): return "配置写入失败，已恢复导入前文件：\(message)。备份保留在：\(backupPath)"
        case let .deploymentFailed(message, backupPath): return "配置已回滚：部署失败（\(message)）。导入前备份保留在：\(backupPath)"
        case let .recoveryFailed(deployment, recovery, backupPath): return "部署失败：\(deployment)；回滚或恢复 Rime 失败：\(recovery)。请保留备份：\(backupPath)"
        case let .backupNotFound(id): return "配置导入备份不存在：\(id)"
        case let .incompleteRollback(message): return "导入回滚未能完成：\(message)"
        }
    }
}

/// A versioned, uncompressed, streaming archive. File paths are validated
/// before any payload is written to a destination directory.
public struct RimePortableArchiveService {
    private static let magic = Data("RVCONFIG".utf8)
    private static let currentVersion: UInt32 = 1
    private static let headerLength = 20
    private static let maximumManifestBytes = 16 * 1024 * 1024
    private static let chunkSize = 1024 * 1024

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func previewExport(from rimeDirectory: URL) throws -> RimePortableArchiveExportPreview {
        guard fileManager.fileExists(atPath: rimeDirectory.path) else {
            throw RimeSyncError.missingDirectory(rimeDirectory)
        }
        let files = try inventory(in: rimeDirectory)
        guard !files.isEmpty else { throw RimePortableArchiveError.noPortableFiles }
        let totalBytes = try files.reduce(Int64(0)) { total, file in
            let (nextTotal, overflow) = total.addingReportingOverflow(file.byteCount)
            guard !overflow else { throw RimePortableArchiveError.invalidArchive("导出总大小溢出") }
            return nextTotal
        }
        return RimePortableArchiveExportPreview(files: files, totalBytes: totalBytes)
    }

    @discardableResult
    public func export(
        from rimeDirectory: URL,
        to archiveURL: URL,
        expectedPreview: RimePortableArchiveExportPreview? = nil
    ) throws -> RimePortableArchiveInspection {
        let exportPreview = try previewExport(from: rimeDirectory)
        if let expectedPreview, expectedPreview != exportPreview {
            throw RimePortableArchiveError.sourceChanged("配置目录已在导出预览后变化")
        }
        let files = exportPreview.files
        let manifest = Manifest(version: Int(Self.currentVersion), files: files)
        let manifestData = try JSONEncoder.rimeEncoder.encode(manifest)
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw RimePortableArchiveError.invalidArchive("文件清单过大")
        }

        let parent = archiveURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".rimevoiceconfig-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RimeSyncError.unsupportedOperation("无法创建临时配置存档")
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }

        var header = Self.magic
        Self.append(UInt32(Self.currentVersion), to: &header)
        Self.append(UInt64(manifestData.count), to: &header)
        try output.write(contentsOf: header)
        try output.write(contentsOf: manifestData)

        for file in files {
            let source = try safeFileURL(root: rimeDirectory, relativePath: file.relativePath, allowMissing: false)
            let actual = try streamFile(at: source, to: output)
            guard actual.byteCount == file.byteCount, actual.sha256 == file.sha256 else {
                throw RimePortableArchiveError.sourceChanged(file.relativePath)
            }
        }
        try output.synchronize()
        try output.close()

        let verifiedArchive = try inspect(temporary)

        if fileManager.fileExists(atPath: archiveURL.path) {
            _ = try fileManager.replaceItemAt(archiveURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: archiveURL)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        return verifiedArchive
    }

    public func inspect(_ archiveURL: URL) throws -> RimePortableArchiveInspection {
        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { try? input.close() }
        let header = try readExactly(Self.headerLength, from: input)
        guard header.prefix(Self.magic.count) == Self.magic else {
            throw RimePortableArchiveError.invalidArchive("文件标识不正确")
        }
        let version = UInt32(Self.integer(from: header, at: Self.magic.count, length: 4))
        guard version == Self.currentVersion else {
            throw RimePortableArchiveError.unsupportedVersion(Int(version))
        }
        let manifestLength = Self.integer(from: header, at: Self.magic.count + 4, length: 8)
        guard manifestLength > 0,
              manifestLength <= UInt64(Self.maximumManifestBytes),
              manifestLength <= UInt64(Int.max) else {
            throw RimePortableArchiveError.invalidArchive("文件清单长度非法")
        }
        let manifestData = try readExactly(Int(manifestLength), from: input)
        let manifest: Manifest
        do {
            manifest = try JSONDecoder.rimeDecoder.decode(Manifest.self, from: manifestData)
        } catch {
            throw RimePortableArchiveError.invalidArchive("无法读取文件清单：\(error.localizedDescription)")
        }
        guard manifest.version == Int(Self.currentVersion) else {
            throw RimePortableArchiveError.unsupportedVersion(manifest.version)
        }
        guard !manifest.files.isEmpty else { throw RimePortableArchiveError.noPortableFiles }

        var seen = Set<Data>()
        var canonicalPaths = Set<String>()
        var totalBytes: Int64 = 0
        for file in manifest.files {
            try validatePortablePath(file.relativePath)
            guard seen.insert(Data(file.relativePath.utf8)).inserted else {
                throw RimePortableArchiveError.invalidArchive("清单中存在重复文件：\(file.relativePath)")
            }
            let canonicalPath = Self.canonicalPathKey(file.relativePath)
            guard canonicalPaths.insert(canonicalPath).inserted else {
                throw RimePortableArchiveError.invalidArchive("清单中存在文件系统路径别名：\(file.relativePath)")
            }
            guard file.byteCount >= 0,
                  file.sha256.count == 64,
                  file.sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
                  !file.isExecutable || file.relativePath == "Rime配置助手.command" else {
                throw RimePortableArchiveError.invalidArchive("文件元数据非法：\(file.relativePath)")
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(file.byteCount)
            guard !overflow else { throw RimePortableArchiveError.invalidArchive("存档总大小溢出") }
            totalBytes = nextTotal
        }
        guard manifest.files.map(\.relativePath) == manifest.files.map(\.relativePath).sorted() else {
            throw RimePortableArchiveError.invalidArchive("文件清单顺序错误")
        }
        for canonicalPath in canonicalPaths {
            var prefix = ""
            let components = canonicalPath.split(separator: "/").map(String.init)
            for component in components.dropLast() {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                guard !canonicalPaths.contains(prefix) else {
                    throw RimePortableArchiveError.invalidArchive("清单文件与目录路径冲突：\(canonicalPath)")
                }
            }
        }

        for file in manifest.files {
            var hasher = SHA256()
            var remaining = file.byteCount
            while remaining > 0 {
                let count = Int(min(Int64(Self.chunkSize), remaining))
                let chunk = try readExactly(count, from: input)
                hasher.update(data: chunk)
                remaining -= Int64(count)
            }
            guard Self.hex(hasher.finalize()) == file.sha256 else {
                throw RimePortableArchiveError.invalidArchive("校验失败：\(file.relativePath)")
            }
        }
        if let trailing = try input.read(upToCount: 1), !trailing.isEmpty {
            throw RimePortableArchiveError.invalidArchive("文件末尾包含未登记的数据")
        }
        return RimePortableArchiveInspection(
            files: manifest.files,
            totalBytes: totalBytes,
            archiveSHA256: try hashFile(at: archiveURL).sha256
        )
    }

    public func previewImport(from archiveURL: URL, to targetDirectory: URL) throws -> RimePortableImportPreview {
        let inspection = try inspect(archiveURL)
        var items: [RimePortableImportItem] = []
        for file in inspection.files {
            let target = try safeFileURL(root: targetDirectory, relativePath: file.relativePath, allowMissing: true)
            let change: RimePortableImportChange
            let targetSHA256: String?
            if fileManager.fileExists(atPath: target.path) {
                let attributes = try fileManager.attributesOfItem(atPath: target.path)
                guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                    throw RimePortableArchiveError.invalidPath(file.relativePath)
                }
                targetSHA256 = try hashFile(at: target).sha256
                change = targetSHA256 == file.sha256 ? .unchanged : .replace
            } else {
                targetSHA256 = nil
                change = .add
            }
            items.append(RimePortableImportItem(
                relativePath: file.relativePath,
                change: change,
                byteCount: file.byteCount,
                targetSHA256: targetSHA256
            ))
        }
        return RimePortableImportPreview(archiveSHA256: inspection.archiveSHA256, items: items)
    }

    public func importArchive(
        from archiveURL: URL,
        to targetDirectory: URL,
        backupRoot: URL,
        expectedArchiveSHA256: String? = nil,
        expectedPreview: RimePortableImportPreview? = nil,
        protectedPaths: Set<String> = []
    ) throws -> RimePortableImportReport {
        try performImport(
            from: archiveURL,
            to: targetDirectory,
            backupRoot: backupRoot,
            expectedArchiveSHA256: expectedArchiveSHA256,
            expectedPreview: expectedPreview,
            protectedPaths: protectedPaths,
            beforeApplying: nil,
            afterWriteFailureRollback: nil
        )
    }

    private func performImport(
        from archiveURL: URL,
        to targetDirectory: URL,
        backupRoot: URL,
        expectedArchiveSHA256: String?,
        expectedPreview: RimePortableImportPreview?,
        protectedPaths: Set<String>,
        beforeApplying: ((URL) throws -> Void)?,
        afterWriteFailureRollback: ((URL) throws -> Void)?
    ) throws -> RimePortableImportReport {
        let preview = try previewImport(from: archiveURL, to: targetDirectory)
        let archiveFilesByPath = Dictionary(uniqueKeysWithValues: try inspect(archiveURL).files.map { ($0.relativePath, $0) })
        if let expectedArchiveSHA256, expectedArchiveSHA256 != preview.archiveSHA256 {
            throw RimePortableArchiveError.archiveChanged
        }
        if let expectedPreview, expectedPreview != preview {
            throw RimePortableArchiveError.targetChanged
        }
        let changedItems = preview.items.filter { $0.change != .unchanged }
        guard !changedItems.isEmpty else {
            return RimePortableImportReport(backupID: "", addedFiles: [], replacedFiles: [], unchangedFiles: preview.unchanged.map(\.relativePath))
        }
        for path in protectedPaths { try validatePortablePath(path) }

        let stageRoot = targetDirectory.deletingLastPathComponent()
            .appendingPathComponent(".rime-import-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stageRoot) }
        try fileManager.createDirectory(at: stageRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stagedFiles = try stagePayloads(from: archiveURL, matching: Set(changedItems.map(\.relativePath)), to: stageRoot)
        guard try hashFile(at: archiveURL).sha256 == preview.archiveSHA256 else {
            throw RimePortableArchiveError.archiveChanged
        }
        guard try previewImport(from: archiveURL, to: targetDirectory) == preview else {
            throw RimePortableArchiveError.targetChanged
        }

        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupID = "import-\(UUID().uuidString.lowercased())"
        let backupDirectory = backupRoot.appendingPathComponent(backupID, isDirectory: true)
        let backupFiles = backupDirectory.appendingPathComponent("files", isDirectory: true)
        var transactionSaved = false
        defer {
            if !transactionSaved { try? fileManager.removeItem(at: backupDirectory) }
        }
        try fileManager.createDirectory(at: backupFiles, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetExisted = fileManager.fileExists(atPath: targetDirectory.path)
        let changedPaths = Set(changedItems.map(\.relativePath))
        let transactionPaths = changedPaths.union(protectedPaths).sorted()
        let previewItemsByPath = Dictionary(uniqueKeysWithValues: preview.items.map { ($0.relativePath, $0) })
        var protectedHashes: [String: String] = [:]
        var protectedMissing = Set<String>()
        let transactionFiles = try transactionPaths.map { path -> TransactionFile in
            let target = try safeFileURL(root: targetDirectory, relativePath: path, allowMissing: true)
            let existed = fileManager.fileExists(atPath: target.path)
            if existed {
                let attributes = try fileManager.attributesOfItem(atPath: target.path)
                guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                    throw RimePortableArchiveError.invalidPath(path)
                }
                let targetSHA256 = try hashFile(at: target).sha256
                if let previewItem = previewItemsByPath[path], previewItem.targetSHA256 != targetSHA256 {
                    throw RimePortableArchiveError.targetChanged
                }
                let backup = try safeFileURL(root: backupFiles, relativePath: path, allowMissing: true)
                try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fileManager.copyItem(at: target, to: backup)
                guard try hashFile(at: backup).sha256 == targetSHA256,
                      try hashFile(at: target).sha256 == targetSHA256 else {
                    throw RimePortableArchiveError.targetChanged
                }
                if protectedPaths.contains(path) { protectedHashes[path] = targetSHA256 }
                if let permissions = try? fileManager.attributesOfItem(atPath: target.path)[.posixPermissions] {
                    try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: backup.path)
                }
            } else {
                if let previewItem = previewItemsByPath[path], previewItem.targetSHA256 != nil {
                    throw RimePortableArchiveError.targetChanged
                }
                if protectedPaths.contains(path) { protectedMissing.insert(path) }
            }
            return TransactionFile(relativePath: path, existed: existed, installedSHA256: archiveFilesByPath[path]?.sha256)
        }
        guard try previewImport(from: archiveURL, to: targetDirectory) == preview else {
            throw RimePortableArchiveError.targetChanged
        }
        for path in protectedPaths {
            let target = try safeFileURL(root: targetDirectory, relativePath: path, allowMissing: true)
            if let expectedHash = protectedHashes[path] {
                guard fileManager.fileExists(atPath: target.path), try hashFile(at: target).sha256 == expectedHash else {
                    throw RimePortableArchiveError.targetChanged
                }
            } else if protectedMissing.contains(path) {
                guard !fileManager.fileExists(atPath: target.path) else {
                    throw RimePortableArchiveError.targetChanged
                }
            }
        }
        var transaction = Transaction(
            version: 1,
            state: .active,
            targetDirectoryExisted: targetExisted,
            archiveSHA256: preview.archiveSHA256,
            files: transactionFiles
        )
        try beforeApplying?(backupDirectory)
        try save(transaction, in: backupDirectory)
        transactionSaved = true

        do {
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            for item in changedItems {
                guard let staged = stagedFiles[item.relativePath] else {
                    throw RimePortableArchiveError.invalidArchive("暂存文件丢失：\(item.relativePath)")
                }
                let destination = try safeFileURL(root: targetDirectory, relativePath: item.relativePath, allowMissing: true)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AtomicFileStore.copyItem(from: staged, to: destination, fileManager: fileManager)
                try fileManager.setAttributes([.posixPermissions: item.relativePath == "Rime配置助手.command" && isExecutable(staged) ? 0o755 : 0o644], ofItemAtPath: destination.path)
            }
        } catch {
            do {
                try rollback(transaction, backupDirectory: backupDirectory, targetDirectory: targetDirectory)
                try afterWriteFailureRollback?(backupDirectory)
                transaction.state = .rolledBack
                try save(transaction, in: backupDirectory)
            } catch let rollbackError {
                throw RimePortableArchiveError.incompleteRollback("\(error.localizedDescription)；原状态备份保留在 \(backupDirectory.path)：\(rollbackError.localizedDescription)")
            }
            throw RimePortableArchiveError.writeFailed(error.localizedDescription, backupDirectory.path)
        }

        return RimePortableImportReport(
            backupID: backupID,
            addedFiles: changedItems.filter { $0.change == .add }.map(\.relativePath),
            replacedFiles: changedItems.filter { $0.change == .replace }.map(\.relativePath),
            unchangedFiles: preview.unchanged.map(\.relativePath)
        )
    }

    /// Imports the reviewed archive, runs app-specific state reconciliation
    /// and reloads Rime. Any deployment failure restores the affected files,
    /// restores dependent local state, and reloads the pre-import configuration.
    public func importAndDeploy(
        from archiveURL: URL,
        to targetDirectory: URL,
        backupRoot: URL,
        expectedPreview: RimePortableImportPreview,
        protectedPaths: Set<String> = [],
        backupDependentState: ((URL) throws -> Void)? = nil,
        prepareAfterImport: (_ registerPreparedFile: (String, Data) throws -> Void) throws -> Void,
        deploy: () throws -> Void,
        restoreAfterRollback: @escaping (URL) throws -> Void
    ) throws -> RimePortableImportReport {
        let report = try performImport(
            from: archiveURL,
            to: targetDirectory,
            backupRoot: backupRoot,
            expectedArchiveSHA256: expectedPreview.archiveSHA256,
            expectedPreview: expectedPreview,
            protectedPaths: protectedPaths,
            beforeApplying: backupDependentState,
            afterWriteFailureRollback: restoreAfterRollback
        )
        guard !report.backupID.isEmpty else { return report }
        let backupDirectory = backupRoot.appendingPathComponent(report.backupID, isDirectory: true)
        do {
            try prepareAfterImport { path, data in
                try recordPreparedFileState(
                    backupID: report.backupID,
                    in: backupRoot,
                    relativePath: path,
                    contents: data
                )
            }
            try recordInstalledProtectedState(
                backupID: report.backupID,
                in: backupRoot,
                targetDirectory: targetDirectory,
                paths: protectedPaths
            )
            try deploy()
            try completeImport(backupID: report.backupID, in: backupRoot)
            return report
        } catch {
            let deploymentMessage = error.localizedDescription
        do {
            try restoreImportFiles(backupID: report.backupID, in: backupRoot, targetDirectory: targetDirectory)
            try restoreAfterRollback(backupDirectory)
            try completeRollback(backupID: report.backupID, in: backupRoot)
        } catch {
                throw RimePortableArchiveError.recoveryFailed(
                    deploymentMessage,
                    error.localizedDescription,
                    backupDirectory.path
                )
            }
            throw RimePortableArchiveError.deploymentFailed(deploymentMessage, backupDirectory.path)
        }
    }

    public func completeImport(backupID: String, in backupRoot: URL) throws {
        var transaction = try loadTransaction(backupID: backupID, in: backupRoot)
        guard transaction.state == .active else {
            throw RimePortableArchiveError.incompleteRollback("导入事务已进入回滚状态，不能标记为完成")
        }
        transaction.state = .completed
        try save(transaction, in: backupRoot.appendingPathComponent(backupID, isDirectory: true))
    }

    private func recordInstalledProtectedState(
        backupID: String,
        in backupRoot: URL,
        targetDirectory: URL,
        paths: Set<String>
    ) throws {
        guard !paths.isEmpty else { return }
        var transaction = try loadTransaction(backupID: backupID, in: backupRoot)
        guard transaction.state == .active else { return }
        for index in transaction.files.indices where paths.contains(transaction.files[index].relativePath) {
            let file = transaction.files[index]
            let target = try safeFileURL(root: targetDirectory, relativePath: file.relativePath, allowMissing: true)
            let installedHash = fileManager.fileExists(atPath: target.path)
                ? try hashFile(at: target).sha256
                : nil
            transaction.files[index].installedSHA256 = installedHash
            if let installedHash {
                var preparedHashes = transaction.files[index].preparedSHA256s ?? []
                if !preparedHashes.contains(installedHash) { preparedHashes.append(installedHash) }
                transaction.files[index].preparedSHA256s = preparedHashes
            }
        }
        try save(transaction, in: backupRoot.appendingPathComponent(backupID, isDirectory: true))
    }

    private func recordPreparedFileState(
        backupID: String,
        in backupRoot: URL,
        relativePath: String,
        contents: Data
    ) throws {
        try validatePortablePath(relativePath)
        var transaction = try loadTransaction(backupID: backupID, in: backupRoot)
        guard transaction.state == .active,
              let index = transaction.files.firstIndex(where: { $0.relativePath == relativePath }) else {
            throw RimePortableArchiveError.invalidPath(relativePath)
        }
        let preparedHash = Self.hex(SHA256.hash(data: contents))
        var preparedHashes = transaction.files[index].preparedSHA256s ?? []
        if !preparedHashes.contains(preparedHash) { preparedHashes.append(preparedHash) }
        transaction.files[index].preparedSHA256s = preparedHashes
        try save(transaction, in: backupRoot.appendingPathComponent(backupID, isDirectory: true))
    }

    public func pendingRecoveries(in backupRoot: URL) throws -> [RimePortableImportRecovery] {
        guard fileManager.fileExists(atPath: backupRoot.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var recoveries: [RimePortableImportRecovery] = []
        for directory in directories where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let transactionURL = directory.appendingPathComponent("transaction.json")
            guard fileManager.fileExists(atPath: transactionURL.path) else { continue }
            do {
                let transaction = try JSONDecoder.rimeDecoder.decode(Transaction.self, from: Data(contentsOf: transactionURL))
                guard transaction.state == .active || transaction.state == .filesRestored else { continue }
                for file in transaction.files { try validatePortablePath(file.relativePath) }
                recoveries.append(RimePortableImportRecovery(id: directory.lastPathComponent, filePaths: transaction.files.map(\.relativePath)))
            } catch {
                recoveries.append(RimePortableImportRecovery(
                    id: directory.lastPathComponent,
                    filePaths: [],
                    problem: error.localizedDescription
                ))
            }
        }
        return recoveries.sorted { $0.id < $1.id }
    }

    public func rollbackImport(backupID: String, in backupRoot: URL, targetDirectory: URL) throws {
        try restoreImportFiles(backupID: backupID, in: backupRoot, targetDirectory: targetDirectory)
        try completeRollback(backupID: backupID, in: backupRoot)
    }

    /// Restores imported files but leaves the journal active until the caller
    /// has also rebuilt dependent state and successfully reloaded Rime.
    public func restoreImportFiles(backupID: String, in backupRoot: URL, targetDirectory: URL) throws {
        var transaction = try loadTransaction(backupID: backupID, in: backupRoot)
        guard transaction.state == .active else { return }
        let backupDirectory = backupRoot.appendingPathComponent(backupID, isDirectory: true)
        try rollback(transaction, backupDirectory: backupDirectory, targetDirectory: targetDirectory)
        transaction.state = .filesRestored
        try save(transaction, in: backupDirectory)
    }

    public func completeRollback(backupID: String, in backupRoot: URL) throws {
        var transaction = try loadTransaction(backupID: backupID, in: backupRoot)
        guard transaction.state == .active || transaction.state == .filesRestored else { return }
        transaction.state = .rolledBack
        try save(transaction, in: backupRoot.appendingPathComponent(backupID, isDirectory: true))
    }

    private struct Manifest: Codable {
        let version: Int
        let files: [RimePortableArchiveFile]
    }

    private struct Transaction: Codable {
        enum State: String, Codable { case active, filesRestored, completed, rolledBack }
        let version: Int
        var state: State
        let targetDirectoryExisted: Bool
        let archiveSHA256: String
        var files: [TransactionFile]
    }

    private struct TransactionFile: Codable {
        let relativePath: String
        let existed: Bool
        var installedSHA256: String?
        var preparedSHA256s: [String]? = nil
    }

    private struct StreamResult {
        let byteCount: Int64
        let sha256: String
    }

    private func inventory(in root: URL) throws -> [RimePortableArchiveFile] {
        let resolvedRoot = root.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [RimePortableArchiveFile] = []
        for case let url as URL in enumerator {
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.path.hasPrefix(resolvedRoot.path + "/") else {
                throw RimePortableArchiveError.invalidPath(url.path)
            }
            let relative = String(standardizedURL.path.dropFirst(resolvedRoot.path.count + 1))
            let allowed = Self.isPortablePath(relative)
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                if allowed { throw RimePortableArchiveError.symbolicLink(relative) }
                continue
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let itemType = attributes[.type] as? FileAttributeType
            if itemType == .typeDirectory {
                if !allowed { enumerator.skipDescendants() }
                continue
            }
            guard allowed, itemType == .typeRegular else { continue }
            let result = try hashFile(at: url)
            let executableBits = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let file = RimePortableArchiveFile(
                relativePath: relative,
                byteCount: result.byteCount,
                sha256: result.sha256,
                isExecutable: relative == "Rime配置助手.command" && executableBits & 0o111 != 0
            )
            files.append(file)
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func stagePayloads(from archiveURL: URL, matching paths: Set<String>, to stageRoot: URL) throws -> [String: URL] {
        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { try? input.close() }
        let header = try readExactly(Self.headerLength, from: input)
        guard header.prefix(Self.magic.count) == Self.magic,
              UInt32(Self.integer(from: header, at: Self.magic.count, length: 4)) == Self.currentVersion else {
            throw RimePortableArchiveError.invalidArchive("暂存时存档头发生变化")
        }
        let manifestLength = Self.integer(from: header, at: Self.magic.count + 4, length: 8)
        guard manifestLength > 0,
              manifestLength <= UInt64(Self.maximumManifestBytes),
              manifestLength <= UInt64(Int.max) else {
            throw RimePortableArchiveError.invalidArchive("暂存时文件清单长度非法")
        }
        let manifest = try JSONDecoder.rimeDecoder.decode(Manifest.self, from: readExactly(Int(manifestLength), from: input))
        var staged: [String: URL] = [:]
        for file in manifest.files {
            let destination = try safeFileURL(root: stageRoot, relativePath: file.relativePath, allowMissing: true)
            if paths.contains(file.relativePath) {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard fileManager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: file.isExecutable ? 0o755 : 0o644]) else {
                    throw RimeSyncError.unsupportedOperation("无法暂存文件：\(file.relativePath)")
                }
                let output = try FileHandle(forWritingTo: destination)
                var hasher = SHA256()
                var remaining = file.byteCount
                while remaining > 0 {
                    let count = Int(min(Int64(Self.chunkSize), remaining))
                    let chunk = try readExactly(count, from: input)
                    hasher.update(data: chunk)
                    try output.write(contentsOf: chunk)
                    remaining -= Int64(count)
                }
                try output.synchronize()
                try output.close()
                guard Self.hex(hasher.finalize()) == file.sha256 else {
                    throw RimePortableArchiveError.invalidArchive("暂存时校验失败：\(file.relativePath)")
                }
                staged[file.relativePath] = destination
            } else {
                var remaining = file.byteCount
                while remaining > 0 {
                    let count = Int(min(Int64(Self.chunkSize), remaining))
                    _ = try readExactly(count, from: input)
                    remaining -= Int64(count)
                }
            }
        }
        return staged
    }

    private func rollback(_ transaction: Transaction, backupDirectory: URL, targetDirectory: URL) throws {
        let backupFiles = backupDirectory.appendingPathComponent("files", isDirectory: true)
        try verifyRollbackTargets(transaction, backupFiles: backupFiles, targetDirectory: targetDirectory)
        var failures: [String] = []
        for file in transaction.files.reversed() {
            do {
                let destination = try safeFileURL(root: targetDirectory, relativePath: file.relativePath, allowMissing: true)
                if file.existed {
                    let backup = try safeFileURL(root: backupFiles, relativePath: file.relativePath, allowMissing: false)
                    guard fileManager.fileExists(atPath: backup.path) else {
                        throw RimePortableArchiveError.backupNotFound(backup.path)
                    }
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try AtomicFileStore.copyItem(from: backup, to: destination, fileManager: fileManager)
                } else if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try removeEmptyParents(startingAt: destination.deletingLastPathComponent(), until: targetDirectory)
            } catch {
                failures.append("\(file.relativePath)：\(error.localizedDescription)")
            }
        }
        if !transaction.targetDirectoryExisted {
            if let contents = try? fileManager.contentsOfDirectory(atPath: targetDirectory.path), contents.isEmpty {
                try? fileManager.removeItem(at: targetDirectory)
            }
        }
        guard failures.isEmpty else {
            throw RimePortableArchiveError.incompleteRollback(failures.joined(separator: "；"))
        }
    }

    private func verifyRollbackTargets(
        _ transaction: Transaction,
        backupFiles: URL,
        targetDirectory: URL
    ) throws {
        var conflicts: [String] = []
        for file in transaction.files {
            let target = try safeFileURL(root: targetDirectory, relativePath: file.relativePath, allowMissing: true)
            let exists = fileManager.fileExists(atPath: target.path)
            if file.existed {
                let backup = try safeFileURL(root: backupFiles, relativePath: file.relativePath, allowMissing: false)
                guard fileManager.fileExists(atPath: backup.path) else {
                    throw RimePortableArchiveError.backupNotFound(backup.path)
                }
                let originalHash = try hashFile(at: backup).sha256
                if !exists {
                    conflicts.append(file.relativePath)
                    continue
                }
                let currentHash = try hashFile(at: target).sha256
                let acceptedHashes = Set((file.preparedSHA256s ?? []) + [file.installedSHA256].compactMap { $0 })
                if currentHash != originalHash && !acceptedHashes.contains(currentHash) {
                    conflicts.append(file.relativePath)
                }
            } else if exists {
                let acceptedHashes = Set((file.preparedSHA256s ?? []) + [file.installedSHA256].compactMap { $0 })
                guard acceptedHashes.contains(try hashFile(at: target).sha256) else {
                    conflicts.append(file.relativePath)
                    continue
                }
            }
        }
        guard conflicts.isEmpty else {
            throw RimePortableArchiveError.recoveryConflict(conflicts.sorted().joined(separator: "、"))
        }
    }

    private func removeEmptyParents(startingAt directory: URL, until root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        var current = directory.standardizedFileURL
        while current.path != rootPath, current.path.hasPrefix(rootPath + "/") {
            let contents = try fileManager.contentsOfDirectory(atPath: current.path)
            guard contents.isEmpty else { return }
            try fileManager.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    private func validatePortablePath(_ path: String) throws {
        guard Self.isPortablePath(path) else { throw RimePortableArchiveError.invalidPath(path) }
    }

    private static func isPortablePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return RimeResourcePolicy.isAllowed(relativePath: path) || path == "rime_managed.dict.yaml"
    }

    private func safeFileURL(root: URL, relativePath: String, allowMissing: Bool) throws -> URL {
        try validatePortablePath(relativePath)
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw RimePortableArchiveError.invalidPath(relativePath)
        }
        var current = root
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            if (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw RimePortableArchiveError.symbolicLink(relativePath)
            }
            if index < components.count - 1,
               fileManager.fileExists(atPath: current.path),
               (try? fileManager.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType) != .typeDirectory {
                throw RimePortableArchiveError.invalidPath(relativePath)
            }
        }
        if !allowMissing, !fileManager.fileExists(atPath: candidate.path) {
            throw RimePortableArchiveError.invalidPath(relativePath)
        }
        return candidate
    }

    private func hashFile(at url: URL) throws -> StreamResult {
        let before = try fileManager.attributesOfItem(atPath: url.path)
        guard (before[.type] as? FileAttributeType) == .typeRegular else {
            throw RimePortableArchiveError.invalidPath(url.lastPathComponent)
        }
        let expectedSize = (before[.size] as? NSNumber)?.int64Value ?? -1
        let beforeDate = before[.modificationDate] as? Date
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let result = try streamFile(at: url, to: nil, input: input)
        let after = try fileManager.attributesOfItem(atPath: url.path)
        guard result.byteCount == expectedSize,
              (after[.size] as? NSNumber)?.int64Value == expectedSize,
              (after[.modificationDate] as? Date) == beforeDate else {
            throw RimePortableArchiveError.sourceChanged(url.lastPathComponent)
        }
        return result
    }

    private func streamFile(at url: URL, to output: FileHandle?, input providedInput: FileHandle? = nil) throws -> StreamResult {
        let input: FileHandle
        let ownsInput: Bool
        if let providedInput {
            input = providedInput
            ownsInput = false
        } else {
            input = try FileHandle(forReadingFrom: url)
            ownsInput = true
        }
        defer { if ownsInput { try? input.close() } }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            let (nextCount, overflow) = byteCount.addingReportingOverflow(Int64(chunk.count))
            guard !overflow else { throw RimePortableArchiveError.invalidArchive("文件大小溢出") }
            byteCount = nextCount
            hasher.update(data: chunk)
            try output?.write(contentsOf: chunk)
        }
        return StreamResult(byteCount: byteCount, sha256: Self.hex(hasher.finalize()))
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else { throw RimePortableArchiveError.invalidArchive("读取长度非法") }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: min(Self.chunkSize, count - result.count)), !chunk.isEmpty else {
                throw RimePortableArchiveError.invalidArchive("文件意外结束")
            }
            result.append(chunk)
        }
        return result
    }

    private func loadTransaction(backupID: String, in backupRoot: URL) throws -> Transaction {
        guard !backupID.isEmpty,
              URL(fileURLWithPath: backupID).lastPathComponent == backupID,
              !backupID.contains("/") else {
            throw RimePortableArchiveError.backupNotFound(backupID)
        }
        let directory = backupRoot.appendingPathComponent(backupID, isDirectory: true)
        let url = directory.appendingPathComponent("transaction.json")
        guard fileManager.fileExists(atPath: url.path) else { throw RimePortableArchiveError.backupNotFound(backupID) }
        let transaction = try JSONDecoder.rimeDecoder.decode(Transaction.self, from: Data(contentsOf: url))
        guard transaction.version == 1 else { throw RimePortableArchiveError.backupNotFound(backupID) }
        for file in transaction.files { try validatePortablePath(file.relativePath) }
        return transaction
    }

    private func save(_ transaction: Transaction, in directory: URL) throws {
        let url = directory.appendingPathComponent("transaction.json")
        let data = try JSONEncoder.rimeEncoder.encode(transaction)
        try AtomicFileStore.write(data, to: url, fileManager: fileManager)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isExecutable(_ url: URL) -> Bool {
        let permissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return permissions & 0o111 != 0
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { data.append(contentsOf: $0) }
    }

    private static func integer(from data: Data, at offset: Int, length: Int) -> UInt64 {
        data[offset..<(offset + length)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalPathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
