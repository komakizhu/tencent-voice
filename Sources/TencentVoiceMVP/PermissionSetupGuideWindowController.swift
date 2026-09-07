import AppKit

@MainActor
final class PermissionSetupGuideWindowController: NSWindowController, NSWindowDelegate {
    private let permissionChecker: PrivacyPermissionChecking
    private let onFinished: () -> Void
    private let stepLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let instructionLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "稍后处理", target: nil, action: nil)
    private var stepIndex = 0
    private var requestedPermissions = Set<PrivacyPermission>()
    private let restartButton = NSButton(title: "已开启仍无效？重启并检查", target: nil, action: nil)
    private var didFinish = false
    private var refreshTimer: Timer?
    private let steps: [PrivacyPermission] = [.microphone, .accessibility, .inputMonitoring]

    private var currentPermission: PrivacyPermission? {
        guard stepIndex < steps.count else { return nil }
        return steps[stepIndex]
    }

    init(
        permissionChecker: PrivacyPermissionChecking,
        onFinished: @escaping () -> Void = {}
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rime Voice 权限向导"
        window.isReleasedWhenClosed = false
        self.permissionChecker = permissionChecker
        self.onFinished = onFinished
        super.init(window: window)
        window.delegate = self
        buildView()
        updateCurrentStep()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true, NSApp.isActive else { return }
                if let permission = self.currentPermission, self.isStepGranted(permission) {
                    self.stepIndex += 1
                    self.updateCurrentStep()
                } else {
                    self.refreshCurrentStepStatus()
                    self.requestCurrentPermissionIfNeeded()
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        finishIfNeeded()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateCurrentStep()
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }

        stepLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stepLabel.textColor = .secondaryLabelColor
        titleLabel.font = .boldSystemFont(ofSize: 20)
        instructionLabel.maximumNumberOfLines = 0
        instructionLabel.preferredMaxLayoutWidth = 460
        noteLabel.maximumNumberOfLines = 0
        noteLabel.preferredMaxLayoutWidth = 460
        noteLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 0
        stateLabel.preferredMaxLayoutWidth = 460

        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsPressed)
        openSettingsButton.setContentHuggingPriority(.required, for: .horizontal)
        nextButton.target = self
        nextButton.action = #selector(nextPressed)
        nextButton.keyEquivalent = "\r"
        nextButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        restartButton.target = self
        restartButton.action = #selector(restartPressed)

        let buttons = NSStackView(views: [openSettingsButton, NSView(), nextButton, closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let appIcon = PermissionAppDragView()
        appIcon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        appIcon.toolTip = "拖动此图标到系统设置的权限列表，添加当前这份 Rime Voice"
        appIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let appHint = NSTextField(wrappingLabelWithString: "列表没有 Rime Voice？把左侧图标拖进权限列表，然后打开开关。无需寻找文件。")
        appHint.preferredMaxLayoutWidth = 380
        let appRow = NSStackView(views: [appIcon, appHint])
        appRow.orientation = .horizontal
        appRow.spacing = 12
        let content = NSStackView(views: [
            stepLabel,
            titleLabel,
            instructionLabel,
            noteLabel,
            stateLabel,
            restartButton,
            appRow,
            buttons
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            instructionLabel.widthAnchor.constraint(equalToConstant: 464),
            noteLabel.widthAnchor.constraint(equalToConstant: 464),
            stateLabel.widthAnchor.constraint(equalToConstant: 464),
            buttons.widthAnchor.constraint(equalToConstant: 464)
        ])
    }

    private func updateCurrentStep() {
        if currentPermission == nil, let missingIndex = steps.firstIndex(where: { !isStepGranted($0) }) {
            stepIndex = missingIndex
        }
        guard let permission = currentPermission else {
            stepLabel.stringValue = "授权流程已完成"
            titleLabel.stringValue = "权限已全部开启"
            instructionLabel.stringValue = "Rime Voice 现在可以录音、监听全局快捷键，并把识别结果输入到当前应用。"
            noteLabel.stringValue = "以后如果更换 App 或权限再次失效，可以回到设置页重新启动这个向导。"
            stateLabel.stringValue = "已完成"
            stateLabel.textColor = .systemGreen
            openSettingsButton.isHidden = true
            restartButton.isHidden = true
            nextButton.title = "完成"
            closeButton.title = "关闭"
            return
        }

        stepLabel.stringValue = "第 \(stepIndex + 1)/\(steps.count) 步"
        titleLabel.stringValue = stepTitle(for: permission)
        instructionLabel.stringValue = instruction(for: permission)
        noteLabel.stringValue = "系统要求密码或 Touch ID 时，在系统窗口确认。开启后回到这里会自动进入下一步。"
        openSettingsButton.isHidden = false
        restartButton.isHidden = false
        openSettingsButton.title = openSettingsTitle(for: permission)
        closeButton.title = "稍后处理"
        refreshCurrentStepStatus()
        requestCurrentPermissionIfNeeded()
    }

    private func refreshCurrentStepStatus() {
        guard let permission = currentPermission else { return }
        if isStepGranted(permission) {
            stateLabel.stringValue = "当前状态：已允许，可以进入下一步。"
            stateLabel.textColor = .systemGreen
            nextButton.title = "进入下一步"
        } else {
            let accessibilityGranted = permissionChecker.report().status(for: .accessibility)?.isGranted == true
            stateLabel.stringValue = permission == .accessibility && accessibilityGranted
                ? "辅助功能已允许；发送键盘事件尚未生效。如果开关已经开启，请点击下方“重启并检查”，保留现有授权后重新检测。"
                : "当前进程尚未检测到授权。如果系统开关已经开启，请点击下方“重启并检查”，无需重新删除、添加 App。"
            stateLabel.textColor = .systemRed
            nextButton.title = "我已开启，检查下一步"
        }
    }

    private func isStepGranted(_ permission: PrivacyPermission) -> Bool {
        let report = permissionChecker.report()
        guard report.status(for: permission)?.isGranted == true else { return false }
        return permission != .accessibility || report.status(for: .postEvent)?.isGranted == true
    }

    private func requestCurrentPermissionIfNeeded() {
        guard let permission = currentPermission,
              !isStepGranted(permission)
        else {
            return
        }

        let requestedPermission: PrivacyPermission = permission == .accessibility
            && permissionChecker.report().status(for: .accessibility)?.isGranted == true
            ? .postEvent : permission
        guard requestedPermissions.insert(requestedPermission).inserted else { return }
        permissionChecker.requestPermission(for: requestedPermission) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentPermission == permission else { return }
                self.refreshCurrentStepStatus()
            }
        }
    }

    @objc private func openSettingsPressed() {
        guard let permission = currentPermission else { return }
        if permissionChecker.openSettings(for: permission) {
            stateLabel.stringValue = "已打开“\(permission.title)”设置；完成后回到本窗口。"
            stateLabel.textColor = .secondaryLabelColor
        } else {
            stateLabel.stringValue = "无法自动打开系统设置，请手动进入“隐私与安全性”并完成这一步。"
            stateLabel.textColor = .systemRed
        }
    }

    @objc private func nextPressed() {
        guard let permission = currentPermission else {
            window?.close()
            return
        }
        guard isStepGranted(permission) else {
            refreshCurrentStepStatus()
            requestCurrentPermissionIfNeeded()
            return
        }
        stepIndex += 1
        updateCurrentStep()
    }

    @objc private func restartPressed() {
        if !SettingsWindowController.relaunchForPermissionSetup() {
            stateLabel.stringValue = "自动重启失败，请退出后从“应用程序”重新打开 Rime Voice。现有授权已保留。"
        }
    }

    @objc private func closePressed() {
        window?.close()
    }

    private func finishIfNeeded() {
        guard !didFinish else { return }
        didFinish = true
        onFinished()
    }

    private func stepTitle(for permission: PrivacyPermission) -> String {
        switch permission {
        case .microphone: return "开启麦克风"
        case .accessibility: return "开启辅助功能"
        case .postEvent: return "确认发送键盘事件"
        case .inputMonitoring: return "开启输入监控"
        }
    }

    private func openSettingsTitle(for permission: PrivacyPermission) -> String {
        switch permission {
        case .microphone: return "打开麦克风设置"
        case .accessibility: return "打开辅助功能设置"
        case .postEvent: return "打开辅助功能设置"
        case .inputMonitoring: return "打开输入监控设置"
        }
    }

    private func instruction(for permission: PrivacyPermission) -> String {
        switch permission {
        case .microphone:
            return "请在系统弹窗中点击“允许”。如果以前拒绝过，请打开麦克风设置，开启 Rime Voice。麦克风列表由系统请求自动添加，不支持拖入。"
        case .accessibility:
            return "点击“打开辅助功能设置”，打开 Rime Voice 右侧的开关。这一步同时允许输入文字，不需要另外授权“发送键盘事件”。列表没有 App 时，直接拖入下方图标。"
        case .postEvent:
            return "仍在“辅助功能”页面，确认 Rime Voice 已被允许发送键盘事件。它和辅助功能使用同一个系统页面，不需要重复添加 App。"
        case .inputMonitoring:
            return "点击下方按钮，在“隐私与安全性 → 输入监控”中找到 Rime Voice，打开右侧开关。"
        }
    }
}

@MainActor
private final class PermissionAppDragView: NSImageView, NSDraggingSource {
    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
