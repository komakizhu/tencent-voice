import AppKit
import RimeSyncCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: UserDefaultsSettingsStore
    private let credentialStore: PersistentCredentialStore
    private let hotkeyManager: CarbonHotkeyManager
    private let menu: StatusMenuController
    private let coordinator: SessionCoordinator
    private let sessionLogger: SessionLogger
    private let localUsageStore: LocalUsageStore
    private let sharedUsageStore: SharedUsageStore
    private let rimeThemeStore: RimeThemeStore
    private let rimeBackupRetentionStore: RimeBackupRetentionStore
    private let permissionChecker: SystemPrivacyPermissionChecker
    private var rimeReviewCoordinator: RimeReviewSyncCoordinator?
    private let rimeConfigurationCoordinator: RimeReviewSyncCoordinator
    private let rimeLocalDirectory: URL
    private let rimeInstallationID: String
    private var settingsWindowController: SettingsWindowController?
    private var rimeDictionaryWindowController: RimeDictionaryWindowController?
    private var usageMonitorTask: Task<Void, Never>?
    private var rimeThemeSelectionTask: Task<Void, Never>?
    private var rimeSyncTask: Task<Void, Never>?
    private var cachedCredentials: TencentCredentials?
    private var activeUsageSessionID: UUID?

    override init() {
        let settingsStore = UserDefaultsSettingsStore()
        let credentialStore = PersistentCredentialStore(
            perUserFallback: LocalYAMLCredentialStore()
        )
        let hotkeyManager = CarbonHotkeyManager()
        let menu = StatusMenuController()
        let localUsageStore = LocalUsageStore()
        let sharedUsageStore = SharedUsageStore()
        let rimeThemeStore = RimeThemeStore()
        let permissionChecker = SystemPrivacyPermissionChecker()
        let sessionLogger = SessionLogger(enabled: { settingsStore.load().saveTextLogs })
        let rimeBackupRetentionStore = RimeBackupRetentionStore(
            policy: RimeBackupSettings.loadPolicy()
        )
        let localRimeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Rime", isDirectory: true)
        let sharedRimeRoot = URL(fileURLWithPath: "/Users/Shared/RimeSync", isDirectory: true)
        let installationURL = localRimeDirectory.appendingPathComponent("installation.yaml")
        let configuredInstallationID: String?
        do {
            configuredInstallationID = try RimeInstallationFile.loading(from: installationURL)?.installationID
        } catch {
            configuredInstallationID = nil
        }
        let rimeInstallationID = configuredInstallationID ?? Self.defaultRimeInstallationID()
        let rimeMaintenance = SquirrelMaintenance()
        let rimeConfiguration = SyncConfiguration(
            localRimeDirectory: localRimeDirectory,
            sharedRoot: sharedRimeRoot,
            installationID: rimeInstallationID
        )
        let ordinaryRimeSync = DefaultRimeSyncEngine(
            configuration: rimeConfiguration,
            maintenance: rimeMaintenance,
            retentionStore: rimeBackupRetentionStore
        )
        let rimeConfigurationCoordinator = RimeReviewSyncCoordinator(
            configuration: rimeConfiguration,
            maintenance: rimeMaintenance,
            reloader: rimeMaintenance,
            ordinarySync: ordinaryRimeSync,
            retentionStore: rimeBackupRetentionStore
        )
        let rimeReviewCoordinator = configuredInstallationID == nil ? nil : rimeConfigurationCoordinator
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.hotkeyManager = hotkeyManager
        self.menu = menu
        self.localUsageStore = localUsageStore
        self.sharedUsageStore = sharedUsageStore
        self.rimeThemeStore = rimeThemeStore
        self.rimeBackupRetentionStore = rimeBackupRetentionStore
        self.permissionChecker = permissionChecker
        self.rimeReviewCoordinator = rimeReviewCoordinator
        self.rimeConfigurationCoordinator = rimeConfigurationCoordinator
        self.rimeLocalDirectory = localRimeDirectory
        self.rimeInstallationID = rimeInstallationID
        self.sessionLogger = sessionLogger
        coordinator = SessionCoordinator(
            asr: TencentASRClient(),
            audio: SystemAudioCapture(),
            textTarget: AXTextTarget(),
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            logger: sessionLogger,
            onStateChange: { state in
                let diagnosticState: String = switch state {
                case .idle: "idle"
                case .connecting: "connecting"
                case .listening: "listening"
                case .stopping: "stopping"
                case .error: "error"
                }
                sessionLogger.recordDiagnosticAction("session_state_changed", fields: [
                    "state": diagnosticState
                ])
                switch state {
                case .idle: menu.update(status: "就绪")
                case .connecting: menu.update(status: "连接中…")
                case .listening: menu.update(status: "录音中…")
                case .stopping: menu.update(status: "收尾中…")
                case let .error(message): menu.update(status: "错误：\(message)")
                }
            }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        menu.install()
        menu.configure(
            onSettings: { [weak self] in self?.showSettings() },
            onToggleRecording: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.toggleRecording()
                }
            },
            onSelectRimeTheme: { [weak self] themeID in
                self?.selectRimeTheme(themeID)
            },
            onManageRimeDictionary: { [weak self] in
                self?.showRimeDictionaryManager()
            },
            onSyncRimeDictionary: { [weak self] in
                self?.syncRimeDictionary()
            },
            onSyncRimeSkin: { [weak self] in
                self?.syncRimeSkin()
            },
            onSyncRimeConfiguration: { [weak self] in
                self?.syncRimeConfiguration()
            },
            onSyncAllConfiguration: { [weak self] in
                self?.syncAllConfiguration()
            }
        )
        refreshRimeThemes()
        registerHotkey()
        localUsageStore.migrateLegacyUnscopedUsage(to: TencentEnginePreset.standard.rawValue)
        _ = try? sharedUsageStore.recoverAbandonedSessions()
        migrateLocalUsageIfNeeded()
        updateLocalUsageDisplay()
        startLocalUsageMonitor()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: #selector(UndoManager.redo), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageMonitorTask?.cancel()
        rimeThemeSelectionTask?.cancel()
        rimeSyncTask?.cancel()
        rimeDictionaryWindowController?.close()
        hotkeyManager.unregister()
        endTrackedUsageSession()
        coordinator.cancel()
        menu.uninstall()
    }

    private func registerHotkey() {
        let settings = settingsStore.load()
        menu.update(shortcut: settings.shortcut)
        do {
            try hotkeyManager.register(
                settings.shortcut,
                onPress: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.toggleRecording()
                    }
                },
                onRelease: {}
            )
            menu.update(status: "就绪 · \(ShortcutFormatter.string(for: settings.shortcut))")
        } catch {
            sessionLogger.recordDiagnosticAction("hotkey_registration_failed", fields: [
                "errorCode": DiagnosticErrorFormatter.code(for: error),
                "errorMessage": DiagnosticErrorFormatter.message(for: error)
            ])
            menu.update(status: "错误：\(error.localizedDescription)")
        }
    }

    private func showSettings() {
        if let existing = settingsWindowController, existing.window?.isVisible == true {
            sessionLogger.recordDiagnosticAction("settings_opened")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.window?.orderFrontRegardless()
            return
        }

        sessionLogger.recordDiagnosticAction("settings_opened")
        var settings = settingsStore.load()
        let credentials = loadCredentialsForSettings()
        if let credentials,
           let sharedHours = try? sharedUsageStore.prepaidQuotaHours(
               for: credentials,
               engineModelType: settings.engineModelType
           ) {
            settings.prepaidQuotaHoursByModel[settings.engineModelType] = sharedHours
        }
        let controller = SettingsWindowController(
            settings: settings,
            credentials: credentials,
            onSave: { [weak self] newSettings, newCredentials in
                guard let self else { return }
                // Credentials must be persisted before attempting a potentially conflicting hotkey.
                try credentialStore.save(newCredentials)
                cachedCredentials = newCredentials
                try sharedUsageStore.setPrepaidQuotaHours(
                    newSettings.prepaidQuotaHoursByModel[newSettings.engineModelType],
                    for: newCredentials,
                    engineModelType: newSettings.engineModelType
                )
                try hotkeyManager.register(
                    newSettings.shortcut,
                    onPress: { [weak self] in
                        Task { @MainActor [weak self] in await self?.toggleRecording() }
                    },
                    onRelease: {}
                )
                menu.update(shortcut: newSettings.shortcut)
                settingsStore.save(newSettings)
                migrateLocalUsageIfNeeded()
                menu.update(status: "就绪 · \(ShortcutFormatter.string(for: newSettings.shortcut))")
                updateLocalUsageDisplay()
            },
            onTestConnection: { credentials, engineModelType in
                let configuration = TencentSessionConfiguration(
                    appID: credentials.appID,
                    secretID: credentials.secretID,
                    secretKey: credentials.secretKey,
                    engineModelType: engineModelType,
                    voiceID: UUID().uuidString
                )
                try await TencentASRClient().testConnection(configuration: configuration)
            },
            onExportDiagnosticLog: { [weak self] in
                guard let self else { throw DiagnosticLogExportError.unavailable }
                return try self.exportDiagnosticLog()
            },
            onRecordDiagnosticAction: { [weak self] name, fields in
                self?.sessionLogger.recordDiagnosticAction(name, fields: fields)
            },
            permissionChecker: permissionChecker,
            logDirectoryURL: sessionLogger.persistenceDirectoryURL,
            diagnosticDirectoryURL: sessionLogger.diagnosticExportDirectoryURL,
            onClose: { [weak self] in
                guard self != nil else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        )
        settingsWindowController = controller
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
    }

    private func exportDiagnosticLog() throws -> URL? {
        let report = DiagnosticReportBuilder(
            permissionChecker: permissionChecker,
            credentialStore: credentialStore,
            settingsStore: settingsStore,
            logger: sessionLogger
        ).build()

        let panel = NSSavePanel()
        panel.title = "导出诊断报告"
        panel.message = "导出会话状态、错误代码和操作上下文；不会导出密钥、录音或识别文字。"
        panel.nameFieldStringValue = defaultDiagnosticLogFilename()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let data = try DiagnosticJSON.encoder().encode(report)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func defaultDiagnosticLogFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "TencentVoiceMVP-Diagnostic-\(formatter.string(from: Date())).json"
    }

    private func refreshRimeThemes() {
        do {
            menu.update(rimeThemes: try rimeThemeStore.load())
        } catch {
            menu.update(rimeThemeError: error.localizedDescription)
        }
    }

    private func selectRimeTheme(_ themeID: String) {
        guard rimeThemeSelectionTask == nil else { return }
        rimeThemeSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { rimeThemeSelectionTask = nil }
            do {
                menu.update(rimeThemes: try await rimeThemeStore.select(themeID: themeID))
            } catch is CancellationError {
                return
            } catch {
                menu.update(rimeThemeError: error.localizedDescription)
            }
        }
    }

    private func showRimeDictionaryManager() {
        guard let rimeReviewCoordinator else {
            menu.update(status: "Rime 词库管理不可用")
            return
        }
        if let existing = rimeDictionaryWindowController, existing.window?.isVisible == true {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.window?.orderFrontRegardless()
            return
        }
        let controller = RimeDictionaryWindowController(reviewCoordinator: rimeReviewCoordinator)
        rimeDictionaryWindowController = controller
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        controller.begin()
    }

    private func syncRimeDictionary() {
        guard rimeSyncTask == nil else { return }
        do {
            try prepareRimeDirectoryForConfigurationSync()
        } catch {
            menu.update(status: "Rime 词库同步失败：\(error.localizedDescription)")
            return
        }
        guard let coordinator = rimeReviewCoordinator else {
            menu.update(status: "Rime 词库同步不可用")
            return
        }

        menu.update(rimeSyncInProgress: true)
        menu.update(status: "正在同步 Rime 词库…")
        rimeSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                rimeSyncTask = nil
                menu.update(rimeSyncInProgress: false)
            }
            let result: Result<RimeUserDictionarySyncReport, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try coordinator.syncUserDictionary())
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case let .success(report):
                menu.update(status: "Rime 词库同步完成 · \(report.entryCount) 条审核记录")
                rimeDictionaryWindowController?.reloadFromStoredSnapshot()
            case let .failure(error):
                menu.update(status: "Rime 词库同步失败：\(error.localizedDescription)")
            }
        }
    }

    private func syncRimeSkin() {
        syncRimeConfiguration(
            paths: [RimeResourcePolicy.skinConfigurationPath],
            progress: "正在同步 Rime 皮肤…",
            success: "Rime 皮肤同步完成"
        )
    }

    private func syncRimeConfiguration() {
        syncRimeConfiguration(
            paths: nil,
            progress: "正在同步 Rime 所有配置…",
            success: "Rime 所有配置同步完成"
        )
    }

    private func syncAllConfiguration() {
        syncRimeConfiguration(
            paths: nil,
            progress: "正在一键同步所有配置…",
            success: "一键同步所有配置完成"
        )
    }

    private func syncRimeConfiguration(
        paths: Set<String>?,
        progress: String,
        success: String
    ) {
        guard rimeSyncTask == nil else { return }
        do {
            try prepareRimeDirectoryForConfigurationSync()
        } catch {
            menu.update(status: "Rime 配置同步失败：\(error.localizedDescription)")
            return
        }

        menu.update(rimeSyncInProgress: true)
        menu.update(status: progress)
        let coordinator = rimeConfigurationCoordinator
        rimeSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                rimeSyncTask = nil
                menu.update(rimeSyncInProgress: false)
            }
            let result: Result<SyncReport, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try coordinator.syncConfiguration(paths: paths))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case let .success(report):
                let changedCount = report.changedFiles.count + report.deletedFiles.count
                let conflictMessage = report.conflicts.isEmpty
                    ? ""
                    : " · \(report.conflicts.count) 个文件冲突，已暂停"
                menu.update(status: "\(success) · \(changedCount) 项变更\(conflictMessage)")
                refreshRimeThemes()
            case let .failure(error):
                menu.update(status: "Rime 配置同步失败：\(error.localizedDescription)")
            }
        }
    }

    private func prepareRimeDirectoryForConfigurationSync() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rimeLocalDirectory, withIntermediateDirectories: true)
        // Once the local directory is bootstrapped, dictionary operations can
        // use the same coordinator as configuration synchronization.
        rimeReviewCoordinator = rimeConfigurationCoordinator
        let installationURL = rimeLocalDirectory.appendingPathComponent("installation.yaml")
        let syncDirectory = URL(
            fileURLWithPath: "/Users/Shared/RimeSync/rime-userdata",
            isDirectory: true
        )
        let installation = try? RimeInstallationFile.loading(from: installationURL)
        guard installation?.installationID != rimeInstallationID
            || installation?.syncDirectory != syncDirectory.path else {
            return
        }
        try RimeInstallationFile.updating(
            existingURL: installationURL,
            installationID: rimeInstallationID,
            syncDirectory: syncDirectory
        )
    }

    private static func defaultRimeInstallationID() -> String {
        let user = NSUserName().unicodeScalars.map { scalar -> String in
            let value = scalar.value
            let isASCIIAlphaNumeric = (value >= 48 && value <= 57)
                || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122)
            return isASCIIAlphaNumeric || value == 45 || value == 95 ? String(scalar) : "-"
        }.joined()
        let normalized = user.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(normalized.isEmpty ? "local" : normalized)-main"
    }

    private func toggleRecording() async {
        let stateName: String = switch coordinator.state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .listening: "listening"
        case .stopping: "stopping"
        case .error: "error"
        }
        sessionLogger.recordDiagnosticAction("recording_toggle_requested", fields: [
            "state": stateName
        ])
        switch coordinator.state {
        case .idle:
            let engineModelType = settingsStore.load().engineModelType
            try? await coordinator.begin()
            if coordinator.state == .listening {
                guard let credentials = loadCredentials() else { return }
                activeUsageSessionID = try? sharedUsageStore.beginSession(
                    for: credentials,
                    engineModelType: engineModelType
                )
                updateLocalUsageDisplay()
            }
        case .connecting:
            coordinator.cancel()
            updateLocalUsageDisplay()
        case .listening:
            let endingUsageSessionID = activeUsageSessionID
            let stoppedAt = Date()
            try? await coordinator.end()
            if activeUsageSessionID == endingUsageSessionID {
                endTrackedUsageSession(at: stoppedAt)
                updateLocalUsageDisplay()
            }
        case .stopping:
            // The stop request is already draining Tencent's final results.
            // A second shortcut must not cancel the transaction and delete text.
            return
        case .error:
            coordinator.cancel()
            endTrackedUsageSession()
            updateLocalUsageDisplay()
        }
    }

    private func loadCredentials() -> TencentCredentials? {
        if let cachedCredentials { return cachedCredentials }
        cachedCredentials = try? credentialStore.load()
        return cachedCredentials
    }

    private func loadCredentialsForSettings() -> TencentCredentials? {
        if let cachedCredentials { return cachedCredentials }
        cachedCredentials = try? credentialStore.migrateLegacyIfNeeded()
        return cachedCredentials
    }

    private func startLocalUsageMonitor() {
        usageMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                updateLocalUsageDisplay()
                try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    private func updateLocalUsageDisplay(at date: Date = Date()) {
        let settings = settingsStore.load()
        guard let credentials = loadCredentials() else {
            menu.update(usage: "共享用量：请先在设置中配置腾讯凭证")
            return
        }
        if let activeUsageSessionID {
            try? sharedUsageStore.touchSession(activeUsageSessionID, at: date)
        }
        let sharedPrepaidHours = try? sharedUsageStore.prepaidQuotaHours(
            for: credentials,
            engineModelType: settings.engineModelType
        )
        let prepaidHours = sharedPrepaidHours ?? settings.prepaidQuotaHoursByModel[settings.engineModelType]
        let hasPrepaidQuota = prepaidHours.map { $0 > 0 } ?? false
        do {
            let usedSeconds = hasPrepaidQuota
                ? try sharedUsageStore.currentTotalSeconds(
                    for: credentials,
                    engineModelType: settings.engineModelType,
                    at: date
                )
                : try sharedUsageStore.currentSeconds(
                    for: credentials,
                    engineModelType: settings.engineModelType,
                    at: date
                )
            let summary = TencentUsageSummary(
                localUsedSeconds: usedSeconds,
                quotaSeconds: TencentUsageQuota.seconds(
                    for: settings.engineModelType,
                    prepaidHours: prepaidHours
                ),
                engineModelType: settings.engineModelType,
                isPrepaid: hasPrepaidQuota,
                sharedAcrossUsers: true
            )
            menu.update(usage: summary.displayText)
        } catch {
            menu.update(usage: "共享用量读取失败：\(error.localizedDescription)")
        }
    }

    private func endTrackedUsageSession(at date: Date = Date()) {
        guard let sessionID = activeUsageSessionID else { return }
        activeUsageSessionID = nil
        _ = try? sharedUsageStore.endSession(sessionID, at: date)
    }

    private func migrateLocalUsageIfNeeded() {
        guard let credentials = loadCredentials() else { return }
        do {
            try sharedUsageStore.migrateLocalUsageIfNeeded(
                from: localUsageStore,
                for: credentials
            )
            let settings = settingsStore.load()
            for (engineModelType, hours) in settings.prepaidQuotaHoursByModel {
                if try sharedUsageStore.prepaidQuotaHours(
                    for: credentials,
                    engineModelType: engineModelType
                ) == nil {
                    try sharedUsageStore.setPrepaidQuotaHours(
                        hours,
                        for: credentials,
                        engineModelType: engineModelType
                    )
                }
            }
        } catch {
            menu.update(usage: "共享用量迁移失败：\(error.localizedDescription)")
        }
    }
}
