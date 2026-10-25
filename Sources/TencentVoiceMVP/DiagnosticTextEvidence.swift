import Foundation

enum DiagnosticTextEvidenceKind: String, Codable, Equatable, Sendable {
    case rawRecognition
    case processedRecognition
    case sentText
    case plannedText
    case expectedProjection
    case expectedDocument
    case axValue
    case axStringForRange
    case safeCopyPrepared
    case safeCopySucceeded

    var reportTitle: String {
        switch self {
        case .rawRecognition: return "原始识别"
        case .processedRecognition: return "处理后识别"
        case .sentText: return "发送文字"
        case .plannedText: return "计划发送文字（不代表已发送）"
        case .expectedProjection: return "预期语音片段（非完整文档）"
        case .expectedDocument: return "预期正文"
        case .axValue: return "AXValue"
        case .axStringForRange: return "AXStringForRange"
        case .safeCopyPrepared: return "Safe Copy准备内容"
        case .safeCopySucceeded: return "Safe Copy成功内容"
        }
    }
}

enum DiagnosticEvidenceSource: String, Codable, Equatable, Sendable {
    case observed
    case expected
    case inferred
    case unknown

    var reportTitle: String {
        switch self {
        case .observed: return "观测"
        case .expected: return "预期"
        case .inferred: return "推断"
        case .unknown: return "未知"
        }
    }
}

struct DiagnosticTextEvidence: Codable, Equatable, Sendable {
    let kind: DiagnosticTextEvidenceKind
    let source: DiagnosticEvidenceSource
    let text: String
    let revision: UInt64?
    let operationID: String?
    let targetApplicationBundleIdentifier: String?
    let targetApplicationProcessID: Int32?
    let editorIdentity: String?
    let selectionLocationUTF16: Int?
    let selectionLengthUTF16: Int?
    let requestedAt: Date?
    let readStartedAt: Date?
    let readFinishedAt: Date?
    let observedAt: Date?
    let monotonicMilliseconds: UInt64?
    let contextStatus: [String: String]?

    init(
        kind: DiagnosticTextEvidenceKind,
        source: DiagnosticEvidenceSource,
        text: String,
        revision: UInt64? = nil,
        operationID: String? = nil,
        targetApplicationBundleIdentifier: String? = nil,
        targetApplicationProcessID: Int32? = nil,
        editorIdentity: String? = nil,
        selectionLocationUTF16: Int? = nil,
        selectionLengthUTF16: Int? = nil,
        requestedAt: Date? = nil,
        readStartedAt: Date? = nil,
        readFinishedAt: Date? = nil,
        observedAt: Date? = nil,
        monotonicMilliseconds: UInt64? = nil
    ) {
        self.kind = kind
        self.source = source
        self.text = text
        self.revision = revision
        self.operationID = operationID
        self.targetApplicationBundleIdentifier = targetApplicationBundleIdentifier
        self.targetApplicationProcessID = targetApplicationProcessID
        self.editorIdentity = editorIdentity
        self.selectionLocationUTF16 = selectionLocationUTF16
        self.selectionLengthUTF16 = selectionLengthUTF16
        self.requestedAt = requestedAt
        self.readStartedAt = readStartedAt
        self.readFinishedAt = readFinishedAt
        self.observedAt = observedAt
        self.monotonicMilliseconds = monotonicMilliseconds
        let recognition = kind == .rawRecognition || kind == .processedRecognition
        let clipboard = kind == .safeCopyPrepared || kind == .safeCopySucceeded
        self.contextStatus = [
            "operationID": operationID == nil
                ? (recognition ? "not_applicable_recognition_precedes_dispatch" : (clipboard ? "not_applicable_clipboard_not_editor_write" : "not_captured")) : "recorded",
            "editorIdentity": editorIdentity == nil ? "not_captured" : "captured_handle_not_stable_editor_identity",
            "selection": selectionLocationUTF16 == nil ? (clipboard ? "not_applicable_clipboard" : "not_captured") : "recorded_see_event_read_or_dispatch_context",
            "readTiming": readStartedAt == nil ? "not_applicable_or_not_captured_no_AX_read_claimed" : "recorded",
            "targetPID": targetApplicationProcessID == nil ? "unavailable" : "captured_target_process",
            "sessionID": "in_parent_session_log_entry",
            "screenRendering": "unknown_AX_does_not_prove_rendering"
        ]
    }
}
