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
        switch command {
        case "configure", "sync", "resolve", "restore":
            throw RimeSyncError.unsupportedOperation("自动跨账户同步命令已停用。请在 Rime Voice 中使用“导出所有配置…”与“导入所有配置…”；status、conflicts、verify 仅保留只读诊断。")
        default:
            break
        }
        let options = try CLIOptions(arguments: Array(arguments.dropFirst()))
        switch command {
        case "bootstrap":
            try bootstrap(options: options)
        case "status":
            try printReport(makeEngine(options: options).status())
        case "conflicts":
            try printConflicts(makeEngine(options: options).conflictPreviews())
        case "verify":
            let result = RimeVerifier().verify(configuration: makeConfiguration(options: options))
            if result.isValid {
                print("verify: OK")
            } else {
                result.issues.forEach { print("verify: \($0)") }
                throw RimeSyncError.unsupportedOperation("verify 未通过")
            }
        case "help", "--help", "-h":
            printUsage()
        default:
            throw usageError("未知命令：\(command)")
        }
    }

    private static func bootstrap(options: CLIOptions) throws {
        guard options.captureOnly, !options.install else {
            throw RimeSyncError.unsupportedOperation("bootstrap 只允许 --capture-only；安装与共享初始化已停用，请使用手动配置存档")
        }
        let source = options.source ?? URL(fileURLWithPath: "/Users/Shared/RimeMigration-20260904/Rime")
        let workspace = options.workspace ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("rime", isDirectory: true)
        let bootstrapper = RimeBootstrapper()
        let copied = try bootstrapper.captureStableResources(from: source, to: workspace)
        print("bootstrap: 已保存 \(copied.count) 个稳定资源到 \(workspace.path)")
        print("bootstrap: capture-only 未读取或写入共享 userdb")
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
        let status: String
        if !report.conflicts.isEmpty {
            status = "partial"
        } else if !report.reloadSucceeded {
            status = "saved-reload-failed"
        } else {
            status = "complete"
        }
        print("status: \(status)")
        print("operations: \(report.operations.count)")
        report.operations.forEach {
            print("  [\($0.kind.rawValue)] \($0.relativePath) (\($0.kind.displayName))")
        }
        print("changed: \(report.changedFiles.count)")
        report.changedFiles.forEach { print("  \($0)") }
        print("deleted: \(report.deletedFiles.count)")
        report.deletedFiles.forEach { print("  \($0)") }
        print("conflicts: \(report.conflicts.count)")
        report.conflicts.forEach { print("  \($0)") }
        report.conflictDetails.forEach {
            print("  reason[\($0.relativePath)]: \($0.reason.rawValue) (\($0.reason.displayName)), nodes=\($0.nodeIDs.joined(separator: ","))")
        }
        if !report.autoRecoveredFiles.isEmpty {
            print("auto-recovered: \(report.autoRecoveredFiles.count)")
            report.autoRecoveredFiles.forEach { print("  \($0)") }
        }
        if !report.reloadSucceeded {
            print("reload: failed")
            if let reloadError = report.reloadError { print("  \(reloadError)") }
        }
        if !report.backupID.isEmpty { print("backup: \(report.backupID)") }
        print("userdb-sync: \(report.userDictionarySyncSucceeded ? "OK" : "not run")")
    }

    private static func printConflicts(_ previews: [RimeConflictPreview]) {
        print("conflicts: \(previews.count)")
        for preview in previews {
            print("\(preview.relativePath): \(preview.reason.rawValue) (\(preview.reason.displayName))")
            print("  nodes: \(preview.variants.map(\.nodeID).joined(separator: ","))")
            print("  version: \(preview.versionToken)")
            if let localText = preview.localText {
                print("  local:")
                print(localText, terminator: localText.hasSuffix("\n") ? "" : "\n")
            }
            if let sharedText = preview.sharedText {
                print("  shared:")
                print(sharedText, terminator: sharedText.hasSuffix("\n") ? "" : "\n")
            }
            if let suggestedMerge = preview.suggestedMerge {
                print("  suggested-merge:")
                print(suggestedMerge, terminator: suggestedMerge.hasSuffix("\n") ? "" : "\n")
            }
        }
    }

    private static func usageError(_ message: String = "") -> Error {
        RimeSyncError.unsupportedOperation(message.isEmpty ? "缺少命令；运行 RimeSync help 查看用法" : "\(message)\n\n\(usageText)")
    }

    private static func printUsage() { print(usageText) }

    private static let usageText = """
    用法：
      RimeSync bootstrap --capture-only [--source <Rime目录>] [--workspace <目录>]
      RimeSync status [--rime-dir <目录>] [--shared-root <诊断目录>]
      RimeSync conflicts [--rime-dir <目录>] [--shared-root <诊断目录>]
      RimeSync verify [--rime-dir <目录>] [--shared-root <诊断目录>]

    sync、configure、resolve 与 restore 已停用，仅保留只读历史诊断。
    默认审核/诊断状态：~/Library/Application Support/Rime Voice/Review。
    只读检查旧共享数据时，可给 status、conflicts 或 verify 显式传入 --shared-root /Users/Shared/RimeSync。
    """
}

private struct CLIOptions {
    let localRimeDirectory: URL
    let sharedRoot: URL
    let installationID: String
    let nodeID: String?
    let source: URL?
    let workspace: URL?
    let install: Bool
    let captureOnly: Bool

    init(arguments: [String]) throws {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var local = URL(fileURLWithPath: home).appendingPathComponent("Library/Rime", isDirectory: true)
        var shared = RimeLocalReviewStorage.defaultRoot()
        var installationID = "mac2-main"
        var node: String?
        var source: URL?
        var workspace: URL?
        var install = false
        var captureOnly = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--install": install = true
            case "--capture-only": captureOnly = true
            case "--rime-dir": local = try Self.value(arguments, index: &index, for: argument).asURL()
            case "--shared-root": shared = try Self.value(arguments, index: &index, for: argument).asURL()
            case "--installation-id": installationID = try Self.value(arguments, index: &index, for: argument)
            case "--node": node = try Self.value(arguments, index: &index, for: argument)
            case "--source": source = try Self.value(arguments, index: &index, for: argument).asURL()
            case "--workspace": workspace = try Self.value(arguments, index: &index, for: argument).asURL()
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
        self.install = install
        self.captureOnly = captureOnly
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
