import Foundation

enum DiagnosticAnomaly {
    static let events: Set<String> = [
        "keyboard_write_unconfirmed", "ax_write_unconfirmed", "keyboard_confirmed_state_changed",
        "keyboard_state_change_observed", "keyboard_user_edit_detected", "keyboard_user_edit_ambiguous",
        "keyboard_user_edit_read_failed", "mixed_input_ambiguous", "input_degradation",
        "safe_copy_update_failed", "keyboard_target_reacquire_rejected",
        "safari_keyboard_target_reacquire_rejected", "keyboard_focus_changed",
        "ax_focus_changed", "input_application_changed", "ax_write_failed", "ax_document_mismatch",
        "ax_selection_mismatch", "ax_coordinate_mapping_failed", "finish_error", "stream_error", "input_error"
    ]
}

struct DiagnosticCauseAssessment: Codable, Sendable {
    let observableFailure: String
    let status: String
    let candidateCauses: [String]
    let supportingEvidence: [String]
    let missingEvidence: [String]
}

// A factual index into the evidence, not a root-cause verdict.
struct DiagnosticSessionSummary: Codable, Sendable {
    let sessionID: UUID
    let firstAnomaly: SessionLogEntry?
    let lastSuccessBeforeAnomaly: SessionLogEntry?
    let recognitionEventsAfterAnomaly: Int
    let finalSafeCopy: SessionLogEntry?
    let fullTextEvidenceCount: Int
    let screenEvidenceStatus: String
    var causeAssessment: DiagnosticCauseAssessment? = nil

    static func make(
        from events: [SessionLogEntry],
        screenEvidenceStatus: String = "not_captured_AX_text_is_not_screen_evidence"
    ) -> [Self] {
        Dictionary(grouping: events.filter { $0.kind == .session }, by: \.sessionID)
            .map { sessionID, entries in
                let ordered = orderedDiagnosticSessionEntries(entries)
                let firstAnomalyIndex = ordered.firstIndex { DiagnosticAnomaly.events.contains($0.event) }
                let first = firstAnomalyIndex.map { ordered[$0] }
                let precedingEntries = firstAnomalyIndex.map { Array(ordered[..<$0]) } ?? ordered
                let success = precedingEntries.last {
                    ["keyboard_write_acknowledged", "ax_write_acknowledged"].contains($0.event)
                }
                let assessment = first.flatMap(Self.assessCause)
                return Self(sessionID: sessionID, firstAnomaly: first, lastSuccessBeforeAnomaly: success,
                    recognitionEventsAfterAnomaly: firstAnomalyIndex.map { index in
                        ordered.dropFirst(index + 1).filter {
                            ["partial", "final", "discarded"].contains($0.event)
                        }.count
                    } ?? 0,
                    finalSafeCopy: ordered.last { $0.textEvidence.contains { $0.kind == .safeCopySucceeded } },
                    fullTextEvidenceCount: ordered.reduce(0) { $0 + $1.textEvidence.count },
                    screenEvidenceStatus: screenEvidenceStatus,
                    causeAssessment: assessment)
            }.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    private static func assessCause(for failure: SessionLogEntry) -> DiagnosticCauseAssessment? {
        guard ["keyboard_write_unconfirmed", "keyboard_confirmed_state_changed", "keyboard_state_change_observed"]
            .contains(failure.event),
              let expected = failure.textEvidence.first(where: { $0.kind == .expectedDocument })?.text,
              let observed = failure.textEvidence.last(where: { [.axValue, .axStringForRange].contains($0.kind) })?.text,
              expected != observed else { return nil }
        return DiagnosticCauseAssessment(
            observableFailure: "正文与预期正文不一致",
            status: "原因未唯一确定",
            candidateCauses: ["编辑器实际选区移动", "AX 读数滞后"],
            supportingEvidence: ["同一故障记录中的预期正文与 AX 读到的正文不同"],
            missingEvidence: ["独立于 AX 的页面正文或选区状态", "编辑器实际处理键盘事件的时间"]
        )
    }
}
