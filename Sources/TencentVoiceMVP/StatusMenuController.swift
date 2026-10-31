import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private(set) var statusItem: NSStatusItem?
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
    private var onToggleFailureContext: (() -> Void)?
    private var onReportInputFailure: (() -> Void)?
    private var onOpenFailureReports: (() -> Void)?
    private var failureContextMenuItem: NSMenuItem?
    private var failureResultMenuItem: NSMenuItem?
    private var archiveMenuItems: [NSMenuItem] = []
    private var displayRefreshTimer: Timer?
    private var snapshotProvider: (() -> RecordingDisplaySnapshot?)?
    private var sessionState: SessionState = .idle
    private var displaySnapshot: RecordingDisplaySnapshot?
    private var statusFeedback: String?
    private var waveformDisplayModel = WaveformDisplayModel()
    private let monotonicClock: () -> UInt64
    private let applicationStatusImageURL: URL?
    private(set) var menuBarDisplayMode: MenuBarDisplayMode = .defaultMode
    private(set) var statusButtonTitle = ""
    private(set) var statusButtonToolTip = "Rime Voice"
    private(set) var statusButtonAccessibilityLabel = "Rime Voice"
    private(set) var statusButtonWaveformLevels = Array(repeating: 0.0, count: 5)
    private(set) var statusButtonImageStyle: StatusButtonImageStyle = .application
    private(set) var statusText = "就绪"
    private(set) var installedMenu: NSMenu?

    init(
        monotonicClock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        applicationStatusImageURL: URL? = Bundle.main.url(forResource: "statusbar-matched", withExtension: "png")
    ) {
        self.monotonicClock = monotonicClock
        self.applicationStatusImageURL = applicationStatusImageURL
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }

        waveformDisplayModel.reset()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = ""
        item.button?.image = statusImage(for: .application)
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.setAccessibilityLabel("Rime Voice")
        item.button?.toolTip = "Rime Voice"

        item.menu = makeMenu()
        statusItem = item
        if let snapshotProvider {
            displaySnapshot = snapshotProvider()
        }
        updateRecordMenuItem()
        renderStatusButton()
        updateDisplayRefreshTimer()
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
        menu.addItem(.separator())
        let context = NSMenuItem(title: "记录浏览器与 Codex 故障前操作", action: #selector(toggleFailureContextPressed), keyEquivalent: "")
        context.target = self
        context.toolTip = "保留开启期间的语音识别、目标输入框完整文字及操作证据；容量不足会明确报告遗漏。持久化由设置页日志开关控制；不录音、不截图、不自动上传。"
        menu.addItem(context)
        let failure = NSMenuItem(title: "报告输入失效", action: #selector(reportInputFailurePressed), keyEquivalent: "")
        failure.target = self
        failure.toolTip = "保存最近一分钟的操作场记和输入诊断日志到本机；请提前启用操作记录。"
        menu.addItem(failure)
        let result = NSMenuItem(title: "报告保存在本机诊断目录", action: nil, keyEquivalent: "")
        result.isEnabled = false
        menu.addItem(result)
        let openReports = NSMenuItem(title: "打开失效报告目录", action: #selector(openFailureReportsPressed), keyEquivalent: "")
        openReports.target = self
        menu.addItem(openReports)
        failureContextMenuItem = context
        failureResultMenuItem = result
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
        if status.hasPrefix("错误：") || status.hasPrefix("无法开始录音：") {
            statusFeedback = status
        } else {
            statusFeedback = nil
        }
        renderStatusButton()
    }

    func configureRecordingDisplay(snapshotProvider: @escaping () -> RecordingDisplaySnapshot?) {
        self.snapshotProvider = snapshotProvider
        displaySnapshot = snapshotProvider()
        renderStatusButton()
        updateDisplayRefreshTimer()
    }

    func update(menuBarDisplayMode: MenuBarDisplayMode) {
        guard self.menuBarDisplayMode != menuBarDisplayMode else { return }
        self.menuBarDisplayMode = menuBarDisplayMode
        waveformDisplayModel.reset()
        if let snapshotProvider {
            displaySnapshot = snapshotProvider()
        }
        renderStatusButton()
        updateDisplayRefreshTimer()
    }

    func update(recordingState: SessionState) {
        let changed = sessionState != recordingState
        sessionState = recordingState
        if changed {
            switch recordingState {
            case .idle, .recovering, .stopping, .error:
                waveformDisplayModel.reset()
            case .connecting, .listening:
                break
            }
        }
        if let snapshotProvider {
            displaySnapshot = snapshotProvider()
        }
        updateRecordMenuItem()
        renderStatusButton()
        updateDisplayRefreshTimer()
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
        onImportRimeConfiguration: @escaping () -> Void,
        onToggleFailureContext: @escaping () -> Void = {},
        onReportInputFailure: @escaping () -> Void = {},
        onOpenFailureReports: @escaping () -> Void = {}
    ) {
        self.onSettings = onSettings
        self.onCalibrateUsage = onCalibrateUsage
        self.onToggleRecording = onToggleRecording
        self.onToggleAutoStart = onToggleAutoStart
        self.onSelectRimeTheme = onSelectRimeTheme
        self.onManageRimeDictionary = onManageRimeDictionary
        self.onExportRimeConfiguration = onExportRimeConfiguration
        self.onImportRimeConfiguration = onImportRimeConfiguration
        self.onToggleFailureContext = onToggleFailureContext
        self.onReportInputFailure = onReportInputFailure
        self.onOpenFailureReports = onOpenFailureReports
    }

    func update(failureContextEnabled: Bool) {
        failureContextMenuItem?.state = failureContextEnabled ? .on : .off
    }

    func update(failureReportResult: String, path: String? = nil) {
        failureResultMenuItem?.title = failureReportResult
        failureResultMenuItem?.toolTip = path
    }

    @objc private func toggleFailureContextPressed() { onToggleFailureContext?() }
    @objc private func reportInputFailurePressed() { onReportInputFailure?() }
    @objc private func openFailureReportsPressed() { onOpenFailureReports?() }

    private func updateRecordMenuItem() {
        let isStopping: Bool
        switch sessionState {
        case .idle, .error:
            recordMenuItem?.title = "开始录音"
            isStopping = false
        case .connecting, .listening, .recovering:
            recordMenuItem?.title = "停止录音"
            isStopping = false
        case .stopping:
            recordMenuItem?.title = "收尾中…"
            isStopping = true
        }
        recordMenuItem?.isEnabled = !isStopping
    }

    private func updateDisplayRefreshTimer() {
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
        guard statusItem != nil else { return }

        let interval: TimeInterval?
        let currentState = displaySnapshot?.state ?? sessionState
        let isCapturing = displaySnapshot?.isCapturing ?? false
        switch (menuBarDisplayMode, currentState, isCapturing) {
        case (.timer, .connecting, true), (.timer, .listening, true),
             (.timer, .recovering, true), (.timer, .stopping, true):
            interval = 0.25
        case (.waveform, .connecting, true), (.waveform, .listening, true),
             (.waveform, .recovering, true), (.waveform, .stopping, true):
            interval = 1.0 / 30
        default:
            interval = nil
        }
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDisplaySnapshot()
            }
        }
        displayRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshDisplaySnapshot() {
        guard let snapshot = snapshotProvider?() else { return }
        let stateChanged = sessionState != snapshot.state
        let sessionChanged = displaySnapshot?.sessionID != snapshot.sessionID
        let captureChanged = displaySnapshot?.isCapturing != snapshot.isCapturing
        if stateChanged {
            sessionState = snapshot.state
            updateRecordMenuItem()
        }
        if sessionChanged {
            waveformDisplayModel.reset()
        }
        displaySnapshot = snapshot
        renderStatusButton()
        if stateChanged || sessionChanged || captureChanged {
            updateDisplayRefreshTimer()
        }
    }

    private func renderStatusButton() {
        let snapshot = displaySnapshot ?? RecordingDisplaySnapshot(
            sessionID: nil,
            state: sessionState,
            audio: .empty
        )
        let presentation = StatusButtonPresentation.make(
            mode: menuBarDisplayMode,
            state: snapshot.state,
            isCapturing: snapshot.isCapturing,
            duration: snapshot.audio.durationSeconds,
            statusFeedback: statusFeedback
        )
        statusButtonTitle = presentation.title
        statusButtonToolTip = presentation.toolTip
        statusButtonAccessibilityLabel = presentation.accessibilityLabel
        statusButtonImageStyle = presentation.imageStyle

        if presentation.imageStyle == .waveform {
            statusButtonWaveformLevels = waveformDisplayModel.update(snapshot: snapshot, now: monotonicClock())
        } else {
            waveformDisplayModel.reset()
            statusButtonWaveformLevels = Array(repeating: 0, count: 5)
        }

        guard let button = statusItem?.button else { return }
        // Recording styles share one image canvas. The idle application image
        // keeps its original resource, size and native image-only rendering.
        button.title = ""
        button.image = statusImage(for: presentation.imageStyle)
        button.imagePosition = .imageOnly
        button.toolTip = presentation.toolTip
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        if presentation.imageStyle == .timer, let image = button.image {
            // Keep the original square item's side margins; only the visible
            // timer content needs more room than the original 18-point icon.
            let nativeWidth = NSStatusBar.system.thickness
            let horizontalPadding = max(0, nativeWidth - 18)
            statusItem?.length = max(nativeWidth, image.size.width + horizontalPadding)
        } else {
            statusItem?.length = NSStatusItem.squareLength
        }
    }

    static func formattedDuration(_ duration: Double) -> String {
        RecordingDurationFormatter.string(from: duration)
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
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
        snapshotProvider = nil
        removeStatusItem()
        onSettings = nil
        onToggleRecording = nil
        onToggleAutoStart = nil
        onSelectRimeTheme = nil
        onManageRimeDictionary = nil
        onExportRimeConfiguration = nil
        onImportRimeConfiguration = nil
        onToggleFailureContext = nil
        onReportInputFailure = nil
        onOpenFailureReports = nil
    }

    private func removeStatusItem() {
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
        waveformDisplayModel.reset()
        statusButtonWaveformLevels = Array(repeating: 0, count: 5)
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
        failureContextMenuItem = nil
        failureResultMenuItem = nil
    }

    private func statusImage(for style: StatusButtonImageStyle) -> NSImage? {
        switch style {
        case .application:
            return applicationStatusImage()
        case .recording:
            return recordingImage()
        case .timer:
            return recordingTimerImage(title: statusButtonTitle)
        case .waveform:
            return waveformImage()
        }
    }

    private func recordingImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSColor.systemRed.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
        ring.lineWidth = 1.6
        ring.stroke()
        NSBezierPath(ovalIn: NSRect(x: 5.4, y: 5.4, width: 7.2, height: 7.2)).fill()
        image.unlockFocus()
        // A template image loses its red recording cue in the macOS menu bar.
        image.isTemplate = false
        return image
    }

    private func recordingTimerImage(title: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let dot = NSImage(size: NSSize(width: 6, height: 6))
        dot.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 6, height: 6)).fill()
        dot.unlockFocus()
        dot.isTemplate = false
        let attachment = NSTextAttachment()
        attachment.image = dot
        // Share the text baseline and center the dot on the visible digit height.
        // Native attributed text handles light/dark colors and drawing direction.
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - 6) / 2, width: 6, height: 6)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: "\u{2002}" + title))
        text.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: text.length))
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 18))
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            text.draw(at: NSPoint(x: (image.size.width - size.width) / 2, y: (image.size.height - size.height) / 2))
            image.unlockFocus()
        }
        return verticallyCenteredImage(image)
    }

    private func verticallyCenteredImage(_ image: NSImage) -> NSImage {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return image }
        var minY = bitmap.pixelsHigh
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxY >= minY else { return image }
        let scale = CGFloat(bitmap.pixelsHigh) / image.size.height
        let center = image.size.height - CGFloat(minY + maxY + 1) / (2 * scale)
        let centered = NSImage(size: image.size)
        centered.lockFocus()
        image.draw(at: NSPoint(x: 0, y: image.size.height / 2 - center), from: .zero, operation: .sourceOver, fraction: 1)
        centered.unlockFocus()
        centered.isTemplate = image.isTemplate
        return centered
    }

    private func applicationStatusImage() -> NSImage {
        if let url = applicationStatusImageURL,
           let image = NSImage(contentsOfFile: url.path) {
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

    private func waveformImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let levels = statusButtonWaveformLevels.map { min(1, max(0, $0)) }
        let width = 2.4
        NSColor.white.setFill()
        for index in 0..<5 {
            // Silence still shows a solid baseline: the microphone is live even
            // when there is no sound. Only height follows the measured volume.
            let height = 3 + 13 * levels[index]
            let x = 9 + Double(index - 2) * 3.4 - width / 2
            NSBezierPath(
                roundedRect: NSRect(x: x, y: (18 - height) / 2, width: width, height: height),
                xRadius: width / 2,
                yRadius: width / 2
            ).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

}
