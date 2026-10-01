import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var usageMenuItemView: UsageMenuItemView?
    private var calibrateUsageMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var autoStartMenuItem: NSMenuItem?
    private var rimeThemeMenuItem: NSMenuItem?
    private var rimeDictionaryMenuItem: NSMenuItem?
    private var onSettings: (() -> Void)?
    private var onCalibrateUsage: (() -> Void)?
    private var onToggleRecording: (() -> Void)?
    private var onToggleAutoStart: (() -> Void)?
    private var onSelectRimeTheme: ((String) -> Void)?
    private var onManageRimeDictionary: (() -> Void)?
    private var onExportRimeConfiguration: (() -> Void)?
    private var onImportRimeConfiguration: (() -> Void)?
    private var archiveMenuItems: [NSMenuItem] = []
    private(set) var statusText = "就绪"
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

    func setVisible(_ visible: Bool) {
        if visible {
            install()
        } else {
            removeStatusItem()
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let usageView = UsageMenuItemView(text: "模型：计算中…\n用量：计算中…")
        let usage = NSMenuItem()
        usage.view = usageView
        usage.isEnabled = false
        menu.addItem(usage)
        let calibrateUsage = NSMenuItem(title: "校准用量…", action: #selector(calibrateUsagePressed), keyEquivalent: "")
        calibrateUsage.target = self
        menu.addItem(calibrateUsage)
        menu.addItem(.separator())
        let rimeTheme = NSMenuItem(title: "Rime 皮肤", action: nil, keyEquivalent: "")
        rimeTheme.submenu = NSMenu(title: "Rime 皮肤")
        menu.addItem(rimeTheme)
        let dictionary = NSMenuItem(title: "Rime 词库管理…", action: #selector(rimeDictionaryPressed), keyEquivalent: "")
        dictionary.target = self
        Self.applyLocalShortcut(to: dictionary, keyEquivalent: "m")
        menu.addItem(dictionary)
        menu.addItem(.separator())
        let export = NSMenuItem(title: "导出所有配置…", action: #selector(exportRimeConfigurationPressed), keyEquivalent: "")
        export.target = self
        export.toolTip = "将当前账户可迁移的 Rime 配置打包为便携存档"
        let `import` = NSMenuItem(title: "导入所有配置…", action: #selector(importRimeConfigurationPressed), keyEquivalent: "")
        `import`.target = self
        `import`.toolTip = "校验存档、预览将新增或替换的文件，并在确认后导入"
        menu.addItem(export)
        menu.addItem(`import`)
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsPressed), keyEquivalent: ",")
        settings.target = self
        let record = NSMenuItem(title: "开始录音", action: #selector(toggleRecordingPressed), keyEquivalent: "")
        record.target = self
        let autoStart = NSMenuItem(title: "开机自动启动", action: #selector(autoStartPressed), keyEquivalent: "")
        autoStart.target = self
        autoStart.toolTip = "登录 macOS 账户后自动启动 Rime Voice。"
        menu.addItem(settings)
        menu.addItem(record)
        menu.addItem(autoStart)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        installedMenu = menu
        usageMenuItemView = usageView
        calibrateUsageMenuItem = calibrateUsage
        settingsMenuItem = settings
        recordMenuItem = record
        autoStartMenuItem = autoStart
        rimeThemeMenuItem = rimeTheme
        rimeDictionaryMenuItem = dictionary
        archiveMenuItems = [export, `import`]
        return menu
    }

    static func applyLocalShortcut(to item: NSMenuItem, keyEquivalent: String) {
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = [.command]
    }

    func update(status: String) {
        statusText = status
        let isIdle = status.contains("就绪")
        let isError = status.hasPrefix("错误：") || status.hasPrefix("无法开始录音：")
        let isStopping = status.contains("收尾中")
        recordMenuItem?.title = isStopping
            ? "收尾中…"
            : (isIdle || isError ? "开始录音" : "停止录音")
        recordMenuItem?.isEnabled = !isStopping
    }

    func update(shortcut: Shortcut) {
        recordMenuItem?.keyEquivalent = ShortcutFormatter.menuKeyEquivalent(for: shortcut)
        recordMenuItem?.keyEquivalentModifierMask = ShortcutFormatter.menuModifierFlags(for: shortcut)
    }

    func update(autoStartEnabled: Bool) {
        autoStartMenuItem?.state = autoStartEnabled ? .on : .off
    }

    func update(usage: String) {
        usageMenuItemView?.text = usage
    }

    func update(calibrationInProgress: Bool) {
        calibrateUsageMenuItem?.title = calibrationInProgress ? "正在核对腾讯云…" : "校准用量…"
        calibrateUsageMenuItem?.isEnabled = !calibrationInProgress
    }

    func update(configurationArchiveInProgress: Bool) {
        archiveMenuItems.forEach { $0.isEnabled = !configurationArchiveInProgress }
        rimeThemeMenuItem?.isEnabled = !configurationArchiveInProgress
        rimeDictionaryMenuItem?.isEnabled = !configurationArchiveInProgress
    }

    func configure(
        onSettings: @escaping () -> Void,
        onCalibrateUsage: @escaping () -> Void = {},
        onToggleRecording: @escaping () -> Void,
        onToggleAutoStart: @escaping () -> Void,
        onSelectRimeTheme: @escaping (String) -> Void,
        onManageRimeDictionary: @escaping () -> Void,
        onExportRimeConfiguration: @escaping () -> Void,
        onImportRimeConfiguration: @escaping () -> Void
    ) {
        self.onSettings = onSettings
        self.onCalibrateUsage = onCalibrateUsage
        self.onToggleRecording = onToggleRecording
        self.onToggleAutoStart = onToggleAutoStart
        self.onSelectRimeTheme = onSelectRimeTheme
        self.onManageRimeDictionary = onManageRimeDictionary
        self.onExportRimeConfiguration = onExportRimeConfiguration
        self.onImportRimeConfiguration = onImportRimeConfiguration
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

    @objc private func calibrateUsagePressed() {
        onCalibrateUsage?()
    }

    @objc private func toggleRecordingPressed() {
        onToggleRecording?()
    }

    @objc private func autoStartPressed() {
        onToggleAutoStart?()
    }

    @objc private func rimeThemePressed(_ sender: NSMenuItem) {
        guard let themeID = sender.representedObject as? String else { return }
        onSelectRimeTheme?(themeID)
    }

    @objc private func rimeDictionaryPressed() {
        onManageRimeDictionary?()
    }

    @objc private func exportRimeConfigurationPressed() {
        onExportRimeConfiguration?()
    }

    @objc private func importRimeConfigurationPressed() {
        onImportRimeConfiguration?()
    }

    func uninstall() {
        removeStatusItem()
        onSettings = nil
        onToggleRecording = nil
        onToggleAutoStart = nil
        onSelectRimeTheme = nil
        onManageRimeDictionary = nil
        onExportRimeConfiguration = nil
        onImportRimeConfiguration = nil
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
        installedMenu = nil
        usageMenuItemView = nil
        settingsMenuItem = nil
        recordMenuItem = nil
        autoStartMenuItem = nil
        rimeThemeMenuItem = nil
        rimeDictionaryMenuItem = nil
        archiveMenuItems = []
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
