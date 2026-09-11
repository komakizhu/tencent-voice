import Foundation

@MainActor
enum KeyboardReconciliation: Equatable {
    case matched
    case ownWriteInFlight
    case externalEdit
}

@MainActor
protocol KeyboardAcknowledgingTarget: TextTarget {
    var requiresKeyboardAcknowledgement: Bool { get }
    func acknowledgeKeyboardWrite() async throws
    func reconcileKeyboardStateForUserEdit() throws -> KeyboardReconciliation
    func writeKeyboardText(previousText: String, with text: String) async throws
}

extension KeyboardAcknowledgingTarget {
    func reconcileKeyboardStateForUserEdit() throws -> KeyboardReconciliation { .matched }

    // Targets that have not adopted the atomic preflight/send entry point keep
    // the existing synchronous send and acknowledgement lifecycle.
    func writeKeyboardText(previousText: String, with text: String) async throws {
        if previousText.isEmpty {
            try paste(text)
        } else {
            try replaceTrailingText(previousText, with: text)
        }
        try await acknowledgeKeyboardWrite()
    }
}

enum KeyboardWriteReadError: Error, Equatable {
    case retryable
}

struct KeyboardDocumentState: Equatable {
    let text: String
    let selection: TextRange
    let rawText: String?
    let mapping: AXTextCoordinateMapping?

    init(
        text: String,
        selection: TextRange,
        rawText: String? = nil,
        mapping: AXTextCoordinateMapping? = nil
    ) {
        self.text = text
        self.selection = selection
        self.rawText = rawText
        self.mapping = mapping
    }

    func compare(
        to expected: KeyboardDocumentState,
        allowingStructuralRawDifference: Bool = false
    ) -> KeyboardDocumentComparison {
        guard text == expected.text else { return .documentMismatch }
        guard selection == expected.selection else { return .selectionMismatch }
        if allowingStructuralRawDifference {
            guard let mapping else { return .rawMappingUnavailable }
            if mapping.source == .placeholder {
                guard text.isEmpty,
                      selection == TextRange(location: 0, length: 0),
                      mapping.coordinateDocumentLength == 0,
                      mapping.rawDocumentLength == rawText?.utf16.count,
                      mapping.rawBoundaryOffsets == [0],
                      let placeholderRange = mapping.rawPlaceholderRange,
                      placeholderRange == TextRange(
                          location: 0,
                          length: mapping.rawDocumentLength
                      ) else {
                    return .rawMappingUnavailable
                }
                return .matched
            }
            let textUTF16 = Array(text.utf16)
            guard mapping.coordinateDocumentLength == text.utf16.count,
                  mapping.rawDocumentLength == rawText?.utf16.count,
                  mapping.rawBoundaryOffsets.count == text.utf16.count + 1,
                  mapping.rawBoundaryOffsets.first == 0,
                  mapping.rawBoundaryOffsets.last == rawText?.utf16.count,
                  mapping.rawBoundaryOffsets.enumerated().allSatisfy({ index, offset in
                      if offset >= 0 {
                          return offset <= mapping.rawDocumentLength
                      }
                      guard index > 0, index < text.utf16.count else { return false }
                      return textUTF16[index - 1] >= 0xD800 && textUTF16[index - 1] <= 0xDBFF
                          && textUTF16[index] >= 0xDC00 && textUTF16[index] <= 0xDFFF
                  }) else {
                return .rawMappingUnavailable
            }
            var previousOffset = 0
            for offset in mapping.rawBoundaryOffsets where offset >= 0 {
                guard offset >= previousOffset else { return .rawMappingUnavailable }
                previousOffset = offset
            }
            return .matched
        }
        guard rawText == expected.rawText else { return .rawTextMismatch }
        return .matched
    }
}

