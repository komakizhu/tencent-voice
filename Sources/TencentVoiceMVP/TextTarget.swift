import ApplicationServices
import Foundation

struct TextRange: Equatable, Sendable {
    var location: Int
    var length: Int
}

struct TextTargetApplication: Codable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: Int32
}

enum AXTextAncestorScanStatus: String, Equatable, Sendable {
    case webArea
    case completeWithoutWebArea
    case truncated
    case cycle
    case readFailure
}

struct AXTextAncestorScanResult: Equatable, Sendable {
    let status: AXTextAncestorScanStatus
    let webAreaDepth: Int?
}

/// Shared, bounded ancestor walk used by production AX discovery and replay tests.
/// The walk includes the focused text element as depth zero and never guesses when
/// the tree cannot be classified within the budget.
struct AXTextAncestorScanner {
    static func scan<Node>(
        start: Node,
        nodeLimit: Int = 64,
        deadlineReached: () -> Bool = { false },
        role: (Node) -> String?,
        parent: (Node) -> Node?,
        equals: (Node, Node) -> Bool,
        onWebArea: ((Node, Int) -> Void)? = nil
    ) -> AXTextAncestorScanResult {
        guard nodeLimit > 0 else {
            return AXTextAncestorScanResult(status: .truncated, webAreaDepth: nil)
        }

        var node = start
        var visited: [Node] = []
        for depth in 0..<nodeLimit {
            if deadlineReached() {
                return AXTextAncestorScanResult(status: .truncated, webAreaDepth: nil)
            }
            if visited.contains(where: { equals($0, node) }) {
                return AXTextAncestorScanResult(status: .cycle, webAreaDepth: nil)
            }
            visited.append(node)

            guard let nodeRole = role(node) else {
                return AXTextAncestorScanResult(status: .readFailure, webAreaDepth: nil)
            }
            if deadlineReached() {
                return AXTextAncestorScanResult(status: .truncated, webAreaDepth: nil)
            }
            if nodeRole == "AXWebArea" {
                onWebArea?(node, depth)
                return AXTextAncestorScanResult(status: .webArea, webAreaDepth: depth)
            }

            if deadlineReached() {
                return AXTextAncestorScanResult(status: .truncated, webAreaDepth: nil)
            }
            guard let next = parent(node) else {
                return AXTextAncestorScanResult(status: .completeWithoutWebArea, webAreaDepth: nil)
            }
            if deadlineReached() {
                return AXTextAncestorScanResult(status: .truncated, webAreaDepth: nil)
            }
            node = next
        }
        return AXTextAncestorScanResult(status: .truncated, webAreaDepth: nil)
    }
}

struct AXTextInputTargetContext: Equatable {
    let role: String?
    let hasWebAreaAncestor: Bool
    let webURL: URL?
    /// `nil` means the accessibility attribute could not be classified safely.
    let isReadOnly: Bool?
    let isSecure: Bool?
    let ancestorScanStatus: AXTextAncestorScanStatus
    let webAreaDepth: Int?

    init(
        role: String?,
        hasWebAreaAncestor: Bool,
        webURL: URL?,
        isReadOnly: Bool?,
        isSecure: Bool?,
        ancestorScanStatus: AXTextAncestorScanStatus? = nil,
        webAreaDepth: Int? = nil
    ) {
        self.role = role
        self.hasWebAreaAncestor = hasWebAreaAncestor
        self.webURL = webURL
        self.isReadOnly = isReadOnly
        self.isSecure = isSecure
        self.ancestorScanStatus = ancestorScanStatus
            ?? (hasWebAreaAncestor ? .webArea : .completeWithoutWebArea)
        self.webAreaDepth = webAreaDepth
    }
}

enum AXTextInputStrategy: Equatable {
    case accessibility
    case acknowledgedKeyboard(reason: String)
    case safeStop(reason: String)

