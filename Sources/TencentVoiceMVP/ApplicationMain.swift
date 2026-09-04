import AppKit

@main
@MainActor
struct TencentVoiceMVPMain {
    static func main() {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "local.tencent-voice-mvp"
        let anotherInstanceIsRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentProcessID }
        guard !anotherInstanceIsRunning else { return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
