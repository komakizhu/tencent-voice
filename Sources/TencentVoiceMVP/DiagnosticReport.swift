import AppKit
import Foundation

enum DiagnosticFindingLevel: String, Codable, Equatable, Sendable {
    case info
    case warning
    case failure

    var title: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .failure: return "失败"
        }
    }
}

struct DiagnosticFinding: Codable, Equatable, Sendable {
    let level: DiagnosticFindingLevel
    let code: String
    let message: String
}

enum DiagnosticCredentialState: String, Codable, Equatable, Sendable {
    case configured
    case missing
    case unreadable
}

struct DiagnosticCredentialInfo: Codable, Equatable, Sendable {
    let state: DiagnosticCredentialState
    let detail: String
}

struct DiagnosticSettingsInfo: Codable, Equatable, Sendable {
    let shortcut: String
    let engineModelType: String
    let persistentSessionLogEnabled: Bool
    let safeCopyEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case shortcut
        case engineModelType
        case persistentSessionLogEnabled
        case safeCopyEnabled
    }

    init(
        shortcut: String,
        engineModelType: String,
        persistentSessionLogEnabled: Bool,
        safeCopyEnabled: Bool = false
    ) {
        self.shortcut = shortcut
        self.engineModelType = engineModelType
        self.persistentSessionLogEnabled = persistentSessionLogEnabled
        self.safeCopyEnabled = safeCopyEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decode(String.self, forKey: .shortcut)
        engineModelType = try container.decode(String.self, forKey: .engineModelType)
        persistentSessionLogEnabled = try container.decode(Bool.self, forKey: .persistentSessionLogEnabled)
        safeCopyEnabled = try container.decodeIfPresent(Bool.self, forKey: .safeCopyEnabled) ?? false
    }
}

struct DiagnosticAppInfo: Codable, Equatable, Sendable {
    let displayName: String
    let bundleIdentifier: String
    let shortVersion: String
    let build: String
    let bundlePath: String
    let executablePath: String
    let bundleModificationDate: Date?
    let processIdentifier: Int32
    let processLaunchDate: Date?
    let currentUser: String
    let operatingSystem: String
    let machineArchitecture: String
    let signatureVerified: Bool
    let signatureDetails: String
}

