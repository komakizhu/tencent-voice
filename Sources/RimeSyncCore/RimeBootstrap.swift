import Foundation

public struct RimeInstallationFile {
    public let installationID: String
    public let syncDirectory: String?

    public init(installationID: String, syncDirectory: String? = nil) {
        self.installationID = installationID
        self.syncDirectory = syncDirectory
    }

    public static func loading(from url: URL, fileManager: FileManager = .default) throws -> RimeInstallationFile? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let installationID = value(for: "installation_id", in: text) else { return nil }
        return RimeInstallationFile(installationID: installationID, syncDirectory: value(for: "sync_dir", in: text))
    }

    public static func updating(
        existingURL: URL,
        installationID: String,
        syncDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let original = (try? String(contentsOf: existingURL, encoding: .utf8)) ?? ""
        var lines = original.isEmpty ? [] : original.components(separatedBy: .newlines)
        let updates = [
            "installation_id": "installation_id: '\(yamlQuoted(installationID))'",
            "sync_dir": "sync_dir: '\(yamlQuoted(syncDirectory.path))'"
        ]
        for (key, replacement) in updates {
            if let index = lines.firstIndex(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("\(key):")
            }) {
                lines[index] = replacement
            } else {
                lines.append(replacement)
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        try AtomicFileStore.write(Data(text.utf8), to: existingURL, fileManager: fileManager)
    }

    private static func value(for key: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let raw = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return nil
    }

    private static func yamlQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

public final class RimeBootstrapper {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func captureStableResources(from source: URL, to workspace: URL) throws -> [String] {
        guard fileManager.fileExists(atPath: source.path) else { throw RimeSyncError.missingDirectory(source) }
        let records = try RimeFileInventory(root: source, fileManager: fileManager).scan(owner: "source")
        var copied: [String] = []
        for record in records {
            let sourceURL = try AtomicFileStore.safeURL(root: source, relativePath: record.relativePath)
            let destination = try AtomicFileStore.safeURL(root: workspace, relativePath: record.relativePath)
            if record.relativePath == "Rime配置助手.command" {
                let original = try String(contentsOf: sourceURL, encoding: .utf8)
                let portable = original.replacingOccurrences(of: "/Users/mac/Library/Rime", with: "$HOME/Library/Rime")
                try AtomicFileStore.write(Data(portable.utf8), to: destination, fileManager: fileManager)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            } else {
                try AtomicFileStore.copyItem(from: sourceURL, to: destination, fileManager: fileManager)
            }
            copied.append(record.relativePath)
        }
        return copied.sorted()
    }

    @discardableResult
    public func installStableResources(
        from workspace: URL,
        to destination: URL,
        installationID: String,
        sharedRoot: URL
    ) throws -> [String] {
        guard fileManager.fileExists(atPath: workspace.path) else { throw RimeSyncError.missingDirectory(workspace) }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let records = try RimeFileInventory(root: workspace, fileManager: fileManager).scan(owner: "workspace")
        for record in records {
            let source = try AtomicFileStore.safeURL(root: workspace, relativePath: record.relativePath)
            let target = try AtomicFileStore.safeURL(root: destination, relativePath: record.relativePath)
            try AtomicFileStore.copyItem(from: source, to: target, fileManager: fileManager)
        }
        try RimeInstallationFile.updating(
            existingURL: destination.appendingPathComponent("installation.yaml"),
            installationID: installationID,
            syncDirectory: sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true),
            fileManager: fileManager
        )
        return records.map(\.relativePath).sorted()
    }

    public func initializeShared(
        from source: URL,
        sharedRoot: URL,
        sourceInstallationID: String,
        sourceNodeID: String = "mac"
    ) throws {
        try validateMainUserDataSnapshot(from: source, sourceInstallationID: sourceInstallationID)
        try SharedDirectoryLayout.prepare(sharedRoot: sharedRoot, nodeIDs: [sourceNodeID], fileManager: fileManager)
        let configuration = SyncConfiguration(
            localRimeDirectory: source,
            sharedRoot: sharedRoot,
            installationID: sourceInstallationID,
            nodeID: sourceNodeID
        )
        try fileManager.createDirectory(at: configuration.sharedConfigRoot, withIntermediateDirectories: true)
        let existing = try RimeManifest.loading(from: configuration.manifestURL, fileManager: fileManager)
        guard existing.records.isEmpty else { return }
        _ = try captureStableResources(from: source, to: configuration.nodeDirectory)
        let records = try RimeFileInventory(root: configuration.nodeDirectory, fileManager: fileManager).scan(owner: sourceNodeID)
        let manifest = RimeManifest(
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.relativePath, $0) }),
            nodes: [sourceNodeID: Dictionary(uniqueKeysWithValues: records.map { ($0.relativePath, $0) })]
        )
        try manifest.saving(to: configuration.manifestURL, fileManager: fileManager)
        try SharedDirectoryLayout.makeGroupWritable(configuration.manifestURL, fileManager: fileManager)
        try importUserData(from: source, sourceInstallationID: sourceInstallationID, sharedRoot: sharedRoot)
    }

    private func validateMainUserDataSnapshot(from source: URL, sourceInstallationID: String) throws {
        let raw = source.appendingPathComponent("rime_ice.userdb", isDirectory: true)
        let snapshot = source.appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(sourceInstallationID, isDirectory: true)
            .appendingPathComponent("rime_ice.userdb.txt")
        guard fileManager.fileExists(atPath: raw.path), fileManager.fileExists(atPath: snapshot.path) else {
            throw RimeSyncError.unsupportedOperation("缺少 rime_ice.userdb 或其同步快照，无法安全初始化个人词频")
        }
        let rawDate = newestModificationDate(in: raw)
        let snapshotDate = try fileManager.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date
        if let rawDate, let snapshotDate, rawDate > snapshotDate {
            throw RimeSyncError.unsupportedOperation("rime_ice.userdb 比同步快照更新，请先以源账户执行 Squirrel --sync")
        }
    }

    private func newestModificationDate(in directory: URL) -> Date? {
        var newest = (try? fileManager.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date) ?? nil
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return newest
        }
        for case let file as URL in enumerator {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return newest
    }

    private func importUserData(from source: URL, sourceInstallationID: String, sharedRoot: URL) throws {
        let sourceSync = source.appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(sourceInstallationID, isDirectory: true)
        let nativeDestination = sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true)
            .appendingPathComponent(sourceInstallationID, isDirectory: true)
        let legacyDestination = sharedRoot.appendingPathComponent("legacy-userdata", isDirectory: true)
        if fileManager.fileExists(atPath: sourceSync.path), let entries = try? fileManager.contentsOfDirectory(at: sourceSync, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension == "txt" {
                let destinationRoot = entry.lastPathComponent == "rime_ice.userdb.txt" ? nativeDestination : legacyDestination.appendingPathComponent("snapshots/\(sourceInstallationID)", isDirectory: true)
                let destination = destinationRoot.appendingPathComponent(entry.lastPathComponent)
                try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: entry, to: destination)
                }
            }
        }

        if let entries = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            for entry in entries where entry.lastPathComponent.hasSuffix(".userdb") {
                let destination = legacyDestination.appendingPathComponent("raw/\(entry.lastPathComponent)", isDirectory: true)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: entry, to: destination)
                }
            }
        }
    }
}
