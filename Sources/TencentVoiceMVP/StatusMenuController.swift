import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var usageMenuItemView: UsageMenuItemView?
    private var settingsMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var rimeThemeMenuItem: NSMenuItem?
    private var onSettings: (() -> Void)?
    private var onToggleRecording: (() -> Void)?
    private var onSelectRimeTheme: ((String) -> Void)?
    private var onManageRimeDictionary: (() -> Void)?
    private var onSyncRimeDictionary: (() -> Void)?
    private var onSyncRimeSkin: (() -> Void)?
    private var onSyncAllConfiguration: (() -> Void)?
    private var rimeSyncMenuItems: [NSMenuItem] = []
    private var syncStatusMenuItem: NSMenuItem?
    private var syncStatusMenuItemView: SyncStatusMenuItemView?
    private(set) var statusText = "就绪"
    private(set) var syncStatusText = "就绪"
    private(set) var installedMenu: NSMenu?

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = ""
        item.button?.image = statusImage()
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.setAccessibilityLabel("Rime Voice")
        item.button?.toolTip = "Rime Voice"

        item.menu = makeMenu()
        statusItem = item
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let usageView = UsageMenuItemView(text: "模型：计算中…\n用量：计算中…")
        let usage = NSMenuItem()
        usage.view = usageView
        usage.isEnabled = false
        menu.addItem(usage)
        let syncStatusTitle = "同步状态：\(syncStatusText)"
        let syncStatusView = SyncStatusMenuItemView(text: syncStatusTitle, width: usageView.frame.width)
        let syncStatus = NSMenuItem(title: syncStatusTitle, action: nil, keyEquivalent: "")
        syncStatus.view = syncStatusView
        syncStatus.isEnabled = false
        menu.addItem(syncStatus)
        menu.addItem(.separator())
        let rimeTheme = NSMenuItem(title: "Rime 皮肤", action: nil, keyEquivalent: "")
        rimeTheme.submenu = NSMenu(title: "Rime 皮肤")
        menu.addItem(rimeTheme)
        let dictionary = NSMenuItem(title: "Rime 词库管理…", action: #selector(rimeDictionaryPressed), keyEquivalent: "")
        dictionary.target = self
        Self.applyLocalShortcut(to: dictionary, keyEquivalent: "m")
        menu.addItem(dictionary)
        let syncDictionary = NSMenuItem(title: "同步 Rime 词库", action: #selector(syncRimeDictionaryPressed), keyEquivalent: "")
        syncDictionary.target = self
        Self.applyLocalShortcut(to: syncDictionary, keyEquivalent: "s")
        menu.addItem(syncDictionary)
        let syncSkin = NSMenuItem(title: "同步 Rime 皮肤", action: #selector(syncRimeSkinPressed), keyEquivalent: "")
        syncSkin.target = self
        syncSkin.toolTip = "只同步 squirrel.custom.yaml 皮肤配置"
        menu.addItem(syncSkin)
        menu.addItem(.separator())
        let syncAllConfiguration = NSMenuItem(title: "一键同步所有配置", action: #selector(syncAllConfigurationPressed), keyEquivalent: "")
        syncAllConfiguration.target = self
        syncAllConfiguration.toolTip = "同步全部 Rime 稳定配置；实时用户词库仍使用“同步 Rime 词库”"
        menu.addItem(syncAllConfiguration)
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsPressed), keyEquivalent: ",")
        settings.target = self
        let record = NSMenuItem(title: "开始录音", action: #selector(toggleRecordingPressed), keyEquivalent: "")
        record.target = self
        menu.addItem(settings)
        menu.addItem(record)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        installedMenu = menu
        usageMenuItemView = usageView
        settingsMenuItem = settings
        recordMenuItem = record
        rimeThemeMenuItem = rimeTheme
        rimeSyncMenuItems = [syncDictionary, syncSkin, syncAllConfiguration]
        syncStatusMenuItem = syncStatus
        syncStatusMenuItemView = syncStatusView
        return menu
    }

    static func applyLocalShortcut(to item: NSMenuItem, keyEquivalent: String) {
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = [.command]
    }

    func update(status: String) {
        statusText = status
        let isIdle = status.contains("就绪")
        let isStopping = status.contains("收尾中")
        recordMenuItem?.title = isStopping
            ? "收尾中…"
            : (isIdle ? "开始录音" : "停止录音")
        recordMenuItem?.isEnabled = !isStopping
    }

    func update(syncStatus: String) {
        syncStatusText = syncStatus
        let title = "同步状态：\(syncStatus)"
        syncStatusMenuItem?.title = title
        syncStatusMenuItemView?.text = title
        statusItem?.button?.toolTip = "Rime Voice · 同步状态：\(syncStatus)"
    }

    func update(shortcut: Shortcut) {
        recordMenuItem?.keyEquivalent = ShortcutFormatter.menuKeyEquivalent(for: shortcut)
        recordMenuItem?.keyEquivalentModifierMask = ShortcutFormatter.menuModifierFlags(for: shortcut)
    }

    func update(usage: String) {
        usageMenuItemView?.text = usage
        if let width = usageMenuItemView?.frame.width {
            syncStatusMenuItemView?.update(width: width)
        }
    }

    func update(rimeSyncInProgress: Bool) {
        rimeSyncMenuItems.forEach { $0.isEnabled = !rimeSyncInProgress }
    }

    func configure(
        onSettings: @escaping () -> Void,
        onToggleRecording: @escaping () -> Void,
        onSelectRimeTheme: @escaping (String) -> Void,
        onManageRimeDictionary: @escaping () -> Void,
        onSyncRimeDictionary: @escaping () -> Void,
        onSyncRimeSkin: @escaping () -> Void,
        onSyncAllConfiguration: @escaping () -> Void
    ) {
        self.onSettings = onSettings
        self.onToggleRecording = onToggleRecording
        self.onSelectRimeTheme = onSelectRimeTheme
        self.onManageRimeDictionary = onManageRimeDictionary
        self.onSyncRimeDictionary = onSyncRimeDictionary
        self.onSyncRimeSkin = onSyncRimeSkin
        self.onSyncAllConfiguration = onSyncAllConfiguration
    }

    func update(rimeThemes snapshot: RimeThemeSnapshot) {
        guard let submenu = rimeThemeMenuItem?.submenu else { return }
        submenu.removeAllItems()
        for theme in snapshot.themes {
            let item = NSMenuItem(title: theme.displayName, action: #selector(rimeThemePressed), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.id
            item.state = theme.id == snapshot.selectedThemeID ? .on : .off
            submenu.addItem(item)
        }
        if snapshot.themes.isEmpty {
            let empty = NSMenuItem(title: "没有可用皮肤", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
    }

    func update(rimeThemeError message: String) {
        guard let submenu = rimeThemeMenuItem?.submenu else { return }
        submenu.removeAllItems()
        let item = NSMenuItem(title: "读取失败：\(message)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        submenu.addItem(item)
    }

    @objc private func settingsPressed() {
        onSettings?()
    }

    @objc private func toggleRecordingPressed() {
        onToggleRecording?()
    }

    @objc private func rimeThemePressed(_ sender: NSMenuItem) {
        guard let themeID = sender.representedObject as? String else { return }
        onSelectRimeTheme?(themeID)
    }

    @objc private func rimeDictionaryPressed() {
        onManageRimeDictionary?()
    }

    @objc private func syncRimeDictionaryPressed() {
        onSyncRimeDictionary?()
    }

    @objc private func syncRimeSkinPressed() {
        onSyncRimeSkin?()
    }

    @objc private func syncAllConfigurationPressed() {
        onSyncAllConfiguration?()
    }

    func uninstall() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        installedMenu = nil
        usageMenuItemView = nil
        settingsMenuItem = nil
        recordMenuItem = nil
        rimeThemeMenuItem = nil
        syncStatusMenuItem = nil
        syncStatusMenuItemView = nil
        onSettings = nil
        onToggleRecording = nil
        onSelectRimeTheme = nil
        onManageRimeDictionary = nil
        onSyncRimeDictionary = nil
        onSyncRimeSkin = nil
        onSyncAllConfiguration = nil
        rimeSyncMenuItems = []
    }

    private func statusImage() -> NSImage {
        if let path = Bundle.main.path(forResource: "statusbar-matched", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 18, height: 18)
            // Let macOS tint the transparent mask for light/dark menu bars.
            image.isTemplate = true
            return image
        }

        // Keep the menu usable when running directly from SwiftPM tests.
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.white.setStroke()
        let bubble = NSBezierPath(roundedRect: NSRect(x: 0.7, y: 1.7, width: 16.6, height: 14.6), xRadius: 4.4, yRadius: 4.4)
        bubble.lineWidth = 1.3
        bubble.stroke()
        NSColor.white.setFill()
        for (x, height) in [(4.6, 5.0), (7.2, 9.4), (9.8, 6.7), (12.4, 10.4)] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 4.3, width: 1.3, height: height), xRadius: 0.65, yRadius: 0.65).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
