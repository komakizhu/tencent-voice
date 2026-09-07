import AppKit
import Carbon.HIToolbox

@MainActor
final class DelayedHelpStackView: NSStackView, NSPopoverDelegate {
    static let helpDelay: TimeInterval = 1.5

    private let helpText: String
    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?
    private var popover: NSPopover?
    private var isPointerInside = false

    init(contentView: NSView, helpText: String) {
        self.helpText = helpText
        super.init(frame: .zero)
        addArrangedSubview(contentView)
        contentView.setAccessibilityHelp(helpText)
        setAccessibilityHelp(helpText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.helpDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPointerInside else { return }
                self.presentHelpPopover()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        dismissHelpPopover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dismissHelpPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    private func presentHelpPopover() {
        guard popover == nil, let window, window.isVisible else { return }

        let label = NSTextField(wrappingLabelWithString: helpText)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 280
        label.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])

        let viewController = NSViewController()
        viewController.view = contentView
        viewController.preferredContentSize = NSSize(width: 310, height: 78)

        let popover = NSPopover()
        popover.contentViewController = viewController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func dismissHelpPopover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        popover?.performClose(nil)
        popover = nil
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private enum DirectoryTarget: Int {
        case sessionLogs
        case diagnosticReports

        var displayName: String {
            switch self {
            case .sessionLogs: return "会话日志目录"
            case .diagnosticReports: return "诊断报告目录"
            }
        }

        var buttonTitle: String {
            switch self {
            case .sessionLogs: return "打开日志目录"
            case .diagnosticReports: return "打开诊断目录"
            }
        }

        var diagnosticEventName: String {
            switch self {
            case .sessionLogs: return "session_log_directory_opened"
            case .diagnosticReports: return "diagnostic_directory_opened"
            }
        }
    }

    private let appIDField = NSTextField()
    private let secretIDField = NSTextField()
    private let secretKeyField = NSSecureTextField()
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let prepaidHoursPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let logCheckbox = NSButton(checkboxWithTitle: "自动保存诊断日志", target: nil, action: nil)
    private let safeCopyCheckbox = NSButton(
        checkboxWithTitle: "Safe Copy（始终复制到剪贴板）",
        target: nil,
        action: nil
    )
    private let hideMenuBarIconCheckbox = NSButton(
        checkboxWithTitle: "隐藏菜单栏图标",
        target: nil,
        action: nil
    )
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: AppVersion.displayText)
    private let statusLabel = NSTextField(labelWithString: "凭证优先保存在本机 YAML")
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let exportDiagnosticLogButton = NSButton(title: "导出诊断报告", target: nil, action: nil)
    private let permissionResetButton = NSButton(title: "重置并重新授权", target: nil, action: nil)
    private let permissionRowsStack = NSStackView()
    private let logDirectoryURL: URL
    private let diagnosticDirectoryURL: URL
    private let onOpenDirectory: ((URL) -> Bool)?
    private let onSave: (AppSettings, TencentCredentials) throws -> Void
    private let onTestConnection: ((TencentCredentials, String) async throws -> Void)?
    private let onExportDiagnosticLog: (() throws -> URL?)?
    private let onRecordDiagnosticAction: ((String, [String: String]) -> Void)?
    private let permissionChecker: PrivacyPermissionChecking
    private let onClose: () -> Void
    private var currentShortcut: Shortcut
    private var displayedEngineModelType: String
    private var prepaidQuotaHoursByModel: [String: Int]
    private var storedCredentials: TencentCredentials?
    private var localMonitor: Any?
    private var testTask: Task<Void, Never>?
    private var permissionStateLabels: [PrivacyPermission: NSTextField] = [:]
    private var permissionRefreshPending = false
    private var permissionGuideWindowController: PermissionSetupGuideWindowController?
    private let onPermissionResetRestart: (() -> Void)?

