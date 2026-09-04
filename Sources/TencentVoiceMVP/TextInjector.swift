import Foundation

@MainActor
final class TextInjector {
    private enum Mode: Equatable {
        case inactive
        case ax
        case keyboardLiveTail
        case safeCopy
    }

    private let target: TextTarget
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

    init(target: TextTarget) {
        self.target = target
    }

    var modeDescription: String {
        switch mode {
        case .inactive: return "inactive"
        case .ax: return "ax"
        case .keyboardLiveTail: return "keyboard_live_tail"
        case .safeCopy: return "safe_copy"
        }
    }

    func begin() throws {
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
            degradationReason = nil
            mode = captured.supportsAXReplacement ? .ax : .keyboardLiveTail
        } catch TextTargetError.unsupported, TextTargetError.targetChanged, TextTargetError.writeFailed {
            snapshot = nil
            lastDocumentText = ""
            lastProjectionText = ""
            lastSubmittedText = ""
            writeCount = 0
            backspaceCount = 0
            deepReplacementCount = 0
            maximumTrailingReplacementLength = 0
            errorCount = 0
            degradationReason = nil
            mode = .keyboardLiveTail
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
        case .safeCopy, .inactive:
            break
        }
    }

    func finish(finalText: String) throws {
        let completionText = finalText.isEmpty ? lastProjectionText : finalText

        switch mode {
        case .keyboardLiveTail:
            do {
                try applyKeyboardCandidate(completionText)
            } catch {
                enterSafeCopy(after: error)
            }
            if mode == .safeCopy {
                try target.copyToClipboard(completionText)
            }
        case .safeCopy:
            try target.copyToClipboard(completionText)
        case .ax, .inactive:
            break
        }
    }

    func cancel() {
        reset()
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
            try applyKeyboardCandidate(projection.text)
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
                writeCount += 1
            }
            lastSubmittedText = candidateText
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

    private func enterSafeCopy(after error: Error) {
        mode = .safeCopy
        errorCount += 1
        degradationReason = error.localizedDescription
    }

    private func reset() {
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
        degradationReason = nil
        mode = .inactive
    }
}
