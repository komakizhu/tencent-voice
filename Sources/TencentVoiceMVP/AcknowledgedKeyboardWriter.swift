import Foundation

@MainActor
protocol KeyboardAcknowledgingTarget: TextTarget {
    var requiresKeyboardAcknowledgement: Bool { get }
    func acknowledgeKeyboardWrite() async throws
}

enum KeyboardWriteReadError: Error, Equatable {
    case retryable
}

struct KeyboardDocumentState: Equatable {
    let text: String
    let selection: TextRange
    let rawText: String?

    init(text: String, selection: TextRange, rawText: String? = nil) {
        self.text = text
        self.selection = selection
        self.rawText = rawText
    }
}

// A deadline bounds an unresponsive target; it never defines successful delivery.
// In particular, a matching caret with stale, same-length text is not a receipt.
@MainActor
enum KeyboardWriteAcknowledgement {
    // Only used while confirming an already posted operation. An inconsistent
    // AX snapshot is not a receipt and must never cause another keyboard post.
    static func readObservation(_ read: () throws -> KeyboardDocumentState) throws -> KeyboardDocumentState {
        do {
            return try read()
        } catch is AXTextDocumentResolutionError {
            throw KeyboardWriteReadError.retryable
        }
    }

    static func replaceSelection(
        selected: KeyboardDocumentState,
        result: KeyboardDocumentState,
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        read: () throws -> KeyboardDocumentState,
        insert: () throws -> Void
    ) async throws {
        try await wait(for: selected, timeoutNanoseconds: timeoutNanoseconds, now: now, sleep: sleep, read: read)
        try Task.checkCancellation()
        try insert()
        try await wait(for: result, timeoutNanoseconds: timeoutNanoseconds, now: now, sleep: sleep, read: read)
    }

    static func wait(
        for expected: KeyboardDocumentState,
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        read: () throws -> KeyboardDocumentState
    ) async throws {
        let start = now()
        while true {
            try Task.checkCancellation()
            do {
                if try read() == expected { return }
            } catch let error as KeyboardWriteReadError where error == .retryable {
                // A renderer may expose the new caret before its AXValue. The
                // existing acknowledgement deadline remains the only bound.
                _ = error
            }
            let elapsed = now() &- start
            guard elapsed < timeoutNanoseconds else { throw TextTargetError.writeFailed }
            try await sleep(min(10_000_000, timeoutNanoseconds - elapsed))
        }
    }
}

// The pacer owns desired presentation timing; this writer owns delivery order.
// Intermediate candidates may be coalesced, but a posted edit is never retried.
@MainActor
final class AcknowledgedKeyboardWriter {
    private let target: any KeyboardAcknowledgingTarget
    private let onCommit: (String, String) -> Void
    private let onFailure: (Error) -> Void
    private var desiredText = ""
    private(set) var confirmedText = ""
    private var runner: Task<Void, Never>?
    private var failure: Error?
    private var cancelled = false

    init(target: any KeyboardAcknowledgingTarget,
         onCommit: @escaping (String, String) -> Void,
         onFailure: @escaping (Error) -> Void) {
        self.target = target
        self.onCommit = onCommit
        self.onFailure = onFailure
    }

    func accept(_ candidate: String) throws {
        guard !cancelled else { throw CancellationError() }
        if let failure { throw failure }
        desiredText = candidate
        guard runner == nil, desiredText != confirmedText else { return }
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runner = nil }
            do {
                while self.desiredText != self.confirmedText {
                    try Task.checkCancellation()
                    let submitted = self.desiredText
                    let previous = self.confirmedText
                    let prefix = sharedTextPrefix(previous, submitted)
                    let previousTail = String(previous.dropFirst(prefix.count))
                    let newTail = String(submitted.dropFirst(prefix.count))
                    if previousTail.isEmpty {
                        try self.target.paste(newTail)
                    } else {
                        try self.target.replaceTrailingText(previousTail, with: newTail)
                    }
                    try await self.target.acknowledgeKeyboardWrite()
                    try Task.checkCancellation()
                    self.confirmedText = submitted
                    self.onCommit(previous, submitted)
                }
            } catch is CancellationError {
                return
            } catch {
                self.failure = error
                self.onFailure(error)
            }
        }
    }

    func finish(_ candidate: String) async throws {
        try accept(candidate)
        while let task = runner { await task.value }
        if let failure { throw failure }
        guard !cancelled else { throw CancellationError() }
    }

    func cancel() {
        cancelled = true
        runner?.cancel()
    }
}
