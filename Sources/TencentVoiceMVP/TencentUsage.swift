import Foundation
import Darwin

struct TencentUsageSummary: Equatable, Sendable {
    let localUsedSeconds: Int
    let quotaSeconds: Int?
    let engineModelType: String
    let isPrepaid: Bool
    let sharedAcrossUsers: Bool

    init(
        localUsedSeconds: Int,
        quotaSeconds: Int?,
        engineModelType: String = TencentEnginePreset.defaultPreset.rawValue,
        isPrepaid: Bool = false,
        sharedAcrossUsers: Bool = false
    ) {
        self.localUsedSeconds = localUsedSeconds
        self.quotaSeconds = quotaSeconds
        self.engineModelType = engineModelType
        self.isPrepaid = isPrepaid
        self.sharedAcrossUsers = sharedAcrossUsers
    }

    var usedSeconds: Int {
        localUsedSeconds
    }

    var percentage: Int? {
        guard let quotaSeconds, quotaSeconds > 0 else { return nil }
        return min(100, Int((Double(usedSeconds) / Double(quotaSeconds) * 100).rounded()))
    }

    var displayText: String {
        let scope = sharedAcrossUsers ? "共享本机本月用量" : "本地本月用量"
        guard let quotaSeconds, quotaSeconds > 0 else {
            return "\(scope)（\(engineModelType)）：\(Self.format(seconds: usedSeconds))（当前引擎无免费额度）"
        }
        if isPrepaid {
            let packageScope = sharedAcrossUsers ? "共享本机套餐用量" : "本地套餐用量"
            return "\(packageScope)（\(engineModelType)）：\(Self.format(seconds: usedSeconds)) / \(Self.formatQuota(seconds: quotaSeconds))（已用 \(percentage ?? 0)%）"
        }
        return "\(scope)（\(engineModelType)）：\(Self.format(seconds: usedSeconds)) / \(Self.format(seconds: quotaSeconds))（已用 \(percentage ?? 0)%）"
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

struct LocalUsageBucket: Equatable, Sendable {
    let engineModelType: String
    let month: String
    let seconds: Int
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
    private let sharedUsageMigrationKey = "sharedUsageMigrationV1"
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

    func usageBuckets() -> [LocalUsageBucket] {
        defaults.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix(keyPrefix) else { return nil }
            let suffix = String(key.dropFirst(keyPrefix.count))
            guard let separator = suffix.lastIndex(of: ".") else { return nil }
            let model = String(suffix[..<separator])
            let month = String(suffix[suffix.index(after: separator)...])
            guard !model.isEmpty,
                  month.range(of: "^\\d{4}-\\d{2}$", options: .regularExpression) != nil else {
                return nil
            }
            let seconds = defaults.integer(forKey: key)
            guard seconds > 0 else { return nil }
            return LocalUsageBucket(engineModelType: model, month: month, seconds: seconds)
        }
    }

    func needsSharedUsageMigration() -> Bool {
        !defaults.bool(forKey: sharedUsageMigrationKey)
    }

    func markSharedUsageMigrationComplete() {
        defaults.set(true, forKey: sharedUsageMigrationKey)
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

enum SharedUsageStoreError: Error, LocalizedError {
    case cannotOpenLock(errno: Int32)
    case cannotLock(errno: Int32)
    case invalidLedger

    var errorDescription: String? {
        switch self {
        case let .cannotOpenLock(errno): return "无法打开共享用量锁（错误码 \(errno)）"
        case let .cannotLock(errno): return "无法锁定共享用量文件（错误码 \(errno)）"
        case .invalidLedger: return "共享用量文件格式无效"
        }
    }
}

private struct SharedUsageSessionRecord: Codable {
    let id: UUID
    let fingerprint: String
    let ownerID: String
    let processID: Int32
    let engineModelType: String
    let startedAt: Date
    var heartbeatAt: Date
}

private struct SharedUsageLedger: Codable {
    var committedSeconds: [String: Int]
    var activeSessions: [SharedUsageSessionRecord]
    var migratedUsageSources: Set<String>
    var prepaidQuotaHours: [String: Int]

    init(
        committedSeconds: [String: Int] = [:],
        activeSessions: [SharedUsageSessionRecord] = [],
        migratedUsageSources: Set<String> = [],
        prepaidQuotaHours: [String: Int] = [:]
    ) {
        self.committedSeconds = committedSeconds
        self.activeSessions = activeSessions
        self.migratedUsageSources = migratedUsageSources
        self.prepaidQuotaHours = prepaidQuotaHours
    }

    private enum CodingKeys: String, CodingKey {
        case committedSeconds
        case activeSessions
        case migratedUsageSources
        case prepaidQuotaHours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        committedSeconds = try container.decodeIfPresent([String: Int].self, forKey: .committedSeconds) ?? [:]
        activeSessions = try container.decodeIfPresent([SharedUsageSessionRecord].self, forKey: .activeSessions) ?? []
        migratedUsageSources = try container.decodeIfPresent(Set<String>.self, forKey: .migratedUsageSources) ?? []
        prepaidQuotaHours = try container.decodeIfPresent([String: Int].self, forKey: .prepaidQuotaHours) ?? [:]
    }
}

final class SharedUsageStore {
    static let defaultFileURL = URL(fileURLWithPath: "/Users/Shared/TencentVoiceMVP/usage.json")

    private let fileURL: URL
    private let ownerID: String
    private let processID: Int32
    private let calendar: Calendar
    private let processLock = NSLock()
    private let staleSessionInterval: TimeInterval = 15

    init(
        fileURL: URL = SharedUsageStore.defaultFileURL,
        ownerID: String = NSUserName(),
        processID: Int32 = getpid()
    ) {
        self.fileURL = fileURL
        self.ownerID = ownerID
        self.processID = processID
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    @discardableResult
    func beginSession(
        for credentials: TencentCredentials,
        engineModelType: String,
        at date: Date = Date()
    ) throws -> UUID {
        let identity = TencentCredentialIdentity(credentials: credentials)
        let session = SharedUsageSessionRecord(
            id: UUID(),
            fingerprint: identity.fingerprint,
            ownerID: ownerID,
            processID: processID,
            engineModelType: engineModelType,
            startedAt: date,
            heartbeatAt: date
        )
        try updateLedger { ledger in
            ledger.activeSessions.append(session)
        }
        return session.id
    }

    func touchSession(_ sessionID: UUID, at date: Date = Date()) throws {
        try updateLedger { ledger in
            guard let index = ledger.activeSessions.firstIndex(where: { $0.id == sessionID }) else { return }
            ledger.activeSessions[index].heartbeatAt = date
        }
    }

    @discardableResult
    func endSession(_ sessionID: UUID, at date: Date = Date()) throws -> Int {
        try updateLedger { ledger in
            guard let index = ledger.activeSessions.firstIndex(where: { $0.id == sessionID }) else { return 0 }
            let session = ledger.activeSessions.remove(at: index)
            let elapsed = max(1, Int(date.timeIntervalSince(session.startedAt)))
            add(
                seconds: elapsed,
                fingerprint: session.fingerprint,
                engineModelType: session.engineModelType,
                at: date,
                to: &ledger
            )
            return elapsed
        }
    }

    @discardableResult
    func recoverAbandonedSessions(at date: Date = Date()) throws -> Int {
        try updateLedger { ledger in
            var recoveredSeconds = 0
            var remaining: [SharedUsageSessionRecord] = []
            for session in ledger.activeSessions {
                let isOwnedByThisUser = session.ownerID == ownerID
                let isStale = date.timeIntervalSince(session.heartbeatAt) >= staleSessionInterval
                guard isOwnedByThisUser || isStale else {
                    remaining.append(session)
                    continue
                }
                let endDate = session.heartbeatAt
                let elapsed = max(1, Int(endDate.timeIntervalSince(session.startedAt)))
                add(
                    seconds: elapsed,
                    fingerprint: session.fingerprint,
                    engineModelType: session.engineModelType,
                    at: endDate,
                    to: &ledger
                )
                recoveredSeconds += elapsed
            }
            ledger.activeSessions = remaining
            return recoveredSeconds
        }
    }

    func currentSeconds(
        for credentials: TencentCredentials,
        engineModelType: String,
        at date: Date = Date()
    ) throws -> Int {
        let identity = TencentCredentialIdentity(credentials: credentials)
        return try readLedger { ledger in
            let committed = ledger.committedSeconds[key(
                fingerprint: identity.fingerprint,
                engineModelType: engineModelType,
                month: month(for: date)
            )] ?? 0
            return committed + activeSeconds(
                in: ledger,
                fingerprint: identity.fingerprint,
                engineModelType: engineModelType,
                at: date
            )
        }
    }

    func currentTotalSeconds(
        for credentials: TencentCredentials,
        engineModelType: String,
        at date: Date = Date()
    ) throws -> Int {
        let identity = TencentCredentialIdentity(credentials: credentials)
        return try readLedger { ledger in
            let prefix = "sharedUsage.\(identity.fingerprint).\(engineModelType)."
            let committed = ledger.committedSeconds
                .filter { $0.key.hasPrefix(prefix) }
                .reduce(0) { $0 + $1.value }
            return committed + activeSeconds(
                in: ledger,
                fingerprint: identity.fingerprint,
                engineModelType: engineModelType,
                at: date
            )
        }
    }

    func prepaidQuotaHours(
        for credentials: TencentCredentials,
        engineModelType: String
    ) throws -> Int? {
        let identity = TencentCredentialIdentity(credentials: credentials)
        return try readLedger { ledger in
            ledger.prepaidQuotaHours[quotaKey(
                fingerprint: identity.fingerprint,
                engineModelType: engineModelType
            )]
        }
    }

    func setPrepaidQuotaHours(
        _ hours: Int?,
        for credentials: TencentCredentials,
        engineModelType: String
    ) throws {
        let identity = TencentCredentialIdentity(credentials: credentials)
        try updateLedger { ledger in
            let key = quotaKey(
                fingerprint: identity.fingerprint,
                engineModelType: engineModelType
            )
            if let hours, hours > 0 {
                ledger.prepaidQuotaHours[key] = hours
            } else {
                ledger.prepaidQuotaHours.removeValue(forKey: key)
            }
        }
    }

    func migrateLocalUsageIfNeeded(
        from localStore: LocalUsageStore,
        for credentials: TencentCredentials
    ) throws {
        let identity = TencentCredentialIdentity(credentials: credentials)
        guard localStore.needsSharedUsageMigration() else { return }
        let buckets = localStore.usageBuckets()
        let migrationSource = ownerID
        try updateLedger { ledger in
            guard !ledger.migratedUsageSources.contains(migrationSource) else { return }
            for bucket in buckets {
                add(
                    seconds: bucket.seconds,
                    fingerprint: identity.fingerprint,
                    engineModelType: bucket.engineModelType,
                    month: bucket.month,
                    to: &ledger
                )
            }
            ledger.migratedUsageSources.insert(migrationSource)
        }
        localStore.markSharedUsageMigrationComplete()
    }

    private func activeSeconds(
        in ledger: SharedUsageLedger,
        fingerprint: String,
        engineModelType: String,
        at date: Date
    ) -> Int {
        ledger.activeSessions
            .filter {
                $0.fingerprint == fingerprint && $0.engineModelType == engineModelType
            }
            .reduce(0) { total, session in
                total + max(0, Int(date.timeIntervalSince(session.startedAt)))
            }
    }

    private func add(
        seconds: Int,
        fingerprint: String,
        engineModelType: String,
        at date: Date,
        to ledger: inout SharedUsageLedger
    ) {
        add(
            seconds: seconds,
            fingerprint: fingerprint,
            engineModelType: engineModelType,
            month: month(for: date),
            to: &ledger
        )
    }

    private func add(
        seconds: Int,
        fingerprint: String,
        engineModelType: String,
        month: String,
        to ledger: inout SharedUsageLedger
    ) {
        guard seconds > 0 else { return }
        let usageKey = key(
            fingerprint: fingerprint,
            engineModelType: engineModelType,
            month: month
        )
        ledger.committedSeconds[usageKey, default: 0] += seconds
    }

    private func key(fingerprint: String, engineModelType: String, month: String) -> String {
        "sharedUsage.\(fingerprint).\(engineModelType).\(month)"
    }

    private func quotaKey(fingerprint: String, engineModelType: String) -> String {
        "sharedQuota.\(fingerprint).\(engineModelType)"
    }

    private func month(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(String(format: "%02d", components.month ?? 0))"
    }

    private func readLedger<T>(_ body: (SharedUsageLedger) throws -> T) throws -> T {
        try withLockedLedger { ledger in
            try body(ledger)
        }
    }

    private func updateLedger<T>(_ body: (inout SharedUsageLedger) throws -> T) throws -> T {
        try withLockedLedger { ledger in
            let result = try body(&ledger)
            try write(ledger)
            return result
        }
    }

    private func withLockedLedger<T>(_ body: (inout SharedUsageLedger) throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o2770]
        )
        try? FileManager.default.setAttributes(
            [
                .posixPermissions: 0o2770,
                .groupOwnerAccountName: "staff"
            ],
            ofItemAtPath: directoryURL.path
        )

        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o660))
        guard descriptor >= 0 else {
            throw SharedUsageStoreError.cannotOpenLock(errno: errno)
        }
        _ = Darwin.fchmod(descriptor, mode_t(0o660))
        var fileLock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = fcntl(descriptor, F_SETLK, &fileLock)
            _ = Darwin.close(descriptor)
        }
        guard fcntl(descriptor, F_SETLKW, &fileLock) == 0 else {
            throw SharedUsageStoreError.cannotLock(errno: errno)
        }
        try? FileManager.default.setAttributes(
            [
                .posixPermissions: 0o660,
                .groupOwnerAccountName: "staff"
            ],
            ofItemAtPath: lockURL.path
        )

        var ledger = try read()
        return try body(&ledger)
    }

    private func read() throws -> SharedUsageLedger {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SharedUsageLedger()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(SharedUsageLedger.self, from: Data(contentsOf: fileURL))
        } catch {
            throw SharedUsageStoreError.invalidLedger
        }
    }

    private func write(_ ledger: SharedUsageLedger) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(ledger).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o660,
                .groupOwnerAccountName: "staff"
            ],
            ofItemAtPath: fileURL.path
        )
    }
}
