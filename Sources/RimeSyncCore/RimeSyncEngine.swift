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
        squirrelExecutable: URL = SquirrelPathResolver.executableURL
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

public protocol WorkingDirectoryCommandRunning {
    func run(executable: URL, arguments: [String], workingDirectory: URL, timeout: TimeInterval) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning, WorkingDirectoryCommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try execute(executable: executable, arguments: arguments, workingDirectory: nil, timeout: timeout)
    }

    public func run(executable: URL, arguments: [String], workingDirectory: URL, timeout: TimeInterval = 30) throws -> CommandResult {
        try execute(executable: executable, arguments: arguments, workingDirectory: workingDirectory, timeout: timeout)
    }

    private func execute(executable: URL, arguments: [String], workingDirectory: URL?, timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
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

public struct SquirrelMaintenance: NativeRimeMaintaining, RimeUserDictionaryMaintaining {
    public let executable: URL
    public let dictionaryManagerExecutable: URL
    public let runner: any CommandRunning
    public let workingDirectoryRunner: any WorkingDirectoryCommandRunning
    public let launchRunner: any CommandRunning
    public let timeout: TimeInterval

    public init(
        executable: URL = SquirrelPathResolver.executableURL,
        dictionaryManagerExecutable: URL = SquirrelPathResolver.dictionaryManagerURL,
        runner: any CommandRunning = ProcessCommandRunner(),
        workingDirectoryRunner: (any WorkingDirectoryCommandRunning)? = nil,
        launchRunner: (any CommandRunning)? = nil,
        timeout: TimeInterval = 30
    ) {
        self.executable = executable
        self.dictionaryManagerExecutable = dictionaryManagerExecutable
        self.runner = runner
        self.workingDirectoryRunner = workingDirectoryRunner ?? (runner as? any WorkingDirectoryCommandRunning) ?? ProcessCommandRunner()
        self.launchRunner = launchRunner ?? runner
        self.timeout = timeout
    }

    public func syncUserData() throws {
        try run(arguments: ["--sync"])
    }

    public func reload() throws {
        try run(arguments: ["--reload"])
    }

    public func captureUserDictionarySnapshot(in rimeDirectory: URL) throws {
        try backupUserDictionary(in: rimeDirectory)
    }

    /// Publish only the current dictionary.  Unlike `--sync`, `--backup`
    /// never imports another installation's snapshot before publishing.
    public func backupUserDictionary(in rimeDirectory: URL) throws {
        try withSquirrelStopped {
            try runDictionaryManager(arguments: ["--backup", "rime_ice"], rimeDirectory: rimeDirectory)
        }
    }

    public func restoreUserDictionarySnapshot(from snapshot: URL, in rimeDirectory: URL) throws {
        try withSquirrelStopped {
            try runDictionaryManager(arguments: ["--restore", snapshot.path], rimeDirectory: rimeDirectory)
        }
    }

    private func run(arguments: [String]) throws {
        let result = try runner.run(executable: executable, arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            throw RimeSyncError.commandFailed("\(executable.path) \(arguments.joined(separator: " ")) 返回 \(result.status)：\(result.output)")
        }
    }

    private func runDictionaryManager(arguments: [String], rimeDirectory: URL) throws {
        let frameworks = dictionaryManagerExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks", isDirectory: true)
        let environment = "DYLD_LIBRARY_PATH=\(frameworks.path)"
        let result = try workingDirectoryRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [environment, dictionaryManagerExecutable.path] + arguments,
            workingDirectory: rimeDirectory,
            timeout: timeout
        )
        guard result.status == 0 else {
            throw RimeSyncError.commandFailed("Rime 用户库命令返回 \(result.status)：\(result.output)")
        }
    }

    private func withSquirrelStopped<T>(_ body: () throws -> T) throws -> T {
        try run(arguments: ["--quit"])
        Thread.sleep(forTimeInterval: 0.2)
        do {
            let result = try body()
            try launchSquirrel()
            return result
        } catch let originalError {
            do {
                try launchSquirrel()
            } catch let restartError {
                throw RimeSyncError.unsupportedOperation(
                    "Rime 用户库操作失败：\(originalError.localizedDescription)；Squirrel 重启也失败：\(restartError.localizedDescription)"
                )
            }
            throw originalError
        }
    }

    private func launchSquirrel() throws {
        let result = try launchRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-a", SquirrelPathResolver.appURL.path],
            timeout: timeout
        )
        guard result.status == 0 else {
            throw RimeSyncError.commandFailed("无法重新启动 Squirrel：\(result.output)")
        }
    }
}

