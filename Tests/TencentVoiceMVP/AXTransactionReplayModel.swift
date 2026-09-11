import Foundation
@testable import TencentVoiceMVP

// Test-only feasibility model. No AX, keyboard, microphone, network, or app access.
// The coordinate adapter here intentionally uses identity mapping; the real
// AXTextTarget replay tests cover production placeholder and coordinate logic.
enum ReplayOutcome: Error, Equatable {
    case confirmed, focusChanged, externalEdit, unconfirmed, cancelled
}

struct ReplayDocument: Equatable {
    var text: String
    var selection: TencentVoiceMVP.TextRange
}

enum ReplayField: CaseIterable { case focus, raw, selection, coordinate }

struct ReplayEdit {
    let before: ReplayDocument
    let range: TencentVoiceMVP.TextRange
    let insertion: String
    let selected: ReplayDocument
    let result: ReplayDocument
    let protectedPrefix: String

    init(before: ReplayDocument, range: TencentVoiceMVP.TextRange, insertion: String) {
        precondition(range.location >= 0 && range.length >= 0)
        precondition(range.location + range.length <= before.text.utf16.count)
        self.before = before
        self.range = range
        self.insertion = insertion
        selected = .init(text: before.text, selection: range)
        let ns = before.text as NSString
        protectedPrefix = ns.substring(to: range.location)
        result = .init(
            text: ns.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: insertion),
            selection: .init(location: range.location + insertion.utf16.count, length: 0)
        )
    }
}

// Actual document state and visible AX fields are deliberately independent.
// A script can change any field between ANY two primitive reads, including the
// two reads of the same attribute in a single collection attempt.
final class ReplayEditor {
    var actual: ReplayDocument
    var visible: ReplayDocument
    var coordinate: String
    var focused = true
    var cancelled = false
    var available = true
    var now: UInt64 = 0
    var ticks = 0
    var primitiveReads = 0
    var selectionPosts = 0
    var insertionPosts = 0
    var illegalPosts = 0
    var trace: [String] = []
    var onRead: ((ReplayEditor, ReplayField) -> Void)?
    var onTick: ((ReplayEditor) -> Void)?
    var onSelection: ((ReplayEditor) -> Void)?
    var onInsertion: ((ReplayEditor) -> Void)?

    init(_ document: ReplayDocument) {
        actual = document
        visible = document
        coordinate = document.text
    }

    func exposeActual() { visible = actual; coordinate = actual.text }

    func read(_ field: ReplayField) {
        primitiveReads += 1
        onRead?(self, field)
    }

    func checkFocus() -> Bool { read(.focus); return focused }

    func sample() -> ReplayDocument? {
        read(.raw)
        let raw = available ? visible.text : nil
        read(.selection)
        let selection = available ? visible.selection : nil
        read(.coordinate)
        let ranged = available ? coordinate : nil
        guard let raw, let selection, let ranged, raw == ranged,
              selection.location >= 0, selection.length >= 0,
              selection.location <= raw.utf16.count,
              selection.length <= raw.utf16.count - selection.location else { return nil }
        return .init(text: raw, selection: selection)
    }

    func observe() throws -> ReplayDocument? {
        guard checkFocus() else { throw ReplayOutcome.focusChanged }
        let first = sample()
        let second = sample()
        guard checkFocus() else { throw ReplayOutcome.focusChanged }
        guard first == second else { return nil }
        return first
    }

    func tick() {
        ticks += 1
        now += 10_000_000 // Virtual polling only: no real sleeps.
        onTick?(self)
    }

    func select(_ edit: ReplayEdit) {
        selectionPosts += 1
        if !focused || actual != edit.before { illegalPosts += 1 }
        actual.selection = edit.range
        trace.append("select")
        if let onSelection { onSelection(self) } else { exposeActual() }
    }