    static func select(
        application: TextTargetApplication?,
        context: AXTextInputTargetContext?,
        hasReadableTextState: Bool = true
    ) -> AXTextInputStrategy {
        guard let context,
              context.role == "AXTextArea" || context.role == "AXTextField" else {
            return .accessibility
        }

        // Never bypass an explicit read-only or secure signal, including for
        // legacy application-specific routes.
        guard context.isReadOnly != true, context.isSecure != true else {
            return .safeStop(reason: "web_control_not_editable")
        }

        // Codex and Obsidian have existing application-specific handling
        // below this strategy layer.
        let usesSpecializedLegacyRoute = application?.bundleIdentifier == "com.openai.codex"
            || application?.bundleIdentifier == "md.obsidian"
        if usesSpecializedLegacyRoute {
            return .accessibility
        }

        if application?.bundleIdentifier == "com.apple.Safari" {
            switch context.ancestorScanStatus {
            case .webArea:
                break
            case .completeWithoutWebArea:
                return .accessibility
            case .truncated, .cycle, .readFailure:
                return .safeStop(reason: "web_ancestor_unclassified")
            }
        }

        switch context.ancestorScanStatus {
        case .truncated, .cycle, .readFailure:
            return .safeStop(reason: "web_ancestor_unclassified")
        case .webArea:
            break
        case .completeWithoutWebArea:
            return .accessibility
        }
        guard context.hasWebAreaAncestor else { return .accessibility }

        // A generic confirmed web control with an unreadable
        // editability/security attribute is not safe to treat as a normal
        // text target. Stop before either AX replacement or keyboard input;
        // do not guess false.
        guard context.isReadOnly != nil, context.isSecure != nil else {
            return .safeStop(reason: "web_editability_unknown")
        }
        guard hasReadableTextState else {
            return .safeStop(reason: "web_text_state_unreadable")
        }
        return .acknowledgedKeyboard(reason: "web_editable_text_control")
    }

    var diagnosticName: String {
        switch self {
        case .accessibility:
            return "accessibility"
        case .acknowledgedKeyboard:
            return "acknowledged_keyboard"
        case .safeStop:
            return "safe_stop"
        }
    }

    var diagnosticReason: String {
        switch self {
        case .accessibility:
            return "default"
        case let .acknowledgedKeyboard(reason):
            return reason
        case let .safeStop(reason):
            return reason
        }
    }

    var prefersAcknowledgedKeyboard: Bool {
        if case .acknowledgedKeyboard = self { return true }
        return false
    }

    var requiresSafeStop: Bool {
        if case .safeStop = self { return true }
        return false
    }

    var suppressesAXReplacement: Bool {
        if case .acknowledgedKeyboard = self {
            return true
        }
        return false
    }
}

struct TextReplacementDelta: Equatable, Sendable {
    let prefixUTF16Length: Int
    let previousMiddleUTF16Length: Int
    let insertion: String

    init(previousText: String, newText: String) {
        let previousCharacters = Array(previousText)
        let newCharacters = Array(newText)
        let prefix = sharedTextPrefix(previousText, newText)
        let prefixLength = prefix.count
        let remainingPrevious = previousCharacters.count - prefixLength
        let remainingNew = newCharacters.count - prefixLength
        let suffixLength = zip(
            previousCharacters.dropFirst(prefixLength).reversed(),
            newCharacters.dropFirst(prefixLength).reversed()
        )
        .prefix { $0 == $1 }
        .count
        let previousMiddle = previousCharacters[prefixLength..<(prefixLength + remainingPrevious - suffixLength)]
        let newMiddle = newCharacters[prefixLength..<(prefixLength + remainingNew - suffixLength)]

        prefixUTF16Length = prefix.utf16.count
        previousMiddleUTF16Length = String(previousMiddle).utf16.count
        insertion = String(newMiddle)
    }
}

func sharedTextPrefix(_ lhs: String, _ rhs: String) -> String {
    var prefix = ""
    for (lhsCharacter, rhsCharacter) in zip(lhs, rhs) {
        guard lhsCharacter == rhsCharacter else { break }
        prefix.append(lhsCharacter)
    }
    return prefix
}