struct DiagnosticReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let app: DiagnosticAppInfo
    let permissions: PrivacyPermissionReport
    let credentials: DiagnosticCredentialInfo
    let settings: DiagnosticSettingsInfo
    let events: [SessionLogEntry]
    let logDirectoryPath: String
    let findings: [DiagnosticFinding]

    init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        app: DiagnosticAppInfo,
        permissions: PrivacyPermissionReport,
        credentials: DiagnosticCredentialInfo,
        settings: DiagnosticSettingsInfo,
        events: [SessionLogEntry],
        logDirectoryPath: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.app = app
        self.permissions = permissions
        self.credentials = credentials
        self.settings = settings
        self.events = events
        self.logDirectoryPath = logDirectoryPath
        findings = Self.makeFindings(
            app: app,
            permissions: permissions,
            credentials: credentials,
            events: events
        )
    }

    func renderedText() -> String {
        var lines = [
            "Rime Voice 故障诊断报告",
            "报告版本：\(schemaVersion)",
            "生成时间：\(Self.format(generatedAt))",
            "",
            "【运行环境】",
            "当前账户：\(app.currentUser)",
            "操作系统：\(app.operatingSystem)",
            "硬件架构：\(app.machineArchitecture)",
            "App 显示名：\(app.displayName)",
            "Bundle ID：\(app.bundleIdentifier)",
            "版本：\(app.shortVersion)（build \(app.build)）",
            "App 路径：\(app.bundlePath)",
            "可执行文件：\(app.executablePath)",
            "App 文件更新时间：\(Self.formatOptional(app.bundleModificationDate))",
            "当前进程 PID：\(app.processIdentifier)",
            "当前进程启动时间：\(Self.formatOptional(app.processLaunchDate))",
            "签名验证：\(app.signatureVerified ? "通过" : "失败")",
            "签名信息：\(app.signatureDetails)",
            "",
            "【权限状态】"
        ]

        for status in permissions.statuses {
            lines.append("\(status.permission.title)：\(status.detail)")
        }

        lines += [
            "",
            "【凭证与设置】",
            "腾讯凭证：\(credentialSummary)",
            "快捷键：\(settings.shortcut)",
            "识别引擎：\(settings.engineModelType)",
            "自动保存诊断日志：\(settings.persistentSessionLogEnabled ? "已开启" : "未开启")",
            "Safe Copy：\(settings.safeCopyEnabled ? "已开启（正常输入并复制到剪贴板）" : "已关闭（发生输入错误时不复制）")",
            "日志目录：\(logDirectoryPath)",
            "",
            "【诊断判断】"
        ]

        if findings.isEmpty {
            lines.append("信息：当前没有发现可判定的问题。")
        } else {
            for finding in findings {
                lines.append("\(finding.level.title)[\(finding.code)]：\(finding.message)")
            }
        }

        lines += [
            "",
            "【会话与诊断事件】",
            "以下内容包含会话状态、错误代码和操作上下文，不包含密钥、录音或识别正文。"
        ]
        if events.isEmpty {
            lines.append("没有可用的日志事件。请开启“自动保存诊断日志”后复现一次，再点击“导出诊断报告”。")
        } else {
            for event in events {
                lines.append(Self.render(event))
            }
        }

        lines += [
            "",
            "【隐私说明】",
            "本报告不包含 AppID、SecretId、SecretKey、录音、识别文字或输入框原文。"
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func makeFindings(
        app: DiagnosticAppInfo,
        permissions: PrivacyPermissionReport,
        credentials: DiagnosticCredentialInfo,
        events: [SessionLogEntry]
    ) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []

        if let processLaunchDate = app.processLaunchDate,
           let bundleModificationDate = app.bundleModificationDate,
           processLaunchDate < bundleModificationDate {
            findings.append(DiagnosticFinding(
                level: .warning,
                code: "process_started_before_app_update",
                message: "当前进程启动于 App 文件更新时间之前；应用可能仍在运行更新前的旧代码，请完全退出后重新打开。"
            ))
        }

        if !permissions.missing.isEmpty {
            findings.append(DiagnosticFinding(
                level: .failure,
                code: "permissions_missing",
                message: "缺少：\(permissions.missing.map(\.title).joined(separator: "、"))。"
            ))
        }

        switch credentials.state {
        case .configured:
            break
        case .missing:
            findings.append(DiagnosticFinding(
                level: .failure,
                code: "credentials_missing",
                message: "当前用户没有读取到腾讯凭证。"
            ))
        case .unreadable:
            findings.append(DiagnosticFinding(
                level: .failure,
                code: "credentials_unreadable",
                message: "当前用户无法读取腾讯凭证（文件不可读或格式无效）。"
            ))
        }

        let sessionGroups = Dictionary(grouping: events, by: \.sessionID)
            .values
            .map { $0.sorted { $0.timestamp < $1.timestamp } }
            .sorted { lhs, rhs in
                (lhs.map(\.timestamp).max() ?? .distantPast)
                    > (rhs.map(\.timestamp).max() ?? .distantPast)
            }

        for sessionEvents in sessionGroups {
            guard let sessionID = sessionEvents.first?.sessionID.uuidString else { continue }
            let sessionLabel = "会话 \(sessionID)"
            let diagnosticMessages: [String: String] = [
                "keyboard_caret_recovered": "键盘事件发出后光标反馈短暂滞后，等待同步后已恢复，未重复发送文字。",
                "keyboard_wait_skipped": "光标位置不符合预期，但未进入等待；等待资格原因已记录，不能据此断言等待超时。",
                "keyboard_wait_timeout": "光标位置不符合预期，已实际等待并超过等待预算；仍不能单独证明是用户移动光标。",
                "keyboard_caret_timeout": "旧版本只记录了 timeout，是否实际等待未知；不能把它当作已等待超时。",
                "keyboard_caret_observed": "键盘输入后的目标状态已读回；本次反馈无需等待。",
                "keyboard_focus_changed": "键盘输入期间焦点元素发生变化，已停止输入。",
                "keyboard_confirmed_state_changed": "确认后的正文、选区或 AX 结构发生变化；未盲目重发，等待安全处理。",
                "keyboard_user_edit_detected": "录音期间检测到当前 Codex 输入框被用户编辑；已固定旧语音内容并重新建立输入边界。",
                "keyboard_user_edit_ambiguous": "录音期间输入框变化无法确认是可安全接续的用户编辑，已暂停写入。",
                "keyboard_user_edit_read_failed": "录音期间无法可靠读回输入框变化，已暂停写入。",
                "keyboard_state_rebased_after_user_edit": "已采用用户编辑后的正文和选区作为新的语音输入起点。",
                "input_application_changed": "前台应用发生变化，已停止输入。",
                "ax_focus_changed": "AX 文本更新期间焦点元素发生变化。",
                "ax_document_mismatch": "AX 读回文本与预期不符；请结合上次写入返回码判断，可能涉及写入未生效、回滚、读回延迟或外部编辑。",
                "ax_selection_mismatch": "AX 光标或文本替换范围不符合预期。",
                "ax_selection_unreadable": "无法取得有效的 AX 光标范围。",
                "ax_value_unreadable": "AX 未提供可读取的文本值。",
                "ax_coordinate_mapping_resolved": "已使用 AX 坐标文本确认当前输入框状态；报告只记录长度和映射来源，不记录正文。",
                "ax_coordinate_mapping_retryable": "AXValue 暂时落后于已前进的选区，确认器按既有确认上限重读；未重复发送文字。",
                "ax_coordinate_mapping_failed": "AX 文本与选区坐标无法安全统一，已停止继续写入；具体原因和长度信息已记录。",
                "mixed_input_rebased": "用户编辑后已冻结旧语音投影，并从当前光标继续输入新的语音内容。",
                "mixed_input_ambiguous": "识别修订跨越了已冻结的语音边界，未猜测新旧内容，已暂停自动写入。",
                "ax_write_failed": "AX 写入接口返回失败，具体属性和返回码已记录。",
                "ax_read_failed": "AX 读取接口返回失败，具体属性和返回码已记录。"
            ]
            for code in diagnosticMessages.keys.sorted() {
                let matching = sessionEvents.filter { $0.event == code }
                guard let latest = matching.last, let message = diagnosticMessages[code] else { continue }
                var values = diagnosticDetails(latest)
                if code == "keyboard_caret_recovered" {
                    values += "；等待耗时分布：\(waitDistribution(matching))"
                }
                findings.append(DiagnosticFinding(
                    level: [
                        "keyboard_caret_recovered", "keyboard_caret_observed", "ax_coordinate_mapping_resolved",
                        "ax_coordinate_mapping_retryable"
                    ].contains(code)
                        ? .info
                        : .warning,
                    code: code,
                    message: "\(sessionLabel)：\(message) 共 \(matching.count) 次。\(values)"
                ))
            }
            let operationEvents = sessionEvents.filter { $0.event == "input_operation" }
            if let latestOperation = operationEvents.last {
                findings.append(DiagnosticFinding(
                    level: .info,
                    code: "input_operation_trace",
                    message: "\(sessionLabel)：已关联 \(operationEvents.count) 次输入操作；最近一次 \(diagnosticDetails(latestOperation))"
                ))
            }
            for truncation in sessionEvents.filter({
                $0.event == "input_diagnostics_truncated" || $0.event == "target_diagnostics_truncated"
            }) {
                findings.append(DiagnosticFinding(
                    level: .warning,
                    code: truncation.event,
                    message: "\(sessionLabel)：诊断上下文被截断，丢弃 \(truncation.metadata["droppedEventCount"] ?? "未知") 条；其余字段仍可用。"
                ))
            }
            let resultEvents = sessionEvents.filter {
                ($0.event == "partial" || $0.event == "final" || $0.event == "stream_ended"
                    || $0.event == "finished" || $0.event == "finished_timeout")
                    && (($0.renderedLength ?? 0) > 0)
            }
            let safeCopyEvent = sessionEvents.last(where: { $0.event == "safe_copy" })
                ?? sessionEvents.last(where: { $0.injectionMode == "safe_copy" })
            let hasRecognizedResult = !resultEvents.isEmpty
                || (safeCopyEvent?.renderedLength ?? 0) > 0

            if let safeCopyEvent {
                let reason: String
                if let code = safeCopyEvent.failureCode,
                   let message = safeFailureMessage(for: safeCopyEvent) {
                    reason = "触发原因：\(code)，\(message)"
                } else if let code = safeCopyEvent.failureCode {
                    reason = "触发原因：\(code)（详细错误已隐藏）"
                } else {
                    reason = "触发原因未记录（旧版本日志没有保存具体错误）。"
                }
                let prefix = hasRecognizedResult
                    ? "识别结果已经返回，但文本输入进入 safe_copy"
                    : "文本输入进入 safe_copy，但没有记录到识别结果"
                let isManual = safeCopyEvent.failureCode == "safe_copy_manual"
                findings.append(DiagnosticFinding(
                    level: isManual ? .info : .failure,
                    code: isManual ? "safe_copy_enabled" : "safe_copy_triggered",
                    message: "\(sessionLabel)：\(prefix)；\(reason)"
                ))
            }

            if let inputError = sessionEvents.last(where: {
                $0.event == "input_error" || $0.injectionMode == "disabled_after_error"
            }) {
                let detail = safeFailureMessage(for: inputError) ?? "错误详情未记录或已隐藏。"
                let timing = degradationTimingSummary(inputError)
                findings.append(DiagnosticFinding(
                    level: .failure,
                    code: "input_error",
                    message: "\(sessionLabel)：Safe Copy 已关闭，输入失败后已停止继续写入；\(detail)\(timing)"
                ))
            }

            let finalEvent = sessionEvents.last {
                ($0.event == "final" || $0.event == "stream_ended")
                    && (($0.renderedLength ?? 0) > 0)
            }
            if let finalEvent,
               finalEvent.writeCount == 0,
               safeCopyEvent == nil {
                findings.append(DiagnosticFinding(
                    level: .warning,
                    code: "recognized_without_write",
                    message: "\(sessionLabel)：识别结果已经返回，但最近一次最终结果没有记录到写入操作。"
                ))
            }

            if sessionEvents.contains(where: { $0.event == "started" }), !hasRecognizedResult {
                findings.append(DiagnosticFinding(
                    level: .warning,
                    code: "no_asr_result",
                    message: "\(sessionLabel)：会话已启动，但没有记录到识别结果；需要检查音频输入或腾讯连接。"
                ))
            }

            if let error = sessionEvents.last(where: {
                $0.event == "error" || $0.event == "startup_error" || $0.event == "finish_error"
            }) {
                let detail = safeFailureMessage(for: error) ?? "错误详情未记录或已隐藏。"
                findings.append(DiagnosticFinding(
                    level: .failure,
                    code: error.failureCode ?? error.event,
                    message: "\(sessionLabel) 在 \(error.event) 阶段失败：\(detail)"
                ))
            }
        }

        if events.isEmpty {
            findings.append(DiagnosticFinding(
                level: .info,
                code: "no_session_data",
                message: "当前没有可分析的会话数据。"
            ))
        }

        return findings
    }

    private var credentialSummary: String {
        switch credentials.state {
        case .configured:
            return "已配置（具体内容已隐藏）"
        case .missing:
            return "未配置"
        case .unreadable:
            return "读取失败（凭证文件不可读或格式无效）"
        }
    }

    private static func render(_ event: SessionLogEntry) -> String {
        var fields = [
            Self.format(event.timestamp),
            "kind=\(event.kind.rawValue)",
            "session=\(event.sessionID.uuidString)",
            "event=\(event.event)",
            "state=\(event.state ?? "-")",
            "mode=\(event.injectionMode ?? "-")"
        ]
        if let name = event.targetApplicationName {
            var target = name
            if let bundleID = event.targetApplicationBundleIdentifier {
                target += " (\(bundleID))"
            }
            if let pid = event.targetApplicationProcessID {
                target += " pid=\(pid)"
            }
            fields.append("target=\(target)")
        }
        if let renderedLength = event.renderedLength { fields.append("resultLength=\(renderedLength)") }
        if let writeCount = event.writeCount { fields.append("writes=\(writeCount)") }
        if let errorCount = event.errorCount { fields.append("errors=\(errorCount)") }
        if let discardCount = event.discardCount { fields.append("discarded=\(discardCount)") }
        if let failureCode = event.failureCode { fields.append("failureCode=\(failureCode)") }
        if let failureMessage = safeFailureMessage(for: event) {
            fields.append("failure=\(failureMessage)")
        }
        if event.event == "input_operation" {
            fields.append("operation=\(event.metadata["operationID"] ?? "unknown")")
            fields.append("operationType=\(event.metadata["operationType"] ?? "unknown")")
            fields.append("operationStatus=\(event.metadata["operationStatus"] ?? "unknown")")
            fields.append("desired=\(lengthSummary(event.metadata, prefix: "desired"))")
            fields.append("submitted=\(lengthSummary(event.metadata, prefix: "submitted"))")
            fields.append("observed=\(lengthSummary(event.metadata, prefix: "observed"))")
            fields.append("revision=\(event.metadata["revision"] ?? "unknown")")
            fields.append("trigger=\(event.metadata["operationTrigger"] ?? "unknown")")
            fields.append("timing=\(timingSummary(event.metadata))")
        } else if event.event.hasPrefix("keyboard_") || event.event.hasPrefix("ax_") {
            fields.append("diagnostic=\(diagnosticDetails(event))")
        }
        if !event.metadata.isEmpty {
            let metadata = event.metadata.keys.sorted().map { key in
                "\(key)=\(event.metadata[key] ?? "")"
            }.joined(separator: ",")
            fields.append("metadata=\(metadata)")
        }
        return fields.joined(separator: " | ")
    }

    private static func diagnosticDetails(_ event: SessionLogEntry) -> String {
        let keys = [
            "operationID", "operationType", "operationStatus", "segmentID", "revision", "segmentPhase",
            "operationTrigger", "waitClassification", "waitSkippedReason", "lastDispatchAgeMilliseconds",
            "waitBudgetMilliseconds", "waitQualificationMaxAgeMilliseconds", "waitMilliseconds", "polls",
            "feedbackObservedMonotonicMilliseconds",
            "reason", "coordinateSource", "placeholderNormalized", "axValueLengthUTF16",
            "axCoordinateLengthUTF16", "omittedStructuralSeparatorCount", "placeholderAttributePresent",
            "placeholderMarkedNodeCount", "placeholderOtherNodeCount",
            "expectedLocation", "expectedLength", "initialLocation", "actualLocation", "actualLength",
            "desiredLengthCharacters", "desiredLengthUTF16", "submittedLengthCharacters",
            "submittedLengthUTF16", "observedLengthCharacters", "observedLengthUTF16",
            "commonPrefixLengthCharacters", "commonPrefixLengthUTF16", "previousTailLengthCharacters",
            "previousTailLengthUTF16", "replacementTailLengthCharacters", "replacementTailLengthUTF16",
            "plannedSelectionLocation", "plannedSelectionLength", "expectedEndLocation", "characterUnit",
            "utf16Unit", "writeCountMeaning", "targetProcessID", "targetApplicationProcessID",
            "targetElementProcessID", "frontmostApplicationMatchesTarget", "elementSame",
            "selectedRangeNonEmpty", "localDispatchCompleted", "targetCompletionConfirmed",
            "plannedKeyboardEventCount", "postedKeyboardEventCount", "unicodeBlockCount",
            "shiftKeyEventCount", "unicodeKeyEventCount", "deleteKeyEventCount",
            "failureCode", "failureOccurredAt", "degradationRecordedAt",
            "degradationRecordedOnASREvent", "degradationRecordTiming", "inputModeBeforeOperation",
            "inputModeBeforeDegradation", "sourceBuild"
        ]
        return keys.compactMap { key in
            guard let value = event.metadata[key] else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: ", ")
    }

    private static func lengthSummary(_ metadata: [String: String], prefix: String) -> String {
        let characters = metadata["\(prefix)LengthCharacters"] ?? "unknown"
        let utf16 = metadata["\(prefix)LengthUTF16"] ?? "unknown"
        return "\(characters) Character/\(utf16) UTF16"
    }

    private static func timingSummary(_ metadata: [String: String]) -> String {
        let keys = [
            "operationCreatedMonotonicMilliseconds", "operationQueuedMonotonicMilliseconds",
            "dispatchStartedMonotonicMilliseconds", "dispatchEndedMonotonicMilliseconds",
            "feedbackObservedMonotonicMilliseconds", "operationCompletedMonotonicMilliseconds",
            "operationFailedMonotonicMilliseconds"
        ]
        return keys.compactMap { key in
            guard let value = metadata[key] else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: ",")
    }

    private static func degradationTimingSummary(_ event: SessionLogEntry) -> String {
        guard let occurredAt = event.metadata["failureOccurredAt"] else {
            return "（故障发生时间未记录）"
        }
        let recordedAt = event.metadata["degradationRecordedAt"] ?? "未知"
        let timing = event.metadata["degradationRecordTiming"] ?? "未知"
        return "（故障发生时间=\(occurredAt)，报告记录时间=\(recordedAt)，记录阶段=\(timing)）"
    }

    private static func waitDistribution(_ events: [SessionLogEntry]) -> String {
        let values = events.compactMap { Double($0.metadata["waitMilliseconds"] ?? "") }
        guard let minimum = values.min(), let maximum = values.max() else {
            return "未知（旧版日志缺少等待耗时）"
        }
        let average = values.reduce(0, +) / Double(values.count)
        return "\(formatNumber(minimum))–\(formatNumber(maximum))ms，平均\(formatNumber(average))ms"
    }

    private static func formatNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func safeFailureMessage(for event: SessionLogEntry) -> String? {
        guard let code = event.failureCode else { return nil }
        return DiagnosticErrorFormatter.canonicalMessage(for: code)
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func formatOptional(_ date: Date?) -> String {
        guard let date else { return "未知" }
        return format(date)
    }
}

@MainActor
final class DiagnosticReportBuilder {
    private let permissionChecker: PrivacyPermissionChecking
    private let credentialStore: CredentialStore
    private let settingsStore: SettingsStore
    private let logger: SessionLogger
    private let suppliedAppInfo: DiagnosticAppInfo?

    init(
        permissionChecker: PrivacyPermissionChecking,
        credentialStore: CredentialStore,
        settingsStore: SettingsStore,
        logger: SessionLogger,
        appInfo: DiagnosticAppInfo? = nil
    ) {
        self.permissionChecker = permissionChecker
        self.credentialStore = credentialStore
        self.settingsStore = settingsStore
        self.logger = logger
        self.suppliedAppInfo = appInfo
    }

    func build() -> DiagnosticReport {
        let settings = settingsStore.load()
        let permissions = permissionChecker.report()
        let credentials = credentialInfo()
        return DiagnosticReport(
            app: suppliedAppInfo ?? AppRuntimeInspector.inspect(),
            permissions: permissions,
            credentials: credentials,
            settings: DiagnosticSettingsInfo(
                shortcut: ShortcutFormatter.string(for: settings.shortcut),
                engineModelType: settings.engineModelType,
                persistentSessionLogEnabled: settings.saveTextLogs,
                safeCopyEnabled: settings.safeCopyEnabled
            ),
            events: mergedEvents(),
            logDirectoryPath: logger.persistenceDirectoryURL.path
        )
    }

    private func credentialInfo() -> DiagnosticCredentialInfo {
        do {
            if try credentialStore.load() != nil {
                return DiagnosticCredentialInfo(state: .configured, detail: "已配置（具体内容已隐藏）")
            }
            return DiagnosticCredentialInfo(state: .missing, detail: "未配置")
        } catch {
            return DiagnosticCredentialInfo(
                state: .unreadable,
                detail: "读取失败（凭证文件不可读或格式无效）"
            )
        }
    }

    private func mergedEvents() -> [SessionLogEntry] {
        let candidates = logger.allPersistedEntries() + logger.recentEntries(limit: 300)
        var seen = Set<String>()
        let unique = candidates.filter { entry in
            let key: String
            if let eventID = entry.eventID {
                key = "event:\(eventID.uuidString)"
            } else {
                let timestampMilliseconds = Int64((entry.timestamp.timeIntervalSince1970 * 1_000).rounded())
                key = "legacy:\(entry.sessionID.uuidString)|\(timestampMilliseconds)|\(entry.event)|\(entry.sequence ?? -1)|\(entry.segmentID ?? -1)|\(entry.revision ?? 0)"
            }
            return seen.insert(key).inserted
        }
        return unique.sorted { $0.timestamp < $1.timestamp }
    }
}

enum AppRuntimeInspector {
    @MainActor
    static func inspect() -> DiagnosticAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let runningApplication = NSRunningApplication.current
        let bundleURL = Bundle.main.bundleURL
        let executableURL = Bundle.main.executableURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundleURL.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        return DiagnosticAppInfo(
            displayName: info["CFBundleDisplayName"] as? String ?? "未知",
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "未知",
            shortVersion: info["CFBundleShortVersionString"] as? String ?? "未知",
            build: info["CFBundleVersion"] as? String ?? "未知",
            bundlePath: bundleURL.path,
            executablePath: executableURL?.path ?? "未知",
            bundleModificationDate: modificationDate,
            processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier),
            processLaunchDate: runningApplication.launchDate,
            currentUser: NSUserName(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            machineArchitecture: machineArchitecture(),
            signatureVerified: SignatureInspector.verify(bundleURL: bundleURL),
            signatureDetails: SignatureInspector.details(bundleURL: bundleURL)
        )
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

private enum SignatureInspector {
    static func verify(bundleURL: URL) -> Bool {
        runCodesign(arguments: ["--verify", "--deep", "--strict", bundleURL.path]).status == 0
    }

    static func details(bundleURL: URL) -> String {
        let display = runCodesign(arguments: ["--display", "--verbose=4", bundleURL.path]).output
        let requirements = runCodesign(arguments: ["--display", "--requirements", "-", bundleURL.path]).output
        let allowedPrefixes = [
            "Identifier=",
            "Format=",
            "CodeDirectory",
            "TeamIdentifier=",
            "Authority=",
            "Signed Time=",
            "CDHash=",
            "designated =>"
        ]
        let lines = (display + "\n" + requirements)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in allowedPrefixes.contains { line.hasPrefix($0) } }
        return lines.isEmpty ? "未读取到签名详情" : lines.joined(separator: "; ")
    }

    private static func runCodesign(arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
