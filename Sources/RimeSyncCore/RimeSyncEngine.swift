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
    public var baselineDirectory: URL {
        sharedConfigRoot.appendingPathComponent("baselines", isDirectory: true).appendingPathComponent(nodeID, isDirectory: true)
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
    public let operations: [SyncFileOperation]
    public let conflicts: [String]
    public let conflictDetails: [RimeConflictSummary]
    public let autoRecoveredFiles: [String]
    public let backupID: String
    public let userDictionarySyncSucceeded: Bool
    public let reloadSucceeded: Bool
    public let reloadError: String?

    public init(
        changedFiles: [String] = [],
        deletedFiles: [String] = [],
        conflicts: [String] = [],
        conflictDetails: [RimeConflictSummary] = [],
        autoRecoveredFiles: [String] = [],
        backupID: String = "",
        userDictionarySyncSucceeded: Bool = false,
        reloadSucceeded: Bool = true,
        reloadError: String? = nil,
        operations: [SyncFileOperation] = []
    ) {
        self.changedFiles = changedFiles.sorted()
        self.deletedFiles = deletedFiles.sorted()
        self.operations = operations.sorted {
            if $0.relativePath == $1.relativePath {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.relativePath < $1.relativePath
        }
        self.conflicts = conflicts.sorted()
        self.conflictDetails = conflictDetails.sorted { $0.relativePath < $1.relativePath }
        self.autoRecoveredFiles = autoRecoveredFiles.sorted()
        self.backupID = backupID
        self.userDictionarySyncSucceeded = userDictionarySyncSucceeded
        self.reloadSucceeded = reloadSucceeded
        self.reloadError = reloadError
    }
}

public protocol RimeSyncEngine {
    func status() throws -> SyncReport
    func sync(dryRun: Bool) throws -> SyncReport
    func sync(paths: Set<String>, dryRun: Bool) throws -> SyncReport
    func restore(backupID: String) throws
    func conflictPreviews() throws -> [RimeConflictPreview]
    func resolveConflict(
        path: String,
        resolution: RimeConflictResolution,
        expectedVersion: String?
    ) throws -> SyncReport
}

public extension RimeSyncEngine {
    /// A whole-configuration-only engine must not silently widen a scoped
    /// request into a full synchronization.
    func sync(paths: Set<String>, dryRun: Bool) throws -> SyncReport {
        throw RimeSyncError.unsupportedOperation("当前同步引擎不支持按文件范围同步")
    }

    func conflictPreviews() throws -> [RimeConflictPreview] {
        throw RimeSyncError.unsupportedOperation("当前同步引擎不支持冲突预览")
    }

    func resolveConflict(
        path: String,
        resolution: RimeConflictResolution,
        expectedVersion: String? = nil
    ) throws -> SyncReport {
        throw RimeSyncError.unsupportedOperation("当前同步引擎不支持处理冲突")
    }
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
        try performSync(paths: nil, dryRun: dryRun)
    }

    public func sync(paths: Set<String>, dryRun: Bool) throws -> SyncReport {
        if let invalidPath = paths.first(where: { !RimeResourcePolicy.isAllowed(relativePath: $0) }) {
            throw RimeSyncError.invalidRelativePath(invalidPath)
        }
        return try performSync(paths: paths, dryRun: dryRun)
    }

    public func conflictPreviews() throws -> [RimeConflictPreview] {
        let localRecords = try currentLocalRecords()
        let manifest = try RimeManifest.loading(from: configuration.manifestURL, fileManager: fileManager)
        let paths = Set(manifest.pausedPaths).union(manifest.conflicts.keys)
            .filter { RimeResourcePolicy.isAllowed(relativePath: $0) }
            .sorted()
        return try paths.compactMap { path in
            let record = conflictRecord(
                for: path,
                manifest: manifest,
                localRecords: localRecords
            )
            guard let record else { return nil }
            return try makePreview(record: record, localRecords: localRecords)
        }
    }

    public func resolveConflict(
        path: String,
        resolution: RimeConflictResolution,
        expectedVersion: String? = nil
    ) throws -> SyncReport {
        guard RimeResourcePolicy.isAllowed(relativePath: path) else {
            throw RimeSyncError.invalidRelativePath(path)
        }
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        return try lock.withLock {
            try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
            let localRecords = try currentLocalRecords()
            var manifest = try RimeManifest.loading(from: configuration.manifestURL, fileManager: fileManager)
            guard let conflict = conflictRecord(for: path, manifest: manifest, localRecords: localRecords) else {
                throw RimeSyncError.conflictNotFound(path)
            }
            let currentPreview = try makePreview(record: conflict, localRecords: localRecords)
            if let expectedVersion, expectedVersion != currentPreview.versionToken {
                throw RimeSyncError.conflictChanged(path)
            }

            let backupID = try backupManager.createBackup(configuration: configuration, retention: retentionStore.current)
            let selected = try selectedResolution(
                resolution,
                path: path,
                conflict: conflict,
                localRecords: localRecords,
                manifest: manifest
            )
            let record = makeRecord(
                path: path,
                data: selected.data,
                owner: configuration.nodeID,
                state: selected.state
            )
            manifest.nodes[configuration.nodeID, default: [:]][path] = record
            manifest.records[path] = record
            manifest.pausedPaths.remove(path)
            manifest.conflicts.removeValue(forKey: path)

            let item = PlanItem(
                path: path,
                action: .reconcile(
                    record: record,
                    data: selected.data,
                    operation: operation(for: resolution, state: selected.state),
                    countsAsChange: true
                )
            )
            let plan = SyncPlan(
                items: [item],
                manifest: manifest,
                autoRecoveredFiles: []
            )
            let snapshots = try snapshots(for: plan)
            do {
                try execute(plan: plan, conflictID: backupID)
                try plan.manifest.saving(to: configuration.manifestURL, fileManager: fileManager)
                try SharedDirectoryLayout.makeGroupWritable(configuration.manifestURL, fileManager: fileManager)
            } catch {
                try rollback(snapshots, originalError: error)
            }

            var reloadSucceeded = true
            var reloadError: String?
            do {
                try maintenance.reload()
            } catch {
                reloadSucceeded = false
                reloadError = error.localizedDescription
            }
            return report(
                for: plan,
                backupID: backupID,
                userDictionarySyncSucceeded: false,
                reloadSucceeded: reloadSucceeded,
                reloadError: reloadError
            )
        }
    }

    private func performSync(paths: Set<String>?, dryRun: Bool) throws -> SyncReport {
        if dryRun { return try report(for: makePlan(paths: paths), backupID: "", userDictionarySyncSucceeded: false) }
        let lock = DirectoryLock(lockURL: configuration.lockURL, fileManager: fileManager)
        return try lock.withLock {
            try SharedDirectoryLayout.prepare(sharedRoot: configuration.sharedRoot, nodeIDs: [configuration.nodeID], fileManager: fileManager)
            let backupID = try backupManager.createBackup(configuration: configuration, retention: retentionStore.current)
            let plan = try makePlan(paths: paths)
            let snapshots = try snapshots(for: plan)
            do {
                try execute(plan: plan, conflictID: backupID)
                try plan.manifest.saving(to: configuration.manifestURL, fileManager: fileManager)
                try SharedDirectoryLayout.makeGroupWritable(configuration.manifestURL, fileManager: fileManager)
            } catch {
                try rollback(snapshots, originalError: error)
            }
            var reloadSucceeded = true
            var reloadError: String?
            if plan.requiresReload {
                do {
                    try maintenance.reload()
                } catch {
                    reloadSucceeded = false
                    reloadError = error.localizedDescription
                }
            }
            return report(
                for: plan,
                backupID: backupID,
                userDictionarySyncSucceeded: false,
                reloadSucceeded: reloadSucceeded,
                reloadError: reloadError
            )
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
            case merge(record: FileRecord, data: Data)
            case reconcile(record: FileRecord, data: Data, operation: SyncOperationKind, countsAsChange: Bool)
            case baseline(FileRecord)
            case conflict(RimeConflictRecord)
        }

        let path: String
        let action: Action
    }

    private struct SyncPlan {
        var items: [PlanItem]
        var manifest: RimeManifest
        var autoRecoveredFiles: [String]
        var requiresReload: Bool {
            items.contains { item in
                if case .baseline = item.action { return false }
                return true
            }
        }
    }

    private func makePlan(paths allowedPaths: Set<String>? = nil) throws -> SyncPlan {
        let localRecords = try currentLocalRecords()
        var manifest = try RimeManifest.loading(from: configuration.manifestURL, fileManager: fileManager)
        var nodeRecords = manifest.nodes[configuration.nodeID] ?? [:]
        let paths = Set(localRecords.keys)
            .union(manifest.records.keys)
            .union(nodeRecords.keys)
            .union(manifest.pausedPaths)
            .union(manifest.conflicts.keys)
            .filter { path in
                RimeResourcePolicy.isAllowed(relativePath: path)
                    && (allowedPaths == nil || allowedPaths?.contains(path) == true)
            }
            .sorted()
        // Older prototypes may have put the generated managed dictionary in
        // the ordinary manifest. Remove that stale bookkeeping so it cannot
        // be pulled back into the account by a later ordinary sync.
        manifest.records.removeValue(forKey: RimeManagedDictionary.fileName)
        for node in manifest.nodes.keys {
            manifest.nodes[node]?.removeValue(forKey: RimeManagedDictionary.fileName)
        }
        manifest.pausedPaths.remove(RimeManagedDictionary.fileName)
        nodeRecords.removeValue(forKey: RimeManagedDictionary.fileName)
        var items: [PlanItem] = []
        var autoRecoveredFiles: [String] = []

        for path in paths {
            if manifest.pausedPaths.contains(path) || manifest.conflicts[path] != nil {
                guard let conflict = conflictRecord(for: path, manifest: manifest, localRecords: localRecords) else {
                    continue
                }
                if let recovery = try automaticRecovery(for: conflict, localRecords: localRecords) {
                    items.append(
                        PlanItem(
                            path: path,
                            action: .reconcile(
                                record: recovery.record,
                                data: recovery.data,
                                operation: .merge,
                                countsAsChange: recovery.countsAsChange
                            )
                        )
                    )
                    autoRecoveredFiles.append(path)
                    manifest.records[path] = recovery.record
                    manifest.pausedPaths.remove(path)
                    manifest.conflicts.removeValue(forKey: path)
                    manifest.nodes[configuration.nodeID, default: [:]][path] = recovery.record
                    nodeRecords[path] = recovery.record
                    continue
                }
                items.append(PlanItem(path: path, action: .conflict(conflict)))
                manifest.pausedPaths.insert(path)
                manifest.conflicts[path] = conflict
                continue
            }

            let baseline = nodeRecords[path]
            let local = localRecords[path] ?? missingRecord(path: path, baseline: baseline)
            let shared = manifest.records[path]
            let decision = ThreeWayMergeResolver.resolve(local: local, shared: shared, baseline: baseline)

            switch decision {
            case .unchanged:
                if let local {
                    nodeRecords[path] = local
                    items.append(PlanItem(path: path, action: .baseline(local)))
                }
            case .local:
                guard let local else { continue }
                items.append(PlanItem(path: path, action: .publish(local)))
                manifest.records[path] = local
                nodeRecords[path] = local
            case .shared:
                guard let shared else { continue }
                items.append(PlanItem(path: path, action: .pull(shared)))
                nodeRecords[path] = shared
            case .merge:
                guard let baseline, let local, let shared,
                      let merged = makeMergedResource(baseline: baseline, local: local, shared: shared) else {
                    let conflict = makeConflictRecord(
                        path: path,
                        local: local,
                        shared: shared,
                        baseline: baseline,
                        reason: conflictReason(local: local, shared: shared, baseline: baseline),
                        manifest: manifest
                    )
                    items.append(PlanItem(path: path, action: .conflict(conflict)))
                    manifest.pausedPaths.insert(path)
                    manifest.conflicts[path] = conflict
                    continue
                }
                items.append(PlanItem(path: path, action: .merge(record: merged.record, data: merged.data)))
                manifest.records[path] = merged.record
                nodeRecords[path] = merged.record
            case .conflict:
                let conflict = makeConflictRecord(
                    path: path,
                    local: local,
                    shared: shared,
                    baseline: baseline,
                    reason: conflictReason(local: local, shared: shared, baseline: baseline),
                    manifest: manifest
                )
                items.append(PlanItem(path: path, action: .conflict(conflict)))
                manifest.pausedPaths.insert(path)
                manifest.conflicts[path] = conflict
            }
        }

        manifest.nodes[configuration.nodeID] = nodeRecords
        return SyncPlan(
            items: items,
            manifest: manifest,
            autoRecoveredFiles: autoRecoveredFiles
        )
    }

    private func currentLocalRecords() throws -> [String: FileRecord] {
        Dictionary(
            uniqueKeysWithValues: try RimeFileInventory(
                root: configuration.localRimeDirectory,
                fileManager: fileManager
            ).scan(owner: configuration.nodeID).map { ($0.relativePath, $0) }
        )
    }

    private func conflictRecord(
        for path: String,
        manifest: RimeManifest,
        localRecords: [String: FileRecord]
    ) -> RimeConflictRecord? {
        guard manifest.pausedPaths.contains(path) || manifest.conflicts[path] != nil else {
            return nil
        }
        if var existing = manifest.conflicts[path] {
            if let local = localRecords[path] {
                existing.nodeRecords[configuration.nodeID] = local
            } else if let previousLocal = existing.nodeRecords[configuration.nodeID],
                      let tombstone = missingRecord(path: path, baseline: previousLocal) {
                existing.nodeRecords[configuration.nodeID] = tombstone
            }
            existing.sharedRecord = manifest.records[path]
            return existing
        }

        var nodeRecords = manifest.nodes.reduce(into: [String: FileRecord]()) { result, entry in
            if let record = entry.value[path] {
                result[entry.key] = record
            }
        }
        if let local = localRecords[path] {
            nodeRecords[configuration.nodeID] = local
        } else if let nodeRecord = manifest.nodes[configuration.nodeID]?[path] {
            nodeRecords[configuration.nodeID] = missingRecord(path: path, baseline: nodeRecord) ?? nodeRecord
        }
        let legacy = legacyConflictEvidence(for: path)
        nodeRecords.merge(legacy.nodeRecords) { current, _ in current }
        return RimeConflictRecord(
            relativePath: path,
            nodeRecords: nodeRecords,
            sharedRecord: manifest.records[path] ?? legacy.shared,
            baselineRecord: legacy.baseline,
            reason: legacy.reason,
            artifactID: legacy.artifactID
        )
    }

    private func makeConflictRecord(
        path: String,
        local: FileRecord?,
        shared: FileRecord?,
        baseline: FileRecord?,
        reason: RimeConflictReason,
        manifest: RimeManifest
    ) -> RimeConflictRecord {
        var nodeRecords = manifest.nodes.reduce(into: [String: FileRecord]()) { result, entry in
            if let record = entry.value[path] {
                result[entry.key] = record
            }
        }
        if let local {
            nodeRecords[configuration.nodeID] = local
        }
        return RimeConflictRecord(
            relativePath: path,
            nodeRecords: nodeRecords,
            sharedRecord: shared,
            baselineRecord: baseline,
            reason: reason
        )
    }

    private func conflictReason(
        local: FileRecord?,
        shared: FileRecord?,
        baseline: FileRecord?
    ) -> RimeConflictReason {
        if local?.state != shared?.state, local != nil, shared != nil {
            return .deletionConflict
        }
        if baseline == nil {
            return .firstSync
        }
        guard baseline?.state == .present,
              local?.state == .present,
              shared?.state == .present else {
            return .deletionConflict
        }
        guard let baselineData = try? baselineData(for: baseline!) else {
            return .missingBaseline
        }
        if !dataMatches(baselineData, record: baseline!) {
            return .baselineMismatch
        }
        return .overlappingEdits
    }

    private struct LegacyConflictEvidence {
        var artifactID: String?
        var baseline: FileRecord?
        var nodeRecords: [String: FileRecord] = [:]
        var shared: FileRecord?
        var reason: RimeConflictReason = .historical
    }

    private func legacyConflictEvidence(for path: String) -> LegacyConflictEvidence {
        let name = path.replacingOccurrences(of: "/", with: "__")
        guard let directories = try? fileManager.contentsOfDirectory(
            at: configuration.conflictRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return LegacyConflictEvidence()
        }
        for directory in directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let detailURL = directory.appendingPathComponent("\(name).conflict.json")
            if let detailData = try? Data(contentsOf: detailURL),
               let detail = try? JSONDecoder.rimeDecoder.decode(RimeConflictRecord.self, from: detailData) {
                return LegacyConflictEvidence(
                    artifactID: directory.lastPathComponent,
                    baseline: detail.baselineRecord,
                    nodeRecords: detail.nodeRecords,
                    shared: detail.sharedRecord,
                    reason: detail.reason
                )
            }
            let baselineURL = directory.appendingPathComponent("\(name).baseline.json")
            let baseline = (try? Data(contentsOf: baselineURL)).flatMap {
                try? JSONDecoder.rimeDecoder.decode(FileRecord.self, from: $0)
            }
            let sharedURL = directory.appendingPathComponent("\(name).shared.json")
            let shared = (try? Data(contentsOf: sharedURL)).flatMap {
                try? JSONDecoder.rimeDecoder.decode(FileRecord.self, from: $0)
            }
            if baseline != nil || shared != nil {
                return LegacyConflictEvidence(
                    artifactID: directory.lastPathComponent,
                    baseline: baseline,
                    shared: shared
                )
            }
        }
        return LegacyConflictEvidence()
    }

    private struct AutomaticRecovery {
        let record: FileRecord
        let data: Data
        let countsAsChange: Bool
    }

    private func automaticRecovery(
        for conflict: RimeConflictRecord,
        localRecords: [String: FileRecord]
    ) throws -> AutomaticRecovery? {
        // Legacy artifacts are deliberately conservative when their contents
        // still differ or their evidence is incomplete. Equal current
        // content is safe to reconcile because no version choice is needed.
        guard let sharedRecord = conflict.sharedRecord,
              sharedRecord.state == .present else {
            return nil
        }

        var nodeRecords = conflict.nodeRecords
        if let local = localRecords[conflict.relativePath] {
            nodeRecords[configuration.nodeID] = local
        }
        guard !nodeRecords.isEmpty else { return nil }

        var dataByIdentity: [String: Data] = [:]
        var timestamps: [Int64] = [sharedRecord.modifiedNanoseconds]
        for (nodeID, record) in nodeRecords {
            guard record.state == .present,
                  let data = try? nodeData(for: record, nodeID: nodeID),
                  dataMatches(data, record: record) else {
                return nil
            }
            timestamps.append(record.modifiedNanoseconds)
            dataByIdentity[record.contentIdentity] = data
        }
        guard let sharedData = try? sharedData(for: sharedRecord),
              dataMatches(sharedData, record: sharedRecord) else {
            return nil
        }
        dataByIdentity[sharedRecord.contentIdentity] = sharedData

        if dataByIdentity.count == 1, let data = dataByIdentity.values.first {
            let record = makeRecord(
                path: conflict.relativePath,
                data: data,
                owner: configuration.nodeID,
                modifiedNanoseconds: max(nowNanoseconds(), timestamps.max() ?? nowNanoseconds())
            )
            let changed = localRecords[conflict.relativePath]?.contentIdentity != record.contentIdentity
            return AutomaticRecovery(
                record: record,
                data: data,
                countsAsChange: changed
            )
        }

        // A historical artifact with different current content still needs
        // an explicit user choice because its original baseline is not
        // trustworthy.
        guard conflict.reason != .historical else { return nil }

        // If this account already equals the shared version while another
        // node still differs, do not let this account clear that node's
        // unresolved conflict.
        if localRecords[conflict.relativePath]?.contentIdentity == sharedRecord.contentIdentity {
            return nil
        }
        guard dataByIdentity.count == 2,
              let baseline = conflict.baselineRecord,
              baseline.state == .present,
              let baseData = try? baselineData(for: baseline),
              dataMatches(baseData, record: baseline),
              let baseText = String(data: baseData, encoding: .utf8),
              let localRecord = localRecords[conflict.relativePath],
              localRecord.state == .present,
              let localData = try? localData(for: localRecord),
              dataMatches(localData, record: localRecord),
              localRecord.contentIdentity != sharedRecord.contentIdentity,
              let localText = String(data: localData, encoding: .utf8),
              let sharedText = String(data: sharedData, encoding: .utf8) else {
            return nil
        }
        guard case let .merged(mergedText) = RimeTextMerger.merge(
                  base: baseText,
                  local: localText,
                  shared: sharedText
              ) else {
            return nil
        }
        let data = Data(mergedText.utf8)
        let record = makeRecord(
            path: conflict.relativePath,
            data: data,
            owner: configuration.nodeID,
            modifiedNanoseconds: max(nowNanoseconds(), (timestamps.max() ?? nowNanoseconds()) + 1)
        )
        return AutomaticRecovery(
            record: record,
            data: data,
            countsAsChange: true
        )
    }

    private func makePreview(
        record: RimeConflictRecord,
        localRecords: [String: FileRecord]
    ) throws -> RimeConflictPreview {
        var variants: [RimeConflictVariant] = []
        for nodeID in record.nodeRecords.keys.sorted() {
            guard let nodeRecord = record.nodeRecords[nodeID] else { continue }
            let data = try? nodeData(for: nodeRecord, nodeID: nodeID)
            variants.append(
                RimeConflictVariant(
                    nodeID: nodeID,
                    record: nodeRecord,
                    text: data.flatMap { String(data: $0, encoding: .utf8) }
                )
            )
        }
        let localRecord = localRecords[record.relativePath] ?? record.nodeRecords[configuration.nodeID]
        let localBytes: Data? = localRecord.flatMap { item in try? localData(for: item) }
        let sharedBytes: Data? = record.sharedRecord.flatMap { item in try? sharedData(for: item) }
        let localText = localBytes.flatMap { String(data: $0, encoding: .utf8) }
        let sharedText = sharedBytes.flatMap { String(data: $0, encoding: .utf8) }
        let suggestedMerge = suggestedMerge(for: record, variants: variants)
        let versionSource = [
            record.relativePath,
            record.reason.rawValue,
            record.sharedRecord?.contentIdentity ?? "missing-shared",
            record.baselineRecord?.contentIdentity ?? "missing-baseline"
        ] + variants.map { "\($0.nodeID)=\($0.record.contentIdentity)" }
        let versionToken = RimeSnapshotParser.digest(Data(versionSource.joined(separator: "|").utf8))
        return RimeConflictPreview(
            relativePath: record.relativePath,
            reason: record.reason,
            variants: variants,
            localRecord: localRecord,
            sharedRecord: record.sharedRecord,
            baselineRecord: record.baselineRecord,
            localText: localText,
            sharedText: sharedText,
            suggestedMerge: suggestedMerge,
            versionToken: versionToken
        )
    }

    private func suggestedMerge(
        for conflict: RimeConflictRecord,
        variants: [RimeConflictVariant]
    ) -> String? {
        guard let baseline = conflict.baselineRecord,
              let baseData = try? baselineData(for: baseline),
              dataMatches(baseData, record: baseline),
              let baseText = String(data: baseData, encoding: .utf8) else {
            return nil
        }
        var texts: [String] = []
        for text in variants.compactMap(\.text) where !texts.contains(text) {
            texts.append(text)
        }
        guard texts.count == 2,
              case let .merged(text) = RimeTextMerger.merge(
                  base: baseText,
                  local: texts[0],
                  shared: texts[1]
              ) else {
            return nil
        }
        return text
    }

    private func nodeData(for record: FileRecord, nodeID: String) throws -> Data {
        if nodeID == configuration.nodeID {
            return try localData(for: record)
        }
        let root = configuration.sharedConfigRoot
            .appendingPathComponent("nodes", isDirectory: true)
            .appendingPathComponent(nodeID, isDirectory: true)
        let url = try AtomicFileStore.safeURL(root: root, relativePath: record.relativePath)
        return try Data(contentsOf: url)
    }

    private struct SelectedResolution {
        let data: Data
        let state: FileState
    }

    private func selectedResolution(
        _ resolution: RimeConflictResolution,
        path: String,
        conflict: RimeConflictRecord,
        localRecords: [String: FileRecord],
        manifest: RimeManifest
    ) throws -> SelectedResolution {
        switch resolution {
        case .keepLocal:
            guard let local = localRecords[path] else {
                if conflict.nodeRecords[configuration.nodeID] != nil {
                    return SelectedResolution(data: Data(), state: .tombstone)
                }
                throw RimeSyncError.unsupportedOperation("当前账户缺少本地版本：\(path)")
            }
            guard local.state == .present else {
                return SelectedResolution(data: Data(), state: .tombstone)
            }
            let data = try localData(for: local)
            guard dataMatches(data, record: local) else {
                throw RimeSyncError.conflictChanged(path)
            }
            return SelectedResolution(data: data, state: .present)
        case .keepShared:
            guard let shared = conflict.sharedRecord ?? manifest.records[path] else {
                throw RimeSyncError.unsupportedOperation("共享目录缺少版本：\(path)")
            }
            guard shared.state == .present else {
                return SelectedResolution(data: Data(), state: .tombstone)
            }
            let data = try sharedData(for: shared)
            guard dataMatches(data, record: shared) else {
                throw RimeSyncError.conflictChanged(path)
            }
            return SelectedResolution(data: data, state: .present)
        case let .merge(text):
            guard let local = localRecords[path] ?? conflict.nodeRecords[configuration.nodeID],
                  local.state == .present,
                  let shared = conflict.sharedRecord ?? manifest.records[path],
                  shared.state == .present else {
                throw RimeSyncError.unsupportedOperation("二进制文件不能使用文本合并：\(path)")
            }
            let localBytes = try localData(for: local)
            let sharedBytes = try sharedData(for: shared)
            guard dataMatches(localBytes, record: local),
                  dataMatches(sharedBytes, record: shared),
                  String(data: localBytes, encoding: .utf8) != nil,
                  String(data: sharedBytes, encoding: .utf8) != nil else {
                throw RimeSyncError.conflictChanged(path)
            }
            return SelectedResolution(data: Data(text.utf8), state: .present)
        }
    }

    private func operation(
        for resolution: RimeConflictResolution,
        state: FileState
    ) -> SyncOperationKind {
        switch resolution {
        case .keepLocal:
            return state == .tombstone ? .deleteShared : .upload
        case .keepShared:
            return state == .tombstone ? .deleteLocal : .download
        case .merge:
            return .merge
        }
    }

    private func makeRecord(
        path: String,
        data: Data,
        owner: String,
        modifiedNanoseconds: Int64? = nil,
        state: FileState = .present
    ) -> FileRecord {
        switch state {
        case .present:
            return .present(
                path: path,
                modifiedNanoseconds: modifiedNanoseconds ?? nowNanoseconds(),
                byteCount: Int64(data.count),
                sha256: RimeSnapshotParser.digest(data),
                owner: owner
            )
        case .tombstone:
            return .tombstone(
                path: path,
                modifiedNanoseconds: modifiedNanoseconds ?? nowNanoseconds(),
                owner: owner
            )
        }
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

    private struct FileSnapshot {
        let url: URL
        let existed: Bool
        let data: Data?
    }

    private func snapshots(for plan: SyncPlan) throws -> [FileSnapshot] {
        var urls = Set<URL>()
        urls.insert(configuration.manifestURL)
        for item in plan.items {
            switch item.action {
            case .publish:
                urls.insert(try localURL(for: item.path))
                urls.insert(try nodeURL(for: item.path, nodeID: configuration.nodeID))
                urls.insert(try baselineURL(for: item.path, nodeID: configuration.nodeID))
            case .pull:
                urls.insert(try localURL(for: item.path))
                urls.insert(try baselineURL(for: item.path, nodeID: configuration.nodeID))
            case .merge:
                urls.insert(try localURL(for: item.path))
                urls.insert(try nodeURL(for: item.path, nodeID: configuration.nodeID))
                urls.insert(try baselineURL(for: item.path, nodeID: configuration.nodeID))
            case .reconcile:
                urls.insert(try localURL(for: item.path))
                urls.insert(try nodeURL(for: item.path, nodeID: configuration.nodeID))
                urls.insert(try baselineURL(for: item.path, nodeID: configuration.nodeID))
            case .baseline:
                urls.insert(try baselineURL(for: item.path, nodeID: configuration.nodeID))
            case .conflict:
                continue
            }
        }
        return try urls.sorted { $0.path < $1.path }.map { url in
            FileSnapshot(
                url: url,
                existed: fileManager.fileExists(atPath: url.path),
                data: fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            )
        }
    }

    private func rollback(_ snapshots: [FileSnapshot], originalError: Error) throws -> Never {
        var recoveryErrors: [String] = []
        for snapshot in snapshots.reversed() {
            do {
                if snapshot.existed, let data = snapshot.data {
                    try AtomicFileStore.write(data, to: snapshot.url, fileManager: fileManager)
                } else if fileManager.fileExists(atPath: snapshot.url.path) {
                    try fileManager.removeItem(at: snapshot.url)
                }
            } catch {
                recoveryErrors.append("\(snapshot.url.path)：\(error.localizedDescription)")
            }
        }
        if recoveryErrors.isEmpty {
            throw originalError
        }
        throw RimeSyncError.unsupportedOperation(
            "同步写入失败：\(originalError.localizedDescription)；局部回滚失败：\(recoveryErrors.joined(separator: "；"))"
        )
    }

    private func localURL(for path: String) throws -> URL {
        try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: path)
    }

    private func nodeURL(for path: String, nodeID: String) throws -> URL {
        let root = configuration.sharedConfigRoot
            .appendingPathComponent("nodes", isDirectory: true)
            .appendingPathComponent(nodeID, isDirectory: true)
        return try AtomicFileStore.safeURL(root: root, relativePath: path)
    }

    private func baselineURL(for path: String, nodeID: String) throws -> URL {
        let root = configuration.sharedConfigRoot
            .appendingPathComponent("baselines", isDirectory: true)
            .appendingPathComponent(nodeID, isDirectory: true)
        return try AtomicFileStore.safeURL(root: root, relativePath: path)
    }

    private func execute(plan: SyncPlan, conflictID: String) throws {
        for item in plan.items {
            switch item.action {
            case let .publish(record):
                let source = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: item.path)
                let destination = try AtomicFileStore.safeURL(root: configuration.nodeDirectory, relativePath: item.path)
                try apply(record: record, source: source, destination: destination)
                try updateBaseline(record: record, source: source)
            case let .pull(record):
                let source = try AtomicFileStore.safeURL(
                    root: configuration.sharedConfigRoot.appendingPathComponent("nodes", isDirectory: true).appendingPathComponent(record.owner, isDirectory: true),
                    relativePath: item.path
                )
                let destination = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: item.path)
                try apply(record: record, source: source, destination: destination)
                try updateBaseline(record: record, source: source)
            case let .merge(record, data):
                let localDestination = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: item.path)
                let nodeDestination = try AtomicFileStore.safeURL(root: configuration.nodeDirectory, relativePath: item.path)
                try AtomicFileStore.write(data, to: localDestination, fileManager: fileManager)
                try AtomicFileStore.write(data, to: nodeDestination, fileManager: fileManager)
                try writeBaseline(data, for: record)
            case let .reconcile(record, data, _, _):
                let localDestination = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: item.path)
                try apply(record: record, data: data, destination: localDestination)
                let nodeDestination = try AtomicFileStore.safeURL(root: configuration.nodeDirectory, relativePath: item.path)
                try apply(record: record, data: data, destination: nodeDestination)
                try updateBaseline(record: record, source: nodeDestination)
            case let .baseline(record):
                let source = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: item.path)
                try updateBaseline(record: record, source: source)
            case let .conflict(conflict):
                try saveConflict(conflict: conflict, conflictID: conflictID)
            }
        }
    }

    private func makeMergedResource(
        baseline: FileRecord,
        local: FileRecord,
        shared: FileRecord
    ) -> (record: FileRecord, data: Data)? {
        guard baseline.state == .present, local.state == .present, shared.state == .present,
              let baseData = try? baselineData(for: baseline),
              let localData = try? localData(for: local),
              let sharedData = try? sharedData(for: shared),
              dataMatches(baseData, record: baseline),
              dataMatches(localData, record: local),
              dataMatches(sharedData, record: shared),
              let baseText = String(data: baseData, encoding: .utf8),
              let localText = String(data: localData, encoding: .utf8),
              let sharedText = String(data: sharedData, encoding: .utf8) else {
            return nil
        }
        guard case let .merged(text) = RimeTextMerger.merge(base: baseText, local: localText, shared: sharedText) else {
            return nil
        }
        let data = Data(text.utf8)
        let latestTimestamp = max(local.modifiedNanoseconds, shared.modifiedNanoseconds)
        let nextTimestamp = latestTimestamp == Int64.max ? latestTimestamp : latestTimestamp + 1
        let modifiedNanoseconds = max(nowNanoseconds(), nextTimestamp)
        return (
            FileRecord.present(
                path: local.relativePath,
                modifiedNanoseconds: modifiedNanoseconds,
                byteCount: Int64(data.count),
                sha256: RimeSnapshotParser.digest(data),
                owner: configuration.nodeID
            ),
            data
        )
    }

    private func localData(for record: FileRecord) throws -> Data {
        let url = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: record.relativePath)
        return try Data(contentsOf: url)
    }

    private func baselineData(for record: FileRecord) throws -> Data {
        let currentBaselineURL = try baselineURL(for: record.relativePath, nodeID: configuration.nodeID)
        if fileManager.fileExists(atPath: currentBaselineURL.path) {
            return try Data(contentsOf: currentBaselineURL)
        }
        // Older builds sometimes keyed baselines by the record owner rather
        // than by the node that observed the record. Keep that layout as a
        // compatibility fallback, but still validate the returned bytes
        // against the recorded digest at the call site.
        if record.owner != configuration.nodeID {
            let legacyBaselineURL = try baselineURL(for: record.relativePath, nodeID: record.owner)
            if fileManager.fileExists(atPath: legacyBaselineURL.path) {
                return try Data(contentsOf: legacyBaselineURL)
            }
        }
        // Compatibility for nodes created before baseline snapshots existed.
        // It is safe only when the baseline belongs to this node; another
        // node's current file may already have advanced past the baseline.
        guard record.owner == configuration.nodeID else {
            throw RimeSyncError.unsupportedOperation("缺少共同基线：\(record.relativePath)")
        }
        let nodeRoot = configuration.sharedConfigRoot
            .appendingPathComponent("nodes", isDirectory: true)
            .appendingPathComponent(record.owner, isDirectory: true)
        let nodeURL = try AtomicFileStore.safeURL(root: nodeRoot, relativePath: record.relativePath)
        return try Data(contentsOf: nodeURL)
    }

    private func sharedData(for record: FileRecord) throws -> Data {
        let root = configuration.sharedConfigRoot
            .appendingPathComponent("nodes", isDirectory: true)
            .appendingPathComponent(record.owner, isDirectory: true)
        let url = try AtomicFileStore.safeURL(root: root, relativePath: record.relativePath)
        return try Data(contentsOf: url)
    }

    private func dataMatches(_ data: Data, record: FileRecord) -> Bool {
        guard record.state == .present else { return false }
        return Int64(data.count) == record.byteCount
            && RimeSnapshotParser.digest(data) == record.sha256
    }

    private func writeBaseline(_ data: Data, for record: FileRecord, nodeID: String? = nil) throws {
        let destination = try baselineURL(
            for: record.relativePath,
            nodeID: nodeID ?? configuration.nodeID
        )
        try AtomicFileStore.write(data, to: destination, fileManager: fileManager)
        try SharedDirectoryLayout.makeGroupWritable(destination, fileManager: fileManager)
    }

    private func apply(record: FileRecord, data: Data, destination: URL) throws {
        switch record.state {
        case .present:
            try AtomicFileStore.write(data, to: destination, fileManager: fileManager)
        case .tombstone:
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
        }
    }

    private func updateBaseline(record: FileRecord, source: URL, nodeID: String? = nil) throws {
        let baselineNodeID = nodeID ?? configuration.nodeID
        let baselineRoot = configuration.sharedConfigRoot
            .appendingPathComponent("baselines", isDirectory: true)
            .appendingPathComponent(baselineNodeID, isDirectory: true)
        let baselineURL = try AtomicFileStore.safeURL(root: baselineRoot, relativePath: record.relativePath)
        guard record.state == .present else {
            if fileManager.fileExists(atPath: baselineURL.path) {
                try fileManager.removeItem(at: baselineURL)
            }
            return
        }
        try writeBaseline(try Data(contentsOf: source), for: record, nodeID: baselineNodeID)
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

    private func saveConflict(conflict: RimeConflictRecord, conflictID: String) throws {
        let path = conflict.relativePath
        let directory = configuration.conflictRoot.appendingPathComponent(conflictID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = path.replacingOccurrences(of: "/", with: "__")
        if let local = conflict.nodeRecords[configuration.nodeID], local.state == .present {
            let source = try AtomicFileStore.safeURL(root: configuration.localRimeDirectory, relativePath: path)
            let destination = directory.appendingPathComponent("\(name).\(configuration.nodeID).local")
            try fileManager.copyItem(at: source, to: destination)
        } else if let local = conflict.nodeRecords[configuration.nodeID] {
            let data = try JSONEncoder.rimeEncoder.encode(local)
            try AtomicFileStore.write(data, to: directory.appendingPathComponent("\(name).\(configuration.nodeID).local.tombstone.json"), fileManager: fileManager)
        }
        if let shared = conflict.sharedRecord {
            let data = try JSONEncoder.rimeEncoder.encode(shared)
            try AtomicFileStore.write(data, to: directory.appendingPathComponent("\(name).shared.json"), fileManager: fileManager)
        }
        if let baseline = conflict.baselineRecord {
            let data = try JSONEncoder.rimeEncoder.encode(baseline)
            try AtomicFileStore.write(data, to: directory.appendingPathComponent("\(name).baseline.json"), fileManager: fileManager)
        }
        let detail = try JSONEncoder.rimeEncoder.encode(conflict)
        try AtomicFileStore.write(detail, to: directory.appendingPathComponent("\(name).conflict.json"), fileManager: fileManager)
    }

    private func report(
        for plan: SyncPlan,
        backupID: String,
        userDictionarySyncSucceeded: Bool,
        reloadSucceeded: Bool = true,
        reloadError: String? = nil
    ) -> SyncReport {
        let operations = plan.items.compactMap { item -> SyncFileOperation? in
            switch item.action {
            case let .publish(record):
                return SyncFileOperation(
                    relativePath: item.path,
                    kind: record.state == .tombstone ? .deleteShared : .upload
                )
            case let .pull(record):
                return SyncFileOperation(
                    relativePath: item.path,
                    kind: record.state == .tombstone ? .deleteLocal : .download
                )
            case .merge:
                return SyncFileOperation(relativePath: item.path, kind: .merge)
            case let .reconcile(_, _, operation, countsAsChange):
                return countsAsChange
                    ? SyncFileOperation(relativePath: item.path, kind: operation)
                    : nil
            case .baseline, .conflict:
                return nil
            }
        }
        let changed = plan.items.compactMap { item -> String? in
            switch item.action {
            case .baseline, .conflict:
                return nil
            case let .publish(record), let .pull(record):
                return record.state == .present ? item.path : nil
            case let .merge(record, _):
                return record.state == .present ? item.path : nil
            case let .reconcile(record, _, _, countsAsChange):
                return countsAsChange && record.state == .present ? item.path : nil
            }
        }
        let deleted = plan.items.compactMap { item -> String? in
            switch item.action {
            case let .publish(record), let .pull(record): return record.state == .tombstone ? item.path : nil
            case let .merge(record, _): return record.state == .tombstone ? item.path : nil
            case let .reconcile(record, _, _, countsAsChange):
                return countsAsChange && record.state == .tombstone ? item.path : nil
            case .baseline, .conflict: return nil
            }
        }
        let conflictRecords = plan.items.compactMap { item -> RimeConflictRecord? in
            if case let .conflict(conflict) = item.action { return conflict }
            return nil
        }
        let conflicts = conflictRecords.map(\.relativePath)
        let summaries = conflictRecords.map { conflict in
            RimeConflictSummary(
                relativePath: conflict.relativePath,
                nodeIDs: Array(conflict.nodeRecords.keys),
                reason: conflict.reason,
                hasBaseline: conflict.baselineRecord != nil
            )
        }
        return SyncReport(
            changedFiles: changed,
            deletedFiles: deleted,
            conflicts: conflicts,
            conflictDetails: summaries,
            autoRecoveredFiles: plan.autoRecoveredFiles,
            backupID: backupID,
            userDictionarySyncSucceeded: userDictionarySyncSucceeded,
            reloadSucceeded: reloadSucceeded,
            reloadError: reloadError,
            operations: operations
        )
    }

    private func nowNanoseconds() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1_000_000_000).rounded())
    }
}
