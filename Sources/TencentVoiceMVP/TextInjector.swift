import Foundation

@MainActor
final class TextInjector {
    private enum Mode: Equatable {
        case inactive
        case ax
        case keyboardTransactional
        case keyboardAppendOnly
        case safeCopy
    }

    private let target: TextTarget
    private var snapshot: TextSnapshot?
    private var ownedRange = TextRange(location: 0, length: 0)
    private var lastDocumentText = ""
    private var lastRenderedText = ""
    private var lastCommittedText = ""
    private var lastAppendedText = ""
    private var lastActiveSegmentID: Int?
    private var lastActiveText = ""
    private var mode: Mode = .inactive
    private(set) var writeCount = 0
    private(set) var backspaceCount = 0
    private(set) var errorCount = 0
    private(set) var degradationReason: String?

    init(target: TextTarget) {
        self.target = target
    }

    var modeDescription: String {
        switch mode {
        case .inactive: return "inactive"
        case .ax: return "ax"
        case .keyboardTransactional: return "keyboard_transactional"
        case .keyboardAppendOnly: return "keyboard_append_only"
        case .safeCopy: return "safe_copy"
        }
    }

    func begin() throws {
        do {
            let captured = try target.capture()
            snapshot = captured
            ownedRange = captured.selection
            lastDocumentText = captured.text
            lastRenderedText = ""
            lastCommittedText = ""
            lastAppendedText = ""
            lastActiveSegmentID = nil
            lastActiveText = ""
            writeCount = 0
            backspaceCount = 0
            errorCount = 0
            degradationReason = nil
            mode = captured.supportsAXReplacement ? .ax : .keyboardTransactional
        } catch TextTargetError.unsupported, TextTargetError.targetChanged, TextTargetError.writeFailed {
            snapshot = nil
            lastDocumentText = ""
            lastRenderedText = ""
            lastCommittedText = ""
            lastAppendedText = ""
            lastActiveSegmentID = nil
            lastActiveText = ""
            writeCount = 0
            backspaceCount = 0
            errorCount = 0
            degradationReason = nil
            mode = .keyboardAppendOnly
        }
    }

    func apply(projection: ASRProjection) {
        guard projection.changed || projection.isFinal else { return }

        switch mode {
        case .ax:
            applyAX(projection)
        case .keyboardTransactional:
            applyKeyboardTransactional(projection)
        case .keyboardAppendOnly:
            applyKeyboardAppendOnly(projection)
        case .safeCopy, .inactive:
            break
        }
    }

    func finish(finalText: String) throws {
        defer { reset() }

        switch mode {
        case .keyboardAppendOnly:
            do {
                guard finalText.hasPrefix(lastAppendedText) else {
                    enterSafeCopy(after: TextTargetError.targetChanged)
                    break
                }
                let suffix = String(finalText.dropFirst(lastAppendedText.count))
                if !suffix.isEmpty {
                    try target.paste(suffix)
                    writeCount += 1
                }
                lastAppendedText = finalText
            } catch {
                enterSafeCopy(after: error)
            }
            if mode == .safeCopy {
                try target.copyToClipboard(finalText)
            }
        case .safeCopy:
            try target.copyToClipboard(finalText)
        case .ax, .keyboardTransactional, .inactive:
            break
        }
    }

    func cancel() {
        reset()
    }

    private func applyAX(_ projection: ASRProjection) {
        guard projection.text != lastRenderedText,
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
            lastRenderedText = projection.text
            writeCount += 1
        } catch {
            enterSafeCopy(after: error)
        }
    }

    private func applyKeyboardTransactional(_ projection: ASRProjection) {
        guard let activeSegmentID = projection.activeSegmentID else { return }

        do {
            if lastActiveSegmentID == activeSegmentID {
                guard projection.committedText == lastCommittedText else {
                    enterSafeCopy(after: TextTargetError.targetChanged)
                    return
                }
                guard projection.activeSegmentText != lastActiveText else { return }
                let delta = PastedTextDelta(
                    previousText: lastActiveText,
                    newText: projection.activeSegmentText
                )
                try target.replacePastedText(
                    previousText: lastActiveText,
                    with: projection.activeSegmentText
                )
                writeCount += 1
                backspaceCount += delta.backspaceCount
            } else {
                let expectedCommittedText = lastCommittedText + lastActiveText
                guard projection.committedText.hasPrefix(expectedCommittedText) else {
                    enterSafeCopy(after: TextTargetError.targetChanged)
                    return
                }
                if !projection.activeSegmentText.isEmpty {
                    try target.paste(projection.activeSegmentText)
                    writeCount += 1
                }
            }

            lastCommittedText = projection.committedText
            lastActiveSegmentID = activeSegmentID
            lastActiveText = projection.activeSegmentText
            lastRenderedText = projection.text
        } catch {
            enterSafeCopy(after: error)
        }
    }

    private func applyKeyboardAppendOnly(_ projection: ASRProjection) {
        guard projection.committedText.hasPrefix(lastAppendedText) else {
            enterSafeCopy(after: TextTargetError.targetChanged)
            return
        }

        do {
            let suffix = String(projection.committedText.dropFirst(lastAppendedText.count))
            if !suffix.isEmpty {
                try target.paste(suffix)
                lastAppendedText = projection.committedText
                writeCount += 1
            }
            lastRenderedText = projection.text
        } catch {
            enterSafeCopy(after: error)
        }
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
        lastRenderedText = ""
        lastCommittedText = ""
        lastAppendedText = ""
        lastActiveSegmentID = nil
        lastActiveText = ""
        writeCount = 0
        backspaceCount = 0
        errorCount = 0
        degradationReason = nil
        mode = .inactive
    }
}
