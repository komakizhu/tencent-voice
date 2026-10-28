import Foundation
import XCTest
import RimeSyncCore
@testable import TencentVoiceMVP

@MainActor
final class AppSmokeTests: XCTestCase {
    func testMicrophoneButtonRequestsOnlyMicrophoneAndRefreshesResult() async throws {
        for grant in [true, false] {
            var authorized = false
            var requested: [PrivacyPermission] = []
            var opened: [PrivacyPermission] = []
            var resets = 0
            let checker = SystemPrivacyPermissionChecker(
                microphoneStatus: { authorized ? .authorized : .notDetermined },
                accessibilityStatus: { true },
                postEventStatus: { true },
                inputMonitoringStatus: { true },
                openSettings: { opened.append($0); return true },
                requestPermission: { permission, completion in
                    requested.append(permission)
                    authorized = grant
                    completion(grant)
                },
                resetPermissions: { resets += 1; return true }
            )
            let controller = SettingsWindowController(
                settings: AppSettings(), credentials: nil,
                onSave: { _, _ in }, permissionChecker: checker
            )
            let button = try XCTUnwrap(flatten(controller.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "打开设置" && $0.tag == PrivacyPermission.microphone.rawValue })
            button.performClick(nil)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(requested, [.microphone])
            XCTAssertEqual(opened, grant ? [] : [.microphone])
            XCTAssertEqual(resets, 0)
            XCTAssertTrue(button.isEnabled)
            if grant {
                XCTAssertTrue(flatten(controller.window?.contentView)
                    .compactMap { $0 as? NSTextField }
                    .contains { $0.stringValue.contains("麦克风已允许；") })
            }
        }
    }

