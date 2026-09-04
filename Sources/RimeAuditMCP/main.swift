import Foundation
import MCP
import RimeSyncCore

/// Read-only bridge between an AI client and the Rime audit batch.
///
/// The only mutating operation exposed here is submitting a proposal to the
/// shared review JSON.  Applying a proposal, writing a managed dictionary,
/// creating a tombstone, and restoring a backup remain menu-bar UI actions.
private final class RimeAuditMCPService: @unchecked Sendable {
    private let options: RimeAuditMCPOptions
    private let fileManager: FileManager
    private let batchStore: RimeAuditBatchStore
    private let reviewStore: RimeReviewStore

    init(options: RimeAuditMCPOptions, fileManager: FileManager = .default) {
        self.options = options
        self.fileManager = fileManager
        self.batchStore = RimeAuditBatchStore(
            url: options.sharedRoot
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("rime-audit-batch.json"),
            fileManager: fileManager
        )
        self.reviewStore = RimeReviewStore(
            url: options.sharedRoot
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("rime-review-state.json"),
            fileManager: fileManager
        )
    }

    var tools: [Tool] {
        [
            Tool(
                name: "rime_audit_summary",
                description: "读取当前 Rime 审核批次的摘要、来源快照和状态数量。",
                inputSchema: Self.objectSchema(),
                annotations: readOnlyAnnotations
            ),
            Tool(
                name: "rime_audit_list",
                description: "按视图、累计次数、有效热度、最近活动和搜索条件分页读取 Rime 词条。",
                inputSchema: Self.listSchema(),
                annotations: readOnlyAnnotations
            ),
            Tool(
                name: "rime_audit_export",
                description: "导出当前审核批次的 RFC 4180 CSV，供 AI 离线分析。",
                inputSchema: Self.objectSchema(),
                annotations: readOnlyAnnotations
            ),
            Tool(
                name: "rime_audit_submit_proposal",
                description: "校验并保存 AI 审核提案；不会应用提案或修改 userdb。",
                inputSchema: Self.submitSchema(),
                annotations: Tool.Annotations(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            Tool(
                name: "rime_audit_preview",
                description: "预览已提交的 AI 提案数量，并报告批次是否已经过期。",
                inputSchema: Self.objectSchema(),
                annotations: readOnlyAnnotations
            )
        ]
    }

    func handle(_ parameters: CallTool.Parameters) -> CallTool.Result {
        do {
            let text: String
            switch parameters.name {
            case "rime_audit_summary":
                text = try summary()
            case "rime_audit_list":
                text = try list(arguments: parameters.arguments ?? [:])
            case "rime_audit_export":
                text = try export()
            case "rime_audit_submit_proposal":
                text = try submitProposal(arguments: parameters.arguments ?? [:])
            case "rime_audit_preview":
                text = try preview()
            default:
                throw RimeSyncError.unsupportedOperation("未知 Rime 审核工具：\(parameters.name)")
            }
            return CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)],
                isError: false
            )
        } catch {
            let message = "RimeAuditMCP: \(error.localizedDescription)"
            writeLog(message)
            return CallTool.Result(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private func summary() throws -> String {
        let batch = try loadBatch()
        let state = try reviewStore.load()
        let statusCounts = Dictionary(grouping: batch.entries, by: { $0.currentStatus.rawValue })
            .mapValues(\.count)
        let output = SummaryOutput(
            schemaVersion: batch.schemaVersion,
            batchID: batch.batchID,
            snapshotDigest: batch.snapshotDigest,
            snapshotDigests: batch.snapshotDigests,
            entryCount: batch.entries.count,
            statusCounts: statusCounts,
            proposalCount: state.proposals[batch.batchID]?.count ?? 0,
            isInitialBaseline: batch.isInitialBaseline,
            migration: state.migration
        )
        return try json(output)
    }

    private func list(arguments: [String: Value]) throws -> String {
        let batch = try loadBatch()
        let query = try makeQuery(arguments: arguments)
        let result = RimeAuditFilter.filter(batch.entries, query: query)
        let output = ListOutput(
            schemaVersion: batch.schemaVersion,
            batchID: batch.batchID,
            snapshotDigest: batch.snapshotDigest,
            entries: result.entries,
            heatThreshold: result.heatThreshold,
            totalBeforePaging: result.totalBeforePaging
        )
        return try json(output)
    }

    private func export() throws -> String {
        let batch = try loadBatch()
        return String(decoding: RimeAuditCSV.export(batch: batch), as: UTF8.self)
    }

    private func submitProposal(arguments: [String: Value]) throws -> String {
        guard let csv = arguments["csv"]?.stringValue else {
            throw RimeSyncError.unsupportedOperation("rime_audit_submit_proposal 需要 csv 字段")
        }
        let batch = try loadBatch()
        let proposals = try RimeAuditCSV.importProposals(data: Data(csv.utf8), batch: batch)
        guard try currentAggregateDigest() == batch.snapshotDigest else {
            throw RimeSyncError.unsupportedOperation("AI 提案对应的 Rime 快照已变化，请重新导出和分析")
        }
        let lock = DirectoryLock(
            lockURL: options.sharedRoot.appendingPathComponent(".lock", isDirectory: true),
            fileManager: fileManager
        )
        try lock.withLock {
            var state = try reviewStore.load()
            state.proposals[batch.batchID] = proposals
            try reviewStore.save(state)
        }
        return try json(previewOutput(batch: batch, proposals: proposals))
    }

    private func preview() throws -> String {
        let batch = try loadBatch()
        let state = try reviewStore.load()
        let proposals = state.proposals[batch.batchID] ?? []
        return try json(previewOutput(batch: batch, proposals: proposals))
    }

    private func previewOutput(batch: RimeAuditBatch, proposals: [RimeAuditProposal]) -> PreviewOutput {
        var counts: [String: Int] = [:]
        for proposal in proposals {
            counts[proposal.action.rawValue, default: 0] += 1
        }
        let currentDigest = (try? currentAggregateDigest()) ?? nil
        return PreviewOutput(
            batchID: batch.batchID,
            snapshotDigest: batch.snapshotDigest,
            proposalCount: proposals.count,
            countsByAction: counts,
            stale: currentDigest != batch.snapshotDigest
        )
    }

    private func loadBatch() throws -> RimeAuditBatch {
        guard let batch = try batchStore.load() else {
            throw RimeSyncError.unsupportedOperation("尚未生成 Rime 审核批次，请先在菜单栏程序中读取词库")
        }
        return batch
    }

    private func makeQuery(arguments: [String: Value]) throws -> RimeAuditQuery {
        let view = try parse(RimeAuditView.self, key: "view", arguments: arguments) ?? .all
        let commitBand = try parse(RimeCommitCountBand.self, key: "commit_band", arguments: arguments) ?? .all
        let heatBand = try parse(RimeHeatBand.self, key: "heat_band", arguments: arguments) ?? .all
        let activityBand = try parse(
            RimeRecentActivityBand.self,
            key: "activity_band",
            arguments: arguments
        ) ?? .all
        let sortKey = try parse(RimeAuditSortKey.self, key: "sort", arguments: arguments) ?? .heat
        let offset = max(0, arguments["offset"]?.intValue ?? 0)
        let requestedLimit = arguments["limit"]?.intValue ?? 100
        let limit = min(1_000, max(0, requestedLimit))
        return RimeAuditQuery(
            view: view,
            commitBand: commitBand,
            heatBand: heatBand,
            activityBand: activityBand,
            search: arguments["search"]?.stringValue ?? "",
            sortKey: sortKey,
            ascending: arguments["ascending"]?.boolValue ?? false,
            offset: offset,
            limit: limit,
            includeStale: arguments["include_stale"]?.boolValue ?? false
        )
    }

    private func parse<T: RawRepresentable>(
        _ type: T.Type,
        key: String,
        arguments: [String: Value]
    ) throws -> T? where T.RawValue == String {
        guard let raw = arguments[key]?.stringValue else { return nil }
        guard let result = T(rawValue: raw) else {
            throw RimeSyncError.unsupportedOperation("参数 \(key) 无效：\(raw)")
        }
        return result
    }

    private func currentAggregateDigest() throws -> String {
        let digests = try currentSnapshotDigests()
        return RimeAuditBatch.aggregateSnapshotDigest(digests)
    }

    private func currentSnapshotDigests() throws -> [String: String] {
        let root = options.sharedRoot.appendingPathComponent("rime-userdata", isDirectory: true)
        var result: [String: String] = [:]
        if fileManager.fileExists(atPath: root.path) {
            let directories = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for directory in directories where
                (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            {
                let snapshot = directory.appendingPathComponent("rime_ice.userdb.txt")
                guard fileManager.fileExists(atPath: snapshot.path) else { continue }
                result[directory.lastPathComponent] = RimeSnapshotParser.digest(
                    try Data(contentsOf: snapshot, options: [.mappedIfSafe])
                )
            }
        }

        let localSnapshot = options.localRimeDirectory
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(options.installationID, isDirectory: true)
            .appendingPathComponent("rime_ice.userdb.txt")
        if result[options.installationID] == nil,
           fileManager.fileExists(atPath: localSnapshot.path)
        {
            result[options.installationID] = RimeSnapshotParser.digest(
                try Data(contentsOf: localSnapshot, options: [.mappedIfSafe])
            )
        }
        return result
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder.rimeEncoder.encode(value), as: UTF8.self)
    }

    private static let readOnlyAnnotations = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    private var readOnlyAnnotations: Tool.Annotations { Self.readOnlyAnnotations }

    private static func objectSchema() -> Value {
        .object(["type": .string("object"), "properties": .object([:])])
    }

    private static func listSchema() -> Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "view": .object([
                    "type": .string("string"),
                    "enum": .array(RimeAuditView.allCases.map { .string($0.rawValue) })
                ]),
                "commit_band": .object([
                    "type": .string("string"),
                    "enum": .array(RimeCommitCountBand.allCases.map { .string($0.rawValue) })
                ]),
                "heat_band": .object([
                    "type": .string("string"),
                    "enum": .array(RimeHeatBand.allCases.map { .string($0.rawValue) })
                ]),
                "activity_band": .object([
                    "type": .string("string"),
                    "enum": .array(RimeRecentActivityBand.allCases.map { .string($0.rawValue) })
                ]),
                "search": .object(["type": .string("string")]),
                "sort": .object([
                    "type": .string("string"),
                    "enum": .array(RimeAuditSortKey.allCases.map { .string($0.rawValue) })
                ]),
                "ascending": .object(["type": .string("boolean")]),
                "offset": .object(["type": .string("integer"), "minimum": .int(0)]),
                "limit": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1_000)]),
                "include_stale": .object(["type": .string("boolean")])
            ])
        ])
    }

    private static func submitSchema() -> Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "csv": .object([
                    "type": .string("string"),
                    "description": .string("由 rime_audit_export 导出的批次提案 CSV")
                ])
            ]),
            "required": .array([.string("csv")])
        ])
    }
}

