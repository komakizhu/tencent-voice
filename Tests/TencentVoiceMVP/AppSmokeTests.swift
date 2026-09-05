import XCTest
import RimeSyncCore
@testable import TencentVoiceMVP

@MainActor
final class AppSmokeTests: XCTestCase {
    func testStatusMenuControllerCanBeCreated() {
        let controller = StatusMenuController()
        XCTAssertEqual(controller.statusText, "就绪")
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
            "系统权限完整，可以录音并把识别结果输入到当前应用。"
        ] + PrivacyPermission.allCases.map(\.purpose)
        XCTAssertTrue(removedTexts.allSatisfy { text in
            !labels.contains { $0.stringValue == text }
        })
        XCTAssertTrue(labels.contains { $0.stringValue == "保存崩溃日志" })
        XCTAssertFalse(labels.contains { $0.stringValue == "保存文本日志" })

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
            .first { $0.title == "保存崩溃日志" }
        let saveButton = flatten(contentView)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "保存" }
        guard let testConnectionButton, let shortcutLabel, let logCheckbox, let saveButton else {
            XCTFail("设置页操作控件不存在")
            return
        }
        let testFrame = testConnectionButton.convert(testConnectionButton.bounds, to: contentView)
        let shortcutFrame = shortcutLabel.convert(shortcutLabel.bounds, to: contentView)
        let logFrame = logCheckbox.convert(logCheckbox.bounds, to: contentView)
        let saveFrame = saveButton.convert(saveButton.bounds, to: contentView)
        XCTAssertGreaterThan(testFrame.minY, shortcutFrame.maxY)
        XCTAssertEqual(logFrame.midY, saveFrame.midY, accuracy: 1)
        XCTAssertLessThan(logFrame.minX, saveFrame.minX)
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
