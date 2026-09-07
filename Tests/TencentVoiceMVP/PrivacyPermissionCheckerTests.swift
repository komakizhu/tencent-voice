import AVFoundation
import XCTest
@testable import TencentVoiceMVP

@MainActor
final class PrivacyPermissionCheckerTests: XCTestCase {
    func testReportListsEveryPermissionAndExplainsMissingItems() {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .denied },
            accessibilityStatus: { false },
            postEventStatus: { false },
            inputMonitoringStatus: { true }
        )

        let report = checker.report()

        XCTAssertEqual(report.statuses.map(\.permission), PrivacyPermission.allCases)
        XCTAssertEqual(report.missing, [.microphone, .accessibility, .postEvent])
        XCTAssertFalse(report.allGranted)
        XCTAssertTrue(report.summary.contains("麦克风"))
        XCTAssertTrue(report.summary.contains("打开设置"))
        XCTAssertEqual(report.status(for: .inputMonitoring)?.detail, "已允许")
    }

    func testReportIsCompleteWhenAllPermissionsAreGranted() {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .authorized },
            accessibilityStatus: { true },
            postEventStatus: { true },
            inputMonitoringStatus: { true }
        )

        let report = checker.report()

        XCTAssertTrue(report.allGranted)
        XCTAssertTrue(report.missing.isEmpty)
        XCTAssertEqual(
            report.summary,
            "系统权限完整，可以录音并把识别结果输入到当前应用。"
        )
    }

    func testKeyboardEventPermissionOpensAccessibilityPane() {
        XCTAssertEqual(PrivacyPermission.postEvent.settingsPane, "Privacy_Accessibility")
        XCTAssertEqual(PrivacyPermission.inputMonitoring.settingsPane, "Privacy_ListenEvent")
        XCTAssertEqual(
            PrivacyPermission.postEvent.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testPermissionActionsUseInjectedResetAndSettingsActions() {
        var resetCount = 0
        var openCount = 0
        var requestedPermission: PrivacyPermission?
        var requestResult = false
        let checker = SystemPrivacyPermissionChecker(
            openSettings: { permission in
                XCTAssertEqual(permission, .microphone)
                openCount += 1
                return true
            },
            requestPermission: { permission, completion in
                requestedPermission = permission
                completion(true)
            },
            resetPermissions: {
                resetCount += 1
                return true
            }
        )

        XCTAssertTrue(checker.resetPermissions())
        XCTAssertTrue(checker.openSettings(for: .microphone))
        checker.requestPermission(for: .inputMonitoring) { granted in
            requestResult = granted
        }
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(requestedPermission, .inputMonitoring)
        XCTAssertTrue(requestResult)
    }

    func testReportDoesNotTreatUndecidedOrDeniedPermissionsAsGranted() {
        let checker = SystemPrivacyPermissionChecker(
            microphoneStatus: { .notDetermined },
            accessibilityStatus: { false },
            postEventStatus: { false },
            inputMonitoringStatus: { false }
        )

        let report = checker.report()

        XCTAssertEqual(report.missing, PrivacyPermission.allCases)
        XCTAssertFalse(report.allGranted)
    }
}
