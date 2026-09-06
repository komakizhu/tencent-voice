import CryptoKit
import Foundation

enum TencentSigner {
    static func hmacSHA1Base64(message: Data, key: Data) -> String {
        let symmetricKey = SymmetricKey(data: key)
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey)
        return Data(digest).base64EncodedString()
    }

    static func makeURL(
        configuration: TencentSessionConfiguration,
        timestamp: Int,
        expired: Int,
        nonce: Int
    ) throws -> URL {
        let hostPath = "asr.cloud.tencent.com/asr/v2/\(configuration.appID)"
        var pairs: [(String, String)] = [
            ("engine_model_type", configuration.engineModelType),
            ("expired", String(expired)),
            ("needvad", String(configuration.needVAD)),
            ("nonce", String(nonce)),
            ("secretid", configuration.secretID),
            ("timestamp", String(timestamp)),
            ("voice_format", String(configuration.voiceFormat)),
            ("voice_id", configuration.voiceID)
        ]
        if configuration.wordInfo > 0 {
            pairs.append(("word_info", String(configuration.wordInfo)))
        }
        pairs.sort { $0.0 < $1.0 }

        let canonicalQuery = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let source = "\(hostPath)?\(canonicalQuery)"
        let signature = hmacSHA1Base64(
            message: Data(source.utf8),
            key: Data(configuration.secretKey.utf8)
        )
        let finalQuery = pairs
            .map { "\($0.0)=\($0.1.percentEncodedForQuery)" }
            .joined(separator: "&")
            + "&signature=\(signature.percentEncodedForQuery)"

        guard let url = URL(string: "wss://\(hostPath)?\(finalQuery)") else {
            throw TencentASRError.invalidURL
        }
        return url
    }
}

private extension String {
    var percentEncodedForQuery: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
