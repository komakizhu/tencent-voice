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

    func begin() throws {
        resetForBegin()
        if safeCopyEnabled {
            mode = .safeCopy
            degradationCode = "safe_copy_manual"
            degradationReason = DiagnosticErrorFormatter.canonicalMessage(for: "safe_copy_manual")
            return
        }

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
            mode = captured.supportsAXReplacement ? .ax : .keyboardLiveTail
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
            } catch {
                enterSafeCopy(after: error)
            }
            if mode == .safeCopy {
                try copyIfNeeded(completionText)
            }
        case .safeCopy:
            try copyIfNeeded(completionText)
        case .ax, .inactive, .disabledAfterError:
            break
        }
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
            if mode == .safeCopy {
                try copyIfNeeded(completionText)
            }
        case .safeCopy:
            try copyIfNeeded(completionText)
        case .ax, .inactive, .disabledAfterError:
            break
        }
    }

    func cancel() {
        reset()
    }

    private func copyIfNeeded(_ text: String) throws {
        guard !text.isEmpty else { return }
        try target.copyToClipboard(text)
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
        try target.paste(text)
        lastSubmittedText.append(contentsOf: text)
        writeCount += 1
    }

    private func replacePacedTrailingText(_ previousText: String, with text: String) throws {
        guard lastSubmittedText.hasSuffix(previousText) else {
            throw TextTargetError.targetChanged
        }
        try target.replaceTrailingText(previousText, with: text)
        lastSubmittedText = String(lastSubmittedText.dropLast(previousText.count)) + text
        writeCount += 1
    }

    private func enterSafeCopy(after error: Error) {
        keyboardPacer?.cancel()
        mode = safeCopyEnabled ? .safeCopy : .disabledAfterError
        errorCount += 1
        degradationCode = DiagnosticErrorFormatter.code(for: error)
        degradationReason = DiagnosticErrorFormatter.message(for: error)
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
        mode = .inactive
    }
}
