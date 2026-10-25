import Foundation

enum DiagnosticLogSanitizer {
    private static let sensitiveKeys: Set<String> = [
        "payload", "audio",
        "appid", "secretid", "secretkey", "credential", "credentials", "authorization",
        "url", "accesstoken", "refreshtoken"
    ]

    static func fields(_ fields: [String: String]) -> [String: String] {
        fields.reduce(into: [String: String]()) { result, field in
            let normalizedKey = field.key.lowercased().filter { $0.isLetter || $0.isNumber }
            if sensitiveKeys.contains(normalizedKey) {
                result[field.key] = "已隐藏"
            } else {
                result[field.key] = field.value
            }
        }
    }

    static func value(_ value: String, forKey key: String) -> String {
        fields([key: value])[key] ?? "已隐藏"
    }

    static func failureMessage(_ value: String) -> String {
        let credentialNames = ["AppID", "SecretId", "SecretKey", "Authorization", "access_token", "refresh_token"]
        return credentialNames.reduce(value) { result, name in
            guard let expression = try? NSRegularExpression(
                pattern: #"(?i)(["']?\b\#(NSRegularExpression.escapedPattern(for: name))\b["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|(?:Bearer|Basic)\s+[^\s,;]+|[^\s,;]+)"#
            ) else { return result }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return expression.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[已移除凭据]")
        }
    }
}

enum DiagnosticJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        configureDateEncoding(for: encoder)
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        configureDateDecoding(for: decoder)
        return decoder
    }

    static func configureDateEncoding(for encoder: JSONEncoder) {
        // An encoder is created per report task and used by one thread. Reuse its
        // formatter for every timestamp instead of constructing one per event.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
    }

    static func configureDateDecoding(for decoder: JSONDecoder) {
        // Decoders are likewise task-local; historical JSONL scans no longer
        // allocate an ISO formatter for each decoded event.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 timestamp"
                )
            }
            return date
        }
    }
}

enum DiagnosticLogExportError: Error, LocalizedError, Equatable {
    case unavailable
    case reportAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .unavailable: return "诊断报告导出功能当前不可用"
        case .reportAlreadyInProgress: return "已有诊断报告正在处理中，请完成后再试"
        }
    }
}
