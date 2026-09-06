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
    private let filePermissions: Int
    private let directoryPermissions: Int
    private let groupOwnerAccountName: String?

    init(
        fileURL: URL = LocalYAMLCredentialStore.defaultFileURL,
        filePermissions: Int = 0o600,
        directoryPermissions: Int = 0o700,
        groupOwnerAccountName: String? = nil
    ) {
        self.fileURL = fileURL
        self.filePermissions = filePermissions
        self.directoryPermissions = directoryPermissions
        self.groupOwnerAccountName = groupOwnerAccountName
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
        var directoryAttributes: [FileAttributeKey: Any] = [.posixPermissions: directoryPermissions]
        if let groupOwnerAccountName {
            directoryAttributes[.groupOwnerAccountName] = groupOwnerAccountName
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions]
        )
        try? FileManager.default.setAttributes(directoryAttributes, ofItemAtPath: directoryURL.path)
        let content = [
            filePermissions == 0o600
                ? "# 腾讯语音输入凭证（明文，仅当前 macOS 用户可读）"
                : "# 腾讯语音输入凭证（明文，供本机 macOS 账户共享）",
            "app_id: \(quote(credentials.appID))",
            "secret_id: \(quote(credentials.secretID))",
            "secret_key: \(quote(credentials.secretKey))",
            ""
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: filePermissions],
            ofItemAtPath: fileURL.path
        )
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

    static var sharedFileURL: URL {
        URL(fileURLWithPath: "/Users/Shared/TencentVoiceMVP", isDirectory: true)
            .appendingPathComponent("tencent-credentials.yaml")
    }

    static var shared: LocalYAMLCredentialStore {
        LocalYAMLCredentialStore(
            fileURL: sharedFileURL,
            filePermissions: 0o660,
            directoryPermissions: 0o2770,
            groupOwnerAccountName: "staff"
        )
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
    private let perUserFallback: CredentialStore?
    private let legacy: CredentialStore

    init(
        primary: LocalYAMLCredentialStore = .shared,
        legacy: CredentialStore = KeychainCredentialStore(),
        perUserFallback: CredentialStore? = nil
    ) {
        self.primary = primary
        self.perUserFallback = perUserFallback
        self.legacy = legacy
    }

    func load() throws -> TencentCredentials? {
        if let credentials = try primary.load() { return credentials }
        guard let perUserFallback, let credentials = try perUserFallback.load() else {
            return nil
        }
        try primary.save(credentials)
        return credentials
    }

    func migrateLegacyIfNeeded() throws -> TencentCredentials? {
        if let credentials = try load() { return credentials }
        guard let credentials = try legacy.load() else { return nil }
        try primary.save(credentials)
        return credentials
    }

    func save(_ credentials: TencentCredentials) throws {
        try primary.save(credentials)
    }

    func delete() throws {
        try primary.delete()
        try perUserFallback?.delete()
        try legacy.delete()
    }
}
