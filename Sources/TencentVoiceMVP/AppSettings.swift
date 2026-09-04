import Foundation

protocol SettingsStore: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

struct AppSettings: Codable, Equatable, Sendable {
    var shortcut: Shortcut
    var engineModelType: String
    var saveTextLogs: Bool

    init(
        shortcut: Shortcut = .defaultF5,
        engineModelType: String = "16k_zh",
        saveTextLogs: Bool = false
    ) {
        self.shortcut = shortcut
        self.engineModelType = engineModelType
        self.saveTextLogs = saveTextLogs
    }
}

final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key = "appSettings"

    init(suiteName: String = "local.tencent.voice.mvp") {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
