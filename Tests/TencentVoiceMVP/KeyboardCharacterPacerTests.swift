import XCTest
@testable import TencentVoiceMVP

@MainActor
final class KeyboardCharacterPacerTests: XCTestCase {
    func testFirstCharacterIsImmediateAndFollowingCharactersUseOneContinuousQueue() async throws {
        let clock = ManualKeyboardPacingClock()
        var pastedTexts: [String] = []
        let pacer = KeyboardCharacterPacer(
            configuration: .test,
            clock: clock,
            append: { pastedTexts.append($0) },
            replaceTrailingText: { _, _ in },
            onFailure: { _ in }
        )

        pacer.beginSession()
        try pacer.accept(candidate: "甲乙", trigger: .partial)
        XCTAssertEqual(pastedTexts, ["甲"])
        await settle()

        try pacer.accept(candidate: "甲乙丙丁", trigger: .partial)
        XCTAssertEqual(pastedTexts, ["甲"])

        clock.advance(by: 60_000_000)
        await settle()
        XCTAssertEqual(pastedTexts, ["甲", "乙"])

        clock.advance(by: 60_000_000)
        await settle()
        XCTAssertEqual(pastedTexts, ["甲", "乙", "丙"])
    }

    func testFinalUsesBoundedNonlinearFlush() async throws {
        let clock = ManualKeyboardPacingClock()
        var pastedTexts: [String] = []
        let pacer = KeyboardCharacterPacer(
            configuration: .test,
            clock: clock,
            append: { pastedTexts.append($0) },
            replaceTrailingText: { _, _ in },
            onFailure: { _ in }
        )

        pacer.beginSession()
        try pacer.accept(candidate: "甲乙丙丁戊", trigger: .partial)
        XCTAssertEqual(pastedTexts, ["甲"])

        try pacer.accept(candidate: "甲乙丙丁戊", trigger: .segmentFinal)
        XCTAssertGreaterThanOrEqual(pastedTexts.count, 2)
        XCTAssertLessThan(pastedTexts.count, 5)
        await settle()

        clock.advance(by: 120_000_000)
        await settle()
        XCTAssertEqual(pastedTexts.joined(), "甲乙丙丁戊")
    }

    func testPendingRevisionChangesMemoryWithoutReplacingVisibleText() async throws {
        let clock = ManualKeyboardPacingClock()
        var pastedTexts: [String] = []
        var replacements: [(String, String)] = []
        let pacer = KeyboardCharacterPacer(
            configuration: .test,
            clock: clock,
            append: { pastedTexts.append($0) },
            replaceTrailingText: { previous, replacement in
                replacements.append((previous, replacement))
            },
            onFailure: { _ in }
        )

        pacer.beginSession()
        try pacer.accept(candidate: "甲乙丙丁", trigger: .partial)
        await settle()
        try pacer.accept(candidate: "甲乙改丁", trigger: .partial)

        XCTAssertEqual(replacements.count, 0)
        clock.advance(by: 250_000_000)
        await settle()
        XCTAssertEqual(pastedTexts.joined(), "甲乙改丁")
    }

    func testSubsequentBatchUsesReservoirAfterTheQueueDrains() async throws {
        let clock = ManualKeyboardPacingClock()
        var pastedTexts: [String] = []
        let pacer = KeyboardCharacterPacer(
            configuration: .test,
            clock: clock,
            append: { pastedTexts.append($0) },
            replaceTrailingText: { _, _ in },
            onFailure: { _ in }
        )

        pacer.beginSession()
        try pacer.accept(candidate: "甲", trigger: .partial)
        XCTAssertEqual(pastedTexts, ["甲"])

        try pacer.accept(candidate: "甲乙", trigger: .partial)
        await settle()
        XCTAssertEqual(pastedTexts, ["甲"])

        clock.advance(by: 40_000_000)
        await settle()
        XCTAssertEqual(pastedTexts, ["甲"])

        clock.advance(by: 100_000_000)
        await settle()
        XCTAssertEqual(pastedTexts.joined(), "甲乙")
    }

    func testVisibleRevisionReplacesOnlyTheAlreadyVisibleTail() async throws {
        let clock = ManualKeyboardPacingClock()
        var replacements: [(String, String)] = []
        let pacer = KeyboardCharacterPacer(
            configuration: .test,
            clock: clock,
            append: { _ in },
            replaceTrailingText: { previous, replacement in
                replacements.append((previous, replacement))
            },
            onFailure: { _ in }
        )

        pacer.beginSession()
        try pacer.accept(candidate: "甲乙丙丁", trigger: .partial)
        await settle()
        clock.advance(by: 60_000_000)
        await settle()

        try pacer.accept(candidate: "甲改丙丁", trigger: .partial)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements.first?.0, "乙")
        XCTAssertEqual(replacements.first?.1, "改")
    }

    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}