struct TextSnapshot {
    let element: AXUIElement?
    let text: String
    let rawText: String
    let coordinateText: String
    let selection: TextRange
    let supportsAXReplacement: Bool
    let targetApplication: TextTargetApplication?
    let placeholderNormalized: Bool
    let coordinateMapping: AXTextCoordinateMapping?
    let preferredInputStrategy: AXTextInputStrategy

    init(
        element: AXUIElement? = nil,
        text: String,
        selection: TextRange,
        supportsAXReplacement: Bool = true,
        targetApplication: TextTargetApplication? = nil,
        rawText: String? = nil,
        coordinateText: String? = nil,
        placeholderNormalized: Bool = false,
        coordinateMapping: AXTextCoordinateMapping? = nil,
        preferredInputStrategy: AXTextInputStrategy = .accessibility
    ) {
        self.element = element
        self.text = text
        self.rawText = rawText ?? text
        self.coordinateText = coordinateText ?? text
        self.selection = selection
        self.supportsAXReplacement = supportsAXReplacement
        self.targetApplication = targetApplication
        self.placeholderNormalized = placeholderNormalized
        self.coordinateMapping = coordinateMapping
        self.preferredInputStrategy = preferredInputStrategy
    }
}

struct AXTextWriteReceipt: Equatable, Sendable {
    let text: String
    let selection: TextRange
    let writtenRange: TextRange
}

@MainActor
protocol TextTarget: AnyObject {
    func drainDiagnostics() -> [TextInputDiagnostic]
    func setDiagnosticOperation(_ context: TextInputDiagnosticContext?)
    func currentApplication() -> TextTargetApplication?
    func capture() throws -> TextSnapshot
    func replace(snapshot: TextSnapshot, range: TextRange, expectedText: String, with text: String) throws -> TextRange
    func paste(_ text: String) throws
    func replaceTrailingText(_ previousText: String, with text: String) throws
    func copyToClipboard(_ text: String) throws
}

// AX writes are submitted synchronously by the accessibility API, but the
// target is not considered updated until a later read confirms the complete
// document and selection. Only AXTextTarget adopts this internal seam; test
// and legacy targets keep the synchronous TextTarget replacement fallback.
@MainActor
protocol AXAcknowledgingTarget: TextTarget {
    func writeAXText(
        snapshot: TextSnapshot,
        range: TextRange,
        expectedText: String,
        with text: String
    ) async throws -> AXTextWriteReceipt
    func cancelAXWrite()
}

extension TextTarget {
    func drainDiagnostics() -> [TextInputDiagnostic] { [] }
    func setDiagnosticOperation(_ context: TextInputDiagnosticContext?) {}
    func currentApplication() -> TextTargetApplication? { nil }

    func replaceTrailingText(_ previousText: String, with text: String) throws {
        throw TextTargetError.unsupported
    }
}

enum TextTargetError: Error, LocalizedError {
    case unsupported
    case targetChanged
    case writeFailed
    case accessibilityDenied
    case postEventDenied

    var errorDescription: String? {
        switch self {
        case .unsupported: return "当前输入框不支持实时改写"
        case .targetChanged: return "输入目标在识别过程中发生了变化"
        case .writeFailed: return "无法写入当前输入框"
        case .accessibilityDenied: return "请在系统设置的“隐私与安全性 → 辅助功能”中允许 Rime Voice"
        case .postEventDenied: return "系统禁止 Rime Voice 发送键盘事件，请在辅助功能中重新允许后重启应用"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .unsupported: return "text_target_unsupported"
        case .targetChanged: return "text_target_changed"
        case .writeFailed: return "text_target_write_failed"
        case .accessibilityDenied: return "accessibility_denied"
        case .postEventDenied: return "post_event_denied"
        }
    }
}

extension SessionError {
    var diagnosticCode: String {
        switch self {
        case .credentialsMissing: return "credentials_missing"
        case .microphoneDenied: return "microphone_denied"
        case .noTextTarget: return "text_target_missing"
        case .busy: return "session_busy"
        case .cancelled: return "session_cancelled"
        case .recognitionEnded: return "asr_stream_ended_unexpectedly"
        }
    }
}