    init(
        settings: AppSettings,
        credentials: TencentCredentials?,
        onSave: @escaping (AppSettings, TencentCredentials) throws -> Void,
        onTestConnection: ((TencentCredentials, String) async throws -> Void)? = nil,
        onExportDiagnosticLog: (() throws -> URL?)? = nil,
        onRecordDiagnosticAction: ((String, [String: String]) -> Void)? = nil,
        permissionChecker: PrivacyPermissionChecking? = nil,
        logDirectoryURL: URL? = nil,
        diagnosticDirectoryURL: URL? = nil,
        onOpenDirectory: ((URL) -> Bool)? = nil,
        onPermissionResetRestart: (() -> Void)? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 830),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rime Voice 设置"
        self.onSave = onSave
        self.onTestConnection = onTestConnection
        self.onExportDiagnosticLog = onExportDiagnosticLog
        self.onRecordDiagnosticAction = onRecordDiagnosticAction
        self.permissionChecker = permissionChecker ?? SystemPrivacyPermissionChecker()
        self.logDirectoryURL = logDirectoryURL ?? SessionLogger.defaultPersistenceDirectoryURL
        self.diagnosticDirectoryURL = diagnosticDirectoryURL
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        self.onOpenDirectory = onOpenDirectory
        self.onClose = onClose
        self.onPermissionResetRestart = onPermissionResetRestart
        currentShortcut = settings.shortcut
        let selectedPreset = TencentEnginePreset(persistedModelType: settings.engineModelType)
        displayedEngineModelType = selectedPreset.rawValue
        prepaidQuotaHoursByModel = settings.prepaidQuotaHoursByModel
        storedCredentials = credentials
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        appIDField.stringValue = credentials?.appID ?? ""
        secretIDField.stringValue = credentials?.secretID ?? ""
        secretKeyField.stringValue = credentials?.secretKey ?? ""
        statusLabel.stringValue = credentials == nil
            ? "凭证保存在本机共享目录（明文）"
            : "已读取本机共享凭证；两个 macOS 账户可共用"
        for preset in TencentEnginePreset.allCases {
            enginePopup.addItem(withTitle: preset.displayName)
            enginePopup.lastItem?.representedObject = preset.rawValue
        }
        enginePopup.selectItem(at: TencentEnginePreset.allCases.firstIndex(of: selectedPreset) ?? 0)
        enginePopup.target = self
        enginePopup.action = #selector(engineSelectionChanged)
        prepaidHoursPopup.target = self
        prepaidHoursPopup.action = #selector(prepaidHoursChanged)
        rebuildPrepaidHoursPopup()
        logCheckbox.state = settings.saveTextLogs ? .on : .off
        safeCopyCheckbox.state = settings.safeCopyEnabled ? .on : .off
        hideMenuBarIconCheckbox.state = settings.hideMenuBarIcon ? .on : .off
        shortcutLabel.stringValue = ShortcutFormatter.string(for: currentShortcut)
        buildView()
        refreshPermissionReport()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        permissionGuideWindowController?.close()
        permissionGuideWindowController = nil
        stopShortcutCapture()
        testTask?.cancel()
        testTask = nil
        onClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard permissionRefreshPending else { return }
        permissionRefreshPending = false
        let report = refreshPermissionReport()
        if report.allGranted {
            statusLabel.stringValue = "权限已全部恢复，可以开始录音。"
        } else {
            statusLabel.stringValue = "仍缺少：\(report.missing.map(\.title).joined(separator: "、"))；请继续开启后回到这里。"
        }
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        let logRow = diagnosticLogRow()
        let fields = NSStackView(views: [
            labeled(
                "AppID",
                view: appIDField,
                toolTip: "腾讯云账号的 AppID，用于识别你的腾讯云账号。"
            ),
            labeled(
                "SecretId",
                view: secretIDField,
                toolTip: "腾讯云 API 凭证的 SecretId，与 SecretKey 配合调用语音识别。"
            ),
            labeled(
                "SecretKey",
                view: secretKeyField,
                toolTip: "腾讯云 API 凭证的 SecretKey，只用于生成请求签名，不会写入诊断日志。"
            ),
            labeled(
                "识别引擎",
                view: enginePopup,
                toolTip: "选择腾讯云实时语音识别模型；切换模型会使用该模型的独立用量额度。"
            ),
            labeled(
                "已充值时长（当前模型）",
                view: prepaidHoursPopup,
                toolTip: "设置当前模型的已充值时长，用于计算菜单栏用量百分比；修改后点击“保存设置”。"
            ),
            testButton,
            safeCopyRow(),
            logRow,
            hideMenuBarIconCheckbox,
            storageSection()
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 10
        fields.translatesAutoresizingMaskIntoConstraints = false

        let shortcutButton = NSButton(title: "重新录制", target: self, action: #selector(captureShortcut))
        shortcutLabel.toolTip = "当前用于开始或停止录音的全局快捷键。"
        shortcutButton.toolTip = "录制新的全局快捷键；选择后点击“保存设置”生效。"
        let shortcutRow = NSStackView(views: [
            NSTextField(labelWithString: "快捷键"), shortcutLabel, shortcutButton
        ])
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 10

        let saveButton = NSButton(title: "保存设置", target: self, action: #selector(saveButtonPressed))
        saveButton.keyEquivalent = "\r"
        testButton.target = self
        testButton.action = #selector(testConnectionPressed)
        testButton.isEnabled = onTestConnection != nil
        testButton.toolTip = "使用当前填写的凭证和识别引擎发起握手测试；不会录音或输入文字。"
        exportDiagnosticLogButton.target = self
        exportDiagnosticLogButton.action = #selector(exportDiagnosticLogPressed)
        exportDiagnosticLogButton.isEnabled = onExportDiagnosticLog != nil
        exportDiagnosticLogButton.toolTip = "将自动保存的会话与诊断事件导出为诊断报告 JSON；不会导出密钥、录音或识别正文。"
        safeCopyCheckbox.toolTip = "开启后始终把识别结果复制到剪贴板；关闭后只按正常方式输入。"
        logCheckbox.toolTip = "开启后自动保存会话状态、错误代码和操作上下文；点击右侧“导出诊断报告”导出已保存内容。"
        hideMenuBarIconCheckbox.toolTip = "隐藏状态栏图标；隐藏后可从 Dock 中 Rime Voice 的应用菜单重新打开设置。"
        saveButton.toolTip = "保存腾讯云凭证和设置；日志开关、Safe Copy 与快捷键也在此生效。"
        permissionResetButton.target = self
        permissionResetButton.action = #selector(resetPermissionsPressed)
        permissionResetButton.toolTip = "清除 Rime Voice 的全部 macOS 权限记录，打开隐私设置，从头重新授权。"
        statusLabel.toolTip = "显示当前设置页操作、权限、连接测试、快捷键和导出结果。"
        versionLabel.toolTip = "显示当前应用版本和构建号。"
        let buttons = NSStackView(views: [statusLabel, NSView(), saveButton])
        buttons.distribution = .fill
        buttons.alignment = .centerY
        buttons.spacing = 8
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        let permissionView = buildPermissionView()
        let content = NSStackView(views: [versionLabel, fields, shortcutRow, permissionView, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            fields.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            fields.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            logRow.widthAnchor.constraint(equalTo: fields.widthAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: permissionView.trailingAnchor)
        ])
        versionLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        saveButton.setAccessibilityLabel("保存设置")
    }

    private func buildPermissionView() -> NSView {
        let title = NSTextField(labelWithString: "系统权限（当前 macOS 账户）")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.toolTip = "下面列出的权限用于录音、识别结果输入和全局快捷键。"
        let titleRow = NSStackView(views: [title, NSView(), permissionResetButton])
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.widthAnchor.constraint(equalToConstant: 452).isActive = true

        permissionRowsStack.orientation = .vertical
        permissionRowsStack.alignment = .leading
        permissionRowsStack.spacing = 6
        permissionRowsStack.translatesAutoresizingMaskIntoConstraints = false

        for permission in PrivacyPermission.allCases {
            let name = NSTextField(labelWithString: "\(permission.title)：")
            name.toolTip = "\(permission.title)：\(permission.purpose)。"
            name.setContentHuggingPriority(.required, for: .horizontal)
            name.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let state = NSTextField(labelWithString: "未检查")
            state.toolTip = "当前\(permission.title)权限状态；若未允许，请点击右侧“打开设置”。"
            state.setContentHuggingPriority(.required, for: .horizontal)
            state.widthAnchor.constraint(equalToConstant: 82).isActive = true
            permissionStateLabels[permission] = state

            let openButton = NSButton(
                title: "打开设置",
                target: self,
                action: #selector(openPermissionSettingsPressed(_:))
            )
            openButton.tag = permission.rawValue
            openButton.toolTip = "打开 macOS“隐私与安全性”中的\(permission.title)设置；用途：\(permission.purpose)。"

            let row = NSStackView(views: [name, state, NSView(), openButton])
            row.alignment = .centerY
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 452).isActive = true
            permissionRowsStack.addArrangedSubview(row)
        }

        let view = NSStackView(views: [titleRow, permissionRowsStack])
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func safeCopyRow() -> NSView {
        let row = DelayedHelpStackView(
            contentView: safeCopyCheckbox,
            helpText: "正常输出到输入框，并在会话结束时同步复制最终识别结果；发生输入错误时作为回退；保存后生效"
        )
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func diagnosticLogRow() -> NSView {
        let row = NSStackView(views: [logCheckbox, NSView(), exportDiagnosticLogButton])
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        exportDiagnosticLogButton.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func storageSection() -> NSView {
        let title = NSTextField(labelWithString: "数据位置")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let rows = NSStackView(views: [
            storageRow(title: "会话日志目录", url: logDirectoryURL, target: .sessionLogs),
            storageRow(title: "诊断报告目录", url: diagnosticDirectoryURL, target: .diagnosticReports)
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6

        let section = NSStackView(views: [title, rows])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        section.translatesAutoresizingMaskIntoConstraints = false
        return section
    }

    private func storageRow(title: String, url: URL, target: DirectoryTarget) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let pathLabel = NSTextField(labelWithString: displayPath(for: url))
        pathLabel.isSelectable = true
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let openButton = NSButton(
            title: target.buttonTitle,
            target: self,
            action: #selector(openDirectoryPressed(_:))
        )
        openButton.tag = target.rawValue
        openButton.setAccessibilityLabel(target.buttonTitle)
        openButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [titleLabel, pathLabel, openButton])
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 452).isActive = true
        return row
    }

    private func displayPath(for url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    @objc private func resetPermissionsPressed() {
        let didReset = permissionChecker.resetPermissions()
        onRecordDiagnosticAction?("permissions_reset_requested", [
            "succeeded": String(didReset)
        ])
        guard didReset else {
            let report = refreshPermissionReport()
            statusLabel.stringValue = report.allGranted
                ? "无法重置权限；当前权限仍可用。"
                : "无法自动重置权限，请退出应用后重试。"
            return
        }

        // A fresh process is required after TCC reset: permission APIs may cache results.
        if let onPermissionResetRestart {
            onPermissionResetRestart()
            return
        }
        if !Self.relaunchForPermissionSetup() {
            statusLabel.stringValue = "授权记录已重置，但自动重启失败。请退出后重新打开 Rime Voice。"
        }
    }

    static func relaunchForPermissionSetup() -> Bool {
        UserDefaults.standard.set(true, forKey: "resumePermissionSetup")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -g \"$2\"", "rime-voice-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try relaunch.run()
            NSApp.terminate(nil)
            return true
        } catch {
            UserDefaults.standard.removeObject(forKey: "resumePermissionSetup")
            return false
        }
    }

    func resumePermissionSetup() {
        permissionRefreshPending = true
        for permission in PrivacyPermission.allCases {
            permissionStateLabels[permission]?.stringValue = "待重新授权"
            permissionStateLabels[permission]?.textColor = .systemRed
        }

        permissionGuideWindowController?.close()
        permissionGuideWindowController = PermissionSetupGuideWindowController(
            permissionChecker: permissionChecker,
            onFinished: { [weak self] in
                guard let self else { return }
                permissionGuideWindowController = nil
                permissionRefreshPending = false
                let report = refreshPermissionReport()
                statusLabel.stringValue = report.allGranted
                    ? "权限已全部恢复，可以开始录音。"
                    : "权限向导已结束；仍缺少：\(report.missing.map(\.title).joined(separator: "、"))。"
            }
        )
        permissionGuideWindowController?.showWindow(nil)
        permissionGuideWindowController?.window?.center()
        statusLabel.stringValue = "已重新启动并检测授权。已生效的步骤会自动通过。"
    }

    @objc private func openPermissionSettingsPressed(_ sender: NSButton) {
        guard let permission = PrivacyPermission(rawValue: sender.tag) else { return }
        onRecordDiagnosticAction?("permission_settings_open_requested", [
            "permission": String(permission.rawValue)
        ])
        if permissionChecker.openSettings(for: permission) {
            permissionRefreshPending = true
            statusLabel.stringValue = "已打开“\(permission.title)”设置；开启后回到这里会自动刷新状态。"
        } else {
            statusLabel.stringValue = "无法自动打开系统设置，请手动进入“隐私与安全性”"
        }
    }

    @discardableResult
    private func refreshPermissionReport() -> PrivacyPermissionReport {
        let report = permissionChecker.report()
        for status in report.statuses {
            permissionStateLabels[status.permission]?.stringValue = status.detail
            permissionStateLabels[status.permission]?.textColor = status.isGranted
                ? .systemGreen
                : .systemRed
        }
        return report
    }

    private func labeled(_ title: String, view: NSView, toolTip: String) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.toolTip = toolTip
        if let field = view as? NSTextField {
            field.placeholderString = title
        }
        let label = NSTextField(labelWithString: title)
        label.toolTip = toolTip
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, view])
        row.spacing = 10
        row.alignment = .centerY
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        return row
    }

    @objc private func captureShortcut() {
        guard localMonitor == nil else { return }
        statusLabel.stringValue = "请按下新的功能键或组合键…"
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = CarbonHotkeyManager.carbonModifiers(from: event.modifierFlags)
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            guard ShortcutValidator.isAllowed(shortcut) else {
                self.statusLabel.stringValue = "不能使用裸字母，请按功能键或带修饰键的组合"
                return nil
            }
            self.currentShortcut = shortcut
            self.shortcutLabel.stringValue = ShortcutFormatter.string(for: shortcut)
            self.onRecordDiagnosticAction?("shortcut_selected", [
                "shortcut": ShortcutFormatter.string(for: shortcut)
            ])
            self.statusLabel.stringValue = "快捷键已选择，保存后生效"
            self.stopShortcutCapture()
            return nil
        }
    }

