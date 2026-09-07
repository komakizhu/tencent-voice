import XCTest
import RimeSyncCore
@testable import TencentVoiceMVP

@MainActor
final class AppSmokeTests: XCTestCase {
    func testStatusMenuControllerCanBeCreated() {
        let controller = StatusMenuController()
        XCTAssertEqual(controller.statusText, "就绪")
    }

    func testStatusMenuContainsSeparateRimeSyncActions() {
        let controller = StatusMenuController()
        let menu = controller.makeMenu()

        let titles = menu.items.map(\.title)
        let syncTitles = titles.filter {
            ["同步 Rime 词库", "同步 Rime 皮肤", "同步 Rime 所有配置", "一键同步所有配置"].contains($0)
        }

        XCTAssertEqual(
            syncTitles,
            ["同步 Rime 词库", "同步 Rime 皮肤", "同步 Rime 所有配置", "一键同步所有配置"]
        )
    }

    func testStatusMenuDisablesAllRimeSyncActionsWhileBusy() {
        let controller = StatusMenuController()
        let menu = controller.makeMenu()
        let titles = ["同步 Rime 词库", "同步 Rime 皮肤", "同步 Rime 所有配置", "一键同步所有配置"]

        controller.update(rimeSyncInProgress: true)
        XCTAssertTrue(
            titles.allSatisfy { title in
                menu.items.first { $0.title == title }?.isEnabled == false
            }
        )

        controller.update(rimeSyncInProgress: false)
        XCTAssertTrue(
            titles.allSatisfy { title in
                menu.items.first { $0.title == title }?.isEnabled == true
            }
        )
    }

    func testRimeDictionaryMenuItemsUseLocalCommandShortcuts() {
        let dictionary = NSMenuItem()
        let syncDictionary = NSMenuItem()
        StatusMenuController.applyLocalShortcut(to: dictionary, keyEquivalent: "m")
        StatusMenuController.applyLocalShortcut(to: syncDictionary, keyEquivalent: "s")

        XCTAssertEqual(dictionary.keyEquivalent, "m")
        XCTAssertEqual(dictionary.keyEquivalentModifierMask, NSEvent.ModifierFlags.command)
        XCTAssertEqual(syncDictionary.keyEquivalent, "s")
        XCTAssertEqual(syncDictionary.keyEquivalentModifierMask, NSEvent.ModifierFlags.command)
    }

    func testUsageMenuItemViewRendersUsageAcrossTwoLines() {
        let text = "模型：16k_zh_en_2.0\n用量：38min 58s / 60h（1%）"
        let view = UsageMenuItemView(text: text)

        XCTAssertEqual(view.text, text)
        XCTAssertEqual(view.frame.width, UsageMenuItemView.width(for: text), accuracy: 0.5)
        XCTAssertLessThan(view.frame.width, 260)
        XCTAssertEqual(view.frame.height, UsageMenuItemView.preferredHeight)
        XCTAssertEqual(view.modelTextField.maximumNumberOfLines, 1)
        XCTAssertEqual(view.usageTextField.maximumNumberOfLines, 1)
        XCTAssertTrue(view.modelTextField.usesSingleLineMode)
        XCTAssertTrue(view.usageTextField.usesSingleLineMode)
        view.layoutSubtreeIfNeeded()
        let modelAlignmentRect = view.modelTextField.alignmentRect(forFrame: view.modelTextField.frame)
        let usageAlignmentRect = view.usageTextField.alignmentRect(forFrame: view.usageTextField.frame)
        XCTAssertEqual(modelAlignmentRect.minX, UsageMenuItemView.horizontalInset, accuracy: 0.5)
        XCTAssertEqual(usageAlignmentRect.minX, UsageMenuItemView.horizontalInset, accuracy: 0.5)
        XCTAssertEqual(view.modelTextField.frame.height, UsageMenuItemView.lineHeight, accuracy: 0.5)
        XCTAssertEqual(view.usageTextField.frame.height, UsageMenuItemView.lineHeight, accuracy: 0.5)
    }

