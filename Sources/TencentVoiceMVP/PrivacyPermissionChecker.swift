import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum PrivacyPermission: Int, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case microphone
    case accessibility
    case postEvent
    case inputMonitoring

    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .accessibility: return "辅助功能"
        case .postEvent: return "发送键盘事件"
        case .inputMonitoring: return "输入监控"
        }
    }

    var purpose: String {
        switch self {
        case .microphone:
            return "采集语音并发送给腾讯实时识别"
        case .accessibility:
            return "读取并写入当前应用的输入框"
        case .postEvent:
            return "把识别结果作为文字输入到当前应用"
        case .inputMonitoring:
            return "监听全局快捷键"
        }
    }

    var settingsPane: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility, .postEvent: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }

    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)")
    }
}

struct PrivacyPermissionStatus: Codable, Equatable, Sendable {
    let permission: PrivacyPermission
    let isGranted: Bool
    let detail: String
}

struct PrivacyPermissionReport: Codable, Equatable, Sendable {
    let statuses: [PrivacyPermissionStatus]

    var allGranted: Bool {
        statuses.allSatisfy(\.isGranted)
    }

    var missing: [PrivacyPermission] {
        statuses.filter { !$0.isGranted }.map(\.permission)
    }

    func status(for permission: PrivacyPermission) -> PrivacyPermissionStatus? {
        statuses.first { $0.permission == permission }
    }

    var summary: String {
        guard !allGranted else {
            return "系统权限完整，可以录音并把识别结果输入到当前应用。"
        }
        let missingNames = missing.map(\.title).joined(separator: "、")
        return "还缺少：\(missingNames)。点击“重置并重新授权”清除旧记录并重新开启，或点击对应的“打开设置”进行单项授权；回到此窗口后会自动刷新。"
    }
}

@MainActor
protocol PrivacyPermissionChecking: AnyObject {
    func report() -> PrivacyPermissionReport
    @discardableResult
    func openSettings(for permission: PrivacyPermission) -> Bool
    func requestPermission(
        for permission: PrivacyPermission,
        completion: @escaping (Bool) -> Void
    )
    @discardableResult
    func resetPermissions() -> Bool
}

@MainActor
final class SystemPrivacyPermissionChecker: PrivacyPermissionChecking {
    private let microphoneStatus: () -> AVAuthorizationStatus
    private let accessibilityStatus: () -> Bool
    private let postEventStatus: () -> Bool
    private let inputMonitoringStatus: () -> Bool
    private let openSettingsAction: (PrivacyPermission) -> Bool
    private let requestPermissionAction: (PrivacyPermission, @escaping (Bool) -> Void) -> Void
    private let resetPermissionsAction: () -> Bool

    init(
        microphoneStatus: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        accessibilityStatus: @escaping () -> Bool = {
            AXIsProcessTrusted()
        },
        postEventStatus: @escaping () -> Bool = {
            CGPreflightPostEventAccess()
        },
        inputMonitoringStatus: @escaping () -> Bool = {
            CGPreflightListenEventAccess()
        },
        openSettings: ((PrivacyPermission) -> Bool)? = nil,
        requestPermission: ((PrivacyPermission, @escaping (Bool) -> Void) -> Void)? = nil,
        resetPermissions: (() -> Bool)? = nil
    ) {
        self.microphoneStatus = microphoneStatus
        self.accessibilityStatus = accessibilityStatus
        self.postEventStatus = postEventStatus
        self.inputMonitoringStatus = inputMonitoringStatus
        openSettingsAction = openSettings ?? { permission in
            Self.openSystemSettings(for: permission)
        }
        requestPermissionAction = requestPermission ?? { permission, completion in
            switch permission {
            case .microphone:
                AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
            case .accessibility:
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                completion(AXIsProcessTrustedWithOptions(options))
            case .postEvent:
                completion(CGRequestPostEventAccess())
            case .inputMonitoring:
                completion(CGRequestListenEventAccess())
            }
        }
        resetPermissionsAction = resetPermissions ?? Self.resetSystemPermissions
    }

    func report() -> PrivacyPermissionReport {
        let currentMicrophoneStatus = microphoneStatus()
        let hasAccessibility = accessibilityStatus()
        let canPostEvents = postEventStatus()
        let canMonitorInput = inputMonitoringStatus()
        return PrivacyPermissionReport(statuses: [
            PrivacyPermissionStatus(
                permission: .microphone,
                isGranted: currentMicrophoneStatus == .authorized,
                detail: microphoneDetail(currentMicrophoneStatus)
            ),
            PrivacyPermissionStatus(
                permission: .accessibility,
                isGranted: hasAccessibility,
                detail: hasAccessibility ? "已允许" : "未允许"
            ),
            PrivacyPermissionStatus(
                permission: .postEvent,
                isGranted: canPostEvents,
                detail: canPostEvents ? "已允许" : "未允许"
            ),
            PrivacyPermissionStatus(
                permission: .inputMonitoring,
                isGranted: canMonitorInput,
                detail: canMonitorInput ? "已允许" : "未允许"
            )
        ])
    }

    @discardableResult
    func openSettings(for permission: PrivacyPermission) -> Bool {
        openSettingsAction(permission)
    }

    func requestPermission(
        for permission: PrivacyPermission,
        completion: @escaping (Bool) -> Void
    ) {
        requestPermissionAction(permission, completion)
    }

    @discardableResult
    func resetPermissions() -> Bool {
        resetPermissionsAction()
    }

    private static func openSystemSettings(for permission: PrivacyPermission) -> Bool {
        guard let url = permission.settingsURL else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private static func resetSystemPermissions() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", bundleIdentifier]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func microphoneDetail(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已允许"
        case .notDetermined: return "尚未决定"
        case .denied: return "未允许"
        case .restricted: return "受系统限制"
        @unknown default: return "状态未知"
        }
    }
}
