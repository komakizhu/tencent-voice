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
    private(set) var statusText = "就绪"

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = ""
        item.button?.image = statusImage()
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.setAccessibilityLabel("腾讯语音输入")
        item.button?.toolTip = "腾讯语音输入"

        let menu = NSMenu()
        let usageView = UsageMenuItemView(text: "模型：计算中…\n用量：计算中…")
        let usage = NSMenuItem()
        usage.view = usageView
        usage.isEnabled = false
        menu.addItem(usage)
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
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsPressed), keyEquivalent: ",")
        settings.target = self
        let record = NSMenuItem(title: "开始录音", action: #selector(toggleRecordingPressed), keyEquivalent: "")
        record.target = self
        menu.addItem(settings)
        menu.addItem(record)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
        usageMenuItemView = usageView
        settingsMenuItem = settings
        recordMenuItem = record
        rimeThemeMenuItem = rimeTheme
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

    func update(shortcut: Shortcut) {
        recordMenuItem?.keyEquivalent = ShortcutFormatter.menuKeyEquivalent(for: shortcut)
        recordMenuItem?.keyEquivalentModifierMask = ShortcutFormatter.menuModifierFlags(for: shortcut)
    }

    func update(usage: String) {
        usageMenuItemView?.text = usage
    }

    func configure(
        onSettings: @escaping () -> Void,
        onToggleRecording: @escaping () -> Void,
        onSelectRimeTheme: @escaping (String) -> Void,
        onManageRimeDictionary: @escaping () -> Void,
        onSyncRimeDictionary: @escaping () -> Void
    ) {
        self.onSettings = onSettings
        self.onToggleRecording = onToggleRecording
        self.onSelectRimeTheme = onSelectRimeTheme
        self.onManageRimeDictionary = onManageRimeDictionary
        self.onSyncRimeDictionary = onSyncRimeDictionary
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

    func uninstall() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        usageMenuItemView = nil
        settingsMenuItem = nil
        recordMenuItem = nil
        rimeThemeMenuItem = nil
        onSettings = nil
        onToggleRecording = nil
        onSelectRimeTheme = nil
        onManageRimeDictionary = nil
        onSyncRimeDictionary = nil
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
