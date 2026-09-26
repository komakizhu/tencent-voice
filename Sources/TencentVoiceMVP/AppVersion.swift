import Foundation

enum AppVersion {
    static var displayText: String {
        displayText(for: Bundle.main.infoDictionary ?? [:])
    }

    static func displayText(for info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "未知"
        return "当前版本：\(version)"
    }
}
