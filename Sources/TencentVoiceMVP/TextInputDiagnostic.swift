import Foundation

struct TextInputDiagnostic {
    let timestamp: Date
    let event: String
    let fields: [String: String]
}

// Poll acknowledgement only. Never resend keys; recheck focus on every read.
@MainActor
enum KeyboardCaretSynchronizer {
    struct Result {
        let selection: TextRange?
        let polls: Int
        let elapsedMilliseconds: Int
    }

    static func wait(
        expected: TextRange, initial: TextRange?, canWait: Bool,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        read: () throws -> TextRange?
    ) throws -> Result {
        let start = now()
        var actual = initial
        var polls = 0
        while canWait, actual != expected, polls < 15, now() - start < 0.15 {
            pause(min(0.01, max(0, 0.15 - (now() - start))))
            actual = try read()
            polls += 1
        }
        return Result(selection: actual, polls: polls,
                      elapsedMilliseconds: Int(max(0, now() - start) * 1_000))
    }
}