    @objc private func saveButtonPressed() {
        persistSelectedPrepaidHours()
        guard let credentials = credentialsFromFields() else { return }

        let settings = AppSettings(
            shortcut: currentShortcut,
            engineModelType: enginePopup.selectedItem?.representedObject as? String
                ?? TencentEnginePreset.defaultPreset.rawValue,
            saveTextLogs: logCheckbox.state == .on,
            safeCopyEnabled: safeCopyCheckbox.state == .on,
            hideMenuBarIcon: hideMenuBarIconCheckbox.state == .on,
            prepaidQuotaHoursByModel: prepaidQuotaHoursByModel
        )
        do {
            try onSave(settings, credentials)
            storedCredentials = credentials
            onRecordDiagnosticAction?("settings_saved", [
                "engineModelType": settings.engineModelType,
                "saveTextLogs": String(settings.saveTextLogs),
                "safeCopyEnabled": String(settings.safeCopyEnabled),
                "hideMenuBarIcon": String(settings.hideMenuBarIcon)
            ])
            statusLabel.stringValue = "设置已保存"
        } catch {
            onRecordDiagnosticAction?("settings_save_failed", [
                "errorCode": DiagnosticErrorFormatter.code(for: error),
                "errorMessage": DiagnosticErrorFormatter.message(for: error)
            ])
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }

    @objc private func openDirectoryPressed(_ sender: NSButton) {
        guard let target = DirectoryTarget(rawValue: sender.tag) else { return }
        let url: URL = switch target {
        case .sessionLogs: logDirectoryURL
        case .diagnosticReports: diagnosticDirectoryURL
        }

        let opened: Bool
        if let onOpenDirectory {
            opened = onOpenDirectory(url)
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
                opened = NSWorkspace.shared.open(url)
            } catch {
                statusLabel.stringValue = "无法准备\(target.displayName)：\(error.localizedDescription)"
                return
            }
        }

        onRecordDiagnosticAction?(target.diagnosticEventName, [:])
        statusLabel.stringValue = opened
            ? "已打开\(target.displayName)：\(displayPath(for: url))"
            : "无法打开\(target.displayName)，路径为：\(url.path)"
    }

