import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var stateMenuItem: NSMenuItem?
    private var usageMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var onSettings: (() -> Void)?
    private var onToggleRecording: (() -> Void)?
    private(set) var statusText = "就绪"

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "语"

        let menu = NSMenu()
        let state = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let usage = NSMenuItem(title: "本地本月用量：计算中…", action: nil, keyEquivalent: "")
        usage.isEnabled = false
        menu.addItem(usage)
        menu.addItem(.separator())
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

    func configure(onSettings: @escaping () -> Void, onToggleRecording: @escaping () -> Void) {
        self.onSettings = onSettings
        self.onToggleRecording = onToggleRecording
    }

    @objc private func settingsPressed() {
        onSettings?()
    }

    @objc private func toggleRecordingPressed() {
        onToggleRecording?()
    }

    func uninstall() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        stateMenuItem = nil
        usageMenuItem = nil
        settingsMenuItem = nil
        recordMenuItem = nil
        onSettings = nil
        onToggleRecording = nil
    }
}
