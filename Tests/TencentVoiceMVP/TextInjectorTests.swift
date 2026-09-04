import XCTest
@testable import TencentVoiceMVP

@MainActor
final class TextInjectorTests: XCTestCase {
    func testPartialUpdatesReplaceOwnedRange() throws {
        let target = FakeTextTarget(text: "前缀")
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "你", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "", active: "你好", id: 1, revision: 2))
        injector.apply(projection: projection(committed: "", active: "你好呀", id: 1, revision: 3, isFinal: true))
        try injector.finish(finalText: "你好呀")
        XCTAssertEqual(target.text, "前缀你好呀")
        XCTAssertEqual(target.replaceCallCount, 3)
    }

    func testExternalEditStopsLiveReplacementAndCopiesFinal() throws {
        let target = FakeTextTarget(text: "原文")
        let injector = TextInjector(target: target)
        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "临时", id: 1, revision: 1))
        target.text = "用户自己改过的文字"
        injector.apply(projection: projection(committed: "", active: "最终", id: 1, revision: 2))
        try injector.finish(finalText: "最终")
        XCTAssertEqual(target.text, "用户自己改过的文字")
        XCTAssertEqual(target.copiedText, "最终")
    }

    func testAXUnsupportedTargetUsesKeyboardTransactionalModeWhenReadable() throws {
        let target = KeyboardTransactionalTextTarget()
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "实时", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "", active: "实时结果", id: 1, revision: 2))
        try injector.finish(finalText: "实时结果")

        XCTAssertEqual(target.pastedTexts, ["实时"])
        XCTAssertEqual(target.replacementTexts, ["实时结果"])
        XCTAssertNil(target.copiedText)
    }

    func testKeyboardTransactionalModeDoesNotDeleteEarlierSegment() throws {
        let target = KeyboardTransactionalTextTarget()
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "第一段", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "第一段", active: "第二段", id: 2, revision: 2))
        try injector.finish(finalText: "第一段第二段")

        XCTAssertTrue(target.replacementCalls.isEmpty)
        XCTAssertEqual(target.pastedTexts, ["第一段", "第二段"])
        XCTAssertNil(target.copiedText)
    }

    func testKeyboardAppendOnlyModeOnlyAppendsCommittedText() throws {
        let target = AppendOnlyTextTarget()
        let injector = TextInjector(target: target)

        try injector.begin()
        injector.apply(projection: projection(committed: "", active: "第一", id: 1, revision: 1))
        injector.apply(projection: projection(committed: "第一", active: "第二", id: 2, revision: 2))
        injector.apply(projection: projection(committed: "第一", active: "第二段", id: 2, revision: 3, isFinal: true))
        try injector.finish(finalText: "第一第二段")

        XCTAssertEqual(target.pastedTexts, ["第一", "第二段"])
        XCTAssertNil(target.copiedText)
    }
}

@MainActor
private func projection(
    committed: String,
    active: String,
    id: Int,
    revision: UInt64,
    isFinal: Bool = false
) -> ASRProjection {
    ASRProjection(
        committedText: committed,
        activeSegmentText: active,
        activeSegmentID: id,
        activeIsFinal: isFinal,
        revision: revision,
        changed: true,
        isFinal: isFinal
    )
}

@MainActor
private class KeyboardTransactionalTextTarget: TextTarget {
    private(set) var pastedTexts: [String] = []
    private(set) var replacementTexts: [String] = []
    private(set) var copiedText: String?
    private(set) var replacementCalls: [(String, String)] = []

    func capture() throws -> TextSnapshot {
        TextSnapshot(text: "", selection: TextRange(location: 0, length: 0), supportsAXReplacement: false)
    }

    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String, with replacement: String) throws -> TencentVoiceMVP.TextRange {
        throw TextTargetError.writeFailed
    }

    func replacePastedText(previousText: String, with text: String) throws {
        replacementTexts.append(text)
        replacementCalls.append((previousText, text))
    }

    func paste(_ text: String) throws {
        pastedTexts.append(text)
    }

    func copyToClipboard(_ text: String) throws {
        copiedText = text
    }
}

@MainActor
private final class AppendOnlyTextTarget: TextTarget {
    private(set) var pastedTexts: [String] = []
    private(set) var copiedText: String?

    func capture() throws -> TextSnapshot {
        throw TextTargetError.unsupported
    }

    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String, with replacement: String) throws -> TencentVoiceMVP.TextRange {
        throw TextTargetError.unsupported
    }

    func replacePastedText(previousText: String, with text: String) throws {
        throw TextTargetError.unsupported
    }

    func paste(_ text: String) throws {
        pastedTexts.append(text)
    }

    func copyToClipboard(_ text: String) throws {
        copiedText = text
    }
}