    @objc private func testConnectionPressed() {
        guard testTask == nil else { return }
        guard let onTestConnection else {
            statusLabel.stringValue = "当前版本不支持连接测试"
            return
        }
        guard let credentials = credentialsFromFields() else { return }

        let model = selectedEngineModelType
        onRecordDiagnosticAction?("connection_test_started", ["engineModelType": model])
        testButton.isEnabled = false
        statusLabel.stringValue = "正在握手测试（不会录音）…"
        testTask = Task { [weak self] in
            defer {
                self?.testButton.isEnabled = true
                self?.testTask = nil
            }
            do {
                try await onTestConnection(credentials, model)
                guard !Task.isCancelled else { return }
                self?.onRecordDiagnosticAction?("connection_test_finished", [
                    "engineModelType": model,
                    "result": "success"
                ])
                self?.statusLabel.stringValue = "连接成功：凭证和当前引擎可用"
            } catch {
                guard !Task.isCancelled else { return }
                self?.onRecordDiagnosticAction?("connection_test_finished", [
                    "engineModelType": model,
                    "result": "failure",
                    "errorCode": DiagnosticErrorFormatter.code(for: error),
                    "errorMessage": DiagnosticErrorFormatter.message(for: error)
                ])
                self?.statusLabel.stringValue = "连接失败：\(error.localizedDescription)"
            }
            self?.testButton.isEnabled = true
            self?.testTask = nil
        }
    }

