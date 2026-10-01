import AppKit
import RimeSyncCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: UserDefaultsSettingsStore
    private let credentialStore: PersistentCredentialStore
    private let hotkeyManager: CarbonHotkeyManager
    private let nativeF5Remapper: NativeF5Remapper
    private let menu: StatusMenuController
    private let loginItemManager: LoginItemManager
    private let coordinator: SessionCoordinator
    private let sessionLogger: SessionLogger
    private let localUsageStore: LocalUsageStore
    private let sharedUsageStore: SharedUsageStore
    private let rimeThemeStore: RimeThemeStore
    private let rimeBackupRetentionStore: RimeBackupRetentionStore
    private let permissionChecker: SystemPrivacyPermissionChecker
    private let rimeReviewCoordinator: RimeReviewSyncCoordinator
    private let rimeLocalSupportRoot: URL
    private let rimeLocalDirectory: URL
    private var settingsWindowController: SettingsWindowController?
    private var rimeDictionaryWindowController: RimeDictionaryWindowController?
    private var usageMonitorTask: Task<Void, Never>?
    private var nativeF5MonitorTask: Task<Void, Never>?
    private var rimeThemeSelectionTask: Task<Void, Never>?
    private var configurationArchiveTask: Task<Void, Never>?
    private var configurationImportRecoveryPending = false
    private var cachedCredentials: TencentCredentials?
    private var activeUsageSessionID: UUID?

    override init() {
        let settingsStore = UserDefaultsSettingsStore()
        let credentialStore = PersistentCredentialStore(
            perUserFallback: LocalYAMLCredentialStore()
        )
        let hotkeyManager = CarbonHotkeyManager()
        let nativeF5Remapper = NativeF5Remapper()
        let menu = StatusMenuController()
        let loginItemManager = LoginItemManager()
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
        let localSupportRoot = RimeLocalReviewStorage.defaultRoot()
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
            sharedRoot: localSupportRoot,
            installationID: rimeInstallationID
        )
        let ordinaryRimeSync = DefaultRimeSyncEngine(
            configuration: rimeConfiguration,
            maintenance: rimeMaintenance,
            retentionStore: rimeBackupRetentionStore
        )
        let rimeReviewCoordinator = RimeReviewSyncCoordinator(
            configuration: rimeConfiguration,
            maintenance: rimeMaintenance,
            reloader: rimeMaintenance,
            ordinarySync: ordinaryRimeSync,
            retentionStore: rimeBackupRetentionStore,
            storageMode: .local
        )
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.hotkeyManager = hotkeyManager
        self.nativeF5Remapper = nativeF5Remapper
        self.menu = menu
        self.loginItemManager = loginItemManager
        self.localUsageStore = localUsageStore
        self.sharedUsageStore = sharedUsageStore
        self.rimeThemeStore = rimeThemeStore
        self.rimeBackupRetentionStore = rimeBackupRetentionStore
        self.permissionChecker = permissionChecker
        self.rimeReviewCoordinator = rimeReviewCoordinator
        self.rimeLocalSupportRoot = localSupportRoot
        self.rimeLocalDirectory = localRimeDirectory
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
                case .recovering: "recovering"
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
                case .recovering: menu.update(status: "麦克风恢复中…")
                case .stopping: menu.update(status: "收尾中…")
                case let .error(message): menu.update(status: "错误：\(message)")
                }
            }
        )
        super.init()
        coordinator.setStateObserver { [weak self] state in
            guard case .error = state else { return }
            self?.endTrackedUsageSession()
            self?.updateLocalUsageDisplay()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchSettings = settingsStore.load()
        NSApp.setActivationPolicy(launchSettings.hideMenuBarIcon ? .regular : .accessory)
        installMainMenu()
        if !launchSettings.hideMenuBarIcon {
            menu.install()
        }
        menu.configure(
            onSettings: { [weak self] in self?.showSettings() },
            onCalibrateUsage: { [weak self] in
                Task { @MainActor [weak self] in await self?.refreshCloudUsage() }
            },
            onToggleRecording: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.toggleRecording()
                }
            },
            onToggleAutoStart: { [weak self] in
                self?.toggleAutoStart()
            },
            onSelectRimeTheme: { [weak self] themeID in
                self?.selectRimeTheme(themeID)
            },
            onManageRimeDictionary: { [weak self] in
                self?.showRimeDictionaryManager()
            },
            onExportRimeConfiguration: { [weak self] in
                self?.exportRimeConfiguration()
            },
            onImportRimeConfiguration: { [weak self] in
                self?.importRimeConfiguration()
            }
        )
        menu.update(autoStartEnabled: loginItemManager.isEnabled)
        refreshRimeThemes()
        recoverPendingConfigurationImports()
        registerHotkey()
        startNativeF5Monitor()
        localUsageStore.migrateLegacyUnscopedUsage(to: TencentEnginePreset.standard.rawValue)
        _ = try? sharedUsageStore.recoverAbandonedSessions()
        migrateLocalUsageIfNeeded()
        updateLocalUsageDisplay()
        startLocalUsageMonitor()
        if UserDefaults.standard.bool(forKey: "resumePermissionSetup") {
            UserDefaults.standard.removeObject(forKey: "resumePermissionSetup")
            showSettings()
            settingsWindowController?.resumePermissionSetup()
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(settingsMenuPressed),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
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

    @objc private func settingsMenuPressed() {
        showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nativeF5MonitorTask?.cancel()
        usageMonitorTask?.cancel()
        rimeThemeSelectionTask?.cancel()
        rimeDictionaryWindowController?.close()
        hotkeyManager.unregister()
        if !nativeF5Remapper.restoreIfOwned() {
            sessionLogger.recordDiagnosticAction("hotkey_native_f5_restore_failed", fields: [
                "errorCode": "hotkey_native_f5_remap_unavailable",
                "errorMessage": "退出时无法恢复 macOS 原生按键映射"
            ])
        }
        endTrackedUsageSession()
        coordinator.cancel()
        menu.uninstall()
    }

    private func registerHotkey() {
        let settings = settingsStore.load()
        menu.update(shortcut: settings.shortcut)
        do {
            try synchronizeNativeF5(for: settings.shortcut)
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
            _ = nativeF5Remapper.restoreIfOwned()
            sessionLogger.recordDiagnosticAction("hotkey_registration_failed", fields: [
                "errorCode": DiagnosticErrorFormatter.code(for: error),
                "errorMessage": DiagnosticErrorFormatter.message(for: error)
            ])
            menu.update(status: "错误：\(error.localizedDescription)")
        }
    }

    private func synchronizeNativeF5(for shortcut: Shortcut) throws {
        guard nativeF5Remapper.synchronize(shouldApply: shortcut.isNativeF5Preset) else {
            throw HotkeyError.nativeF5RemapUnavailable
        }
    }

    private func startNativeF5Monitor() {
        nativeF5MonitorTask = Task { @MainActor [weak self] in
            var reportedFailure = false
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self else { return }
                // Only the foreground login session owns hardware mappings.
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                guard session?["kCGSSessionOnConsoleKey"] as? Bool == true,
                      self.settingsStore.load().shortcut.isNativeF5Preset else { continue }
                let ready = self.nativeF5Remapper.synchronize(shouldApply: true)
                if !ready && !reportedFailure {
                    self.sessionLogger.recordDiagnosticAction("hotkey_native_f5_remap_unavailable")
                    self.menu.update(status: "错误：听写键映射失效，请检查其他键盘工具的映射")
                }
                reportedFailure = !ready
            }
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
                let previousSettings = settingsStore.load()
                // Credentials must be persisted before attempting a potentially conflicting hotkey.
                try credentialStore.save(newCredentials)
                cachedCredentials = newCredentials
                try sharedUsageStore.setPrepaidQuotaHours(
                    newSettings.prepaidQuotaHoursByModel[newSettings.engineModelType],
                    for: newCredentials,
                    engineModelType: newSettings.engineModelType
                )
                do {
                    try synchronizeNativeF5(for: newSettings.shortcut)
                    try hotkeyManager.register(
                        newSettings.shortcut,
                        onPress: { [weak self] in
                            Task { @MainActor [weak self] in await self?.toggleRecording() }
                        },
                        onRelease: {}
                    )
                } catch {
                    _ = nativeF5Remapper.synchronize(
                        shouldApply: previousSettings.shortcut.isNativeF5Preset
                    )
                    throw error
                }
                settingsStore.save(newSettings)
                menu.setVisible(!newSettings.hideMenuBarIcon)
                if !newSettings.hideMenuBarIcon {
                    menu.update(autoStartEnabled: loginItemManager.isEnabled)
                    refreshRimeThemes()
                }
                menu.update(shortcut: newSettings.shortcut)
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
                guard let self else { return }
                let hideMenuBarIcon = self.settingsStore.load().hideMenuBarIcon
                NSApp.setActivationPolicy(hideMenuBarIcon ? .regular : .accessory)
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

    private func toggleAutoStart() {
        let shouldEnable = !loginItemManager.isEnabled
        do {
            try loginItemManager.setEnabled(shouldEnable)
            menu.update(autoStartEnabled: loginItemManager.isEnabled)
            sessionLogger.recordDiagnosticAction("auto_start_updated", fields: [
                "enabled": String(loginItemManager.isEnabled),
                "status": String(describing: loginItemManager.status)
            ])

            if shouldEnable, loginItemManager.status == .requiresApproval {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "请允许 Rime Voice 开机自动启动"
                alert.informativeText = "请打开“系统设置 → 通用 → 登录项”，允许 Rime Voice 在登录时启动。"
                alert.runModal()
            }
        } catch {
            menu.update(autoStartEnabled: loginItemManager.isEnabled)
            sessionLogger.recordDiagnosticAction("auto_start_update_failed", fields: [
                "enabled": String(shouldEnable),
                "errorCode": DiagnosticErrorFormatter.code(for: error),
                "errorMessage": DiagnosticErrorFormatter.message(for: error)
            ])

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = shouldEnable ? "无法开启开机自动启动" : "无法关闭开机自动启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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
        return "Rime Voice-Diagnostic-\(formatter.string(from: Date())).json"
    }

    private func refreshRimeThemes() {
        do {
            menu.update(rimeThemes: try rimeThemeStore.load())
        } catch {
            menu.update(rimeThemeError: error.localizedDescription)
        }
    }

    private func selectRimeTheme(_ themeID: String) {
        guard rimeThemeSelectionTask == nil,
              configurationArchiveTask == nil,
              !configurationImportRecoveryPending else { return }
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
        guard configurationArchiveTask == nil, !configurationImportRecoveryPending else { return }
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

    private func exportRimeConfiguration() {
        guard configurationArchiveTask == nil, !configurationImportRecoveryPending else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "rimevoiceconfig") ?? .data]
        panel.nameFieldStringValue = "Rime Voice Configuration-\(Self.archiveDateFormatter.string(from: Date())).rimevoiceconfig"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        menu.update(configurationArchiveInProgress: true)
        configurationArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                configurationArchiveTask = nil
                refreshConfigurationImportRecoveryState()
            }
            do {
                let source = rimeLocalDirectory
                let exportPreview = try await Task.detached(priority: .userInitiated) {
                    try RimePortableArchiveService().previewExport(from: source)
                }.value
                let confirmation = NSAlert()
                confirmation.messageText = "导出所有 Rime 配置？"
                confirmation.informativeText = "将导出 \(exportPreview.files.count) 个文件，预计 \(ByteCountFormatter.string(fromByteCount: exportPreview.totalBytes, countStyle: .file))。请确认完整文件清单后继续。"
                confirmation.accessoryView = Self.archivePreviewScrollView(lines: Self.exportPreviewLines(exportPreview))
                confirmation.addButton(withTitle: "导出存档")
                confirmation.addButton(withTitle: "取消")
                guard confirmation.runModal() == .alertFirstButtonReturn else { return }
                let inspection = try await Task.detached(priority: .userInitiated) {
                    try RimePortableArchiveService().export(from: source, to: destination, expectedPreview: exportPreview)
                }.value
                showArchiveNotice(
                    title: "配置存档已导出",
                    message: "已导出 \(inspection.files.count) 个文件（\(ByteCountFormatter.string(fromByteCount: inspection.totalBytes, countStyle: .file))）。\n\n\(destination.path)"
                )
            } catch {
                showArchiveNotice(title: "导出失败", message: error.localizedDescription, style: .critical)
            }
        }
    }

    private func importRimeConfiguration() {
        guard configurationArchiveTask == nil, !configurationImportRecoveryPending else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "rimevoiceconfig") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let archiveURL = panel.url else { return }
        guard rimeThemeSelectionTask == nil else {
            showArchiveNotice(title: "暂时无法导入", message: "皮肤切换正在进行，请稍后再导入配置。")
            return
        }
        guard rimeDictionaryWindowController?.hasPendingOperation != true else {
            showArchiveNotice(title: "暂时无法导入", message: "词库管理操作正在进行，请稍后再导入配置。")
            return
        }
        menu.update(configurationArchiveInProgress: true)
        rimeDictionaryWindowController?.window?.close()
        rimeDictionaryWindowController = nil
        configurationArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                configurationArchiveTask = nil
                refreshConfigurationImportRecoveryState()
            }
            do {
                let target = rimeLocalDirectory
                let preview = try await Task.detached(priority: .userInitiated) {
                    try RimePortableArchiveService().previewImport(from: archiveURL, to: target)
                }.value
                guard preview.changedCount > 0 else {
                    showArchiveNotice(title: "配置无需更新", message: "存档中的 \(preview.items.count) 个文件与当前配置完全相同；未创建备份，也未重新部署。")
                    return
                }
                let containsCode = preview.items.contains { item in
                    item.relativePath == "Rime配置助手.command" || item.relativePath.hasPrefix("lua/")
                }
                if containsCode {
                    let trustConfirmation = NSAlert()
                    trustConfirmation.alertStyle = .critical
                    trustConfirmation.messageText = "存档包含可执行代码"
                    trustConfirmation.informativeText = "该存档包含 Lua 或 Rime 配置助手脚本。重新部署可能加载 Lua 代码；配置助手命令文件也会保留其执行权限。只有在确认存档来源可信时继续。"
                    trustConfirmation.addButton(withTitle: "信任来源并继续")
                    trustConfirmation.addButton(withTitle: "取消")
                    guard trustConfirmation.runModal() == .alertFirstButtonReturn else { return }
                }
                let confirmation = NSAlert()
                confirmation.alertStyle = .warning
                confirmation.messageText = "导入并替换同名配置？"
                confirmation.informativeText = "新增 \(preview.additions.count) 个文件；替换 \(preview.replacements.count) 个文件；内容相同 \(preview.unchanged.count) 个文件。未列入存档的目标文件会保留。请确认完整文件清单后继续。"
                confirmation.accessoryView = Self.archivePreviewScrollView(lines: Self.importPreviewLines(preview))
                confirmation.addButton(withTitle: "导入并重新部署")
                confirmation.addButton(withTitle: "取消")
                guard confirmation.runModal() == .alertFirstButtonReturn else { return }

                try RimeLocalReviewStorage.prepare(root: rimeLocalSupportRoot)
                let archiveIncludesManagedDictionary = preview.items.contains {
                    $0.relativePath == RimeManagedDictionary.fileName
                }
                let managedDictionaryWillChange = preview.items.contains {
                    $0.relativePath == RimeManagedDictionary.fileName && $0.change != .unchanged
                }
                let backupRoot = rimeLocalSupportRoot.appendingPathComponent("backups", isDirectory: true)
                let coordinator = rimeReviewCoordinator
                let importReport = try await Task.detached(priority: .userInitiated) {
                    try RimePortableArchiveService().importAndDeploy(
                        from: archiveURL,
                        to: target,
                        backupRoot: backupRoot,
                        expectedPreview: preview,
                        protectedPaths: archiveIncludesManagedDictionary ? ["rime_ice.dict.yaml", RimeManagedDictionary.fileName] : [],
                        backupDependentState: { backupDirectory in
                            if managedDictionaryWillChange {
                                try coordinator.backupLocalReviewStateForConfigurationImport(at: backupDirectory)
                            }
                        },
                        prepareAfterImport: { registerPreparedFile in
                            if archiveIncludesManagedDictionary {
                                try coordinator.reconcileManagedDictionaryAfterImport(
                                    rebuildReviewState: managedDictionaryWillChange,
                                    registerPreparedFile: registerPreparedFile
                                )
                            }
                        },
                        deploy: { try SquirrelMaintenance().reload() },
                        restoreAfterRollback: { backupDirectory in
                            if managedDictionaryWillChange {
                                try coordinator.restoreLocalReviewStateFromConfigurationImport(at: backupDirectory)
                            }
                            try SquirrelMaintenance().reload()
                        }
                    )
                }.value
                guard !importReport.backupID.isEmpty else {
                    showArchiveNotice(title: "配置无需更新", message: "目标文件在确认时已与存档一致；未创建备份或重新部署。")
                    return
                }

                refreshRimeThemes()
                showArchiveNotice(
                    title: "配置已导入",
                    message: "新增 \(importReport.addedFiles.count) 个文件，替换 \(importReport.replacedFiles.count) 个文件。当前账户独有文件已保留。\n\n导入前备份：\(rimeLocalSupportRoot.appendingPathComponent("backups/\(importReport.backupID)").path)"
                )
            } catch {
                showArchiveNotice(title: "导入失败", message: error.localizedDescription, style: .critical)
            }
        }
    }

    private func recoverPendingConfigurationImports() {
        let backupRoot = rimeLocalSupportRoot.appendingPathComponent("backups", isDirectory: true)
        let recoveries: [RimePortableImportRecovery]
        do {
            recoveries = try RimePortableArchiveService().pendingRecoveries(in: backupRoot)
        } catch {
            configurationImportRecoveryPending = true
            menu.update(configurationArchiveInProgress: true)
            Task { @MainActor [weak self] in
                self?.showArchiveNotice(
                    title: "无法检查未完成的配置导入",
                    message: "为避免覆盖未恢复的配置，本次运行期间已停用 Rime 配置操作。检查失败：\(error.localizedDescription)\n\n请保留备份目录并检查后重启应用：\(backupRoot.path)",
                    style: .critical
                )
            }
            return
        }
        guard !recoveries.isEmpty else { return }
        configurationImportRecoveryPending = true
        menu.update(configurationArchiveInProgress: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for recovery in recoveries {
                let backupDirectory = backupRoot.appendingPathComponent(recovery.id, isDirectory: true)
                if let problem = recovery.problem {
                    showArchiveNotice(
                        title: "配置导入恢复记录无法读取",
                        message: "为避免误覆盖，本次运行期间已停用 Rime 配置操作。记录错误：\(problem)\n\n请保留并人工检查此备份目录，然后重启应用：\(backupDirectory.path)",
                        style: .critical
                    )
                    continue
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "发现未完成的配置导入"
                alert.informativeText = "检测到尚未确认完成的导入。为避免把部分写入误标为完整，只能恢复导入前内容；也可以稍后处理。恢复前会检查目标文件，若发现后续编辑，将停止回滚并保留备份。\n\n涉及 \(recovery.filePaths.count) 个文件。\n备份：\(backupDirectory.path)"
                alert.addButton(withTitle: "恢复导入前配置")
                alert.addButton(withTitle: "稍后处理")
                do {
                    guard alert.runModal() == .alertFirstButtonReturn else { continue }
                    let target = rimeLocalDirectory
                    let coordinator = rimeReviewCoordinator
                    let needsManagedReconcile = recovery.filePaths.contains(RimeManagedDictionary.fileName)
                    try await Task.detached(priority: .userInitiated) {
                        try RimePortableArchiveService().restoreImportFiles(backupID: recovery.id, in: backupRoot, targetDirectory: target)
                        if needsManagedReconcile {
                            try coordinator.restoreLocalReviewStateFromConfigurationImport(at: backupDirectory)
                        }
                        try SquirrelMaintenance().reload()
                        try RimePortableArchiveService().completeRollback(backupID: recovery.id, in: backupRoot)
                    }.value
                } catch {
                    showArchiveNotice(title: "恢复未完成", message: "\(error.localizedDescription)\n\n请保留备份：\(backupRoot.appendingPathComponent(recovery.id).path)", style: .critical)
                }
            }
            refreshConfigurationImportRecoveryState()
        }
    }

    private func refreshConfigurationImportRecoveryState() {
        let backupRoot = rimeLocalSupportRoot.appendingPathComponent("backups", isDirectory: true)
        do {
            let recoveries = try RimePortableArchiveService().pendingRecoveries(in: backupRoot)
            configurationImportRecoveryPending = !recoveries.isEmpty
        } catch {
            configurationImportRecoveryPending = true
        }
        menu.update(configurationArchiveInProgress: configurationImportRecoveryPending || configurationArchiveTask != nil)
    }

    private func showArchiveNotice(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func importPreviewLines(_ preview: RimePortableImportPreview) -> [String] {
        let symbols: [RimePortableImportChange: String] = [.add: "新增", .replace: "替换", .unchanged: "相同"]
        return preview.items.map { "\(symbols[$0.change, default: ""])  \($0.relativePath)" }
    }

    private static func exportPreviewLines(_ preview: RimePortableArchiveExportPreview) -> [String] {
        preview.files.map { file in
            "\(file.relativePath)  ·  \(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))"
        }
    }

    private static func archivePreviewScrollView(lines: [String]) -> NSScrollView {
        let size = NSSize(width: 520, height: 260)
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        textView.string = lines.joined(separator: "\n")
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = size
        textView.maxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: container)
            let contentHeight = ceil(layoutManager.usedRect(for: container).height + 24)
            textView.setFrameSize(NSSize(width: size.width, height: max(size.height, contentHeight)))
        }
        scrollView.documentView = textView
        return scrollView
    }

    private static let archiveDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

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
        case .recovering: "recovering"
        case .stopping: "stopping"
        case .error: "error"
        }
        sessionLogger.recordDiagnosticAction("recording_toggle_requested", fields: [
            "state": stateName
        ])
        switch coordinator.state {
        case .idle:
            await beginRecording()
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
        case .recovering:
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
            await beginRecording()
        }
    }

    private func beginRecording() async {
        let engineModelType = settingsStore.load().engineModelType
        do {
            try await coordinator.begin()
        } catch {
            handleRecordingStartFailure(error)
            return
        }
        guard coordinator.state == .listening || coordinator.state == .recovering,
              let credentials = loadCredentials() else { return }
        activeUsageSessionID = try? sharedUsageStore.beginSession(
            for: credentials,
            engineModelType: engineModelType
        )
        updateLocalUsageDisplay()
    }

    private func handleRecordingStartFailure(_ error: Error) {
        let errorCode = DiagnosticErrorFormatter.code(for: error)
        let errorMessage = DiagnosticErrorFormatter.message(for: error)
        sessionLogger.recordDiagnosticAction("recording_start_failed", fields: [
            "errorCode": errorCode,
            "errorMessage": errorMessage
        ])
        menu.update(status: RecordingStartFeedback.message(for: error))
        guard RecordingStartFeedback.shouldShowSettings(for: error) else { return }
        showSettings()
        settingsWindowController?.showRecordingStartFailure(error)
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

    private func refreshCloudUsage() async {
        guard let credentials = loadCredentials() else {
            updateLocalUsageDisplay()
            let alert = NSAlert()
            alert.messageText = "请先配置腾讯云凭证"
            alert.informativeText = "校准用量使用设置中已有的 SecretId 和 SecretKey，无需登录腾讯云网页。"
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { showSettings() }
            return
        }
        let model = settingsStore.load().engineModelType
        menu.update(calibrationInProgress: true)
        defer { menu.update(calibrationInProgress: false) }
        do {
            let usage = try await TencentCloudUsageClient().activePackageUsage(
                credentials: credentials, engineModelType: model
            )
            guard !Task.isCancelled, loadCredentials() == credentials,
                  settingsStore.load().engineModelType == model else { return }
            guard let usage else {
                updateLocalUsageDisplay()
                showCloudCalibrationFallback("腾讯云没有返回当前模型的有效实时识别资源包；若目前按量后付费，请手动输入用量。")
                return
            }
            let alert = NSAlert()
            alert.messageText = "腾讯云核对结果"
            let packageType = usage.isPrepaid ? "付费套餐累计" : "本月免费额度"
            alert.informativeText = "模型：\(model)\n\(packageType)已用 \(TencentUsageSummary.format(seconds: usage.usedSeconds)) / \(TencentUsageSummary.format(seconds: usage.totalSeconds))。确认与控制台一致后使用此数值。"
            alert.addButton(withTitle: "使用此用量")
            alert.addButton(withTitle: "手动输入")
            alert.addButton(withTitle: "打开腾讯云页面")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try sharedUsageStore.setDisplayedSeconds(
                        usage.usedSeconds,
                        for: credentials,
                        engineModelType: model,
                        isPrepaid: usage.isPrepaid,
                        prepaidQuotaHours: usage.isPrepaid
                            ? (usage.totalSeconds.isMultiple(of: 3_600) ? usage.totalSeconds / 3_600 : nil)
                            : 0
                    )
                    updateLocalUsageDisplay()
                } catch {
                    showUsageCorrectionError(error.localizedDescription)
                }
            case .alertSecondButtonReturn:
                correctUsage()
            case .alertThirdButtonReturn:
                NSWorkspace.shared.open(TencentCloudUsageClient.resourceBundleURL)
            default:
                break
            }
        } catch {
            guard !Task.isCancelled, loadCredentials() == credentials,
                  settingsStore.load().engineModelType == model else { return }
            updateLocalUsageDisplay()
            showCloudCalibrationFallback("腾讯云查询失败：\(error.localizedDescription)")
        }
    }

    private func showCloudCalibrationFallback(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "暂时无法自动校准"
        alert.informativeText = detail
        alert.addButton(withTitle: "手动输入")
        alert.addButton(withTitle: "打开腾讯云页面")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: correctUsage()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(TencentCloudUsageClient.resourceBundleURL)
        default: break
        }
    }

    private func correctUsage() {
        guard let credentials = loadCredentials() else {
            showSettings()
            return
        }
        let settings = settingsStore.load()
        let model = settings.engineModelType
        let prepaidHours = (try? sharedUsageStore.prepaidQuotaHours(
            for: credentials,
            engineModelType: model
        )) ?? settings.prepaidQuotaHoursByModel[model]
        let isPrepaid = (prepaidHours ?? 0) > 0
        let current: Int
        do {
            current = isPrepaid
                ? try sharedUsageStore.currentTotalSeconds(for: credentials, engineModelType: model)
                : try sharedUsageStore.currentSeconds(for: credentials, engineModelType: model)
        } catch {
            showUsageCorrectionError(error.localizedDescription)
            return
        }

        let hoursField = NSTextField(string: String(current / 3_600))
        let minutesField = NSTextField(string: String((current % 3_600) / 60))
        hoursField.alignment = .right
        minutesField.alignment = .right
        let row = NSStackView(views: [hoursField, NSTextField(labelWithString: "小时"),
                                     minutesField, NSTextField(labelWithString: "分钟")])
        row.spacing = 8
        row.alignment = .centerY
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 30)
        hoursField.widthAnchor.constraint(equalToConstant: 85).isActive = true
        minutesField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let alert = NSAlert()
        alert.messageText = "校正当前模型用量"
        alert.informativeText = "模型：\(model)；范围：\(isPrepaid ? "套餐累计" : "本月")。保存后，后续录音会继续累计。"
        alert.accessoryView = row
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let seconds = UsageCorrectionInput.seconds(
            hours: hoursField.stringValue,
            minutes: minutesField.stringValue
        ) else {
            showUsageCorrectionError("请输入 0 至 100000 小时、0 至 59 分钟的整数")
            return
        }
        do {
            try sharedUsageStore.setDisplayedSeconds(
                seconds,
                for: credentials,
                engineModelType: model,
                isPrepaid: isPrepaid
            )
            updateLocalUsageDisplay()
        } catch {
            showUsageCorrectionError(error.localizedDescription)
        }
    }

    private func showUsageCorrectionError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法校正用量"
        alert.informativeText = message
        alert.runModal()
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
                sharedAcrossUsers: true,
                sourceLabel: "本机估算用量"
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
