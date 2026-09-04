import ApplicationServices
import Foundation

struct TextRange: Equatable, Sendable {
    var location: Int
    var length: Int
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
    func paste(_ text: String) throws
    func replaceTrailingText(_ previousText: String, with text: String) throws
    func copyToClipboard(_ text: String) throws
}

extension TextTarget {
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
        case .accessibilityDenied: return "请在系统设置的“隐私与安全性 → 辅助功能”中允许腾讯语音输入 MVP"
        case .postEventDenied: return "系统禁止腾讯语音输入 MVP 发送键盘事件，请在辅助功能中重新允许后重启应用"
        }
    }
}
