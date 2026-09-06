import Foundation

enum DiagnosticErrorFormatter {
    static func code(for error: Error) -> String {
        if let error = error as? SessionError {
            return error.diagnosticCode
        }
        if let error = error as? TextTargetError {
            return error.diagnosticCode
        }
        if let error = error as? AudioCaptureError {
            return error.diagnosticCode
        }
        if let error = error as? TencentASRError {
            return error.diagnosticCode
        }
        if let error = error as? HotkeyError {
            return error.diagnosticCode
        }
        return String(describing: type(of: error))
    }

    static func message(for error: Error) -> String {
        if let message = canonicalMessage(for: code(for: error)) {
            return message
        }
        return "错误类型：\(String(describing: type(of: error)))"
    }

    static func canonicalMessage(for code: String) -> String? {
        switch code {
        case "text_target_unsupported",
             "text_target_changed":
            return code == "text_target_changed"
                ? "输入目标在识别过程中发生了变化"
                : "当前输入框不支持实时改写"
        case "text_target_write_failed":
            return "无法写入当前输入框"
        case "safe_copy_manual":
            return "用户手动启用了 Safe Copy"
        case "accessibility_denied":
            return "辅助功能权限不可用"
        case "post_event_denied":
            return "发送键盘事件权限不可用"
        case "credentials_missing":
            return "当前用户没有读取到腾讯凭证"
        case "microphone_denied":
            return "麦克风权限未开启"
        case "text_target_missing":
            return "没有找到可输入的文本目标"
        case "session_busy":
            return "已有语音会话正在运行"
        case "session_cancelled":
            return "语音会话已取消"
        case "microphone_input_unavailable":
            return "没有可用的麦克风输入"
        case "microphone_converter_unavailable":
            return "无法把麦克风转换为 16 kHz PCM"
        case "microphone_engine_start_failed":
            return "麦克风启动失败（系统错误详情已隐藏）"
        case "tencent_asr_invalid_url":
            return "腾讯 ASR 地址无效"
        case "tencent_asr_handshake_timeout":
            return "腾讯 ASR 握手超时，请检查网络或服务是否可用"
        case "tencent_asr_not_started":
            return "腾讯 ASR 连接尚未建立"
        case "tencent_asr_already_finished":
            return "腾讯 ASR 连接已经结束"
        case "hotkey_invalid_shortcut":
            return "快捷键配置无效"
        default:
            if code.hasPrefix("hotkey_unavailable_") {
                return "快捷键不可用，系统状态码已记录"
            }
            let prefix = "tencent_asr_server_"
            guard code.hasPrefix(prefix) else { return nil }
            let status = code.dropFirst(prefix.count)
            guard !status.isEmpty, status.allSatisfy(\.isNumber) else {
                return "腾讯 ASR 服务端返回错误，详情已隐藏"
            }
            return "腾讯 ASR 返回错误（\(status)），服务端详情已隐藏"
        }
    }
}