enum KeyboardDocumentComparison: String, Equatable {
    case matched
    case documentMismatch
    case selectionMismatch
    case rawTextMismatch
    case rawMappingUnavailable
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
        } catch let error as AXTextDocumentResolutionError {
            // A coordinate read can be transient while a renderer publishes a
            // new accessibility tree. Invalid ranges, bounds and mappings are
            // terminal observations and must reach the caller unchanged.
            switch error {
            case .coordinateReadUnavailable, .coordinateTextMismatch:
                throw KeyboardWriteReadError.retryable
            case .invalidSelection, .coordinateLengthMismatch,
                    .selectionOutOfBounds, .selectedRangeUnavailable:
                throw error
            }
        }
    }

    static func replaceSelection(
        selected: KeyboardDocumentState,
        result: KeyboardDocumentState,
        matches: @escaping (KeyboardDocumentState, KeyboardDocumentState) -> Bool = { $0 == $1 },
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        read: () throws -> KeyboardDocumentState,
        insert: () throws -> Void
    ) async throws -> KeyboardDocumentState {
        _ = try await wait(
            for: selected,
            matches: matches,
            timeoutNanoseconds: timeoutNanoseconds,
            now: now,
            sleep: sleep,
            read: read
        )
        try Task.checkCancellation()
        try insert()
        return try await wait(
            for: result,
            matches: matches,
            timeoutNanoseconds: timeoutNanoseconds,
            now: now,
            sleep: sleep,
            read: read
        )
    }

    static func wait(
        for expected: KeyboardDocumentState,
        matches: @escaping (KeyboardDocumentState, KeyboardDocumentState) -> Bool = { $0 == $1 },
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        read: () throws -> KeyboardDocumentState
    ) async throws -> KeyboardDocumentState {
        let start = now()
        while true {
            try Task.checkCancellation()
            do {
                let observed = try read()
                if matches(expected, observed) { return observed }
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
    struct OperationContext {
        let diagnostic: TextInputDiagnosticContext
        let onDispatch: () -> Void
        let onFinish: (_ status: String, _ error: Error?) -> Void
    }

    private let target: any KeyboardAcknowledgingTarget
    private let onCommit: (String, String) -> Void
    private let onFailure: (Error) -> Void
    private let operationContextProvider: ((String, String) -> OperationContext?)?
    private var desiredText = ""
    private(set) var confirmedText = ""
    private var runner: Task<Void, Never>?
    private var runnerGeneration: UInt64 = 0
    private var failure: Error?
    private var cancelled = false

    var hasPendingWork: Bool {
        runner != nil || desiredText != confirmedText
    }

    init(target: any KeyboardAcknowledgingTarget,
         onCommit: @escaping (String, String) -> Void,
         onFailure: @escaping (Error) -> Void,
         operationContextProvider: ((String, String) -> OperationContext?)? = nil) {
        self.target = target
        self.onCommit = onCommit
        self.onFailure = onFailure
        self.operationContextProvider = operationContextProvider
    }

    func accept(_ candidate: String) throws {
        guard !cancelled else { throw CancellationError() }
        if let failure { throw failure }
        desiredText = candidate
        guard runner == nil, desiredText != confirmedText else { return }
        runnerGeneration &+= 1
        let generation = runnerGeneration
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.runnerGeneration == generation {
                    self.runner = nil
                }
            }
            do {
                while self.runnerGeneration == generation,
                      self.desiredText != self.confirmedText {
                    try Task.checkCancellation()
                    let submitted = self.desiredText
                    let previous = self.confirmedText
                    let prefix = sharedTextPrefix(previous, submitted)
                    let previousTail = String(previous.dropFirst(prefix.count))
                    let newTail = String(submitted.dropFirst(prefix.count))
                    let operation = self.operationContextProvider?(previous, submitted)
                    if let operation {
                        self.target.setDiagnosticOperation(operation.diagnostic)
                        operation.onDispatch()
                    }
                    do {
                        try await self.target.writeKeyboardText(
                            previousText: previousTail,
                            with: newTail
                        )
                        operation?.onFinish("acknowledged", nil)
                    } catch is CancellationError {
                        operation?.onFinish("cancelled", nil)
                        if operation != nil { self.target.setDiagnosticOperation(nil) }
                        throw CancellationError()
                    } catch {
                        operation?.onFinish("unconfirmed", error)
                        if operation != nil { self.target.setDiagnosticOperation(nil) }
                        throw error
                    }
                    if operation != nil { self.target.setDiagnosticOperation(nil) }
                    try Task.checkCancellation()
                    guard self.runnerGeneration == generation else { throw CancellationError() }
                    self.confirmedText = submitted
                    self.onCommit(previous, submitted)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.runnerGeneration == generation else { return }
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
        runnerGeneration &+= 1
        runner?.cancel()
        runner = nil
    }

    func resetForExternalEdit() {
        runnerGeneration &+= 1
        runner?.cancel()
        runner = nil
        desiredText = ""
        confirmedText = ""
        failure = nil
        cancelled = false
    }
}
