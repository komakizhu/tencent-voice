import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: UserDefaultsSettingsStore
    private let credentialStore: PersistentCredentialStore
    private let hotkeyManager: CarbonHotkeyManager
    private let menu: StatusMenuController
    private let coordinator: SessionCoordinator
    private let localUsageStore: LocalUsageStore
    private var settingsWindowController: SettingsWindowController?
    private var usageMonitorTask: Task<Void, Never>?
    private var cachedCredentials: TencentCredentials?
    private var activeUsageSessionID: UUID?

    override init() {
        let settingsStore = UserDefaultsSettingsStore()
        let credentialStore = PersistentCredentialStore()
        let hotkeyManager = CarbonHotkeyManager()
        let menu = StatusMenuController()
        let localUsageStore = LocalUsageStore()
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.hotkeyManager = hotkeyManager
        self.menu = menu
        self.localUsageStore = localUsageStore
        coordinator = SessionCoordinator(
            asr: TencentASRClient(),
            audio: SystemAudioCapture(),
            textTarget: AXTextTarget(),
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            logger: SessionLogger(enabled: { settingsStore.load().saveTextLogs }),
            onStateChange: { state in
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
            }
        )
        registerHotkey()
        localUsageStore.recoverAbandonedSession()
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
        hotkeyManager.unregister()
        endTrackedUsageSession()
        coordinator.cancel()
        menu.uninstall()
    }

    private func registerHotkey() {
        let settings = settingsStore.load()
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
            menu.update(status: "错误：\(error.localizedDescription)")
        }
    }

    private func showSettings() {
        if let existing = settingsWindowController, existing.window?.isVisible == true {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.window?.orderFrontRegardless()
            return
        }

        let settings = settingsStore.load()
        let credentials = loadCredentialsForSettings()
        let controller = SettingsWindowController(settings: settings, credentials: credentials ?? nil) { [weak self] newSettings, newCredentials in
            guard let self else { return }
            // Credentials must be persisted before attempting a potentially conflicting hotkey.
            try credentialStore.save(newCredentials)
            cachedCredentials = newCredentials
            try hotkeyManager.register(
                    newSettings.shortcut,
                    onPress: { [weak self] in
                        Task { @MainActor [weak self] in await self?.toggleRecording() }
                    },
                    onRelease: {}
            )
            settingsStore.save(newSettings)
            menu.update(status: "就绪 · \(ShortcutFormatter.string(for: newSettings.shortcut))")
            updateLocalUsageDisplay()
        } onClose: { [weak self] in
            guard self != nil else { return }
            NSApp.setActivationPolicy(.accessory)
        }
        settingsWindowController = controller
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
    }

    private func toggleRecording() async {
        switch coordinator.state {
        case .idle:
            try? await coordinator.begin()
            if coordinator.state == .listening {
                activeUsageSessionID = UUID()
                localUsageStore.beginSession()
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
        localUsageStore.touchSession(at: date)
        let summary = TencentUsageSummary(
            localUsedSeconds: localUsageStore.currentSeconds(at: date),
            quotaSeconds: TencentUsageQuota.freeQuotaSeconds(for: settings.engineModelType)
        )
        menu.update(usage: summary.displayText)
    }

    private func endTrackedUsageSession(at date: Date = Date()) {
        guard activeUsageSessionID != nil else { return }
        activeUsageSessionID = nil
        localUsageStore.endSession(at: date)
    }
}
