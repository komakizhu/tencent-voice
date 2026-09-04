import Foundation

enum LocalYAMLCredentialStoreError: Error, LocalizedError {
    case invalidFormat
    case unsupportedValue

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "本地凭证 YAML 格式无效"
        case .unsupportedValue: return "凭证不能包含换行符"
        }
    }
}

final class LocalYAMLCredentialStore: CredentialStore {
    let fileURL: URL

    init(fileURL: URL = LocalYAMLCredentialStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> TencentCredentials? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let values = try parse(content)
        guard let appID = values["app_id"],
              let secretID = values["secret_id"],
              let secretKey = values["secret_key"],
              !appID.isEmpty, !secretID.isEmpty, !secretKey.isEmpty else {
            throw LocalYAMLCredentialStoreError.invalidFormat
        }
        return TencentCredentials(appID: appID, secretID: secretID, secretKey: secretKey)
    }

    func save(_ credentials: TencentCredentials) throws {
        let values = [credentials.appID, credentials.secretID, credentials.secretKey]
        guard values.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw LocalYAMLCredentialStoreError.unsupportedValue
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let content = [
            "# 腾讯语音输入凭证（明文，仅当前 macOS 用户可读）",
            "app_id: \(quote(credentials.appID))",
            "secret_id: \(quote(credentials.secretID))",
            "secret_key: \(quote(credentials.secretKey))",
            ""
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("TencentVoiceMVP", isDirectory: true)
            .appendingPathComponent("tencent-credentials.yaml")
    }

    private func parse(_ content: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: ":") else {
                throw LocalYAMLCredentialStoreError.invalidFormat
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard ["app_id", "secret_id", "secret_key"].contains(key) else { continue }
            values[key] = try unquote(rawValue)
        }
        return values
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func unquote(_ value: String) throws -> String {
        guard value.count >= 2, value.first == "'", value.last == "'" else {
            throw LocalYAMLCredentialStoreError.invalidFormat
        }
        let inner = value.dropFirst().dropLast()
        return inner.replacingOccurrences(of: "''", with: "'")
    }
}

final class PersistentCredentialStore: CredentialStore {
    private let primary: LocalYAMLCredentialStore
    private let legacy: CredentialStore

    init(
        primary: LocalYAMLCredentialStore = LocalYAMLCredentialStore(),
        legacy: CredentialStore = KeychainCredentialStore()
    ) {
        self.primary = primary
        self.legacy = legacy
    }

    func load() throws -> TencentCredentials? {
        try primary.load()
    }

    func migrateLegacyIfNeeded() throws -> TencentCredentials? {
        if let credentials = try primary.load() { return credentials }
        guard let credentials = try legacy.load() else { return nil }
        try primary.save(credentials)
        return credentials
    }

    func save(_ credentials: TencentCredentials) throws {
        try primary.save(credentials)
    }

    func delete() throws {
        try primary.delete()
        try legacy.delete()
    }
}
