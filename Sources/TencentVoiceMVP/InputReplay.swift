import AppKit
import ApplicationServices
import Foundation

// Explicit diagnostic CLI mode. No microphone, hotkey, window activation, or Return key.
@MainActor
enum InputReplay {
    static func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let status = await run()
            fflush(stdout)
            exit(status)
        }
        app.run()
    }

    private static func run() async -> Int32 {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--target-pid"), index + 1 < args.count,
              let pid = Int32(args[index + 1]),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == pid, app.bundleIdentifier == "com.openai.codex" else {
            print("Replay refused: specified Codex process must already be frontmost.")
            return 2
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            print("Replay refused: accessibility and keyboard-event permissions are required.")
            return 2
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            print("Replay refused: no focused accessibility element.")
            return 2
        }
        let element = focused as! AXUIElement
        let recorder = InputReplayRecorder(element: element, pid: pid)
        recorder.observe("preflight")
        if args.contains("--inspect-target") {
            var attributes: [String: Any] = [:]
            for name in ["AXRole", "AXSubrole", "AXValue", "AXPlaceholderValue", "AXTitle", "AXDescription", "AXHelp", "AXNumberOfCharacters"] {
                var result: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
                attributes[name] = ["status": status.rawValue, "value": result.map { String(describing: $0) } ?? "<unavailable>"]
            }
            recorder.emit(["event": "target_attributes", "attributes": attributes])
            return 0
        }
        let tailIndex = args.firstIndex(of: "--tail-count")
        guard ["AXTextArea", "AXTextField"].contains(recorder.stringAttribute(kAXRoleAttribute) ?? "") else {
            recorder.observe("refused_nontext_control")
            return 2
        }
        let tailCount = tailIndex.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 104
        guard (4...1000).contains(tailCount) else { return 2 }
        let prefix = String(repeating: "甲", count: 199)
        let original = prefix + String(repeating: "乙", count: tailCount)
        let shortRevision = prefix + String(repeating: "乙", count: tailCount - 4) + "丁丁丁丁"
        let longRevision = prefix + String(repeating: "丙", count: tailCount - 1)
        let candidates = [original, shortRevision, longRevision, longRevision + "下一句"]
        let remainderIndex = args.firstIndex(of: "--owned-remainder")
        let ownedRemainder = remainderIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if args.contains("--probe-selection") {
            guard recorder.stringAttribute(kAXRoleAttribute) == "AXTextArea",
                  let current = recorder.stringAttribute(kAXValueAttribute), !current.isEmpty,
                  candidates.contains(current) || current == ownedRemainder,
                  recorder.selection() == TextRange(location: current.utf16.count, length: 0) else {
                recorder.observe("selection_probe_refused_unknown_content")
                return 2
            }
            let selected = TextRange(location: 0, length: current.utf16.count)
            recorder.emit(["event": "selection_probe_set", "status": recorder.setSelection(selected)])
            for delay in [0, 50, 150] {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                recorder.observe("selection_probe_observation")
            }
            let matched = recorder.selection() == selected
            guard recorder.stringAttribute(kAXValueAttribute) == current else { return 1 }
            recorder.emit(["event": "selection_probe_restore", "status": recorder.setSelection(
                TextRange(location: current.utf16.count, length: 0))])
            recorder.emit(["event": "selection_probe_result", "matched": matched])
            return matched ? 0 : 1
        }
        if args.contains("--resume-test-fixture"), args.contains("--allow-test-input") {
            let fixtures = [104, 260, 520, tailCount].flatMap { count -> [String] in
                let initial = prefix + String(repeating: "乙", count: count)
                let short = prefix + String(repeating: "乙", count: count - 4) + "丁丁丁丁"
                let revised = prefix + String(repeating: "丙", count: count - 1)
                return [initial, short, revised, revised + "下", revised + "下一", revised + "下一句"]
            }
            if let current = recorder.stringAttribute(kAXValueAttribute),
               fixtures.contains(current) || (!current.isEmpty && current == ownedRemainder) {
                guard recorder.selection() == TextRange(location: current.utf16.count, length: 0) else {
                    recorder.observe("refused_fixture_selection_changed")
                    return 2
                }
                do {
                    let cleanupTarget = AXTextTarget()
                    _ = try cleanupTarget.capture()
                    try cleanupTarget.replaceTrailingText(current, with: "")
                    try await cleanupTarget.acknowledgeKeyboardWrite()
                    let deadline = ProcessInfo.processInfo.systemUptime + 10
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return 2 }
                        let value = recorder.stringAttribute(kAXValueAttribute)
                        if (value == "" || value == "\n随心输入"), recorder.selection() == TextRange(location: 0, length: 0) {
                            recorder.observe("owned_fixture_cleared")
                            break
                        }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                } catch {
                    recorder.emit(["event": "fixture_cleanup_failed", "code": DiagnosticErrorFormatter.code(for: error)])
                    return 2
                }
            }
        }
        // Reading an empty field can return its placeholder as the AX value.
        let value = recorder.stringAttribute(kAXValueAttribute)
        let placeholder = recorder.stringAttribute("AXPlaceholderValue")
        let selection = recorder.selection()
        // Only for a placeholder independently identified by a read-only inspection.
        let emptyIndex = args.firstIndex(of: "--known-empty-value")
        let knownEmptyValue = emptyIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        guard let value, (value.isEmpty || (!value.isEmpty && value == placeholder) || value == knownEmptyValue),
              selection?.location == 0, selection?.length == 0 else {
            recorder.observe("refused_nonempty_or_unreadable_field")
            return 2
        }
        guard args.contains("--allow-test-input") else {
            recorder.observe("read_only_preflight_complete")
            return 0
        }

        let target = AXTextTarget(operationObserver: { recorder.observe($0) })
        let injector = TextInjector(target: target, keyboardSmoothing: .live, safeCopyEnabled: false)
        defer { injector.cancel() }
        do {
            try injector.begin()
            for (index, candidate) in candidates.enumerated() {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    recorder.observe("abort_application_changed")
                    return 1
                }
                recorder.operation = index + 1
                recorder.expected = candidate
                recorder.observe("candidate_begin")
                injector.apply(projection: ASRProjection(
                    committedText: index == 3 ? longRevision : "",
                    activeSegmentText: index == 3 ? "下一句" : candidate,
                    activeSegmentID: index == 3 ? 1 : 0,
                    activeIsFinal: index != 3, revision: UInt64(index + 1), changed: true,
                    isFinal: index != 3
                ))
                // Cumulative snapshots at 0, 50, 150, 350 and 1000 ms after submission.
                recorder.observe("candidate_return")
                let overlapIndex = args.firstIndex(of: "--next-delay-ms")
                let overlapDelay = overlapIndex.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
                if index == 2, let overlapDelay {
                    try await Task.sleep(nanoseconds: UInt64(max(0, overlapDelay)) * 1_000_000)
                    recorder.observe("overlap_next_segment_due")
                    continue
                }
                let delayIndex = args.firstIndex(of: "--settle-ms")
                let settle = delayIndex.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 1000
                let delays = settle == 1000 ? [50, 100, 200, 650] : [max(1, settle)]
                for delay in delays {
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    recorder.observe("settling_observation")
                }
                for diagnostic in target.drainDiagnostics() {
                    recorder.emit(["event": diagnostic.event, "fields": diagnostic.fields])
                }
                recorder.emit(["event": "candidate_end", "mode": injector.modeDescription,
                               "writes": injector.writeCount, "errorCount": injector.errorCount])
                guard injector.errorCount == 0, recorder.matchesExpected(),
                      recorder.selection() == TextRange(location: candidate.utf16.count, length: 0) else {
                    recorder.observe("replay_failed")
                    return 1
                }
            }
            try await injector.finish(finalText: candidates.last!)
            recorder.observe("replay_passed")
            return 0
        } catch {
            recorder.emit(["event": "replay_error", "code": DiagnosticErrorFormatter.code(for: error)])
            return 1
        }
    }
}

