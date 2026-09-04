import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var stateMenuItem: NSMenuItem?
    private var usageMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var rimeThemeMenuItem: NSMenuItem?
    private var onSettings: (() -> Void)?
    private var onToggleRecording: (() -> Void)?
    private var onSelectRimeTheme: ((String) -> Void)?
    private var onManageRimeDictionary: (() -> Void)?
    private(set) var statusText = "就绪"

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "语"

        let menu = NSMenu()
        let state = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let usage = NSMenuItem(title: "共享本机本月用量：计算中…", action: nil, keyEquivalent: "")
        usage.isEnabled = false
        menu.addItem(usage)
        menu.addItem(.separator())
        let rimeTheme = NSMenuItem(title: "Rime 皮肤", action: nil, keyEquivalent: "")
        rimeTheme.submenu = NSMenu(title: "Rime 皮肤")
        menu.addItem(rimeTheme)
        let dictionary = NSMenuItem(title: "Rime 词库管理…", action: #selector(rimeDictionaryPressed), keyEquivalent: "")
        dictionary.target = self
        menu.addItem(dictionary)
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsPressed), keyEquivalent: ",")
        settings.target = self
        let record = NSMenuItem(title: "开始录音", action: #selector(toggleRecordingPressed), keyEquivalent: "")
        record.target = self
        menu.addItem(settings)
        menu.addItem(record)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
        stateMenuItem = state
        usageMenuItem = usage
        settingsMenuItem = settings
        recordMenuItem = record
        rimeThemeMenuItem = rimeTheme
    }

    func update(status: String) {
        statusText = status
        stateMenuItem?.title = status
        let isIdle = status.contains("就绪")
        let isStopping = status.contains("收尾中")
        recordMenuItem?.title = isStopping
            ? "收尾中…"
            : (isIdle ? "开始录音" : "停止录音")
        recordMenuItem?.isEnabled = !isStopping
    }

    func update(usage: String) {
        usageMenuItem?.title = usage
    }

    func configure(
        onSettings: @escaping () -> Void,
        onToggleRecording: @escaping () -> Void,
        onSelectRimeTheme: @escaping (String) -> Void,
        onManageRimeDictionary: @escaping () -> Void
    ) {
        self.onSettings = onSettings
        self.onToggleRecording = onToggleRecording
        self.onSelectRimeTheme = onSelectRimeTheme
        self.onManageRimeDictionary = onManageRimeDictionary
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

    func uninstall() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        stateMenuItem = nil
        usageMenuItem = nil
        settingsMenuItem = nil
        recordMenuItem = nil
        rimeThemeMenuItem = nil
        onSettings = nil
        onToggleRecording = nil
        onSelectRimeTheme = nil
        onManageRimeDictionary = nil
    }
}