    func testSettingsWindowExplainsRecordingStartPermissionFailure() throws {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .notDetermined },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true }
        )
        let controller = SettingsWindowController(
            settings: AppSettings(),
            credentials: TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
            onSave: { _, _ in },
            permissionChecker: checker
        )

        controller.showRecordingStartFailure(SessionError.microphoneDenied)

        XCTAssertTrue(
            flatten(controller.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == RecordingStartFeedback.message(for: SessionError.microphoneDenied) }
        )
    }

    func testStatusMenuControllerCanBeCreated() {
        let controller = StatusMenuController()
        XCTAssertEqual(controller.statusText, "就绪")
    }

    func testStatusMenuReturnsToStartAfterRecordingStartFailure() {
        let controller = StatusMenuController()
        let menu = controller.makeMenu()

        controller.update(status: RecordingStartFeedback.message(for: SessionError.microphoneDenied))

        XCTAssertEqual(menu.items.first { $0.title == "开始录音" }?.title, "开始录音")
        XCTAssertNil(menu.items.first { $0.title == "停止录音" })
    }

    func testStatusMenuDisplaysSelectedRecordingModeAndResetsWhenIdle() {
        let controller = StatusMenuController()
        let menu = controller.makeMenu()
        let now = DispatchTime.now().uptimeNanoseconds
        var snapshot = RecordingDisplaySnapshot(
            sessionID: UUID(),
            state: .listening,
            audio: AudioCaptureMetricsSnapshot(
                durationSeconds: 61.9,
                latestRMS: 0.5,
                sampleSequence: 1,
                latestLevelAtUptimeNanoseconds: now,
                latestLevelDurationSeconds: 0.2
            ),
            isCapturing: true
        )
        controller.configureRecordingDisplay { snapshot }

        controller.update(menuBarDisplayMode: .timer)
        controller.update(recordingState: .listening)
        XCTAssertEqual(controller.statusButtonTitle, "01:01")
        XCTAssertTrue(controller.statusButtonAccessibilityLabel.contains("已录 01:01"))
        XCTAssertEqual(menu.items.first { $0.title == "停止录音" }?.title, "停止录音")

        controller.update(menuBarDisplayMode: .waveform)
        XCTAssertEqual(controller.statusButtonWaveformLevels, Array(repeating: 0, count: 5))
        XCTAssertEqual(controller.statusButtonAccessibilityLabel, "正在录音，显示麦克风输入音量")

        snapshot = RecordingDisplaySnapshot(
            sessionID: snapshot.sessionID,
            state: .stopping,
            audio: snapshot.audio,
            isCapturing: false
        )
        controller.update(recordingState: .stopping)
        XCTAssertEqual(menu.items.first { $0.title == "收尾中…" }?.title, "收尾中…")
        XCTAssertFalse(menu.items.first { $0.title == "收尾中…" }?.isEnabled ?? true)
        controller.update(menuBarDisplayMode: .timer)
        XCTAssertEqual(controller.statusButtonImageStyle, .none)
        XCTAssertEqual(controller.statusButtonTitle, "01:01")

        XCTAssertEqual(StatusMenuController.formattedDuration(3_599.99), "59:59")
        XCTAssertEqual(StatusMenuController.formattedDuration(3_600), "1:00:00")
        snapshot = RecordingDisplaySnapshot(sessionID: nil, state: .idle, audio: .empty)
        controller.update(recordingState: .idle)
        XCTAssertEqual(controller.statusButtonTitle, "")
        XCTAssertEqual(controller.statusButtonAccessibilityLabel, "Rime Voice，已就绪")
        XCTAssertEqual(menu.items.first { $0.title == "开始录音" }?.title, "开始录音")
    }

    func testStatusPresentationKeepsTimerIconAndWaveformShapesDistinct() {
        let timer = StatusButtonPresentation.make(
            mode: .timer, state: .listening, isCapturing: true, duration: 61.9
        )
        XCTAssertEqual(timer.title, "01:01")
        XCTAssertEqual(timer.imageStyle, .none)

        let connectingBeforeCapture = StatusButtonPresentation.make(
            mode: .timer, state: .connecting, isCapturing: false, duration: 0
        )
        XCTAssertEqual(connectingBeforeCapture.title, "00:00")
        XCTAssertEqual(connectingBeforeCapture.imageStyle, .none)

        let circleIdle = StatusButtonPresentation.make(
            mode: .icon, state: .connecting, isCapturing: false, duration: 0
        )
        let circleRecording = StatusButtonPresentation.make(
            mode: .icon, state: .connecting, isCapturing: true, duration: 0
        )
        let circleRecovering = StatusButtonPresentation.make(
            mode: .icon, state: .recovering, isCapturing: false, duration: 1
        )
        let circleStopping = StatusButtonPresentation.make(
            mode: .icon, state: .stopping, isCapturing: false, duration: 1
        )
        let circleStoppingCaptureActive = StatusButtonPresentation.make(
            mode: .icon, state: .stopping, isCapturing: true, duration: 1
        )
        XCTAssertEqual(circleIdle.imageStyle, .application)
        XCTAssertEqual(circleRecording.imageStyle, .symbol("record.circle.fill"))
        XCTAssertEqual(circleRecovering.imageStyle, .application)
        XCTAssertEqual(circleStopping.imageStyle, .application)
        XCTAssertEqual(circleStoppingCaptureActive.imageStyle, .symbol("record.circle.fill"))

        XCTAssertEqual(StatusButtonPresentation.make(
            mode: .waveform, state: .listening, isCapturing: true, duration: 1
        ).imageStyle, .waveform)
        XCTAssertEqual(StatusButtonPresentation.make(
            mode: .waveform, state: .recovering, isCapturing: false, duration: 1
        ).imageStyle, .symbol("mic.slash.fill"))
        XCTAssertEqual(StatusButtonPresentation.make(
            mode: .waveform, state: .stopping, isCapturing: false, duration: 1
        ).imageStyle, .symbol("hourglass"))
        XCTAssertEqual(StatusButtonPresentation.make(
            mode: .waveform, state: .error("failure"), isCapturing: false, duration: 0
        ).imageStyle, .symbol("exclamationmark.triangle.fill"))
    }

    func testWaveformGateGainAttackReleaseAndStaleResetAreDeterministic() {
        XCTAssertEqual(WaveformDisplayModel.amplitude(forRMS: 0.005), 0)
        XCTAssertEqual(WaveformDisplayModel.amplitude(forRMS: 0.008), 0.305, accuracy: 0.015)
        XCTAssertLessThan(
            WaveformDisplayModel.amplitude(forRMS: 0.02),
            WaveformDisplayModel.amplitude(forRMS: 0.05)
        )
        XCTAssertEqual(WaveformDisplayModel.amplitude(forRMS: 1), 1)

        let sessionID = UUID()
        var model = WaveformDisplayModel()
        let loud = makeDisplaySnapshot(
            sessionID: sessionID, rms: 0.05, sequence: 1, timestamp: 0, duration: 0.1
        )
        let initial = model.update(snapshot: loud, now: 0)
        XCTAssertEqual(initial, Array(repeating: 0, count: 5))
        let afterAttack = model.update(snapshot: loud, now: 100_000_000)
        XCTAssertGreaterThanOrEqual(afterAttack[2], WaveformDisplayModel.amplitude(forRMS: 0.05) * 0.99)
        XCTAssertEqual(afterAttack[0] / afterAttack[2], 0.55, accuracy: 0.000_001)
        XCTAssertEqual(afterAttack[1] / afterAttack[2], 0.8, accuracy: 0.000_001)

        let quiet = makeDisplaySnapshot(
            sessionID: sessionID, rms: 0.005, sequence: 2, timestamp: 100_000_000, duration: 0.1
        )
        _ = model.update(snapshot: quiet, now: 100_000_000)
        let afterSilence = model.update(snapshot: quiet, now: 250_000_000)
        XCTAssertEqual(afterSilence, Array(repeating: 0, count: 5))

        let loudAgain = makeDisplaySnapshot(
            sessionID: sessionID, rms: 0.2, sequence: 3, timestamp: 300_000_000, duration: 0.1
        )
        _ = model.update(snapshot: loudAgain, now: 300_000_000)
        XCTAssertGreaterThan(model.update(snapshot: loudAgain, now: 350_000_000)[2], 0)
        let stale = model.update(snapshot: loudAgain, now: 600_000_001)
        XCTAssertEqual(stale, Array(repeating: 0, count: 5))

        let interrupted = RecordingDisplaySnapshot(
            sessionID: sessionID, state: .recovering, audio: loudAgain.audio, isCapturing: false
        )
        XCTAssertEqual(model.update(snapshot: interrupted, now: 610_000_000), Array(repeating: 0, count: 5))
    }

    func testPCMMeasurementDistinguishesSilenceNoiseWeakAndStrongSignals() {
        let cases: [(Int16, Double)] = [
            (0, 0),
            (164, 164.0 / 32_768),
            (655, 655.0 / 32_768),
            (1_638, 1_638.0 / 32_768),
            (Int16.max, Double(Int16.max) / 32_768)
        ]
        var displayedLevels: [Double] = []
        for (sample, expectedRMS) in cases {
            var pcm = Data()
            for _ in 0..<1_600 {
                let bits = UInt16(bitPattern: sample)
                pcm.append(UInt8(truncatingIfNeeded: bits))
                pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
            let measuredRMS = AudioCaptureLevelMeasurement.rms(in: pcm)
            XCTAssertEqual(measuredRMS, expectedRMS, accuracy: 0.000_001)
            displayedLevels.append(WaveformDisplayModel.amplitude(forRMS: measuredRMS))
        }
        XCTAssertEqual(displayedLevels[0], 0)
        XCTAssertEqual(displayedLevels[1], 0, "RMS 0.005 底噪必须回平")
        XCTAssertLessThan(displayedLevels[2], displayedLevels[3])
        XCTAssertEqual(displayedLevels[4], 1)
    }

    private func makeDisplaySnapshot(
        sessionID: UUID,
        rms: Double,
        sequence: UInt64,
        timestamp: UInt64,
        duration: TimeInterval
    ) -> RecordingDisplaySnapshot {
        RecordingDisplaySnapshot(
            sessionID: sessionID,
            state: .listening,
            audio: AudioCaptureMetricsSnapshot(
                durationSeconds: 0.3,
                latestRMS: rms,
                sampleSequence: sequence,
                latestLevelAtUptimeNanoseconds: timestamp,
                latestLevelDurationSeconds: duration
            ),
            isCapturing: true
        )
    }

    func testSettingsSavePersistsSelectedMenuBarDisplayMode() throws {
        var savedSettings: AppSettings?
        let controller = SettingsWindowController(
            settings: AppSettings(),
            credentials: TencentCredentials(appID: "app", secretID: "id", secretKey: "key"),
            onSave: { settings, _ in savedSettings = settings }
        )
        let controls = flatten(controller.window?.contentView)
        let modePopup = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("音量波形") && $0.itemTitles.contains("录音计时")
        })
        XCTAssertEqual(modePopup.itemTitles, ["录音图标", "录音计时", "音量波形"])
        modePopup.selectItem(withTitle: "音量波形")

        let saveButton = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "保存设置" })
        saveButton.performClick(nil)

        XCTAssertEqual(savedSettings?.menuBarDisplayMode, .waveform)
    }

    func testStatusMenuHasNoSharedSyncStatusRow() {
        let controller = StatusMenuController()
        let menu = controller.makeMenu()

        let usageView = menu.items.compactMap { $0.view as? UsageMenuItemView }.first
        XCTAssertNotNil(usageView)
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("同步状态：") })
        XCTAssertTrue(menu.items.compactMap { $0.view as? SyncStatusMenuItemView }.isEmpty)

        controller.update(usage: "模型：16k_zh_en_2.0\n用量：1h 36min / 60h（3%）")
        XCTAssertEqual(controller.statusText, "就绪")
        XCTAssertEqual(menu.items.first { $0.title == "开始录音" }?.title, "开始录音")
    }

    func testStatusMenuContainsManualArchiveActionsAndRemovesAutomaticSyncActions() {
        let controller = StatusMenuController()
        let menu = controller.makeMenu()

        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("导出所有配置…"))
        XCTAssertTrue(titles.contains("导入所有配置…"))
        XCTAssertTrue(titles.contains("校准用量…"))
        XCTAssertFalse(titles.contains("用量核查…"))
        controller.update(calibrationInProgress: true)
        XCTAssertEqual(menu.items.first { $0.title == "正在核对腾讯云…" }?.isEnabled, false)
        controller.update(calibrationInProgress: false)
        XCTAssertEqual(menu.items.first { $0.title == "校准用量…" }?.isEnabled, true)
        XCTAssertFalse(titles.contains("同步 Rime 词库"))
        XCTAssertFalse(titles.contains("同步 Rime 皮肤"))
        XCTAssertFalse(titles.contains("一键同步所有配置"))
        XCTAssertFalse(titles.contains("处理配置冲突…"))
    }

    func testStatusMenuContainsAutoStartToggle() throws {
        let controller = StatusMenuController()
        let menu = controller.makeMenu()

        let autoStart = try XCTUnwrap(menu.items.first { $0.title == "开机自动启动" })
        XCTAssertEqual(autoStart.state, .off)

        controller.update(autoStartEnabled: true)
        XCTAssertEqual(autoStart.state, .on)

        controller.update(autoStartEnabled: false)
        XCTAssertEqual(autoStart.state, .off)
    }

    func testStatusMenuDisablesArchiveActionsWhileBusy() {
        let controller = StatusMenuController()
        let menu = controller.makeMenu()
        let titles = ["导出所有配置…", "导入所有配置…"]

        controller.update(configurationArchiveInProgress: true)
        XCTAssertTrue(
            titles.allSatisfy { title in
                menu.items.first { $0.title == title }?.isEnabled == false
            }
        )
        XCTAssertEqual(menu.items.first { $0.title == "Rime 词库管理…" }?.isEnabled, false)
        XCTAssertEqual(menu.items.first { $0.title == "Rime 皮肤" }?.isEnabled, false)

        controller.update(configurationArchiveInProgress: false)
        XCTAssertTrue(
            titles.allSatisfy { title in
                menu.items.first { $0.title == title }?.isEnabled == true
            }
        )
        XCTAssertEqual(menu.items.first { $0.title == "Rime 词库管理…" }?.isEnabled, true)
        XCTAssertEqual(menu.items.first { $0.title == "Rime 皮肤" }?.isEnabled, true)
    }

    func testLegacySyncEntrypointsAreDisabledWithoutCreatingSharedData() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildDirectory = Bundle(for: AppSmokeTests.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(existingExecutable("RimeSync", in: buildDirectory))
        let mcp = try XCTUnwrap(existingExecutable("RimeAuditMCP", in: buildDirectory))
        let probeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeDisabledEntrypoints-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeRoot) }

        let cliSharedRoot = probeRoot.appendingPathComponent("legacy-cli", isDirectory: true)
        let cliResult = try run(cli, arguments: [
            "sync",
            "--dry-run",
            "--rime-dir", probeRoot.appendingPathComponent("rime-cli", isDirectory: true).path,
            "--shared-root", cliSharedRoot.path
        ])
        XCTAssertEqual(cliResult.status, 1)
        XCTAssertTrue(cliResult.output.contains("自动跨账户同步命令已停用"), cliResult.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cliSharedRoot.path))

        let mcpSharedRoot = probeRoot.appendingPathComponent("legacy-mcp", isDirectory: true)
        let mcpResult = try run(mcp, arguments: ["--shared-root", mcpSharedRoot.path])
        XCTAssertEqual(mcpResult.status, 1)
        XCTAssertTrue(mcpResult.output.contains("--shared-root 已停用"), mcpResult.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mcpSharedRoot.path))

        let snapshotScript = root.appendingPathComponent("scripts/rime-refresh-snapshot")
        let scriptResult = try run(URL(fileURLWithPath: "/bin/sh"), arguments: [snapshotScript.path])
        XCTAssertEqual(scriptResult.status, 2)
        XCTAssertTrue(scriptResult.output.contains("已停用"), scriptResult.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeRoot.appendingPathComponent("rime-cli").path))
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
            "操作：点击“打开设置”→打开对应项目中的本应用开关→回到这里点击“重置并重新授权”。",
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
        XCTAssertEqual(popups.count, 4)
        XCTAssertTrue(popups.allSatisfy { !($0.toolTip ?? "").isEmpty })
        guard let shortcutPresetPopup = popups.first(where: { popup in
            popup.itemArray.contains { $0.title == "F5（屏蔽 macOS 听写）" }
        }) else {
            XCTFail("找不到快捷键预设下拉框")
            return
        }
        let shortcutPresetTitles = shortcutPresetPopup.itemArray.map(\.title)
        XCTAssertTrue(shortcutPresetTitles.contains("F5（屏蔽 macOS 听写）"))
        XCTAssertTrue(shortcutPresetTitles.contains("Esc"))
        XCTAssertTrue(shortcutPresetTitles.contains("Home"))
        XCTAssertTrue(shortcutPresetTitles.contains("Page Up"))
        XCTAssertTrue(shortcutPresetTitles.contains("Page Down"))
        XCTAssertFalse(shortcutPresetTitles.contains { $0.localizedCaseInsensitiveContains("delete") })

        let controls = flatten(contentView).compactMap { $0 as? NSButton }
        XCTAssertTrue(controls.contains { $0.title == "自动保存诊断日志" })
        XCTAssertTrue(controls.contains { $0.title == "故障时采集目标窗口画面（可选）" })
        XCTAssertFalse(controls.contains { $0.title == "保存崩溃日志" })
        XCTAssertFalse(controls.contains { $0.title == "故障诊断记录" })
        XCTAssertTrue(controls.contains { $0.title == "始终保存语音内容" })
        let requiredTooltipTitles = [
            "测试连接",
            "始终保存语音内容",
            "自动保存诊断日志",
            "故障时采集目标窗口画面（可选）",
            "重新录制",
            "导出诊断报告",
            "保存设置",
            "重置并重新授权"
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
        let permissionResetButton = flatten(contentView)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "重置并重新授权" }
        guard let permissionTitle, let permissionResetButton else {
            XCTFail("系统权限标题或重置并重新授权按钮不存在")
            return
        }
        let titleFrame = permissionTitle.convert(permissionTitle.bounds, to: contentView)
        let buttonFrame = permissionResetButton.convert(permissionResetButton.bounds, to: contentView)
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
        let permissionResetFrame = permissionResetButton.convert(permissionResetButton.bounds, to: contentView)
        XCTAssertEqual(saveFrame.maxX, permissionResetFrame.maxX, accuracy: 1)

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

    func testPermissionResetButtonPresentsStepByStepGuide() throws {
        var resetCount = 0
        var restartCount = 0
        var openCount = 0
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true },
            openSettings: { _ in
                openCount += 1
                return true
            },
            resetPermissions: {
                resetCount += 1
                return true
            }
        )
        let controller = SettingsWindowController(
            settings: AppSettings(),
            credentials: nil,
            onSave: { _, _ in },
            permissionChecker: checker,
            onPermissionResetRestart: { restartCount += 1 }
        )

        let button = try XCTUnwrap(
            flatten(controller.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "重置并重新授权" }
        )
        button.performClick(nil)

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(restartCount, 1)
    }

    func testPermissionSetupGuideAdvancesOnePermissionAtATime() throws {
        var granted = Set<PrivacyPermission>()
        var openedPermissions: [PrivacyPermission] = []
        var requestedPermissions: [PrivacyPermission] = []
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { granted.contains(.microphone) ? .authorized : .notDetermined },
            accessibilityStatus: { granted.contains(.accessibility) },
            postEventStatus: { granted.contains(.postEvent) },
            inputMonitoringStatus: { granted.contains(.inputMonitoring) },
            openSettings: { permission in
                openedPermissions.append(permission)
                return true
            },
            requestPermission: { permission, completion in
                requestedPermissions.append(permission)
                completion(false)
            },
            resetPermissions: { true }
        )
        let guide = PermissionSetupGuideWindowController(permissionChecker: checker)

        let openButton = try XCTUnwrap(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "打开麦克风设置" }
        )
        let nextButton = try XCTUnwrap(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "刷新授权状态" }
        )
        openButton.performClick(nil)
        XCTAssertEqual(openedPermissions, [.microphone])

        nextButton.performClick(nil)
        XCTAssertNotNil(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "开启麦克风" },
        )

        granted.insert(.microphone)
        nextButton.performClick(nil)
        XCTAssertTrue(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "开启辅助功能" }
        )
        granted.insert(.accessibility)
        guide.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(requestedPermissions, [.microphone, .accessibility, .postEvent])
        guide.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(requestedPermissions, [.microphone, .accessibility, .postEvent])
        XCTAssertTrue(flatten(guide.window?.contentView).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("辅助功能已允许；发送键盘事件尚未生效") })
        nextButton.performClick(nil)
        XCTAssertTrue(flatten(guide.window?.contentView).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "开启辅助功能" })
        granted.insert(.postEvent)
        guide.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        try XCTUnwrap(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "进入下一步" }
        ).performClick(nil)
        granted.insert(.inputMonitoring)
        guide.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        try XCTUnwrap(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "进入下一步" }
        ).performClick(nil)

        XCTAssertTrue(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "权限已全部开启" }
        )
    }

    func testPermissionGuideNamesTheCurrentAppEntryAndOffersRefresh() throws {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { false },
            postEventStatus: { false },
            inputMonitoringStatus: { false },
            openSettings: { _ in true },
            requestPermission: { _, completion in completion(false) },
            resetPermissions: { true }
        )
        let guide = PermissionSetupGuideWindowController(
            permissionChecker: checker,
            currentAppName: "Rime Voice Build196"
        )
        let nextButton = try XCTUnwrap(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "进入下一步" }
        )
        nextButton.performClick(nil)

        let labels = flatten(guide.window?.contentView)
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
        XCTAssertTrue(labels.contains { $0.contains("Rime Voice Build196") })
        XCTAssertTrue(labels.contains {
            $0.contains("只操作这一项：Rime Voice Build196")
        })
        XCTAssertFalse(labels.contains { $0.contains("拖动") })
        XCTAssertTrue(
            flatten(guide.window?.contentView)
                .compactMap { $0 as? NSButton }
                .contains { $0.title == "刷新授权状态" }
        )
    }

    func testKeyboardPermissionRequestsUseNativeHIDApprovalPrompt() {
        var requested: [PrivacyPermission] = []
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { false },
            inputMonitoringStatus: { false },
            requestHIDAccess: { permission in
                requested.append(permission)
                return false
            }
        )

        checker.requestPermission(for: .postEvent) { XCTAssertFalse($0) }
        checker.requestPermission(for: .inputMonitoring) { XCTAssertFalse($0) }

        XCTAssertEqual(requested, [.postEvent, .inputMonitoring])
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

    func testSettingsWindowSavesSelectedShortcutPreset() throws {
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
        let popup = try XCTUnwrap(
            flatten(contentView)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.itemTitles.contains("Page Down") }
        )
        popup.selectItem(withTitle: "Page Down")
        guard let action = popup.action else {
            XCTFail("快捷键预设下拉框没有绑定操作")
            return
        }
        XCTAssertTrue(NSApp.sendAction(action, to: popup.target, from: popup))

        let saveButton = try XCTUnwrap(
            flatten(contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "保存设置" }
        )
        saveButton.performClick(nil)

        XCTAssertEqual(savedSettings?.shortcut, ShortcutPreset.pageDown.shortcut)
        XCTAssertTrue(
            flatten(contentView)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "Page Down" }
        )
    }

    func testSettingsWindowSavesHiddenMenuBarIcon() throws {
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
        let hideMenuBarIconCheckbox = try XCTUnwrap(
            flatten(contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "隐藏菜单栏图标" }
        )
        let saveButton = try XCTUnwrap(
            flatten(contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "保存设置" }
        )

        XCTAssertEqual(hideMenuBarIconCheckbox.state, .off)
        hideMenuBarIconCheckbox.state = .on
        saveButton.performClick(nil)

        XCTAssertTrue(savedSettings?.hideMenuBarIcon == true)
    }

    func testSettingsDiagnosticLogCanBeExportedWithoutTogglingRecording() async throws {
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
            onExportDiagnosticLog: { _ in
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
        try await Task.sleep(for: .milliseconds(20))

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

    func testRimeDictionaryWindowUsesUpdatedActionLayoutAndDoesNotRefreshOnOpen() async throws {
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
        controller.begin()

        XCTAssertTrue(buttons.contains { $0.title == "刷新本机快照" })
        XCTAssertTrue(buttons.contains { $0.title == "导出" })
        XCTAssertTrue(buttons.contains { $0.title == "导入 AI 提案…" })
        XCTAssertTrue(buttons.contains { $0.title == "应用 AI 提案" })
        XCTAssertFalse(buttons.contains { $0.title == "关闭" })
        let export = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.title == "导出" })
        XCTAssertEqual(export.menu?.items.map(\.title), ["导出", "CSV", "TXT", "Markdown", "JSON"])

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(maintenance.calls.isEmpty, "打开词库管理不应自动备份或刷新本机快照")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("shared").path))
    }

    private func flatten(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(flatten)
    }

    private func existingExecutable(_ name: String, in directory: URL) -> URL? {
        let candidate = directory.appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private func run(_ executable: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private final class AppSmokeRimeMaintenance: NativeRimeMaintaining, RimeUserDictionaryMaintaining {
    private(set) var calls: [String] = []
    func syncUserData() throws { calls.append("sync") }
    func reload() throws { calls.append("reload") }
    func captureUserDictionarySnapshot(in rimeDirectory: URL) throws { calls.append("capture") }
    func restoreUserDictionarySnapshot(from snapshot: URL, in rimeDirectory: URL) throws { calls.append("restore") }
}

private final class AppSmokeRimeSync: RimeSyncEngine {
    func status() throws -> SyncReport { SyncReport() }
    func sync(dryRun: Bool) throws -> SyncReport { SyncReport() }
    func restore(backupID: String) throws {}
}
