import Foundation

@MainActor
final class TextInjector {
    private enum Mode: Equatable {
        case inactive
        case ax
        case keyboardLiveTail
        case safeCopy
        case disabledAfterError
    }

    private let target: TextTarget
    private let safeCopyEnabled: Bool
    private let keyboardPacing: KeyboardPacingConfiguration
    private let pacingClock: KeyboardPacingClock
    private var keyboardPacer: KeyboardCharacterPacer?
    private var snapshot: TextSnapshot?
    private var ownedRange = TextRange(location: 0, length: 0)
    private var lastDocumentText = ""
    private var lastProjectionText = ""
    private var lastSubmittedText = ""
    // Revisions inside this tail are the normal fast path. Deeper revisions
    // still update immediately, but are counted separately because they select
    // a longer suffix before replacing it in one transaction.
    private let deepReplacementThreshold = 12
    private var mode: Mode = .inactive
    private(set) var writeCount = 0
    private(set) var backspaceCount = 0
    private(set) var deepReplacementCount = 0
    private(set) var maximumTrailingReplacementLength = 0
    private(set) var errorCount = 0
    private(set) var degradationReason: String?
    private(set) var degradationOccurredAt: Date?
    private(set) var degradationOccurredMonotonicMilliseconds: UInt64?
    private var nextOperationID = 0
    private var diagnostics: [TextInputDiagnostic] = []
    private var droppedDiagnosticCount = 0
    private let diagnosticLimit = 128
    private var currentProjectionDiagnosticFields: [String: String] = [:]
    private var previousProjectionSegmentID: Int?

    init(
        target: TextTarget,
        keyboardSmoothing: KeyboardSmoothingConfiguration = .immediate,
        pacingClock: KeyboardPacingClock? = nil,
        safeCopyEnabled: Bool = false
    ) {
        self.target = target
        self.safeCopyEnabled = safeCopyEnabled
        self.keyboardPacing = keyboardSmoothing
        self.pacingClock = pacingClock ?? ContinuousKeyboardPacingClock()
    }

    var modeDescription: String {
        switch mode {
        case .inactive: return "inactive"
        case .ax: return "ax"
        case .keyboardLiveTail: return "keyboard_live_tail"
        case .safeCopy: return "safe_copy"
        case .disabledAfterError: return "disabled_after_error"
        }
    }

    var targetApplication: TextTargetApplication? {
        snapshot?.targetApplication ?? target.currentApplication()
    }

    private(set) var degradationCode: String?