private struct SummaryOutput: Codable {
    let schemaVersion: Int
    let batchID: String
    let snapshotDigest: String
    let snapshotDigests: [String: String]
    let entryCount: Int
    let statusCounts: [String: Int]
    let proposalCount: Int
    let isInitialBaseline: Bool
    let migration: RimeReviewMigration

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case batchID = "batch_id"
        case snapshotDigest = "snapshot_digest"
        case snapshotDigests = "snapshot_digests"
        case entryCount = "entry_count"
        case statusCounts = "status_counts"
        case proposalCount = "proposal_count"
        case isInitialBaseline = "is_initial_baseline"
        case migration
    }
}

private struct ListOutput: Codable {
    let schemaVersion: Int
    let batchID: String
    let snapshotDigest: String
    let entries: [RimeAuditEntry]
    let heatThreshold: Double?
    let totalBeforePaging: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case batchID = "batch_id"
        case snapshotDigest = "snapshot_digest"
        case entries
        case heatThreshold = "heat_threshold"
        case totalBeforePaging = "total_before_paging"
    }
}

private struct PreviewOutput: Codable {
    let batchID: String
    let snapshotDigest: String
    let proposalCount: Int
    let countsByAction: [String: Int]
    let stale: Bool

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case snapshotDigest = "snapshot_digest"
        case proposalCount = "proposal_count"
        case countsByAction = "counts_by_action"
        case stale
    }
}