    func testSettingsWindowAlignsFormLabelsAndOmitsPermissionDescriptions() {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true }
        )
        let controller = SettingsWindowController(
            settings: AppSettings(),
            credentials: nil,
            onSave: { _, _ in },
            permissionChecker: checker
        )
        let contentView = try! XCTUnwrap(controller.window?.contentView)
        contentView.layoutSubtreeIfNeeded()
        let labels = flatten(contentView).compactMap { $0 as? NSTextField }
        let formLabelTitles = [
            "AppID",
            "SecretId",
            "SecretKey",
            "识别引擎",
            "已充值时长（当前模型）"
        ]
        let formLabels = formLabelTitles.compactMap { title in
            labels.first { $0.stringValue == title }
        }
        XCTAssertEqual(formLabels.count, formLabelTitles.count)
        let labelPositions = formLabels.map { $0.convert($0.bounds, to: contentView).minX }
        XCTAssertEqual(Set(labelPositions).count, 1)

        let removedTexts = [
            "操作：点击“打开设置”→打开对应项目中的本应用开关→回到这里点击“检查权限”。",
            "系统权限完整，可以录音并把识别结果输入到当前应用。",
            "适用于所有支持文本输入的应用；保存后生效；关闭时发生输入错误不会自动复制",
            "勾选后点击“保存设置”生效；开启后自动保存会话状态、错误代码和操作上下文；点击“另存为…”导出全部已保存内容（不含密钥、录音和识别正文）"
        ] + PrivacyPermission.allCases.map(\.purpose)
        XCTAssertTrue(removedTexts.allSatisfy { text in
            !labels.contains { $0.stringValue == text }
        })
        let credentialFields = ["AppID", "SecretId", "SecretKey"].compactMap { title in
            labels.first { $0.placeholderString == title }
        }
        XCTAssertEqual(credentialFields.count, 3)
        XCTAssertTrue(credentialFields.allSatisfy { !($0.toolTip ?? "").isEmpty })

        let popups = flatten(contentView).compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(popups.count, 2)
        XCTAssertTrue(popups.allSatisfy { !($0.toolTip ?? "").isEmpty })

        let controls = flatten(contentView).compactMap { $0 as? NSButton }
        XCTAssertTrue(controls.contains { $0.title == "自动保存诊断日志" })
        XCTAssertFalse(controls.contains { $0.title == "保存崩溃日志" })
        XCTAssertFalse(controls.contains { $0.title == "故障诊断记录" })
        XCTAssertTrue(controls.contains { $0.title == "Safe Copy（始终复制到剪贴板）" })
        let requiredTooltipTitles = [
            "测试连接",
            "Safe Copy（始终复制到剪贴板）",
            "自动保存诊断日志",
            "重新录制",
            "导出诊断报告",
            "保存设置",
            "检查权限"
        ]
        for title in requiredTooltipTitles {
            let matchingControls = controls.filter { $0.title == title }
            XCTAssertFalse(matchingControls.isEmpty, "找不到控件：\(title)")
            XCTAssertTrue(
                matchingControls.allSatisfy { !($0.toolTip ?? "").isEmpty },
                "控件缺少悬浮说明：\(title)"
            )
        }

        let permissionButtons = controls.filter { $0.title == "打开设置" }
        XCTAssertEqual(permissionButtons.count, PrivacyPermission.allCases.count)
        XCTAssertTrue(permissionButtons.allSatisfy { !($0.toolTip ?? "").isEmpty })

        let permissionTitle = labels.first { $0.stringValue == "系统权限（当前 macOS 账户）" }
        let permissionCheckButton = flatten(contentView)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "检查权限" }
        guard let permissionTitle, let permissionCheckButton else {
            XCTFail("系统权限标题或检查权限按钮不存在")
            return
        }
        let titleFrame = permissionTitle.convert(permissionTitle.bounds, to: contentView)
        let buttonFrame = permissionCheckButton.convert(permissionCheckButton.bounds, to: contentView)
        XCTAssertEqual(titleFrame.midY, buttonFrame.midY, accuracy: 1)
        XCTAssertGreaterThan(buttonFrame.minX, titleFrame.maxX)

        let testConnectionButton = flatten(contentView)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "测试连接" }
        let shortcutLabel = labels.first { $0.stringValue == "快捷键" }
        let logCheckbox = flatten(contentView)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "自动保存诊断日志" }
        let saveButton = flatten(contentView)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "保存设置" }
        let exportButton = flatten(contentView)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "导出诊断报告" }
        guard let testConnectionButton, let shortcutLabel, let logCheckbox, let exportButton, let saveButton else {
            XCTFail("设置页操作控件不存在")
            return
        }
        let testFrame = testConnectionButton.convert(testConnectionButton.bounds, to: contentView)
        let shortcutFrame = shortcutLabel.convert(shortcutLabel.bounds, to: contentView)
        let exportFrame = exportButton.convert(exportButton.bounds, to: contentView)
        let saveFrame = saveButton.convert(saveButton.bounds, to: contentView)
        XCTAssertGreaterThan(testFrame.minY, shortcutFrame.maxY)
        let logFrame = logCheckbox.convert(logCheckbox.bounds, to: contentView)
        XCTAssertEqual(exportFrame.midY, logFrame.midY, accuracy: 1)
        XCTAssertGreaterThan(exportFrame.minX, logFrame.maxX)
        XCTAssertLessThan(saveFrame.minY, exportFrame.minY)
        let permissionCheckFrame = permissionCheckButton.convert(permissionCheckButton.bounds, to: contentView)
        XCTAssertEqual(saveFrame.maxX, permissionCheckFrame.maxX, accuracy: 1)

        XCTAssertEqual(saveButton.accessibilityLabel(), "保存设置")
        XCTAssertFalse(controls.contains { $0.title == "打开共享目录" })
        XCTAssertTrue(controls.contains { $0.title == "打开日志目录" })
        XCTAssertTrue(controls.contains { $0.title == "打开诊断目录" })
        XCTAssertFalse(labels.contains { $0.stringValue == "凭证共享目录" })
        XCTAssertTrue(labels.contains { $0.stringValue == "会话日志目录" })
        XCTAssertTrue(labels.contains { $0.stringValue == "诊断报告目录" })

        let helperTexts = [
            "适用于所有支持文本输入的应用；保存后生效；关闭时发生输入错误不会自动复制",
            "持续保存会话状态、长度、计数和错误类型；不保存录音、识别正文或密钥",
            "临时记录一次复现过程；结束后导出脱敏 JSON。与“保存会话日志”不同，它会记录更完整的设置、权限和操作上下文",
            "设置保存在当前账户；腾讯凭证和用量使用本机共享目录，日志不会写入共享目录",
            "尚未读取凭证；填写后点击“保存设置”",
            "已读取凭证；点击“保存设置”后更新"
        ]
        XCTAssertTrue(helperTexts.allSatisfy { text in
            !labels.contains { $0.stringValue == text }
        })
    }

    func testSettingsWindowOpensConfiguredLogDirectory() throws {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true }
        )
        let logDirectory = URL(fileURLWithPath: "/tmp/TencentVoiceMVP-test-sessions")
        var openedURL: URL?
        let controller = SettingsWindowController(
            settings: AppSettings(),
            credentials: nil,
            onSave: { _, _ in },
            permissionChecker: checker,
            logDirectoryURL: logDirectory,
            onOpenDirectory: { url in
                openedURL = url
                return true
            }
        )
        let openButton = try XCTUnwrap(
            flatten(controller.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "打开日志目录" }
        )

        openButton.performClick(nil)

        XCTAssertEqual(openedURL, logDirectory)
    }

    func testSettingsButtonShowsSavedStatus() throws {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true }
        )
        var savedSettings: AppSettings?
        let controller = SettingsWindowController(
            settings: AppSettings(),
            credentials: TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
            onSave: { settings, _ in savedSettings = settings },
            permissionChecker: checker
        )
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let saveButton = try XCTUnwrap(
            flatten(contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "保存设置" }
        )

        saveButton.performClick(nil)

        XCTAssertEqual(savedSettings, AppSettings())
        XCTAssertTrue(
            flatten(contentView)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "设置已保存" }
        )
    }

    func testSettingsDiagnosticLogCanBeExportedWithoutTogglingRecording() throws {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true }
        )
        var exportCount = 0
        let controller = SettingsWindowController(
            settings: AppSettings(),
            credentials: nil,
            onSave: { _, _ in },
            onExportDiagnosticLog: {
                exportCount += 1
                return URL(fileURLWithPath: "/tmp/TencentVoiceMVP-Diagnostic.json")
            },
            permissionChecker: checker
        )
        let button = try XCTUnwrap(
            flatten(controller.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "导出诊断报告" }
        )

        button.performClick(nil)

        XCTAssertEqual(exportCount, 1)
    }

    func testManualRimeEntryFormShowsAllEditableFields() {
        let form = ManualRimeEntryForm()

        XCTAssertEqual(form.wordField.placeholderString, "词条（必填）")
        XCTAssertEqual(form.codeField.placeholderString, "全拼编码（必填）")
        XCTAssertEqual(form.frequencyField.placeholderString, "频率（可选，默认 1）")
        XCTAssertTrue(form.wordField.superview === form)
        XCTAssertTrue(form.codeField.superview === form)
        XCTAssertTrue(form.frequencyField.superview === form)
        XCTAssertFalse(form.wordField.isHidden)
        XCTAssertFalse(form.codeField.isHidden)
        XCTAssertFalse(form.frequencyField.isHidden)
        XCTAssertGreaterThan(form.frame.width, 0)
        XCTAssertGreaterThan(form.frame.height, 0)
        XCTAssertGreaterThan(form.wordField.frame.height, 0)
        XCTAssertGreaterThan(form.codeField.frame.height, 0)
        XCTAssertGreaterThan(form.frequencyField.frame.height, 0)
        XCTAssertTrue([form.wordField, form.codeField, form.frequencyField].allSatisfy { !($0.toolTip ?? "").isEmpty })
    }

    func testRimeFilterSliderShowsFiveSmallTickLabels() {
        let slider = NSSlider()
        let control = RimeFilterSliderView(
            title: "累计次数",
            tickTitles: ["不限", "≥3", "≥10", "≥30", "≥100"],
            slider: slider
        )

        XCTAssertEqual(control.tickTitles, ["不限", "≥3", "≥10", "≥30", "≥100"])
        XCTAssertTrue(control.tickLabels.allSatisfy { $0.font?.pointSize == 9 })
        control.frame = NSRect(x: 0, y: 0, width: 260, height: 42)
        control.layoutSubtreeIfNeeded()
        // AppKit may expand the slider slightly to satisfy the stack view's
        // intrinsic sizing.  The user-facing requirement is a longer track,
        // not an exact pixel width.
        XCTAssertGreaterThanOrEqual(slider.frame.width, 190)
        XCTAssertGreaterThan(slider.frame.height, 0)
    }

    func testRimeAuditCheckboxesSupportMixedHeaderState() {
        let selectAll = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
        selectAll.allowsMixedState = true
        XCTAssertTrue(selectAll.allowsMixedState)
        XCTAssertEqual(selectAll.state, .off)
        XCTAssertEqual(selectAll.title, "全选")

        let cell = RimeAuditCheckboxCell(frame: NSRect(x: 0, y: 0, width: 36, height: 28))
        cell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(cell.checkbox.frame.width, 0)
        XCTAssertGreaterThan(cell.checkbox.frame.height, 0)
    }

    func testBackupPickerShowsConfiguredRetentionAndSelectableBackups() {
        let backups = [
            RimeBackupDescriptor(id: "20260905-120000000-mac2-AAAA1111", nodeID: "mac2", createdAt: Date(timeIntervalSince1970: 100)),
            RimeBackupDescriptor(id: "20260905-110000000-mac2-BBBB2222", nodeID: "mac2", createdAt: Date(timeIntervalSince1970: 50))
        ]
        let picker = RimeBackupPickerView(backups: backups, retentionLimit: 10)

        XCTAssertEqual(picker.numberOfRows(in: picker.tableView), 2)
        XCTAssertEqual(picker.retentionField.stringValue, "10")
        XCTAssertEqual(picker.selectedBackup?.id, backups[0].id)
        XCTAssertEqual(try picker.validatedRetentionPolicy().limit, 10)

        picker.retentionField.stringValue = "0"
        XCTAssertThrowsError(try picker.validatedRetentionPolicy())
        picker.retentionField.stringValue = "unlimited"
        XCTAssertThrowsError(try picker.validatedRetentionPolicy())
    }

    func testBackupSettingsDefaultToTenAndIgnoreInvalidPersistedValues() {
        let suiteName = "RimeBackupSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(RimeBackupSettings.loadPolicy(from: defaults).limit, 10)
        defaults.set(25, forKey: RimeBackupSettings.retentionLimitKey)
        XCTAssertEqual(RimeBackupSettings.loadPolicy(from: defaults).limit, 25)
        defaults.set(0, forKey: RimeBackupSettings.retentionLimitKey)
        XCTAssertEqual(RimeBackupSettings.loadPolicy(from: defaults).limit, 10)
    }

    func testRimeDictionaryWindowUsesUpdatedActionLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeDictionaryWindowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let maintenance = AppSmokeRimeMaintenance()
        let coordinator = RimeReviewSyncCoordinator(
            configuration: SyncConfiguration(
                localRimeDirectory: root.appendingPathComponent("Rime", isDirectory: true),
                sharedRoot: root.appendingPathComponent("shared", isDirectory: true),
                installationID: "mac2-main"
            ),
            maintenance: maintenance,
            reloader: maintenance,
            ordinarySync: AppSmokeRimeSync()
        )
        let controller = RimeDictionaryWindowController(reviewCoordinator: coordinator)
        let views = flatten(controller.window?.contentView)
        let buttons = views.compactMap { $0 as? NSButton }

        XCTAssertTrue(buttons.contains { $0.title == "重新读取" })
        XCTAssertTrue(buttons.contains { $0.title == "导出" })
        XCTAssertTrue(buttons.contains { $0.title == "导入 AI 提案…" })
        XCTAssertTrue(buttons.contains { $0.title == "应用 AI 提案" })
        XCTAssertFalse(buttons.contains { $0.title == "关闭" })
        let export = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.title == "导出" })
        XCTAssertEqual(export.menu?.items.map(\.title), ["导出", "CSV", "TXT", "Markdown", "JSON"])
    }

    private func flatten(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(flatten)
    }
}

private final class AppSmokeRimeMaintenance: NativeRimeMaintaining, RimeUserDictionaryMaintaining {
    func syncUserData() throws {}
    func reload() throws {}
    func captureUserDictionarySnapshot(in rimeDirectory: URL) throws {}
    func restoreUserDictionarySnapshot(from snapshot: URL, in rimeDirectory: URL) throws {}
}

private final class AppSmokeRimeSync: RimeSyncEngine {
    func status() throws -> SyncReport { SyncReport() }
    func sync(dryRun: Bool) throws -> SyncReport { SyncReport() }
    func restore(backupID: String) throws {}
}
