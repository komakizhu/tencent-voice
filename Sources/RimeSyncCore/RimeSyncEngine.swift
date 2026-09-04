import Foundation

public struct SyncConfiguration: Sendable {
    public let localRimeDirectory: URL
    public let sharedRoot: URL
    public let installationID: String
    public let nodeID: String
    public let squirrelExecutable: URL

    public init(
        localRimeDirectory: URL,
        sharedRoot: URL,
        installationID: String,
        nodeID: String? = nil,
        squirrelExecutable: URL = URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel")
    ) {
        self.localRimeDirectory = localRimeDirectory.standardizedFileURL
        self.sharedRoot = sharedRoot.standardizedFileURL
        self.installationID = installationID
        self.nodeID = nodeID ?? Self.defaultNodeID(for: installationID)
        self.squirrelExecutable = squirrelExecutable
    }

    public var sharedConfigRoot: URL { sharedRoot.appendingPathComponent("config", isDirectory: true) }
    public var nodeDirectory: URL {
        sharedConfigRoot.appendingPathComponent("nodes", isDirectory: true).appendingPathComponent(nodeID, isDirectory: true)
    }
    public var manifestURL: URL { sharedConfigRoot.appendingPathComponent("manifest.json") }
    public var conflictRoot: URL { sharedConfigRoot.appendingPathComponent("conflicts", isDirectory: true) }
    public var backupRoot: URL { sharedRoot.appendingPathComponent("backups", isDirectory: true) }
    public var lockURL: URL { sharedRoot.appendingPathComponent(".lock", isDirectory: true) }

    private static func defaultNodeID(for installationID: String) -> String {
        if installationID == "mac2-main" { return "mac2" }
        if installationID == "af672354-60fc-458a-9254-b0a39c8132ea" { return "mac" }
        return installationID.replacingOccurrences(of: "/", with: "-")
    }
}

public struct SyncReport: Equatable, Sendable {
    public let changedFiles: [String]
    public let deletedFiles: [String]
    public let conflicts: [String]
    public let backupID: String
    public let userDictionarySyncSucceeded: Bool

    public init(
        changedFiles: [String] = [],
        deletedFiles: [String] = [],
        conflicts: [String] = [],
        backupID: String = "",
        userDictionarySyncSucceeded: Bool = false
    ) {
        self.changedFiles = changedFiles.sorted()
        self.deletedFiles = deletedFiles.sorted()
        self.conflicts = conflicts.sorted()
        self.backupID = backupID
        self.userDictionarySyncSucceeded = userDictionarySyncSucceeded
    }
}

public protocol RimeSyncEngine {
    func status() throws -> SyncReport
    func sync(dryRun: Bool) throws -> SyncReport
    func restore(backupID: String) throws
}

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

public protocol CommandRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw RimeSyncError.commandFailed("\(executable.path) \(arguments.joined(separator: " ")) 超时")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    }
}

public protocol NativeRimeMaintaining {
    func syncUserData() throws
    func reload() throws
}

public struct SquirrelMaintenance: NativeRimeMaintaining {
    public let executable: URL
    public let runner: any CommandRunning
    public let timeout: TimeInterval

    public init(
        executable: URL = URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"),
        runner: any CommandRunning = ProcessCommandRunner(),
        timeout: TimeInterval = 30
    ) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
    }

    public func syncUserData() throws {
        try run(arguments: ["--sync"])
    }

    public func reload() throws {
        try run(arguments: ["--reload"])
    }

    private func run(arguments: [String]) throws {
        let result = try runner.run(executable: executable, arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            throw RimeSyncError.commandFailed("\(executable.path) \(arguments.joined(separator: " ")) 返回 \(result.status)：\(result.output)")
        }
    }
}

public final class DirectoryLock {
    private let lockURL: URL
    private let fileManager: FileManager

    public init(lockURL: URL, fileManager: FileManager = .default) {
        self.lockURL = lockURL
        self.fileManager = fileManager
    }

    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
        } catch {
            throw RimeSyncError.lockUnavailable(lockURL)
        }
        defer { try? fileManager.removeItem(at: lockURL) }
        let ownerURL = lockURL.appendingPathComponent("owner")
        let owner = "pid=\(ProcessInfo.processInfo.processIdentifier)\ntime=\(Date())\n"
        try? Data(owner.utf8).write(to: ownerURL, options: .atomic)
        return try body()
    }
}

public enum AtomicFileStore {
    public static func copyItem(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".rime-sync-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    public static func write(_ data: Data, to destination: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".rime-sync-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    public static func safeURL(root: URL, relativePath: String) throws -> URL {
        guard RimeResourcePolicy.isAllowed(relativePath: relativePath) else {
            throw RimeSyncError.invalidRelativePath(relativePath)
        }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw RimeSyncError.invalidRelativePath(relativePath)
        }
        return candidate
    }
}

