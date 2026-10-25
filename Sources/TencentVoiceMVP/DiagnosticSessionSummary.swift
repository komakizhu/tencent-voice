import Foundation

enum DiagnosticAnomaly {
    static let events: Set<String> = [
        "keyboard_write_unconfirmed", "ax_write_unconfirmed", "keyboard_confirmed_state_changed",
        "keyboard_state_change_observed", "keyboard_user_edit_detected", "keyboard_user_edit_ambiguous",
        "keyboard_user_edit_read_failed", "mixed_input_ambiguous", "input_degradation",
        "safe_copy_update_failed", "safari_keyboard_target_reacquire_rejected", "keyboard_focus_changed",
        "ax_focus_changed", "input_application_changed", "ax_write_failed", "ax_document_mismatch",
        "ax_selection_mismatch", "ax_coordinate_mapping_failed", "finish_error", "stream_error", "input_error"
    ]
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

    static func make(from events: [SessionLogEntry]) -> [Self] {
        Dictionary(grouping: events.filter { $0.kind == .session }, by: \.sessionID)
            .map { sessionID, entries in
                let ordered = entries.sorted { $0.timestamp < $1.timestamp }
                let first = ordered.first { DiagnosticAnomaly.events.contains($0.event) }
                let success = ordered.last {
                    ["keyboard_write_acknowledged", "ax_write_acknowledged"].contains($0.event)
                        && $0.timestamp <= (first?.timestamp ?? .distantFuture)
                }
                return Self(sessionID: sessionID, firstAnomaly: first, lastSuccessBeforeAnomaly: success,
                    recognitionEventsAfterAnomaly: first.map { anomaly in
                        ordered.filter { $0.timestamp > anomaly.timestamp && ["partial", "final", "discarded"].contains($0.event) }.count
                    } ?? 0,
                    finalSafeCopy: ordered.last { $0.textEvidence.contains { $0.kind == .safeCopySucceeded } },
                    fullTextEvidenceCount: ordered.reduce(0) { $0 + $1.textEvidence.count },
                    screenEvidenceStatus: "not_captured_AX_text_is_not_screen_evidence")
            }.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }
}
