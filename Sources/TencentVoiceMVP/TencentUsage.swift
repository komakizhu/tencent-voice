import Foundation

struct TencentUsageSummary: Equatable, Sendable {
    let localUsedSeconds: Int
    let quotaSeconds: Int?
    let engineModelType: String
    let isPrepaid: Bool

    init(
        localUsedSeconds: Int,
        quotaSeconds: Int?,
        engineModelType: String = TencentEnginePreset.defaultPreset.rawValue,
        isPrepaid: Bool = false
    ) {
        self.localUsedSeconds = localUsedSeconds
        self.quotaSeconds = quotaSeconds
        self.engineModelType = engineModelType
        self.isPrepaid = isPrepaid
    }

    var usedSeconds: Int {
        localUsedSeconds
    }

    var percentage: Int? {
        guard let quotaSeconds, quotaSeconds > 0 else { return nil }
        return min(100, Int((Double(usedSeconds) / Double(quotaSeconds) * 100).rounded()))
    }

    var displayText: String {
        guard let quotaSeconds, quotaSeconds > 0 else {
            return "本地本月用量（\(engineModelType)）：\(Self.format(seconds: usedSeconds))（当前引擎无免费额度）"
        }
        if isPrepaid {
            return "本地套餐用量（\(engineModelType)）：\(Self.format(seconds: usedSeconds)) / \(Self.formatQuota(seconds: quotaSeconds))（已用 \(percentage ?? 0)%）"
        }
        return "本地本月用量（\(engineModelType)）：\(Self.format(seconds: usedSeconds)) / \(Self.format(seconds: quotaSeconds))（已用 \(percentage ?? 0)%）"
    }

    static func format(seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(remainingSeconds)秒" }
        return "\(remainingSeconds)秒"
    }

    private static func formatQuota(seconds: Int) -> String {
        guard seconds >= 3_600, seconds.isMultiple(of: 3_600) else {
            return format(seconds: seconds)
        }
        return "\(seconds / 3_600)小时"
    }
}

enum TencentUsageQuota {
    static let prepaidHourOptions = [10, 30, 60, 100, 1_000]

    static func freeQuotaSeconds(for engineModelType: String) -> Int? {
        switch engineModelType {
        case "16k_zh": return 5 * 3_600
        case "16k_zh_en", "16k_zh_en_2.0": return 0
        default: return nil
        }
    }

    static func seconds(for engineModelType: String, prepaidHours: Int?) -> Int? {
        if let prepaidHours, prepaidHours > 0 {
            return prepaidHours * 3_600
        }
        return freeQuotaSeconds(for: engineModelType)
    }
}

final class LocalUsageStore {
    private let defaults: UserDefaults
    private let keyPrefix = "localUsageSecondsByModel."
    private let legacyKeyPrefix = "localUsageSeconds."
    private let legacyModelType = "legacy-unscoped"
    private let legacyMigrationKey = "localUsageLegacyUnscopedMigrationV1"
    private let activeSessionStartKey = "localUsageActiveSessionStart"
    private let activeSessionHeartbeatKey = "localUsageActiveSessionHeartbeat"
    private let activeSessionModelKey = "localUsageActiveSessionModel"
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    func migrateLegacyUnscopedUsage(to engineModelType: String) {
        guard !defaults.bool(forKey: legacyMigrationKey) else { return }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyKeyPrefix) {
            let month = String(key.dropFirst(legacyKeyPrefix.count))
            guard month.range(of: "^\\d{4}-\\d{2}$", options: .regularExpression) != nil else { continue }

            let legacySeconds = defaults.integer(forKey: key)
            guard legacySeconds > 0 else { continue }
            let modelKey = "\(keyPrefix)\(engineModelType).\(month)"
            defaults.set(defaults.integer(forKey: modelKey) + legacySeconds, forKey: modelKey)
        }

        defaults.set(true, forKey: legacyMigrationKey)
    }

    func add(seconds: Int, for engineModelType: String, at date: Date = Date()) {
        guard seconds > 0 else { return }
        let key = key(for: engineModelType, at: date)
        defaults.set(defaults.integer(forKey: key) + seconds, forKey: key)
    }

    var hasActiveSession: Bool {
        defaults.object(forKey: activeSessionStartKey) != nil
    }

    func beginSession(for engineModelType: String, at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: activeSessionStartKey)
        defaults.set(date.timeIntervalSince1970, forKey: activeSessionHeartbeatKey)
        defaults.set(engineModelType, forKey: activeSessionModelKey)
    }

    func touchSession(at date: Date = Date()) {
        guard hasActiveSession else { return }
        defaults.set(date.timeIntervalSince1970, forKey: activeSessionHeartbeatKey)
    }

    func currentSeconds(for engineModelType: String, at date: Date = Date()) -> Int {
        let accumulated = seconds(for: engineModelType, at: date)
        guard let start = activeSessionStart else { return accumulated }
        guard activeSessionModelType == engineModelType else { return accumulated }
        return accumulated + max(0, Int(date.timeIntervalSince(start)))
    }

    func totalSeconds(for engineModelType: String) -> Int {
        let prefix = "\(keyPrefix)\(engineModelType)."
        return defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .reduce(0) { $0 + defaults.integer(forKey: $1) }
    }

    func currentTotalSeconds(for engineModelType: String, at date: Date = Date()) -> Int {
        let accumulated = totalSeconds(for: engineModelType)
        guard let start = activeSessionStart else { return accumulated }
        guard activeSessionModelType == engineModelType else { return accumulated }
        return accumulated + max(0, Int(date.timeIntervalSince(start)))
    }

    @discardableResult
    func endSession(at date: Date = Date()) -> Int {
        guard let start = activeSessionStart else { return 0 }
        let elapsed = max(1, Int(date.timeIntervalSince(start)))
        add(seconds: elapsed, for: activeSessionModelType ?? legacyModelType, at: date)
        defaults.removeObject(forKey: activeSessionStartKey)
        defaults.removeObject(forKey: activeSessionHeartbeatKey)
        defaults.removeObject(forKey: activeSessionModelKey)
        return elapsed
    }

    @discardableResult
    func recoverAbandonedSession() -> Int {
        guard let start = activeSessionStart else { return 0 }
        let lastHeartbeat = activeSessionHeartbeat ?? start
        let elapsed = max(1, Int(lastHeartbeat.timeIntervalSince(start)))
        add(seconds: elapsed, for: activeSessionModelType ?? legacyModelType, at: lastHeartbeat)
        defaults.removeObject(forKey: activeSessionStartKey)
        defaults.removeObject(forKey: activeSessionHeartbeatKey)
        defaults.removeObject(forKey: activeSessionModelKey)
        return elapsed
    }

    func seconds(for engineModelType: String, at date: Date = Date()) -> Int {
        defaults.integer(forKey: key(for: engineModelType, at: date))
    }

    private var activeSessionStart: Date? {
        guard let timestamp = defaults.object(forKey: activeSessionStartKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private var activeSessionHeartbeat: Date? {
        guard let timestamp = defaults.object(forKey: activeSessionHeartbeatKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private var activeSessionModelType: String? {
        defaults.string(forKey: activeSessionModelKey)
    }

    private func key(for engineModelType: String, at date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(keyPrefix)\(engineModelType).\(components.year ?? 0)-\(String(format: "%02d", components.month ?? 0))"
    }
}