    @objc private func exportDiagnosticLogPressed() {
        guard let onExportDiagnosticLog else {
            statusLabel.stringValue = "当前版本不支持导出诊断报告"
            return
        }

        onRecordDiagnosticAction?("diagnostic_log_export_requested", [:])
        do {
            if let url = try onExportDiagnosticLog() {
                statusLabel.stringValue = "诊断报告已导出：\(url.lastPathComponent)"
            } else {
                statusLabel.stringValue = "已取消导出"
            }
        } catch {
            statusLabel.stringValue = "诊断报告导出失败：\(error.localizedDescription)"
        }
    }

    private func credentialsFromFields() -> TencentCredentials? {
        let appID = appIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretID = secretIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = secretKeyField.stringValue.isEmpty
            ? (storedCredentials?.secretKey ?? "")
            : secretKeyField.stringValue
        guard !appID.isEmpty, !secretID.isEmpty, !secretKey.isEmpty else {
            onRecordDiagnosticAction?("credentials_validation_failed", [:])
            statusLabel.stringValue = "请填写完整的 AppID、SecretId 和 SecretKey"
            return nil
        }
        return TencentCredentials(appID: appID, secretID: secretID, secretKey: secretKey)
    }

    private func stopShortcutCapture() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    @objc private func engineSelectionChanged() {
        persistSelectedPrepaidHours(for: displayedEngineModelType)
        displayedEngineModelType = selectedEngineModelType
        rebuildPrepaidHoursPopup()
        onRecordDiagnosticAction?("engine_selected", ["engineModelType": displayedEngineModelType])
    }