private struct RimeAuditMCPOptions {
    let localRimeDirectory: URL
    let sharedRoot: URL
    let installationID: String

    init(arguments: [String]) throws {
        let environmentHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var local = URL(fileURLWithPath: environmentHome)
            .appendingPathComponent("Library/Rime", isDirectory: true)
        var shared = URL(fileURLWithPath: "/Users/Shared/RimeSync", isDirectory: true)
        var installation = "mac2-main"

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--rime-dir":
                index += 1
                guard index < arguments.count else { throw Self.usageError("--rime-dir 缺少值") }
                local = URL(fileURLWithPath: NSString(string: arguments[index]).expandingTildeInPath)
            case "--shared-root":
                index += 1
                guard index < arguments.count else { throw Self.usageError("--shared-root 缺少值") }
                shared = URL(fileURLWithPath: NSString(string: arguments[index]).expandingTildeInPath)
            case "--installation-id":
                index += 1
                guard index < arguments.count else { throw Self.usageError("--installation-id 缺少值") }
                installation = arguments[index]
            case "--node":
                index += 1
                guard index < arguments.count else { throw Self.usageError("--node 缺少值") }
                // Accepted for parity with RimeSync. The audit batch is
                // keyed by installation IDs, not by UI node labels.
            default:
                throw Self.usageError("未知参数：\(arguments[index])")
            }
            index += 1
        }
        self.localRimeDirectory = local.standardizedFileURL
        self.sharedRoot = shared.standardizedFileURL
        self.installationID = installation
    }

    private static func usageError(_ message: String) -> Error {
        RimeSyncError.unsupportedOperation(
            "\(message)。用法：RimeAuditMCP [--rime-dir <目录>] [--shared-root <目录>] [--installation-id <id>]"
        )
    }
}

private func writeLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
private struct RimeAuditMCPMain {
    static func main() async {
        do {
            let options = try RimeAuditMCPOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let service = RimeAuditMCPService(options: options)
            let server = Server(
                name: "RimeAuditMCP",
                version: "0.1.1",
                instructions: "只读取 Rime 审核数据并提交提案；所有实际修改必须由 TencentVoiceMVP 菜单栏界面确认。",
                capabilities: .init(tools: .init(listChanged: false)),
                configuration: .strict
            )
            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: service.tools)
            }
            await server.withMethodHandler(CallTool.self) { parameters in
                service.handle(parameters)
            }
            let transport = StdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            writeLog(error.localizedDescription)
            Foundation.exit(1)
        }
    }
}