public struct RimeBackupManager {
    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createBackup(configuration: SyncConfiguration) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        let id = "\(formatter.string(from: Date()))-\(configuration.nodeID)-\(UUID().uuidString.prefix(8))"
        let destination = configuration.backupRoot.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let accountDestination = destination.appendingPathComponent(configuration.nodeID, isDirectory: true)
        try fileManager.createDirectory(at: accountDestination, withIntermediateDirectories: true)
        let rimeDestination = accountDestination.appendingPathComponent("Rime", isDirectory: true)
        if fileManager.fileExists(atPath: configuration.localRimeDirectory.path) {
            try fileManager.copyItem(at: configuration.localRimeDirectory, to: rimeDestination)
        } else {
            try fileManager.createDirectory(at: rimeDestination, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: configuration.manifestURL.path) {
            try fileManager.copyItem(at: configuration.manifestURL, to: accountDestination.appendingPathComponent("manifest.json"))
        }
        let sharedDestination = destination.appendingPathComponent("shared", isDirectory: true)
        try copyDirectoryIfPresent(
            configuration.sharedConfigRoot,
            to: sharedDestination.appendingPathComponent("config", isDirectory: true)
        )
        try copyDirectoryIfPresent(
            configuration.sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true),
            to: sharedDestination.appendingPathComponent("rime-userdata", isDirectory: true)
        )
        try prune(configuration: configuration)
        return id
    }

    public func restore(backupID: String, configuration: SyncConfiguration) throws {
        let snapshot = configuration.backupRoot
            .appendingPathComponent(backupID, isDirectory: true)
            .appendingPathComponent(configuration.nodeID, isDirectory: true)
            .appendingPathComponent("Rime", isDirectory: true)
        guard fileManager.fileExists(atPath: snapshot.path) else {
            throw RimeSyncError.backupNotFound(backupID)
        }
        let staged = configuration.localRimeDirectory.deletingLastPathComponent()
            .appendingPathComponent(".rime-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: snapshot, to: staged)
        if fileManager.fileExists(atPath: configuration.localRimeDirectory.path) {
            try fileManager.removeItem(at: configuration.localRimeDirectory)
        }
        try fileManager.moveItem(at: staged, to: configuration.localRimeDirectory)
        let sharedSnapshot = configuration.backupRoot
            .appendingPathComponent(backupID, isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
        try restoreDirectoryIfPresent(
            sharedSnapshot.appendingPathComponent("config", isDirectory: true),
            to: configuration.sharedConfigRoot
        )
        try restoreDirectoryIfPresent(
            sharedSnapshot.appendingPathComponent("rime-userdata", isDirectory: true),
            to: configuration.sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true)
        )
    }

    private func copyDirectoryIfPresent(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    private func restoreDirectoryIfPresent(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".rime-restore-shared-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: source, to: staged)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staged, to: destination)
    }

    private func prune(configuration: SyncConfiguration) throws {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: configuration.backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let directories = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in directories.dropFirst(3) {
            try fileManager.removeItem(at: old)
        }
    }
}

public final class DefaultRimeSyncEngine: RimeSyncEngine {
    private let configuration: SyncConfiguration
    private let maintenance: any NativeRimeMaintaining
    private let fileManager: FileManager
    private let now: () -> Date
    private let backupManager: RimeBackupManager

    public init(
        configuration: SyncConfiguration,
        maintenance: any NativeRimeMaintaining = SquirrelMaintenance(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.maintenance = maintenance
        self.fileManager = fileManager
        self.now = now
        self.backupManager = RimeBackupManager(fileManager: fileManager)
    }

    public func status() throws -> SyncReport {
        let plan = try makePlan()
        return report(for: plan, backupID: "", userDictionarySyncSucceeded: false)
    }

    public func sync(dryRun: Bool = false) throws -> SyncReport {
        if dryRun { return try status() }
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        return try lock.withLock {
            try maintenance.syncUserData()
            try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
            let backupID = try backupManager.createBackup(configuration: configuration)
            let plan = try makePlan()
            try execute(plan: plan, conflictID: backupID)
            try plan.manifest.saving(to: configuration.manifestURL, fileManager: fileManager)
            try SharedDirectoryLayout.makeGroupWritable(configuration.manifestURL, fileManager: fileManager)
            if plan.requiresReload {
                try maintenance.reload()
            }
            return report(for: plan, backupID: backupID, userDictionarySyncSucceeded: true)
        }
    }

    public func restore(backupID: String) throws {
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        try lock.withLock {
            try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
            _ = try backupManager.createBackup(configuration: configuration)
            try backupManager.restore(backupID: backupID, configuration: configuration)
            try maintenance.reload()
        }
    }

    private struct PlanItem {
        enum Action {
            case publish(FileRecord)
            case pull(FileRecord)
            case conflict(local: FileRecord?, shared: FileRecord?)
        }

        let path: String
        let action: Action
    }

    private struct SyncPlan {
        var items: [PlanItem]
        var manifest: RimeManifest
        var requiresReload: Bool { !items.isEmpty }
    }

    private func makePlan() throws -> SyncPlan {
        let localRecords = try Dictionary(uniqueKeysWithValues: RimeFileInventory(root: configuration.localRimeDirectory, fileManager: fileManager).scan(owner: configuration.nodeID).map { ($0.relativePath, $0) })
        var manifest = try RimeManifest.loading(from: configuration.manifestURL, fileManager: fileManager)
        var nodeRecords = manifest.nodes[configuration.nodeID] ?? [:]
        let paths = Set(localRecords.keys).union(manifest.records.keys).union(nodeRecords.keys).sorted()
        var items: [PlanItem] = []

        for path in paths where !manifest.pausedPaths.contains(path) {
            let baseline = nodeRecords[path]
            let local = localRecords[path] ?? missingRecord(path: path, baseline: baseline)
            let shared = manifest.records[path]
            let decision = LastWriterWinsResolver.resolve(local: local, shared: shared, baseline: baseline)

            switch decision {
            case .unchanged:
                if local != nil { nodeRecords[path] = local }
            case .local:
                guard let local else { continue }
                items.append(PlanItem(path: path, action: .publish(local)))
                manifest.records[path] = local
                nodeRecords[path] = local
            case .shared:
                guard let shared else { continue }
                items.append(PlanItem(path: path, action: .pull(shared)))
                nodeRecords[path] = shared
            case .conflict:
                items.append(PlanItem(path: path, action: .conflict(local: local, shared: shared)))
                manifest.pausedPaths.insert(path)
                if let local { nodeRecords[path] = local }
            }
        }

        manifest.nodes[configuration.nodeID] = nodeRecords
        return SyncPlan(items: items, manifest: manifest)
    }

    private func missingRecord(path: String, baseline: FileRecord?) -> FileRecord? {
        guard let baseline else { return nil }
        if baseline.state == .tombstone { return baseline }
        return .tombstone(
            path: path,
            modifiedNanoseconds: max(nowNanoseconds(), baseline.modifiedNanoseconds + 1),
            owner: configuration.nodeID
        )
    }

    private func execute(plan: SyncPlan, conflictID: String) throws {
        for item in plan.items {
            switch item.action {
            case let .publish(record):
                let source = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: item.path)
                let destination = try AtomicFileStore.safeURL(root: configuration.nodeDirectory, relativePath: item.path)
                try apply(record: record, source: source, destination: destination)
            case let .pull(record):
                let source = try AtomicFileStore.safeURL(
                    root: configuration.sharedConfigRoot.appendingPathComponent("nodes", isDirectory: true).appendingPathComponent(record.owner, isDirectory: true),
                    relativePath: item.path
                )
                let destination = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: item.path)
                try apply(record: record, source: source, destination: destination)
            case let .conflict(local, shared):
                try saveConflict(path: item.path, local: local, shared: shared, conflictID: conflictID)
            }
        }
    }

    private func apply(record: FileRecord, source: URL, destination: URL) throws {
        switch record.state {
        case .present:
            guard fileManager.fileExists(atPath: source.path) else {
                throw RimeSyncError.unsupportedOperation("共享节点缺少文件：\(source.path)")
            }
            try AtomicFileStore.copyItem(from: source, to: destination, fileManager: fileManager)
        case .tombstone:
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
        }
    }

    private func saveConflict(path: String, local: FileRecord?, shared: FileRecord?, conflictID: String) throws {
        let directory = configuration.conflictRoot.appendingPathComponent(conflictID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = path.replacingOccurrences(of: "/", with: "__")
        if let local, local.state == .present {
            let source = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: path)
            let destination = directory.appendingPathComponent("\(name).\(configuration.nodeID).local")
            try fileManager.copyItem(at: source, to: destination)
        } else if let local {
            let data = try JSONEncoder.rimeEncoder.encode(local)
            try AtomicFileStore.write(data, to: directory.appendingPathComponent("\(name).\(configuration.nodeID).local.tombstone.json"), fileManager: fileManager)
        }
        if let shared {
            let data = try JSONEncoder.rimeEncoder.encode(shared)
            try AtomicFileStore.write(data, to: directory.appendingPathComponent("\(name).shared.json"), fileManager: fileManager)
        }
    }

    private func report(for plan: SyncPlan, backupID: String, userDictionarySyncSucceeded: Bool) -> SyncReport {
        let changed = plan.items.map(\.path)
        let deleted = plan.items.compactMap { item -> String? in
            switch item.action {
            case let .publish(record), let .pull(record): return record.state == .tombstone ? item.path : nil
            case .conflict: return nil
            }
        }
        let conflicts = plan.items.compactMap { item -> String? in
            if case .conflict = item.action { return item.path }
            return nil
        }
        return SyncReport(changedFiles: changed, deletedFiles: deleted, conflicts: conflicts, backupID: backupID, userDictionarySyncSucceeded: userDictionarySyncSucceeded)
    }

    private func nowNanoseconds() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1_000_000_000).rounded())
    }
}