    func drainDiagnostics() -> [TextInputDiagnostic] {
        var result = diagnostics
        diagnostics.removeAll(keepingCapacity: true)
        result.append(contentsOf: target.drainDiagnostics())
        if droppedDiagnosticCount > 0 {
            result.append(TextInputDiagnostic(
                timestamp: Date(),
                event: "input_diagnostics_truncated",
                fields: ["droppedEventCount": String(droppedDiagnosticCount)]
            ))
            droppedDiagnosticCount = 0
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    func begin() throws {
        resetForBegin()
        do {
            let captured = try target.capture()
            snapshot = captured
            ownedRange = captured.selection
            lastDocumentText = captured.text
            lastProjectionText = ""
            lastSubmittedText = ""
            writeCount = 0
            backspaceCount = 0
            deepReplacementCount = 0
            maximumTrailingReplacementLength = 0
            errorCount = 0
            degradationCode = nil
            degradationReason = nil
            degradationOccurredAt = nil
            degradationOccurredMonotonicMilliseconds = nil
            nextOperationID = 0
            diagnostics.removeAll(keepingCapacity: true)
            droppedDiagnosticCount = 0
            currentProjectionDiagnosticFields = [:]
            previousProjectionSegmentID = nil
            // Codex advertises writable AX text and returns success even when
            // the next read does not reflect the insertion. Use keyboard input
            // from the start; retrying after an AX write could duplicate text.
            // AXTextTarget still checks the focused element and caret before
            // each keyboard operation.
            let requiresKeyboardInput = captured.targetApplication?.bundleIdentifier == "com.openai.codex"
            mode = captured.supportsAXReplacement && !requiresKeyboardInput ? .ax : .keyboardLiveTail
            installKeyboardPacerIfNeeded()
        } catch TextTargetError.unsupported, TextTargetError.targetChanged, TextTargetError.writeFailed {
            resetForBegin()
            mode = .keyboardLiveTail
            installKeyboardPacerIfNeeded()
        }
    }

    func apply(projection: ASRProjection) {
        guard projection.changed || projection.isFinal || projection.isStreamEnded else {
            return
        }

        let previousText = lastProjectionText
        let previousSegmentID = previousProjectionSegmentID
        currentProjectionDiagnosticFields = projectionDiagnosticFields(
            projection,
            previousText: previousText,
            previousSegmentID: previousSegmentID
        )
        defer {
            lastProjectionText = projection.text
            previousProjectionSegmentID = projection.activeSegmentID
        }

        switch mode {
        case .ax:
            applyAX(projection)
        case .keyboardLiveTail:
            applyKeyboardLiveTail(projection)
        case .safeCopy, .disabledAfterError:
            lastProjectionText = projection.text
        case .inactive:
            break
        }
    }

    func beginStopping() {
        guard mode == .keyboardLiveTail, let keyboardPacer else { return }
        do {
            try keyboardPacer.beginStopping()
        } catch {
            enterSafeCopy(after: error)
        }
    }

    func finish(finalText: String) async throws {
        let completionText = finalText.isEmpty ? lastProjectionText : finalText

        switch mode {
        case .keyboardLiveTail:
            do {
                if let keyboardPacer {
                    try await keyboardPacer.finish(candidate: completionText)
                } else {
                    try applyKeyboardCandidate(completionText)
                }
            } catch {
                enterSafeCopy(after: error)
            }
        case .safeCopy, .ax, .inactive, .disabledAfterError:
            break
        }

        try copyOnFinishIfNeeded(completionText)
    }

    func finishImmediately(finalText: String) throws {
        let completionText = finalText.isEmpty ? lastProjectionText : finalText

        switch mode {
        case .keyboardLiveTail:
            do {
                if let keyboardPacer {
                    try keyboardPacer.finishImmediately(candidate: completionText)
                } else {
                    try applyKeyboardCandidate(completionText)
                }
            } catch {
                enterSafeCopy(after: error)
            }
        case .safeCopy, .ax, .inactive, .disabledAfterError:
            break
        }

        try copyOnFinishIfNeeded(completionText)
    }

    func cancel() {
        reset()
    }

    private func copyIfNeeded(_ text: String) throws {
        guard !text.isEmpty else { return }
        try target.copyToClipboard(text)
    }

    private func copyOnFinishIfNeeded(_ text: String) throws {
        guard safeCopyEnabled, mode != .inactive, mode != .disabledAfterError else { return }
        try copyIfNeeded(text)
    }

    private func applyAX(_ projection: ASRProjection) {
        guard projection.text != lastProjectionText,
              let snapshot else { return }
        do {
            let previousRange = ownedRange
            let previousDocumentText = lastDocumentText
            let document = NSMutableString(string: previousDocumentText)
            document.replaceCharacters(
                in: NSRange(location: previousRange.location, length: previousRange.length),
                with: projection.text
            )
            var newRange: TextRange?
            try performInputOperation(
                type: "ax_replacement",
                previousText: lastProjectionText,
                desiredText: projection.text,
                plannedSelection: previousRange
            ) {
                newRange = try target.replace(
                    snapshot: snapshot,
                    range: previousRange,
                    expectedText: previousDocumentText,
                    with: projection.text
                )
            }
            guard let newRange else { throw TextTargetError.writeFailed }
            ownedRange = newRange
            lastDocumentText = document as String
            writeCount += 1
        } catch {
            enterSafeCopy(after: error)
        }
    }

    private func applyKeyboardLiveTail(_ projection: ASRProjection) {
        do {
            guard let keyboardPacer else {
                try applyKeyboardCandidate(projection.text)
                return
            }
            let trigger: KeyboardCharacterPacer.Trigger = if projection.isStreamEnded {
                .streamEnd
            } else if projection.isFinal {
                .segmentFinal
            } else {
                .partial
            }
            try keyboardPacer.accept(candidate: projection.text, trigger: trigger)
        } catch {
            enterSafeCopy(after: error)
        }
    }

    private func applyKeyboardCandidate(_ candidateText: String) throws {
        guard candidateText != lastSubmittedText else { return }

        if candidateText.hasPrefix(lastSubmittedText) {
            let suffix = String(candidateText.dropFirst(lastSubmittedText.count))
            if !suffix.isEmpty {
                try performInputOperation(
                    type: "append",
                    previousText: lastSubmittedText,
                    desiredText: candidateText,
                    plannedSelection: TextRange(
                        location: lastSubmittedText.utf16.count,
                        length: 0
                    )
                ) {
                    try target.paste(suffix)
                }
                lastSubmittedText = candidateText
                writeCount += 1
            }
            return
        }

        let commonPrefix = sharedTextPrefix(lastSubmittedText, candidateText)
        let previousTail = String(lastSubmittedText.dropFirst(commonPrefix.count))
        maximumTrailingReplacementLength = max(
            maximumTrailingReplacementLength,
            previousTail.count
        )
        if previousTail.count > deepReplacementThreshold {
            deepReplacementCount += 1
        }
        let replacementTail = String(candidateText.dropFirst(commonPrefix.count))
        try performInputOperation(
            type: "tail_replacement",
            previousText: lastSubmittedText,
            desiredText: candidateText,
            plannedSelection: TextRange(
                location: lastSubmittedText.utf16.count,
                length: previousTail.utf16.count
            )
        ) {
            try target.replaceTrailingText(previousTail, with: replacementTail)
        }
        writeCount += 1
        lastSubmittedText = candidateText
    }

    private func installKeyboardPacerIfNeeded() {
        guard mode == .keyboardLiveTail, keyboardPacing.isEnabled else { return }
        keyboardPacer = KeyboardCharacterPacer(
            configuration: keyboardPacing,
            clock: pacingClock,
            append: { [weak self] text in
                guard let self else { throw TextTargetError.writeFailed }
                try self.appendPacedText(text)
            },
            replaceTrailingText: { [weak self] previousText, text in
                guard let self else { throw TextTargetError.writeFailed }
                try self.replacePacedTrailingText(previousText, with: text)
            },
            onFailure: { [weak self] error in
                self?.enterSafeCopy(after: error)
            }
        )
        keyboardPacer?.beginSession()
    }

    private func appendPacedText(_ text: String) throws {
        let previousText = lastSubmittedText
        let desiredText = previousText + text
        try performInputOperation(
            type: "append",
            previousText: previousText,
            desiredText: desiredText,
            plannedSelection: TextRange(location: previousText.utf16.count, length: 0)
        ) {
            try target.paste(text)
        }
        lastSubmittedText.append(contentsOf: text)
        writeCount += 1
    }

    private func replacePacedTrailingText(_ previousText: String, with text: String) throws {
        guard lastSubmittedText.hasSuffix(previousText) else {
            throw TextTargetError.targetChanged
        }
        let currentText = lastSubmittedText
        let desiredText = String(currentText.dropLast(previousText.count)) + text
        maximumTrailingReplacementLength = max(
            maximumTrailingReplacementLength,
            previousText.count
        )
        if previousText.count > deepReplacementThreshold {
            deepReplacementCount += 1
        }
        try performInputOperation(
            type: "tail_replacement",
            previousText: currentText,
            desiredText: desiredText,
            plannedSelection: TextRange(
                location: currentText.utf16.count,
                length: previousText.utf16.count
            )
        ) {
            try target.replaceTrailingText(previousText, with: text)
        }
        lastSubmittedText = String(lastSubmittedText.dropLast(previousText.count)) + text
        writeCount += 1
    }

    private func projectionDiagnosticFields(
        _ projection: ASRProjection,
        previousText: String,
        previousSegmentID: Int?
    ) -> [String: String] {
        [
            "segmentID": projection.activeSegmentID.map(String.init) ?? "unknown",
            "revision": String(projection.revision),
            "segmentPhase": projection.isStreamEnded ? "streamEnd" : (projection.isFinal ? "final" : "partial"),
            "operationTrigger": projection.isStreamEnded ? "streamEnd" : (projection.isFinal ? "final" : "partial"),
            "crossedSegment": String(previousSegmentID != nil && previousSegmentID != projection.activeSegmentID),
            "previousProjectionLengthCharacters": String(previousText.count),
            "previousProjectionLengthUTF16": String(previousText.utf16.count)
        ]
    }

    private func performInputOperation(
        type: String,
        previousText: String,
        desiredText: String,
        plannedSelection: TextRange?,
        action: () throws -> Void
    ) throws {
        let operationID = nextOperationID + 1
        nextOperationID = operationID
        let created = TextInputDiagnosticClock.milliseconds()
        var fields = currentProjectionDiagnosticFields
        let commonPrefix = sharedTextPrefix(previousText, desiredText)
        let previousTail = String(previousText.dropFirst(commonPrefix.count))
        let replacementTail = String(desiredText.dropFirst(commonPrefix.count))
        let operationFields: [String: String] = [
            "operationID": String(operationID),
            "operationType": type,
            "inputModeBeforeOperation": modeDescription,
            "operationStatus": "queued",
            "operationCreatedMonotonicMilliseconds": String(created),
            "operationQueuedMonotonicMilliseconds": String(created),
            "desiredLengthCharacters": String(desiredText.count),
            "desiredLengthUTF16": String(desiredText.utf16.count),
            "submittedLengthCharacters": String(previousText.count),
            "submittedLengthUTF16": String(previousText.utf16.count),
            "submittedLengthAfterCharacters": String(desiredText.count),
            "submittedLengthAfterUTF16": String(desiredText.utf16.count),
            "observedLengthCharacters": "unknown",
            "observedLengthUTF16": "unknown",
            "commonPrefixLengthCharacters": String(commonPrefix.count),
            "commonPrefixLengthUTF16": String(commonPrefix.utf16.count),
            "previousTailLengthCharacters": String(previousTail.count),
            "previousTailLengthUTF16": String(previousTail.utf16.count),
            "replacementTailLengthCharacters": String(replacementTail.count),
            "replacementTailLengthUTF16": String(replacementTail.utf16.count),
            "characterUnit": "Character",
            "utf16Unit": "UTF16",
            "plannedSelectionUnit": "UTF16",
            "plannedSelectionLocation": plannedSelection.map { String($0.location) } ?? "unknown",
            "plannedSelectionLength": plannedSelection.map { String($0.length) } ?? "unknown",
            "expectedEndLocation": plannedSelection.map {
                String($0.location + desiredText.utf16.count)
            } ?? "unknown",
            "writeCountMeaning": "submission_call_not_target_confirmation"
        ]
        fields.merge(operationFields) { _, new in new }
        let context = TextInputDiagnosticContext(
            operationID: operationID,
            operationType: type,
            fields: fields
        )
        target.setDiagnosticOperation(context)
        defer { target.setDiagnosticOperation(nil) }

        let dispatchStarted = TextInputDiagnosticClock.milliseconds()
        fields["operationStatus"] = "dispatching"
        fields["dispatchStartedMonotonicMilliseconds"] = String(dispatchStarted)
        do {
            try action()
            let dispatchEnded = TextInputDiagnosticClock.milliseconds()
            fields["dispatchEndedMonotonicMilliseconds"] = String(dispatchEnded)
            fields["feedbackObservedMonotonicMilliseconds"] = "unknown"
            fields["operationCompletedMonotonicMilliseconds"] = String(dispatchEnded)
            fields["operationStatus"] = "submitted"
            recordDiagnostic("input_operation", fields)
        } catch {
            let failed = TextInputDiagnosticClock.milliseconds()
            fields["dispatchEndedMonotonicMilliseconds"] = String(failed)
            fields["operationFailedMonotonicMilliseconds"] = String(failed)
            fields["operationStatus"] = "failed"
            fields["failureCode"] = DiagnosticErrorFormatter.code(for: error)
            recordDiagnostic("input_operation", fields)
            throw error
        }
    }

    private func recordDiagnostic(_ event: String, _ fields: [String: String]) {
        guard diagnostics.count < diagnosticLimit else {
            droppedDiagnosticCount += 1
            return
        }
        diagnostics.append(TextInputDiagnostic(timestamp: Date(), event: event, fields: fields))
    }

    private func enterSafeCopy(after error: Error) {
        let modeBeforeDegradation = modeDescription
        keyboardPacer?.cancel()
        mode = safeCopyEnabled ? .safeCopy : .disabledAfterError
        errorCount += 1
        degradationCode = DiagnosticErrorFormatter.code(for: error)
        degradationReason = DiagnosticErrorFormatter.message(for: error)
        if degradationOccurredAt == nil {
            degradationOccurredAt = Date()
            degradationOccurredMonotonicMilliseconds = TextInputDiagnosticClock.milliseconds()
            recordDiagnostic("input_degradation", [
                "failureCode": degradationCode ?? "unknown",
                "degradationMode": modeDescription,
                "inputModeBeforeDegradation": modeBeforeDegradation,
                "failureOccurredMonotonicMilliseconds": String(
                    degradationOccurredMonotonicMilliseconds ?? 0
                )
            ])
        }
    }

    private func resetForBegin() {
        keyboardPacer?.cancel()
        keyboardPacer = nil
        snapshot = nil
        ownedRange = TextRange(location: 0, length: 0)
        lastDocumentText = ""
        lastProjectionText = ""
        lastSubmittedText = ""
        writeCount = 0
        backspaceCount = 0
        deepReplacementCount = 0
        maximumTrailingReplacementLength = 0
        errorCount = 0
        degradationCode = nil
        degradationReason = nil
        degradationOccurredAt = nil
        degradationOccurredMonotonicMilliseconds = nil
        nextOperationID = 0
        diagnostics.removeAll(keepingCapacity: true)
        droppedDiagnosticCount = 0
        currentProjectionDiagnosticFields = [:]
        previousProjectionSegmentID = nil
        mode = .inactive
    }

    private func reset() {
        keyboardPacer?.cancel()
        keyboardPacer = nil
        snapshot = nil
        ownedRange = TextRange(location: 0, length: 0)
        lastDocumentText = ""
        lastProjectionText = ""
        lastSubmittedText = ""
        writeCount = 0
        backspaceCount = 0
        deepReplacementCount = 0
        maximumTrailingReplacementLength = 0
        errorCount = 0
        degradationCode = nil
        degradationReason = nil
        degradationOccurredAt = nil
        degradationOccurredMonotonicMilliseconds = nil
        nextOperationID = 0
        diagnostics.removeAll(keepingCapacity: true)
        droppedDiagnosticCount = 0
        currentProjectionDiagnosticFields = [:]
        previousProjectionSegmentID = nil
        mode = .inactive
    }
}
