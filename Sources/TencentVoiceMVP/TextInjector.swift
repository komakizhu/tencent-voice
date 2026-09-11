import Foundation

@MainActor
final class TextInjector {
    private final class KeyboardWriteOperationState {
        var fields: [String: String]

        init(fields: [String: String]) {
            self.fields = fields
        }

        func markDispatch() {
            let timestamp = TextInputDiagnosticClock.milliseconds()
            fields["operationStatus"] = "dispatching"
            fields["dispatchStartedMonotonicMilliseconds"] = String(timestamp)
        }

        func finish(status: String, error: Error?) -> [String: String] {
            let timestamp = TextInputDiagnosticClock.milliseconds()
            fields["dispatchEndedMonotonicMilliseconds"] = String(timestamp)
            fields["operationCompletedMonotonicMilliseconds"] = String(timestamp)
            fields["operationStatus"] = status
            fields["targetCompletionConfirmed"] = String(status == "acknowledged")
            fields["localDispatchCompleted"] = String(status != "cancelled")
            if status == "acknowledged" {
                fields["feedbackObservedMonotonicMilliseconds"] = String(timestamp)
            } else {
                fields["feedbackObservedMonotonicMilliseconds"] = "unknown"
            }
            if let error {
                fields["failureCode"] = DiagnosticErrorFormatter.code(for: error)
                fields["operationFailedMonotonicMilliseconds"] = String(timestamp)
            }
            return fields
        }
    }

