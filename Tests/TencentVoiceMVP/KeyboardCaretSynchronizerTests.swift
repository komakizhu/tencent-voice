import XCTest
@testable import TencentVoiceMVP

@MainActor
final class KeyboardCaretSynchronizerTests: XCTestCase {
    func testObserved127To128DelayRecoversWithoutResendingInput() throws {
        var time: TimeInterval = 0
        var reads = 0
        let expected = TencentVoiceMVP.TextRange(location: 128, length: 0)
        let result = try KeyboardCaretSynchronizer.wait(
            expected: expected, initial: .init(location: 127, length: 0), canWait: true,
            now: { time }, pause: { time += $0 },
            read: {
                reads += 1
                return .init(location: time >= 0.05 ? 128 : 127, length: 0)
            }
        )
        XCTAssertEqual(result.selection, expected)
        XCTAssertGreaterThanOrEqual(reads, 5)
        XCTAssertLessThanOrEqual(result.elapsedMilliseconds, 150)
    }

    func testPersistentCaretChangeTimesOut() throws {
        var time: TimeInterval = 0
        let actual = TencentVoiceMVP.TextRange(location: 20, length: 0)
        let result = try KeyboardCaretSynchronizer.wait(
            expected: .init(location: 128, length: 0), initial: actual, canWait: true,
            now: { time }, pause: { time += $0 }, read: { actual }
        )
        XCTAssertEqual(result.selection, actual)
        XCTAssertEqual(result.polls, 15)
        XCTAssertLessThanOrEqual(time, 0.151)
    }

    func testFocusChangeDuringWaitAbortsImmediately() {
        var time: TimeInterval = 0
        XCTAssertThrowsError(try KeyboardCaretSynchronizer.wait(
            expected: .init(location: 128, length: 0), initial: .init(location: 127, length: 0),
            canWait: true, now: { time }, pause: { time += $0 },
            read: { throw TextTargetError.targetChanged }
        ))
        XCTAssertEqual(time, 0.01, accuracy: 0.0001)
    }

    func testNoRecentDispatchDoesNotWaitOrIgnoreUserCaretMovement() throws {
        let result = try KeyboardCaretSynchronizer.wait(
            expected: .init(location: 128, length: 0), initial: .init(location: 40, length: 0),
            canWait: false, pause: { _ in XCTFail("Must not wait") },
            read: { XCTFail("Must not retry"); return nil }
        )
        XCTAssertEqual(result.polls, 0)
        XCTAssertEqual(result.selection?.location, 40)
    }

    func testSynchronizedCaretHasNoExtraLatency() throws {
        let expected = TencentVoiceMVP.TextRange(location: 128, length: 0)
        let result = try KeyboardCaretSynchronizer.wait(
            expected: expected, initial: expected, canWait: true,
            pause: { _ in XCTFail("Must not wait") },
            read: { XCTFail("Must not retry"); return nil }
        )
        XCTAssertEqual(result.polls, 0)
    }
}
