import AppKit
import Carbon.HIToolbox

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let appIDField = NSTextField()
    private let secretIDField = NSTextField()
    private let secretKeyField = NSSecureTextField()
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let prepaidHoursPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let logCheckbox = NSButton(checkboxWithTitle: "保存文本日志", target: nil, action: nil)
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "凭证优先保存在本机 YAML")
    private let onSave: (AppSettings, TencentCredentials) throws -> Void
    private let onClose: () -> Void
    private var currentShortcut: Shortcut
    private var displayedEngineModelType: String
    private var prepaidQuotaHoursByModel: [String: Int]
    private var storedCredentials: TencentCredentials?
    private var localMonitor: Any?

    init(
        settings: AppSettings,
        credentials: TencentCredentials?,
        onSave: @escaping (AppSettings, TencentCredentials) throws -> Void,
        onClose: @escaping () -> Void = {}
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "腾讯语音输入设置"
        self.onSave = onSave
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
        statusLabel.stringValue = credentials == nil
            ? "凭证优先保存在本机 YAML（明文）"
            : "已读取凭证；日常使用仅读本机 YAML"
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
        shortcutLabel.stringValue = ShortcutFormatter.string(for: currentShortcut)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        stopShortcutCapture()
        onClose()
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        let fields = NSStackView(views: [
            labeled("AppID", view: appIDField),
            labeled("SecretId", view: secretIDField),
            labeled("SecretKey", view: secretKeyField),
            labeled("识别引擎", view: enginePopup),
            labeled("已充值时长（当前模型）", view: prepaidHoursPopup)
        ])
        fields.orientation = .vertical
        fields.spacing = 10
        fields.translatesAutoresizingMaskIntoConstraints = false

        let shortcutButton = NSButton(title: "重新录制", target: self, action: #selector(captureShortcut))
        let shortcutRow = NSStackView(views: [
            NSTextField(labelWithString: "快捷键"), shortcutLabel, shortcutButton
        ])
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 10

        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveButtonPressed))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [statusLabel, NSView(), saveButton])
        buttons.alignment = .centerY
        buttons.spacing = 8

        let content = NSStackView(views: [fields, shortcutRow, logCheckbox, buttons])
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
        statusLabel.textColor = .secondaryLabelColor
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
            self.statusLabel.stringValue = "快捷键已选择，保存后生效"
            self.stopShortcutCapture()
            return nil
        }
    }

    @objc private func saveButtonPressed() {
        persistSelectedPrepaidHours()
        let appID = appIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretID = secretIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = secretKeyField.stringValue.isEmpty
            ? (storedCredentials?.secretKey ?? "")
            : secretKeyField.stringValue
        guard !appID.isEmpty, !secretID.isEmpty, !secretKey.isEmpty else {
            statusLabel.stringValue = "请填写完整的 AppID、SecretId 和 SecretKey"
            return
        }

        let settings = AppSettings(
            shortcut: currentShortcut,
            engineModelType: enginePopup.selectedItem?.representedObject as? String
                ?? TencentEnginePreset.defaultPreset.rawValue,
            saveTextLogs: logCheckbox.state == .on,
            prepaidQuotaHoursByModel: prepaidQuotaHoursByModel
        )
        do {
            let credentials = TencentCredentials(appID: appID, secretID: secretID, secretKey: secretKey)
            try onSave(settings, credentials)
            storedCredentials = credentials
            statusLabel.stringValue = "已保存"
        } catch {
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
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
    }

    @objc private func prepaidHoursChanged() {
        persistSelectedPrepaidHours()
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
