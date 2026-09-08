import XCTest
@testable import TencentVoiceMVP

@MainActor
final class CodexTextInjectionTests: XCTestCase {
    func testCodexStreamsAndRevisesWithoutTrustingSuccessfulNoOpAXWrite() async throws {
        for prefix in ["", "Existing draft: "] {
            let target = NoOpAXTarget(prefix: prefix)
            let injector = TextInjector(target: target)
            try injector.begin()
            injector.apply(projection: candidate("hello", revision: 1))
            XCTAssertEqual(target.storage.text, prefix + "hello")
            injector.apply(projection: candidate("hello world", revision: 2))
            XCTAssertEqual(target.storage.text, prefix + "hello world")
            injector.apply(projection: candidate("hello there", revision: 3))
            try await injector.finish(finalText: "hello there")
            XCTAssertEqual(target.storage.text, prefix + "hello there")
            XCTAssertEqual(target.axCalls, 0)
            XCTAssertEqual(injector.errorCount, 0)
            XCTAssertEqual(injector.modeDescription, "keyboard_live_tail")
            XCTAssertNil(target.storage.copiedText)
        }
    }

    func testCodexStillStopsWhenKeyboardTargetChanges() async throws {
        let target = NoOpAXTarget(prefix: "Draft: ")
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: candidate("hello", revision: 1))
        target.keyboardTargetChanged = true
        injector.apply(projection: candidate("hello world", revision: 2))
        try await injector.finish(finalText: "hello world")
        XCTAssertEqual(target.storage.text, "Draft: hello")
        XCTAssertEqual(injector.degradationCode, "text_target_changed")
        XCTAssertEqual(injector.modeDescription, "disabled_after_error")
        XCTAssertNil(target.storage.copiedText)
    }

    func testOtherApplicationsKeepAXRouting() throws {
        for bundle in ["com.tencent.xinWeChat", "com.apple.Spotlight"] {
            let target = NoOpAXTarget(prefix: "", bundleIdentifier: bundle)
            let injector = TextInjector(target: target)
            try injector.begin()
            XCTAssertEqual(injector.modeDescription, "ax")
        }
    }

    private func candidate(_ text: String, revision: UInt64) -> ASRProjection {
        ASRProjection(committedText: "", activeSegmentText: text, activeSegmentID: 1,
                      activeIsFinal: false, revision: revision, changed: true, isFinal: false)
    }
}

// Reproduces the observed seam: AX reports a new range but leaves text unchanged.
@MainActor
private final class NoOpAXTarget: TextTarget {
    let storage: FakeTextTarget
    let bundleIdentifier: String
    var keyboardTargetChanged = false
    private(set) var axCalls = 0

    init(prefix: String, bundleIdentifier: String = "com.openai.codex") {
        storage = FakeTextTarget(text: prefix)
        self.bundleIdentifier = bundleIdentifier
    }

    func capture() throws -> TextSnapshot {
        TextSnapshot(text: storage.text,
                     selection: TencentVoiceMVP.TextRange(location: storage.text.utf16.count, length: 0),
                     supportsAXReplacement: true,
                     targetApplication: TextTargetApplication(name: "Target", bundleIdentifier: bundleIdentifier,
                                                              processIdentifier: 1))
    }

    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String,
                 with text: String) throws -> TencentVoiceMVP.TextRange {
        guard storage.text == expectedText else { throw TextTargetError.targetChanged }
        axCalls += 1
        return TencentVoiceMVP.TextRange(location: range.location, length: text.utf16.count)
    }

    func paste(_ text: String) throws {
        guard !keyboardTargetChanged else { throw TextTargetError.targetChanged }
        try storage.paste(text)
    }

    func replaceTrailingText(_ previousText: String, with text: String) throws {
        guard !keyboardTargetChanged else { throw TextTargetError.targetChanged }
        try storage.replaceTrailingText(previousText, with: text)
    }

    func copyToClipboard(_ text: String) throws {
        try storage.copyToClipboard(text)
    }
}
