import Foundation

struct TencentUsageSummary: Equatable, Sendable {
    let localUsedSeconds: Int
    let quotaSeconds: Int?

    var usedSeconds: Int {
        localUsedSeconds
    }

    var percentage: Int? {
        guard let quotaSeconds, quotaSeconds > 0 else { return nil }
        return min(100, Int((Double(usedSeconds) / Double(quotaSeconds) * 100).rounded()))
    }

    var displayText: String {
        guard let quotaSeconds, quotaSeconds > 0 else {
            return "本地本月用量：\(Self.format(seconds: usedSeconds))（当前引擎无免费额度）"
        }
        return "本地本月用量：\(Self.format(seconds: usedSeconds)) / \(Self.format(seconds: quotaSeconds))（已用 \(percentage ?? 0)%）"
    }

    static func format(seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(remainingSeconds)秒" }
        return "\(remainingSeconds)秒"
    }
}

enum TencentUsageQuota {
    static func freeQuotaSeconds(for engineModelType: String) -> Int? {
        switch engineModelType {
        case "16k_zh": return 5 * 3_600
        case "16k_zh_en", "16k_zh_en_2.0": return 0
        default: return nil
        }
    }
}

final class LocalUsageStore {
    private let defaults: UserDefaults
    private let keyPrefix = "localUsageSeconds."
    private let activeSessionStartKey = "localUsageActiveSessionStart"
    private let activeSessionHeartbeatKey = "localUsageActiveSessionHeartbeat"
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    func add(seconds: Int, at date: Date = Date()) {
        guard seconds > 0 else { return }
        let key = key(for: date)
        defaults.set(defaults.integer(forKey: key) + seconds, forKey: key)
    }

    var hasActiveSession: Bool {
        defaults.object(forKey: activeSessionStartKey) != nil
    }

    func beginSession(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: activeSessionStartKey)
        defaults.set(date.timeIntervalSince1970, forKey: activeSessionHeartbeatKey)
    }

    func touchSession(at date: Date = Date()) {
        guard hasActiveSession else { return }
        defaults.set(date.timeIntervalSince1970, forKey: activeSessionHeartbeatKey)
    }

    func currentSeconds(at date: Date = Date()) -> Int {
        let accumulated = seconds(at: date)
        guard let start = activeSessionStart else { return accumulated }
        return accumulated + max(0, Int(date.timeIntervalSince(start)))
    }

    @discardableResult
    func endSession(at date: Date = Date()) -> Int {
        guard let start = activeSessionStart else { return 0 }
        let elapsed = max(1, Int(date.timeIntervalSince(start)))
        add(seconds: elapsed, at: date)
        defaults.removeObject(forKey: activeSessionStartKey)
        defaults.removeObject(forKey: activeSessionHeartbeatKey)
        return elapsed
    }

    @discardableResult
    func recoverAbandonedSession() -> Int {
        guard let start = activeSessionStart else { return 0 }
        let lastHeartbeat = activeSessionHeartbeat ?? start
        let elapsed = max(1, Int(lastHeartbeat.timeIntervalSince(start)))
        add(seconds: elapsed, at: lastHeartbeat)
        defaults.removeObject(forKey: activeSessionStartKey)
        defaults.removeObject(forKey: activeSessionHeartbeatKey)
        return elapsed
    }

    func seconds(at date: Date = Date()) -> Int {
        defaults.integer(forKey: key(for: date))
    }

    private var activeSessionStart: Date? {
        guard let timestamp = defaults.object(forKey: activeSessionStartKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private var activeSessionHeartbeat: Date? {
        guard let timestamp = defaults.object(forKey: activeSessionHeartbeatKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func key(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(keyPrefix)\(components.year ?? 0)-\(String(format: "%02d", components.month ?? 0))"
    }
}
