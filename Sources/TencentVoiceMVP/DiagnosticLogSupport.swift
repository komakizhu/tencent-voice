import Foundation

enum DiagnosticLogSanitizer {
    private static let sensitiveKeyFragments = [
        "text", "audio", "secret", "credential", "appid", "clipboard", "payload", "url", "raw", "message"
    ]

    static func fields(_ fields: [String: String]) -> [String: String] {
        fields.reduce(into: [String: String]()) { result, field in
            let normalizedKey = field.key.lowercased()
            if sensitiveKeyFragments.contains(where: { normalizedKey.contains($0) }) {
                result[field.key] = "已隐藏"
            } else {
                result[field.key] = String(field.value.prefix(200))
            }
        }
    }

    static func value(_ value: String, forKey key: String) -> String {
        fields([key: value])[key] ?? "已隐藏"
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
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
    }

    static func configureDateDecoding(for decoder: JSONDecoder) {
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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

    var errorDescription: String? {
        "诊断报告导出功能当前不可用"
    }
}