    private enum InputPhase: String {
        case live
        case finalizing
        case frozenByExternalEdit
        case safeCopy
        case closed
    }

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
    private var keyboardWriter: AcknowledgedKeyboardWriter?
    private var snapshot: TextSnapshot?
    private var ownedRange = TextRange(location: 0, length: 0)
    private var lastDocumentText = ""
    private var lastProjectionText = ""
    private var lastSubmittedText = ""
    // After an external edit, the complete projection before that edit is a
    // frozen prefix. Only the suffix after it belongs to the new voice range.
    private var mixedInputFrozenPrefix: String?
    // Revisions inside this tail are the normal fast path. Deeper revisions
    // still update immediately, but are counted separately because they select
    // a longer suffix before replacing it in one transaction.
    private let deepReplacementThreshold = 12
    private var mode: Mode = .inactive
    private var inputPhase: InputPhase = .closed
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
            inputPhase = .live
            ownedRange = captured.selection
            lastDocumentText = captured.text
            lastProjectionText = ""
            lastSubmittedText = ""
            mixedInputFrozenPrefix = nil
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
            inputPhase = .live
            installKeyboardPacerIfNeeded()
        }
    }

    func apply(projection: ASRProjection) {
        guard inputPhase != .closed else { return }
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
            do {
                let candidateText = try prepareKeyboardCandidate(
                    projection.text,
                    previousText: previousText,
                    projection: projection
                )
                applyKeyboardLiveTail(projection, candidateText: candidateText)
            } catch {
                enterSafeCopy(after: error)
            }
        case .safeCopy, .disabledAfterError:
            lastProjectionText = projection.text
        case .inactive:
            break
        }
    }

    func beginStopping() {
        guard mode == .keyboardLiveTail, let keyboardPacer else { return }
        inputPhase = .finalizing
        recordDiagnostic("text_input_phase", ["phase": inputPhase.rawValue, "reason": "legacy_stopping"])
        do {
            try keyboardPacer.beginStopping()
        } catch {
            enterSafeCopy(after: error)
        }
    }

    func beginFinalization() {
        guard mode == .keyboardLiveTail else { return }
        inputPhase = .finalizing
        recordDiagnostic("text_input_phase", ["phase": inputPhase.rawValue, "reason": "asr_finalization_started"])
        keyboardPacer?.beginFinalization()
    }

    func finish(finalText: String) async throws {
        let completionText = finalText.isEmpty ? lastProjectionText : finalText
        if inputPhase == .live {
            inputPhase = .finalizing
            recordDiagnostic("text_input_phase", ["phase": inputPhase.rawValue, "reason": "finish_without_explicit_finalization"])
        }

        switch mode {
        case .keyboardLiveTail:
            do {
                let candidateText = try prepareKeyboardCandidate(
                    completionText,
                    previousText: lastProjectionText,
                    projection: nil
                )
                if let keyboardPacer {
                    try await keyboardPacer.finish(candidate: candidateText)
                } else {
                    try applyKeyboardCandidate(candidateText)
                }
                try await keyboardWriter?.finish(candidateText)
                recordDiagnostic("text_input_phase", ["phase": inputPhase.rawValue, "reason": "finished"])
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
                let candidateText = try prepareKeyboardCandidate(
                    completionText,
                    previousText: lastProjectionText,
                    projection: nil
                )
                if let keyboardPacer {
                    try keyboardPacer.finishImmediately(candidate: candidateText)
                } else {
                    try applyKeyboardCandidate(candidateText)
                }
                recordDiagnostic("text_input_phase", ["phase": inputPhase.rawValue, "reason": "finished_immediately"])
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

    private func applyKeyboardLiveTail(_ projection: ASRProjection, candidateText: String) {
        do {
            guard let keyboardPacer else {
                try applyKeyboardCandidate(candidateText)
                return
            }
            let trigger: KeyboardCharacterPacer.Trigger = if projection.isStreamEnded {
                .streamEnd
            } else if projection.isFinal {
                .segmentFinal
            } else {
                .partial
            }
            try keyboardPacer.accept(candidate: candidateText, trigger: trigger)
        } catch {
            enterSafeCopy(after: error)
        }
    }

    private func prepareKeyboardCandidate(
        _ candidateText: String,
        previousText: String,
        projection: ASRProjection?
    ) throws -> String {
        if let acknowledging = target as? any KeyboardAcknowledgingTarget,
           acknowledging.requiresKeyboardAcknowledgement {
            switch try acknowledging.reconcileKeyboardStateForUserEdit() {
            case .matched:
                break
            case .ownWriteInFlight:
                recordDiagnostic("own_write_in_flight", [
                    "candidateLengthCharacters": String(candidateText.count),
                    "candidateLengthUTF16": String(candidateText.utf16.count),
                    "segmentID": projection?.activeSegmentID.map(String.init) ?? "final",
                    "revision": projection.map { String($0.revision) } ?? "final",
                    "phase": inputPhase.rawValue
                ])
            case .externalEdit:
                recordDiagnostic("external_edit", [
                    "candidateLengthCharacters": String(candidateText.count),
                    "candidateLengthUTF16": String(candidateText.utf16.count),
                    "segmentID": projection?.activeSegmentID.map(String.init) ?? "final",
                    "revision": projection.map { String($0.revision) } ?? "final",
                    "phase": inputPhase.rawValue
                ])
                guard inputPhase != .finalizing else {
                    inputPhase = .frozenByExternalEdit
                    recordDiagnostic("text_input_phase", ["phase": inputPhase.rawValue, "reason": "external_edit_during_finalization"])
                    throw TextTargetError.targetChanged
                }
                guard !(keyboardPacer?.hasPendingOutput ?? false),
                      !(keyboardWriter?.hasPendingWork ?? false) else {
                    recordDiagnostic("mixed_input_ambiguous", [
                        "candidateLengthCharacters": String(candidateText.count),
                        "candidateLengthUTF16": String(candidateText.utf16.count),
                        "segmentID": projection?.activeSegmentID.map(String.init) ?? "final",
                        "revision": projection.map { String($0.revision) } ?? "final",
                        "reason": "voice_output_in_flight"
                    ])
                    throw TextTargetError.targetChanged
                }
                mixedInputFrozenPrefix = previousText
                keyboardPacer?.resetForExternalEdit()
                keyboardWriter?.resetForExternalEdit()
                lastSubmittedText = ""
                recordDiagnostic("mixed_input_rebased", [
                    "frozenPrefixLengthCharacters": String(previousText.count),
                    "frozenPrefixLengthUTF16": String(previousText.utf16.count),
                    "candidateLengthCharacters": String(candidateText.count),
                    "candidateLengthUTF16": String(candidateText.utf16.count),
                    "segmentID": projection?.activeSegmentID.map(String.init) ?? "final",
                    "revision": projection.map { String($0.revision) } ?? "final"
                ])
            }
        }

        guard let frozenPrefix = mixedInputFrozenPrefix else { return candidateText }
        guard candidateText.hasPrefix(frozenPrefix) else {
            recordDiagnostic("mixed_input_ambiguous", [
                "frozenPrefixLengthCharacters": String(frozenPrefix.count),
                "frozenPrefixLengthUTF16": String(frozenPrefix.utf16.count),
                "candidateLengthCharacters": String(candidateText.count),
                "candidateLengthUTF16": String(candidateText.utf16.count),
                "segmentID": projection?.activeSegmentID.map(String.init) ?? "final",
                "revision": projection.map { String($0.revision) } ?? "final",
                "reason": "recognition_prefix_changed"
            ])
            throw TextTargetError.targetChanged
        }
        return String(candidateText.dropFirst(frozenPrefix.count))
    }

    private func applyKeyboardCandidate(_ candidateText: String) throws {
        guard candidateText != lastSubmittedText else { return }

        if let keyboardWriter {
            try keyboardWriter.accept(candidateText)
            lastSubmittedText = candidateText
            return
        }

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
        guard mode == .keyboardLiveTail else { return }
        if let acknowledging = target as? any KeyboardAcknowledgingTarget,
           acknowledging.requiresKeyboardAcknowledgement {
            keyboardWriter = AcknowledgedKeyboardWriter(
                target: acknowledging,
                onCommit: { [weak self] previous, submitted in
                    guard let self else { return }
                    self.writeCount += 1
                    let prefix = sharedTextPrefix(previous, submitted)
                    let replaced = previous.count - prefix.count
                    self.maximumTrailingReplacementLength = max(
                        self.maximumTrailingReplacementLength,
                        replaced
                    )
                    if replaced > self.deepReplacementThreshold {
                        self.deepReplacementCount += 1
                    }
                },
                onFailure: { [weak self] error in
                    self?.enterSafeCopy(after: error)
                },
                operationContextProvider: { [weak self] previous, submitted in
                    guard let self else { return nil }
                    return self.makeKeyboardWriterOperation(
                        previousText: previous,
                        desiredText: submitted
                    )
                }
            )
        }
        guard keyboardPacing.isEnabled else { return }
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

    private func makeKeyboardWriterOperation(
        previousText: String,
        desiredText: String
    ) -> AcknowledgedKeyboardWriter.OperationContext {
        let operationID = nextOperationID + 1
        nextOperationID = operationID
        let created = TextInputDiagnosticClock.milliseconds()
        let commonPrefix = sharedTextPrefix(previousText, desiredText)
        let previousTail = String(previousText.dropFirst(commonPrefix.count))
        let replacementTail = String(desiredText.dropFirst(commonPrefix.count))
        var fields = currentProjectionDiagnosticFields
        let operationFields: [String: String] = [
            "operationID": String(operationID),
            "operationType": previousTail.isEmpty ? "append" : "tail_replacement",
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
            "plannedSelectionLocation": String(previousText.utf16.count),
            "plannedSelectionLength": String(previousTail.utf16.count),
            "expectedEndLocation": String(desiredText.utf16.count),
            "writeCountMeaning": "submission_call_not_target_confirmation"
        ]
        fields.merge(operationFields) { _, new in new }

        let state = KeyboardWriteOperationState(fields: fields)
        let context = TextInputDiagnosticContext(
            operationID: operationID,
            operationType: fields["operationType"] ?? "append",
            fields: fields
        )
        return AcknowledgedKeyboardWriter.OperationContext(
            diagnostic: context,
            onDispatch: { [state] in
                state.markDispatch()
            },
            onFinish: { [weak self, state] status, error in
                guard let self else { return }
                self.recordDiagnostic(
                    "input_operation",
                    state.finish(status: status, error: error)
                )
            }
        )
    }

    private func appendPacedText(_ text: String) throws {
        let previousText = lastSubmittedText
        let desiredText = previousText + text
        if let keyboardWriter {
            try keyboardWriter.accept(desiredText)
            lastSubmittedText = desiredText
            return
        }
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
        if let keyboardWriter {
            try keyboardWriter.accept(desiredText)
            lastSubmittedText = desiredText
            return
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
        guard mode != .safeCopy, mode != .disabledAfterError else { return }
        let modeBeforeDegradation = modeDescription
        keyboardWriter?.cancel()
        keyboardPacer?.cancel()
        mode = safeCopyEnabled ? .safeCopy : .disabledAfterError
        inputPhase = .safeCopy
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
        keyboardWriter?.cancel()
        keyboardWriter = nil
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
        mixedInputFrozenPrefix = nil
        inputPhase = .closed
        mode = .inactive
    }

    private func reset() {
        keyboardWriter?.cancel()
        keyboardWriter = nil
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
        mixedInputFrozenPrefix = nil
        inputPhase = .closed
        mode = .inactive
    }
}
