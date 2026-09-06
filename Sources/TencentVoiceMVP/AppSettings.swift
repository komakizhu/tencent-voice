import Foundation

enum TencentEnginePreset: String, CaseIterable, Sendable {
    case standard = "16k_zh"
    case largeV1 = "16k_zh_en"
    case largeV2 = "16k_zh_en_2.0"

    static let defaultPreset: Self = .standard

    var displayName: String {
        switch self {
        case .standard:
            return "普通话通用（16k_zh）"
        case .largeV1:
            return "中英大模型 1.0（16k_zh_en）"
        case .largeV2:
            return "中英大模型 2.0（16k_zh_en_2.0）"
        }
    }

    init(persistedModelType: String) {
        self = Self(rawValue: persistedModelType) ?? Self.defaultPreset
    }
}

protocol SettingsStore: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

struct AppSettings: Codable, Equatable, Sendable {
    var shortcut: Shortcut
    var engineModelType: String
    var saveTextLogs: Bool
    var safeCopyEnabled: Bool
    var prepaidQuotaHoursByModel: [String: Int]

    private enum CodingKeys: String, CodingKey {
        case shortcut
        case engineModelType
        case saveTextLogs
        case safeCopyEnabled
        case prepaidQuotaHoursByModel
    }

    init(
        shortcut: Shortcut = .defaultCommand0,
        engineModelType: String = TencentEnginePreset.defaultPreset.rawValue,
        saveTextLogs: Bool = false,
        safeCopyEnabled: Bool = false,
        prepaidQuotaHoursByModel: [String: Int] = [:]
    ) {
        self.shortcut = shortcut
        self.engineModelType = engineModelType
        self.saveTextLogs = saveTextLogs
        self.safeCopyEnabled = safeCopyEnabled
        self.prepaidQuotaHoursByModel = prepaidQuotaHoursByModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decode(Shortcut.self, forKey: .shortcut)
        engineModelType = try container.decode(String.self, forKey: .engineModelType)
        saveTextLogs = try container.decode(Bool.self, forKey: .saveTextLogs)
        safeCopyEnabled = try container.decodeIfPresent(Bool.self, forKey: .safeCopyEnabled) ?? false
        prepaidQuotaHoursByModel = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .prepaidQuotaHoursByModel
        ) ?? [:]
    }
}

final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key = "appSettings"
    private let shortcutMigrationKey = "didMigrateDefaultShortcutToCommand0"

    init(suiteName: String = "local.tencent.voice.mvp") {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }

        guard !defaults.bool(forKey: shortcutMigrationKey) else {
            return settings
        }

        // Mark every existing configuration as migration-checked. This keeps
        // custom shortcuts intact and prevents a user-selected F5 from being
        // migrated again on later launches.
        defaults.set(true, forKey: shortcutMigrationKey)
        guard settings.shortcut == .defaultF5 else {
            return settings
        }

        var migratedSettings = settings
        migratedSettings.shortcut = .defaultCommand0
        saveEncoded(migratedSettings)
        return migratedSettings
    }

    func save(_ settings: AppSettings) {
        defaults.set(true, forKey: shortcutMigrationKey)
        saveEncoded(settings)
    }

    private func saveEncoded(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