public enum SquirrelPathResolver {
    private static let fileManager = FileManager.default

    public static var appURL: URL {
        let userURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/Squirrel.app", isDirectory: true)
        if fileManager.fileExists(atPath: userURL.path) {
            return userURL
        }
        return URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app", isDirectory: true)
    }

    public static var executableURL: URL {
        appURL.appendingPathComponent("Contents/MacOS/Squirrel")
    }

    public static var dictionaryManagerURL: URL {
        appURL.appendingPathComponent("Contents/MacOS/rime_dict_manager")
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

public struct RimeBackupRetentionPolicy: Codable, Equatable, Sendable {
    public static let defaultLimit = 10
    public static let defaultValue = try! RimeBackupRetentionPolicy(limit: defaultLimit)

    public let limit: Int

    public init(limit: Int = RimeBackupRetentionPolicy.defaultLimit) throws {
        guard limit >= 1 else {
            throw RimeSyncError.unsupportedOperation("备份保留数量必须至少为 1")
        }
        self.limit = limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(limit: container.decode(Int.self, forKey: .limit))
    }

    private enum CodingKeys: String, CodingKey { case limit }
}

/// The retention setting is shared by the ordinary resource synchronizer and
/// the audit coordinator.  The reference is deliberately lock-protected so
/// the UI can change it while a background sync is in progress.
public final class RimeBackupRetentionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: RimeBackupRetentionPolicy

    public init(policy: RimeBackupRetentionPolicy = .defaultValue) {
        self.policy = policy
    }

    public var current: RimeBackupRetentionPolicy {
        lock.lock(); defer { lock.unlock() }
        return policy
    }

    @discardableResult
    public func update(limit: Int) throws -> RimeBackupRetentionPolicy {
        let updated = try RimeBackupRetentionPolicy(limit: limit)
        lock.lock(); defer { lock.unlock() }
        policy = updated
        return updated
    }
}

public struct RimeBackupDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let nodeID: String
    public let createdAt: Date?

    public init(id: String, nodeID: String, createdAt: Date?) {
        self.id = id
        self.nodeID = nodeID
        self.createdAt = createdAt
    }
}

public protocol RimeBackupListing {
    func listBackups(configuration: SyncConfiguration) throws -> [RimeBackupDescriptor]
}

public struct RimeBackupManager: RimeBackupListing {
    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createBackup(
        configuration: SyncConfiguration,
        retention: RimeBackupRetentionPolicy = .defaultValue,
        pruneAfterCreation: Bool = true
    ) throws -> String {
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
        if pruneAfterCreation {
            try pruneBackups(configuration: configuration, retention: retention)
        }
        return id
    }

    /// Lists only backups that contain a complete snapshot for the current
    /// node, so every row shown by the restore UI is actually restorable by
    /// the current account.
    public func listBackups(configuration: SyncConfiguration) throws -> [RimeBackupDescriptor] {
        guard fileManager.fileExists(atPath: configuration.backupRoot.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: configuration.backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let snapshot = directory
                .appendingPathComponent(configuration.nodeID, isDirectory: true)
                .appendingPathComponent("Rime", isDirectory: true)
            guard fileManager.fileExists(atPath: snapshot.path) else { return nil }
            return RimeBackupDescriptor(
                id: directory.lastPathComponent,
                nodeID: configuration.nodeID,
                createdAt: backupDate(for: directory)
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id > rhs.id
            }
        }
    }

    /// Removes old backups for the current node only.  Backups belonging to
    /// the other macOS account are not affected by this account's setting.
    public func pruneBackups(
        configuration: SyncConfiguration,
        retention: RimeBackupRetentionPolicy,
        protectedBackupIDs: Set<String> = []
    ) throws {
        let backups = try listBackups(configuration: configuration)
        var keep = Set(backups.prefix(retention.limit).map(\.id))
        keep.formUnion(protectedBackupIDs)
        for backup in backups where !keep.contains(backup.id) {
            try fileManager.removeItem(at: configuration.backupRoot.appendingPathComponent(backup.id, isDirectory: true))
        }
    }

