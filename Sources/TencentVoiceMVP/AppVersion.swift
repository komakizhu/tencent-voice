import Foundation

enum AppVersion {
    static var displayText: String {
        displayText(for: Bundle.main.infoDictionary ?? [:])
    }

    static func displayText(for info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "未知"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else {
            return "当前版本：\(version)"
        }
        return "当前版本：\(version)（build \(build)）"
    }
}
