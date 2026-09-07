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
    private let logCheckbox = NSButton(checkboxWithTitle: "保存会话日志", target: nil, action: nil)
    private let safeCopyCheckbox = NSButton(
        checkboxWithTitle: "Safe Copy（始终复制到剪贴板）",
        target: nil,
        action: nil
    )
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: AppVersion.displayText)
    private let statusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let diagnosticCheckbox = NSButton(checkboxWithTitle: "故障诊断记录", target: nil, action: nil)
    private let permissionCheckButton = NSButton(title: "检查权限", target: nil, action: nil)
    private let permissionRowsStack = NSStackView()
    private let logDirectoryURL: URL
    private let diagnosticDirectoryURL: URL
    private let onOpenDirectory: ((URL) -> Bool)?
    private let onSave: (AppSettings, TencentCredentials) throws -> Void
    private let onTestConnection: ((TencentCredentials, String) async throws -> Void)?
    private let onDiagnosticRecordingToggle: ((Bool) throws -> URL?)?
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

    init(
        settings: AppSettings,
        credentials: TencentCredentials?,
        onSave: @escaping (AppSettings, TencentCredentials) throws -> Void,
        onTestConnection: ((TencentCredentials, String) async throws -> Void)? = nil,
        onDiagnosticRecordingToggle: ((Bool) throws -> URL?)? = nil,
        diagnosticRecordingActive: Bool = false,
        onRecordDiagnosticAction: ((String, [String: String]) -> Void)? = nil,
        permissionChecker: PrivacyPermissionChecking? = nil,
        logDirectoryURL: URL? = nil,
        diagnosticDirectoryURL: URL? = nil,
        onOpenDirectory: ((URL) -> Bool)? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 790),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "腾讯语音输入设置"
        self.onSave = onSave
        self.onTestConnection = onTestConnection
        self.onDiagnosticRecordingToggle = onDiagnosticRecordingToggle
        self.onRecordDiagnosticAction = onRecordDiagnosticAction
        self.permissionChecker = permissionChecker ?? SystemPrivacyPermissionChecker()
        self.logDirectoryURL = logDirectoryURL ?? SessionLogger.defaultPersistenceDirectoryURL
        self.diagnosticDirectoryURL = diagnosticDirectoryURL
            ?? DiagnosticSessionRecorder.defaultExportDirectoryURL()
        self.onOpenDirectory = onOpenDirectory
        self.onClose = onClose
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
        diagnosticCheckbox.state = diagnosticRecordingActive ? .on : .off
        shortcutLabel.stringValue = ShortcutFormatter.string(for: currentShortcut)
        buildView()
        refreshPermissionReport()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        stopShortcutCapture()
        testTask?.cancel()
        testTask = nil
        onClose()
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        let fields = NSStackView(views: [
            labeled("AppID", view: appIDField),
            labeled("SecretId", view: secretIDField),
            labeled("SecretKey", view: secretKeyField),
            labeled("识别引擎", view: enginePopup),
            labeled("已充值时长（当前模型）", view: prepaidHoursPopup),
            testButton,
            safeCopyRow(),
            sessionLogRow(),
            diagnosticRow(),
            storageSection()
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 10
        fields.translatesAutoresizingMaskIntoConstraints = false

        let shortcutButton = NSButton(title: "重新录制", target: self, action: #selector(captureShortcut))
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
        diagnosticCheckbox.target = self
        diagnosticCheckbox.action = #selector(diagnosticRecordingToggled)
        diagnosticCheckbox.isEnabled = onDiagnosticRecordingToggle != nil
        permissionCheckButton.target = self
        permissionCheckButton.action = #selector(checkPermissionsPressed)
        let buttons = NSStackView(views: [statusLabel, NSView(), saveButton])
        buttons.alignment = .centerY
        buttons.spacing = 8

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
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        versionLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        saveButton.setAccessibilityLabel("保存设置")
    }

    private func buildPermissionView() -> NSView {
        let title = NSTextField(labelWithString: "系统权限")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let titleRow = NSStackView(views: [title, NSView(), permissionCheckButton])
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
            name.setContentHuggingPriority(.required, for: .horizontal)
            name.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let state = NSTextField(labelWithString: "未检查")
            state.setContentHuggingPriority(.required, for: .horizontal)
            state.widthAnchor.constraint(equalToConstant: 82).isActive = true
            permissionStateLabels[permission] = state

            let openButton = NSButton(
                title: "打开设置",
                target: self,
                action: #selector(openPermissionSettingsPressed(_:))
            )
            openButton.tag = permission.rawValue

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

    private func diagnosticRow() -> NSView {
        let row = DelayedHelpStackView(
            contentView: diagnosticCheckbox,
            helpText: "临时记录一次复现过程；结束后导出脱敏 JSON。与“保存会话日志”不同，它会记录更完整的设置、权限和操作上下文"
        )
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func sessionLogRow() -> NSView {
        let row = DelayedHelpStackView(
            contentView: logCheckbox,
            helpText: "持续保存会话状态、长度、计数和错误类型；不保存录音、识别正文或密钥"
        )
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func safeCopyRow() -> NSView {
        let row = DelayedHelpStackView(
            contentView: safeCopyCheckbox,
            helpText: "适用于所有支持文本输入的应用；保存后生效；关闭时发生输入错误不会自动复制"
        )
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
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

    @objc private func checkPermissionsPressed() {
        let report = refreshPermissionReport()
        onRecordDiagnosticAction?("permissions_checked", [
            "missingCount": String(report.missing.count),
            "grantedCount": String(report.statuses.filter { $0.isGranted }.count)
        ])
        statusLabel.stringValue = "权限检查完成；缺失项可点击旁边的“打开设置”"
    }

    @objc private func openPermissionSettingsPressed(_ sender: NSButton) {
        guard let permission = PrivacyPermission(rawValue: sender.tag) else { return }
        onRecordDiagnosticAction?("permission_settings_open_requested", [
            "permission": String(permission.rawValue)
        ])
        if permissionChecker.openSettings(for: permission) {
            statusLabel.stringValue = "已打开“\(permission.title)”设置；开启后回来点击“检查权限”"
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

    private func labeled(_ title: String, view: NSView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let field = view as? NSTextField {
            field.placeholderString = title
        }
        let label = NSTextField(labelWithString: title)
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
            prepaidQuotaHoursByModel: prepaidQuotaHoursByModel
        )
        do {
            try onSave(settings, credentials)
            storedCredentials = credentials
            onRecordDiagnosticAction?("settings_saved", [
                "engineModelType": settings.engineModelType,
                "saveTextLogs": String(settings.saveTextLogs),
                "safeCopyEnabled": String(settings.safeCopyEnabled)
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

    @objc private func diagnosticRecordingToggled() {
        guard let onDiagnosticRecordingToggle else {
            diagnosticCheckbox.state = .off
            statusLabel.stringValue = "当前版本不支持故障诊断记录"
            return
        }

        let starting = diagnosticCheckbox.state == .on
        do {
            let url = try onDiagnosticRecordingToggle(starting)
            if starting {
                statusLabel.stringValue = "故障诊断记录中；复现问题后再次点击结束"
            } else if let url {
                statusLabel.stringValue = "诊断已结束，JSON 已导出到诊断报告目录：\(url.lastPathComponent)"
            } else {
                statusLabel.stringValue = "诊断记录已结束"
            }
        } catch {
            // Keep the checkbox on after an export failure so the user can
            // retry without losing the in-memory trace.
            diagnosticCheckbox.state = starting ? .off : .on
            statusLabel.stringValue = "故障诊断操作失败：\(error.localizedDescription)"
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