// Called only from the main actor or a synchronous keyboard queue operation.
private final class InputReplayRecorder {
    let element: AXUIElement
    let pid: Int32
    let session = UUID().uuidString
    let start = ProcessInfo.processInfo.systemUptime
    var operation = 0
    var expected = ""

    init(element: AXUIElement, pid: Int32) {
        self.element = element
        self.pid = pid
    }

    func stringAttribute(_ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func selection() -> TextRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return TextRange(location: range.location, length: range.length)
    }

    func setSelection(_ selection: TextRange) -> Int32 {
        var current: CFTypeRef?
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &current) == .success,
              let current, CFEqual(current, element) else { return AXError.invalidUIElement.rawValue }
        var range = CFRange(location: selection.location, length: selection.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return AXError.failure.rawValue }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value).rawValue
    }

    func matchesExpected() -> Bool { stringAttribute(kAXValueAttribute) == expected }

    func observe(_ event: String) {
        let range = selection()
        var current: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                                        &current)
        emit(["event": event, "actualLocation": range?.location ?? -1, "actualLength": range?.length ?? -1,
              "documentLength": stringAttribute(kAXValueAttribute)?.utf16.count ?? -1,
              "expectedDocumentLength": expected.utf16.count, "documentMatches": matchesExpected(),
              "sameElement": current.map { CFEqual($0, element) } ?? false,
              "focusStatus": focusStatus.rawValue])
    }

    func emit(_ fields: [String: Any]) {
        var fields = fields
        fields["session"] = session
        fields["operation"] = operation
        fields["elapsedMilliseconds"] = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        fields["pid"] = pid
        fields["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        fields["appPath"] = Bundle.main.bundlePath
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
}