    func insert(_ edit: ReplayEdit) {
        insertionPosts += 1
        if !focused || actual != edit.selected { illegalPosts += 1 }
        let nsRange = NSRange(location: actual.selection.location, length: actual.selection.length)
        actual.text = (actual.text as NSString).replacingCharacters(in: nsRange, with: edit.insertion)
        actual.selection = .init(location: nsRange.location + edit.insertion.utf16.count, length: 0)
        trace.append("insert")
        if let onInsertion { onInsertion(self) } else { exposeActual() }
    }
}

// Experimental transaction executor, deliberately private to the test target.
// Real app integration is a separate decision after this model's validation.
struct ReplayTransaction {
    let edit: ReplayEdit
    let editor: ReplayEditor
    var timeout: UInt64 = 5_000_000_000

    func wait(for expected: ReplayDocument, beforeSend: Bool) throws {
        let start = editor.now
        while true {
            guard !editor.cancelled else { throw ReplayOutcome.cancelled }
            guard editor.now &- start <= timeout else { throw ReplayOutcome.unconfirmed }
            let observed = try editor.observe()
            guard !editor.cancelled else { throw ReplayOutcome.cancelled }
            guard editor.now &- start <= timeout else { throw ReplayOutcome.unconfirmed }
            if let observed {
                if observed == expected { return }
                // A changed protected draft is outside every permitted stage.
                // Other mismatches after sending could be partially applied input:
                // leave those unconfirmed instead of guessing authorship.
                if !observed.text.hasPrefix(edit.protectedPrefix)
                    || (beforeSend && observed.text != edit.before.text) {
                    throw ReplayOutcome.externalEdit
                }
            }
            guard editor.now &- start < timeout else { throw ReplayOutcome.unconfirmed }
            editor.tick()
        }
    }

    func run() -> ReplayOutcome {
        do {
            try wait(for: edit.before, beforeSend: true)
            guard editor.checkFocus() else { return .focusChanged }
            guard !editor.cancelled else { return .cancelled }
            editor.select(edit)
            try wait(for: edit.selected, beforeSend: true)
            guard editor.checkFocus() else { return .focusChanged }
            guard !editor.cancelled else { return .cancelled }
            editor.insert(edit)
            try wait(for: edit.result, beforeSend: false)
            editor.trace.append("confirm")
            return .confirmed
        } catch let outcome as ReplayOutcome { return outcome }
        catch { preconditionFailure("Unexpected simulation error: \(error)") }
    }
}

// Connects the proposed transaction semantics to the REAL candidate-coalescing
// writer, without substituting a fake implementation of that writer.
@MainActor
final class ReplayWriterTarget: KeyboardAcknowledgingTarget {
    let requiresKeyboardAcknowledgement = true
    let editor: ReplayEditor
    private var pending: ReplayEdit?

    init(draft: String) {
        editor = ReplayEditor(.init(text: draft, selection: .init(location: draft.utf16.count, length: 0)))
    }

    func capture() throws -> TextSnapshot {
        .init(text: editor.actual.text, selection: editor.actual.selection)
    }
    func replace(snapshot: TextSnapshot, range: TencentVoiceMVP.TextRange, expectedText: String, with text: String) throws -> TencentVoiceMVP.TextRange {
        throw TextTargetError.unsupported
    }
    func paste(_ text: String) throws { try replaceTrailingText("", with: text) }
    func replaceTrailingText(_ previousText: String, with text: String) throws {
        guard pending == nil, editor.actual.text.hasSuffix(previousText) else { throw ReplayOutcome.externalEdit }
        pending = ReplayEdit(before: editor.actual,
            range: .init(location: editor.actual.selection.location - previousText.utf16.count,
                         length: previousText.utf16.count), insertion: text)
    }
    func acknowledgeKeyboardWrite() async throws {
        try Task.checkCancellation()
        guard let pending else { return }
        let outcome = ReplayTransaction(edit: pending, editor: editor).run()
        guard outcome == .confirmed else { throw outcome }
        self.pending = nil
    }
    func copyToClipboard(_ text: String) throws {}
}