    public func restore(backupID: String, configuration: SyncConfiguration) throws {
        let backupDirectory = try validatedBackupDirectory(backupID, configuration: configuration)
        let snapshot = backupDirectory
            .appendingPathComponent(configuration.nodeID, isDirectory: true)
            .appendingPathComponent("Rime", isDirectory: true)
        guard fileManager.fileExists(atPath: snapshot.path) else {
            throw RimeSyncError.backupNotFound(backupID)
        }
        let staged = configuration.localRimeDirectory.deletingLastPathComponent()
            .appendingPathComponent(".rime-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: snapshot, to: staged)
        try replaceDirectory(at: configuration.localRimeDirectory, with: staged)
        let sharedSnapshot = backupDirectory
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
        try replaceDirectory(at: destination, with: staged)
    }

    private func replaceDirectory(at destination: URL, with staged: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    private func validatedBackupDirectory(_ backupID: String, configuration: SyncConfiguration) throws -> URL {
        let backupComponent = URL(fileURLWithPath: backupID).lastPathComponent
        guard !backupID.isEmpty,
              backupID.unicodeScalars.allSatisfy({ $0.value != 0 }),
              backupComponent == backupID else {
            throw RimeSyncError.backupNotFound(backupID)
        }

        let root = configuration.backupRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root
            .appendingPathComponent(backupID, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw RimeSyncError.backupNotFound(backupID)
        }
        return candidate
    }

    private func backupDate(for directory: URL) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        let prefix = directory.lastPathComponent.split(separator: "-", maxSplits: 2).prefix(2).joined(separator: "-")
        if let date = formatter.date(from: prefix) { return date }
        let values = try? directory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}

public final class DefaultRimeSyncEngine: RimeSyncEngine {
    private let configuration: SyncConfiguration
    private let maintenance: any NativeRimeMaintaining
    private let fileManager: FileManager
    private let now: () -> Date
    private let backupManager: RimeBackupManager
    private let retentionStore: RimeBackupRetentionStore

    public init(
        configuration: SyncConfiguration,
        maintenance: any NativeRimeMaintaining = SquirrelMaintenance(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        retentionStore: RimeBackupRetentionStore = RimeBackupRetentionStore()
    ) {
        self.configuration = configuration
        self.maintenance = maintenance
        self.fileManager = fileManager
        self.now = now
        self.backupManager = RimeBackupManager(fileManager: fileManager)
        self.retentionStore = retentionStore
    }

    public func status() throws -> SyncReport {
        let plan = try makePlan()
        return report(for: plan, backupID: "", userDictionarySyncSucceeded: false)
    }

    public func sync(dryRun: Bool = false) throws -> SyncReport {
        if dryRun { return try status() }
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        return try lock.withLock {
            try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
            let backupID = try backupManager.createBackup(configuration: configuration, retention: retentionStore.current)
            let plan = try makePlan()
            try execute(plan: plan, conflictID: backupID)
            try plan.manifest.saving(to: configuration.manifestURL, fileManager: fileManager)
            try SharedDirectoryLayout.makeGroupWritable(configuration.manifestURL, fileManager: fileManager)
            if plan.requiresReload {
                try maintenance.reload()
            }
            return report(for: plan, backupID: backupID, userDictionarySyncSucceeded: false)
        }
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
                try maintenance.reload()
                try backupManager.pruneBackups(configuration: configuration, retention: retentionStore.current)
            } catch let originalError {
                do {
                    try backupManager.restore(backupID: rollbackBackupID, configuration: configuration)
                    try maintenance.reload()
                } catch let recoveryError {
                    throw RimeSyncError.unsupportedOperation(
                        "恢复失败：\(originalError.localizedDescription)；回滚也失败：\(recoveryError.localizedDescription)；请使用备份 \(rollbackBackupID) 恢复"
                    )
                }
                throw originalError
            }
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
        let paths = Set(localRecords.keys)
            .union(manifest.records.keys)
            .union(nodeRecords.keys)
            .filter { RimeResourcePolicy.isAllowed(relativePath: $0) }
            .sorted()
        // Older prototypes may have put the generated managed dictionary in
        // the ordinary manifest. Remove that stale bookkeeping so it cannot
        // be pulled back into the account by a later LWW run.
        manifest.records.removeValue(forKey: RimeManagedDictionary.fileName)
        for node in manifest.nodes.keys {
            manifest.nodes[node]?.removeValue(forKey: RimeManagedDictionary.fileName)
        }
        manifest.pausedPaths.remove(RimeManagedDictionary.fileName)
        nodeRecords.removeValue(forKey: RimeManagedDictionary.fileName)
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
