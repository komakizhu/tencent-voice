import Foundation
import RimeSyncCore

enum RimeBackupSettings {
    static let retentionLimitKey = "rime.backup.retention.limit"

    static func loadPolicy(from defaults: UserDefaults = .standard) -> RimeBackupRetentionPolicy {
        let rawValue: Int?
        if let value = defaults.object(forKey: retentionLimitKey) as? Int {
            rawValue = value
        } else if let value = defaults.string(forKey: retentionLimitKey) {
            rawValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            rawValue = nil
        }
        guard let rawValue, let policy = try? RimeBackupRetentionPolicy(limit: rawValue) else {
            return .defaultValue
        }
        return policy
    }

    static func save(_ policy: RimeBackupRetentionPolicy, to defaults: UserDefaults = .standard) {
        defaults.set(policy.limit, forKey: retentionLimitKey)
    }
}
