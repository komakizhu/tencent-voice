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
    private var keyboardWriter: AcknowledgedKeyboardWriter?
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
        target.drainDiagnostics()
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
                try await keyboardWriter?.finish(completionText)
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
            let newRange = try target.replace(
                snapshot: snapshot,
                range: previousRange,
                expectedText: previousDocumentText,
                with: projection.text
            )
            ownedRange = newRange
            lastDocumentText = document as String
            lastProjectionText = projection.text
            writeCount += 1
        } catch {
            enterSafeCopy(after: error)
        }
    }

    private func applyKeyboardLiveTail(_ projection: ASRProjection) {
        lastProjectionText = projection.text
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
        if let keyboardWriter {
            try keyboardWriter.accept(candidateText)
            lastSubmittedText = candidateText
            return
        }

        if candidateText.hasPrefix(lastSubmittedText) {
            let suffix = String(candidateText.dropFirst(lastSubmittedText.count))
            if !suffix.isEmpty {
                try target.paste(suffix)
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
        try target.replaceTrailingText(previousTail, with: replacementTail)
        writeCount += 1
        lastSubmittedText = candidateText
    }

    private func installKeyboardPacerIfNeeded() {
        guard mode == .keyboardLiveTail else { return }
        if let acknowledging = target as? any KeyboardAcknowledgingTarget,
           acknowledging.requiresKeyboardAcknowledgement {
            keyboardWriter = AcknowledgedKeyboardWriter(target: acknowledging,
                onCommit: { [weak self] previous, submitted in
                    guard let self else { return }
                    self.writeCount += 1
                    let prefix = sharedTextPrefix(previous, submitted)
                    let replaced = previous.count - prefix.count
                    self.maximumTrailingReplacementLength = max(self.maximumTrailingReplacementLength, replaced)
                    if replaced > self.deepReplacementThreshold { self.deepReplacementCount += 1 }
                }, onFailure: { [weak self] error in self?.enterSafeCopy(after: error) })
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

    private func appendPacedText(_ text: String) throws {
        if let keyboardWriter {
            try keyboardWriter.accept(lastSubmittedText + text)
            lastSubmittedText.append(contentsOf: text)
            return
        }
        try target.paste(text)
        lastSubmittedText.append(contentsOf: text)
        writeCount += 1
    }

    private func replacePacedTrailingText(_ previousText: String, with text: String) throws {
        guard lastSubmittedText.hasSuffix(previousText) else {
            throw TextTargetError.targetChanged
        }
        if let keyboardWriter {
            let candidate = String(lastSubmittedText.dropLast(previousText.count)) + text
            try keyboardWriter.accept(candidate)
            lastSubmittedText = candidate
            return
        }
        try target.replaceTrailingText(previousText, with: text)
        lastSubmittedText = String(lastSubmittedText.dropLast(previousText.count)) + text
        writeCount += 1
    }

    private func enterSafeCopy(after error: Error) {
        guard mode != .safeCopy, mode != .disabledAfterError else { return }
        keyboardWriter?.cancel()
        keyboardPacer?.cancel()
        mode = safeCopyEnabled ? .safeCopy : .disabledAfterError
        errorCount += 1
        degradationCode = DiagnosticErrorFormatter.code(for: error)
        degradationReason = DiagnosticErrorFormatter.message(for: error)
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
        mode = .inactive
    }
}
