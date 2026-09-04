import Foundation
import RimeSyncCore

@main
struct RimeSyncMain {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("RimeSync: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw usageError()
        }
        let options = try CLIOptions(arguments: Array(arguments.dropFirst()))
        switch command {
        case "bootstrap":
            try bootstrap(options: options)
        case "configure":
            try configure(options: options)
        case "status":
            try printReport(makeEngine(options: options).status())
        case "sync":
            try printReport(makeEngine(options: options).sync(dryRun: options.dryRun))
        case "verify":
            let result = RimeVerifier().verify(configuration: makeConfiguration(options: options))
            if result.isValid {
                print("verify: OK")
            } else {
                result.issues.forEach { print("verify: \($0)") }
                throw RimeSyncError.unsupportedOperation("verify 未通过")
            }
        case "restore":
            guard let backupID = options.backupID else {
                throw usageError("restore 需要 --backup <id>")
            }
            try makeEngine(options: options).restore(backupID: backupID)
            print("restore: \(backupID)")
        case "help", "--help", "-h":
            printUsage()
        default:
            throw usageError("未知命令：\(command)")
        }
    }

    private static func bootstrap(options: CLIOptions) throws {
        let source = options.source ?? URL(fileURLWithPath: "/Users/Shared/RimeMigration-20260904/Rime")
        let workspace = options.workspace ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("rime", isDirectory: true)
        let shared = options.sharedRoot
        let bootstrapper = RimeBootstrapper()
        let copied = try bootstrapper.captureStableResources(from: source, to: workspace)
        if options.captureOnly {
            print("bootstrap: 已保存 \(copied.count) 个稳定资源到 \(workspace.path)")
            print("bootstrap: capture-only 未读取或写入共享 userdb")
            return
        }
        try bootstrapper.initializeShared(
            from: source,
            sharedRoot: shared,
            sourceInstallationID: options.sourceInstallationID,
            sourceNodeID: "mac"
        )
        print("bootstrap: 已保存 \(copied.count) 个稳定资源到 \(workspace.path)")
        print("bootstrap: 已初始化共享配置与 userdb 快照目录 \(shared.path)")
        if options.install {
            let destination = options.localRimeDirectory
            _ = try bootstrapper.installStableResources(
                from: workspace,
                to: destination,
                installationID: options.installationID,
                sharedRoot: shared
            )
            print("bootstrap: 已安装到 \(destination.path)")
        } else {
            print("bootstrap: 未写入本地运行目录；需要安装时追加 --install")
        }
    }

    private static func configure(options: CLIOptions) throws {
        try SharedDirectoryLayout.prepare(sharedRoot: options.sharedRoot, nodeIDs: [options.nodeID ?? "mac2"])
        let installationURL = options.localRimeDirectory.appendingPathComponent("installation.yaml")
        try RimeInstallationFile.updating(
            existingURL: installationURL,
            installationID: options.installationID,
            syncDirectory: options.sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true)
        )
        print("configure: 已更新 \(installationURL.path)")
    }

    private static func makeEngine(options: CLIOptions) -> DefaultRimeSyncEngine {
        DefaultRimeSyncEngine(configuration: makeConfiguration(options: options))
    }

    private static func makeConfiguration(options: CLIOptions) -> SyncConfiguration {
        SyncConfiguration(
            localRimeDirectory: options.localRimeDirectory,
            sharedRoot: options.sharedRoot,
            installationID: options.installationID,
            nodeID: options.nodeID
        )
    }

    private static func printReport(_ report: SyncReport) {
        print("changed: \(report.changedFiles.count)")
        report.changedFiles.forEach { print("  \($0)") }
        print("deleted: \(report.deletedFiles.count)")
        report.deletedFiles.forEach { print("  \($0)") }
        print("conflicts: \(report.conflicts.count)")
        report.conflicts.forEach { print("  \($0)") }
        if !report.backupID.isEmpty { print("backup: \(report.backupID)") }
        print("userdb-sync: \(report.userDictionarySyncSucceeded ? "OK" : "not run")")
    }

    private static func usageError(_ message: String = "") -> Error {
        RimeSyncError.unsupportedOperation(message.isEmpty ? "缺少命令；运行 RimeSync help 查看用法" : "\(message)\n\n\(usageText)")
    }

    private static func printUsage() { print(usageText) }

    private static let usageText = """
    用法：
      RimeSync bootstrap [--source <Rime目录>] [--workspace <目录>] [--capture-only] [--install]
      RimeSync configure [--rime-dir <目录>] [--shared-root <目录>] [--installation-id <id>]
      RimeSync status [--rime-dir <目录>] [--shared-root <目录>]
      RimeSync sync [--dry-run] [--rime-dir <目录>] [--shared-root <目录>]
      RimeSync verify [--rime-dir <目录>] [--shared-root <目录>]
      RimeSync restore --backup <id> [--rime-dir <目录>] [--shared-root <目录>]

    默认：本地 ~/Library/Rime，共享 /Users/Shared/RimeSync，mac2 使用 mac2-main。
    """
}

private struct CLIOptions {
    let localRimeDirectory: URL
    let sharedRoot: URL
    let installationID: String
    let nodeID: String?
    let source: URL?
    let workspace: URL?
    let sourceInstallationID: String
    let install: Bool
    let captureOnly: Bool
    let dryRun: Bool
    let backupID: String?

    init(arguments: [String]) throws {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var local = URL(fileURLWithPath: home).appendingPathComponent("Library/Rime", isDirectory: true)
        var shared = URL(fileURLWithPath: "/Users/Shared/RimeSync", isDirectory: true)
        var installationID = "mac2-main"
        var node: String?
        var source: URL?
        var workspace: URL?
        var sourceInstallationID = "af672354-60fc-458a-9254-b0a39c8132ea"
        var install = false
        var captureOnly = false
        var dryRun = false
        var backup: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--install": install = true
            case "--capture-only": captureOnly = true
            case "--dry-run": dryRun = true
            case "--rime-dir": local = try Self.value(arguments, index: &index, for: argument).asURL()
            case "--shared-root": shared = try Self.value(arguments, index: &index, for: argument).asURL()
            case "--installation-id": installationID = try Self.value(arguments, index: &index, for: argument)
            case "--node": node = try Self.value(arguments, index: &index, for: argument)
            case "--source": source = try Self.value(arguments, index: &index, for: argument).asURL()
            case "--workspace": workspace = try Self.value(arguments, index: &index, for: argument).asURL()
            case "--source-installation-id": sourceInstallationID = try Self.value(arguments, index: &index, for: argument)
            case "--backup": backup = try Self.value(arguments, index: &index, for: argument)
            default: throw RimeSyncError.unsupportedOperation("未知参数：\(argument)")
            }
            index += 1
        }
        self.localRimeDirectory = local
        self.sharedRoot = shared
        self.installationID = installationID
        self.nodeID = node
        self.source = source
        self.workspace = workspace
        self.sourceInstallationID = sourceInstallationID
        self.install = install
        self.captureOnly = captureOnly
        self.dryRun = dryRun
        self.backupID = backup
    }

    private static func value(_ arguments: [String], index: inout Int, for option: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw RimeSyncError.unsupportedOperation("参数 \(option) 缺少值") }
        return arguments[index]
    }
}

private extension String {
    func asURL() -> URL { URL(fileURLWithPath: NSString(string: self).expandingTildeInPath) }
}
