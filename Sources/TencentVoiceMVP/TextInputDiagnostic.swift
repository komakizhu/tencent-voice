import Foundation

struct TextInputDiagnostic {
    let eventID: UUID
    let timestamp: Date
    let monotonicTimestampNanoseconds: UInt64
    let event: String
    let fields: [String: String]
    let textEvidence: [DiagnosticTextEvidence]

    var estimatedDiagnosticBytes: Int {
        256 + fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + textEvidence.reduce(0) { $0 + 256 + $1.text.utf8.count }
    }

    init(
        eventID: UUID = UUID(),
        timestamp: Date,
        monotonicTimestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        event: String,
        fields: [String: String],
        textEvidence: [DiagnosticTextEvidence] = []
    ) {
        self.eventID = eventID
        self.timestamp = timestamp
        self.monotonicTimestampNanoseconds = monotonicTimestampNanoseconds
        self.event = event
        self.fields = fields
        self.textEvidence = textEvidence
    }
}

struct TextInputDiagnosticContext {
    let operationID: Int
    let operationType: String
    let fields: [String: String]
}

enum TextInputDiagnosticClock {
    static func milliseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
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
