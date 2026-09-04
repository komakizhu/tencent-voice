import Foundation
import Security

enum CredentialStoreError: Error, LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .status(status): return "Keychain 操作失败（\(status)）"
        }
    }
}

final class KeychainCredentialStore: CredentialStore {
    private let service: String

    init(service: String = "local.tencent.voice.mvp.credentials") {
        self.service = service
    }

    func load() throws -> TencentCredentials? {
        let appID = try read(account: "appID")
        let secretID = try read(account: "secretID")
        let secretKey = try read(account: "secretKey")
        guard let appID, let secretID, let secretKey else { return nil }
        return TencentCredentials(appID: appID, secretID: secretID, secretKey: secretKey)
    }

    func save(_ credentials: TencentCredentials) throws {
        try write(credentials.appID, account: "appID")
        try write(credentials.secretID, account: "secretID")
        try write(credentials.secretKey, account: "secretKey")
    }

    func delete() throws {
        for account in ["appID", "secretID", "secretKey"] {
            let status = SecItemDelete(query(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.status(status)
            }
        }
    }

    private func read(account: String) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query(account: account, returnsData: true) as CFDictionary,
            &item
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.status(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.status(errSecDecode)
        }
        return value
    }

    private func write(_ value: String, account: String) throws {
        let updateStatus = SecItemUpdate(
            query(account: account) as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query(account: account)
            addQuery[kSecValueData as String] = Data(value.utf8)
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.status(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.status(updateStatus)
        }
    }

    private func query(account: String, returnsData: Bool = false) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if returnsData {
            result[kSecReturnData as String] = true
            result[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return result
    }
}