    @objc private func prepaidHoursChanged() {
        persistSelectedPrepaidHours()
        onRecordDiagnosticAction?("prepaid_hours_selected", [
            "hours": String(prepaidHoursPopup.selectedItem?.tag ?? 0)
        ])
    }

    private func rebuildPrepaidHoursPopup() {
        prepaidHoursPopup.removeAllItems()
        prepaidHoursPopup.addItem(withTitle: "未设置（按当前模型默认额度）")
        prepaidHoursPopup.lastItem?.tag = 0

        var options = TencentUsageQuota.prepaidHourOptions
        let model = selectedEngineModelType
        if let savedHours = prepaidQuotaHoursByModel[model], savedHours > 0, !options.contains(savedHours) {
            options.append(savedHours)
            options.sort()
        }
        for hours in options {
            prepaidHoursPopup.addItem(withTitle: "\(hours) 小时")
            prepaidHoursPopup.lastItem?.tag = hours
        }

        let selectedHours = prepaidQuotaHoursByModel[model] ?? 0
        prepaidHoursPopup.selectItem(withTag: selectedHours)
    }

    private func persistSelectedPrepaidHours(for model: String? = nil) {
        let model = model ?? selectedEngineModelType
        let hours = prepaidHoursPopup.selectedItem?.tag ?? 0
        if hours > 0 {
            prepaidQuotaHoursByModel[model] = hours
        } else {
            prepaidQuotaHoursByModel.removeValue(forKey: model)
        }
    }

    private var selectedEngineModelType: String {
        enginePopup.selectedItem?.representedObject as? String
            ?? TencentEnginePreset.defaultPreset.rawValue
    }
}

extension CarbonHotkeyManager {
    fileprivate static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
