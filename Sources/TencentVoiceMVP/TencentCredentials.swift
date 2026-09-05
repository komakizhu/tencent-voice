import Foundation
import CryptoKit

public struct TencentCredentials: Equatable, Sendable {
    public let appID: String
    public let secretID: String
    public let secretKey: String

    public init(appID: String, secretID: String, secretKey: String) {
        self.appID = appID
        self.secretID = secretID
        self.secretKey = secretKey
    }
}

struct TencentCredentialIdentity: Hashable, Sendable {
    let fingerprint: String

    init(credentials: TencentCredentials) {
        let material = [credentials.appID, credentials.secretID, credentials.secretKey]
            .joined(separator: "\u{1f}")
        fingerprint = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct TencentSessionConfiguration: Equatable, Sendable {
    public let appID: String
    public let secretID: String
    public let secretKey: String
    public let engineModelType: String
    public let voiceID: String
    public let voiceFormat: Int
    public let needVAD: Int
    public let wordInfo: Int

    public init(
        appID: String,
        secretID: String,
        secretKey: String,
        engineModelType: String = "16k_zh",
        voiceID: String = UUID().uuidString,
        voiceFormat: Int = 1,
        needVAD: Int = 0,
        wordInfo: Int = 0
    ) {
        self.appID = appID
        self.secretID = secretID
        self.secretKey = secretKey
        self.engineModelType = engineModelType
        self.voiceID = voiceID
        self.voiceFormat = voiceFormat
        self.needVAD = needVAD
        self.wordInfo = wordInfo
    }
}

protocol CredentialStore: AnyObject {
    func load() throws -> TencentCredentials?
    func save(_ credentials: TencentCredentials) throws
    func delete() throws
}

enum TencentASRError: Error, LocalizedError {
    case invalidURL
    case server(code: Int, message: String)
    case handshakeTimeout
    case notStarted
    case alreadyFinished

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "腾讯 ASR 地址无效"
        case let .server(code, message): return "腾讯 ASR 错误（\(code)）：\(message)"
        case .handshakeTimeout: return "腾讯 ASR 握手超时，请检查网络或服务是否可用"
        case .notStarted: return "语音连接尚未建立"
        case .alreadyFinished: return "语音连接已经结束"
        }
    }
}
