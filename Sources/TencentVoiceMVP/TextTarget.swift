import ApplicationServices
import Foundation

struct TextRange: Equatable, Sendable {
    var location: Int
    var length: Int
}

struct PastedTextDelta: Equatable, Sendable {
    let backspaceCount: Int
    let insertion: String

    init(previousText: String, newText: String) {
        let previousCharacters = Array(previousText)
        let newCharacters = Array(newText)
        let commonPrefixLength = zip(previousCharacters, newCharacters)
            .prefix { $0 == $1 }
            .count

        backspaceCount = previousCharacters.count - commonPrefixLength
        insertion = String(newCharacters.dropFirst(commonPrefixLength))
    }
}

struct TextReplacementDelta: Equatable, Sendable {
    let prefixUTF16Length: Int
    let previousMiddleUTF16Length: Int
    let insertion: String

    init(previousText: String, newText: String) {
        let previousCharacters = Array(previousText)
        let newCharacters = Array(newText)
        let prefixLength = zip(previousCharacters, newCharacters)
            .prefix { $0 == $1 }
            .count
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

        prefixUTF16Length = String(previousCharacters[..<prefixLength]).utf16.count
        previousMiddleUTF16Length = String(previousMiddle).utf16.count
        insertion = String(newMiddle)
    }
}

struct TextSnapshot {
    let element: AXUIElement?
    let text: String
    let selection: TextRange
    let supportsAXReplacement: Bool

    init(
        element: AXUIElement? = nil,
        text: String,
        selection: TextRange,
        supportsAXReplacement: Bool = true
    ) {
        self.element = element
        self.text = text
        self.selection = selection
        self.supportsAXReplacement = supportsAXReplacement
    }
}

@MainActor
protocol TextTarget: AnyObject {
    func capture() throws -> TextSnapshot
    func replace(snapshot: TextSnapshot, range: TextRange, expectedText: String, with text: String) throws -> TextRange
    func replacePastedText(previousText: String, with text: String) throws
    func paste(_ text: String) throws
    func copyToClipboard(_ text: String) throws
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
        case .accessibilityDenied: return "请在系统设置的“隐私与安全性 → 辅助功能”中允许腾讯语音输入 MVP"
        case .postEventDenied: return "系统禁止腾讯语音输入 MVP 发送键盘事件，请在辅助功能中重新允许后重启应用"
        }
    }
}
