# Safari 输入恢复与实时故障取证

## Goal and boundaries

- Repair the confirmed Safari ChatGPT composer layout transition, then improve the one-click failure report for Safari, Chrome, and the Codex desktop client.
- Work only in `codex/task-20261026`; preserve the existing dirty changes. Do not merge, push, install, or auto-commit.
- After each related App change group, run `./scripts/build-app.sh`, resolve failures, and retain the runnable `.app` artifact link.

## Milestones

1. **Safari target continuity.** Capture bounded AX ancestor structure for an eligible web editor. On an invalid old AX handle, reacquire only if the same process/window/web area and a stable editor-specific ancestor are verified, the editor candidate is unique, the before/after role and identifier path is compatible, the focused candidate is editable/nonsecure, and the pending document receipt matches. Never resend the acknowledged character. Any incomplete or conflicting evidence retains the safe stop. Add replay cases for layout rebuild, two editors with identical text, ambiguous ancestry, focus/app changes, and external edits. Keep the existing Codex caret-recovery experiment disabled by default.
2. **Structured report completeness.** Make input activity probes cover Safari, Chrome, and Codex, preserve privacy-safe fields and secure-field restrictions, and correlate wall-clock plus monotonic times to session, operation, and target. Export the fixed preceding 60-second timeline plus bounded, separately timestamped first/latest failure snapshots and their related session evidence. Add capture statuses for disabled, partial, denied, timed out, truncated, and unavailable. Bump report schema compatibly; old optional fields decode as unknown. Test window boundaries and report delay beyond 60 seconds.
3. **Optional target-window frames.** Add an off-by-default ScreenCaptureKit source for the explicitly selected/verified target app window, only during active input sessions. Cap at 5 frames/sec and 128 MiB total memory for a 60-second ring, preserve bounded pre-failure frames, stop on ambiguous target, secure input, session end, or permission loss. Do not capture audio or upload data. Export JSON alone if disabled/unavailable; when frames exist, export one ZIP containing JSON, timestamp index, and compressed frames. Missing permission or capture/encoding failure must not interrupt speech input or JSON export. Clearly report every coverage gap.
4. **Project learning and final verification.** Document the repeatable rule: use each unresolved report to identify the precise evidence gap, add only evidence that distinguishes remaining causes, and verify it with unattended checks before asking for manual reproduction. Run focused tests per subsystem, the requested full test suite, all three environment matrices where safely available, complete App builds after each App group, and inspect the final diff/status. Report real-environment coverage separately from replay coverage and limitations.

## Compatibility and rollback

- Add new settings/report fields as optional with capture default off; preserve decoding of existing settings and report schema versions.
- Safari returns to safe stop whenever editor continuity cannot be proven. Disabling/removing frame capture leaves structured reports and input behavior operational.
- Do not delete or migrate user reports on rollback. Preserve any new report artifacts as user data.
- Before changing a capture boundary, verify the selected window identity, secure-input status, and capture permission; do not use app tooling to bypass the Codex desktop access restriction.

## Acceptance and assumptions

- Safari, Chrome, and Codex coverage includes first input, append, replacement/selection, composer expand/collapse, focus/window/editor changes, safe-copy fallback, and report export.
- Same-text/different-editor, delayed AX setter, stale AX read, external edit, and app switch cases must not cause duplicate input, lost text, or writes into the wrong editor.
- A known reproduction must distinguish the cause using exported evidence or explicitly identify what remains unobservable. The report does not promise a root cause for every unknown failure.
- A stable editor-specific AX ancestor and useful window-frame visibility are hypotheses to verify; if continuity evidence is ambiguous, Safari remains stopped safely.

## Implementation and verification record (2026-10-26)

### Completed

- Safari AX target recovery now checks the same Safari process, web area, stable editor ancestor, unique editable candidate, compatible role/identifier path, focus eligibility, and matching document receipt before accepting a rebuilt AX handle. It does not resend acknowledged text; uncertainty still stops input safely.
- Diagnostic sampling now covers Safari, Chrome, and Codex; events carry wall-clock and monotonic time plus session, operation, and target identifiers when available. Reports keep the click-minute timeline and separately preserve the failure-minute context and related failure evidence.
- Optional target-window frame capture is off by default. It requires an active session, explicit opt-in, a verified target window, Screen Recording permission, and no secure-input state. Frames remain in a bounded local ring and export with the report; missing frames do not block JSON export.
- The report schema is version 5. New fields are optional, and an older schema 3 report was decoded successfully by the compatibility test.
- `AGENTS.md` now directs future RCA work to identify and close evidence gaps with bounded collection and unattended checks before asking for repeated manual reproduction.
- A user-provided Build 210 report from the real Codex desktop client confirmed the current failure: ASR retained the full recognized text; Codex confirmed only the first four characters; then a transient `AXFocusedUIElement` read (`-25204`) interrupted pre-dispatch selection stabilization and the app switched to safe copy. The report's frame capture was disabled.
- Fixed that Codex failure path. The live writer now retries transient reads during selection stabilization within the existing bounded preflight window. It dispatches only after the target and selection are confirmed; it does not repeat the replacement. Added a replay based on the report's “four characters already entered, next read fails” sequence.

### Verification results

| Area | Result |
| --- | --- |
| Automated tests | Final full `swift test` passed: 621 tests, 0 failures. |
| Safari target replay | 127 `AXTextTargetReplayTests` passed, including the Safari layout-rebuild case, same-text/different-editor rejection, and safe-stop cases. |
| Report and collection replay | Tests cover Safari/Chrome/Codex probe selection, delayed report export, first/latest failure retention, one-minute filtering, disabled collection, event overflow/truncation visibility, secure-field exclusion, and legacy decoding. |
| Frame policy and archive | Tests cover default-off/permission/secure-input policy, ring limits, and ZIP contents. Screen Recording permission was not enabled for a live capture. |
| Real Safari page | A temporary blank ChatGPT composer visibly expanded after disposable text was entered. The text was cleared and the temporary tab was closed. This confirms the layout transition, but does not confirm the app's live speech-to-text injection or AX handle recovery in Safari. |
| Real Chrome ChatGPT | Not validated in a live browser session. |
| Real Codex desktop client | A user-provided Build 210 report confirms the actual target and failure: full speech recognition, four confirmed characters, transient AX focus read error, then safe copy. Build 211 has not yet been checked in a live Codex session. |
| App build | `./scripts/build-app.sh` succeeded. Product version `0.5.0`, Build `211`; the executable exists and the app passed strict code-signature verification. |
| Workspace | `git diff --check` passed. Work remains uncommitted on `codex/task-20261026`; no merge, push, or install was performed. |

### Remaining validation and limits

- The Safari replay proves that a carefully identified rebuilt AX target can be reacquired without resending acknowledged text. A temporary Safari ChatGPT composer was observed expanding, but the built app's speech-to-text path and recovery have not yet been checked live in Safari.
- Live Chrome ChatGPT validation remains outstanding. The Codex failure was reported from a real session, but the Build 211 fix still needs a live Codex check; replay coverage does not substitute for that confirmation.
- Frame export was tested with synthetic frame data and policy tests. Real ScreenCaptureKit permission, capture quality, and report ZIP behavior have not been exercised against a live target window.
- Therefore, this change improves the evidence available in future reports but cannot guarantee that every single report will identify an unknown root cause. When evidence is still insufficient, the report should state the missing signal and guide the next bounded collection change.

### Current build artifact

- Runnable app: `dist/Rime Voice Build211.app`
- Bundle version: `0.5.0` (Build `211`)

## Follow-up implementation: shared keyboard strategy and failure evidence (2026-10-26)

This follow-up implements the accepted plan for the repeated “text moved back to an earlier caret position” report. Its build and validation results supersede the artifact and schema version above; the earlier section remains as the record of the prior Safari/Build 211 work.

### Implemented

- `TextTarget.swift` now selects `acknowledgedKeyboard` for Codex only when AX confirms an editable, nonsecure text field with readable text state. Unknown, secure, readonly, and unreadable targets stop safely. Obsidian and Safari/Chrome routing remain on their existing paths.
- `TextInjector.swift` now uses the captured strategy instead of maintaining a separate Codex keyboard override. `AXTextTarget.swift` uses that same strategy for caret and replacement selection ownership; a keyboard-owned selection is not reset through AX before the next append. Existing target, document, operation, and selection checks remain active. No automatic resend or caret-recovery experiment was enabled.
- Replaced the paragraph test's prefilled write snapshots with an editor replay that changes its own text, selection, and structural newline when it receives keyboard input. The delayed AX setter regression now checks the final document order and that each recognized update is submitted once.
- Failure reports now use schema 6. The main timeline remains limited to the minute before the report click; first/latest failure evidence is separately retained with its original timestamps and linked session evidence. Events are deduplicated by event ID and use monotonic order when available, while keeping wall-clock timestamps for people.
- Failure summaries now separate what the report observed from candidate explanations, supporting evidence, and missing evidence. An AX text mismatch is not treated as proof of whether the editor moved its caret or AX returned stale state. Older reports without the new summary field still decode.
- Targeted AX notifications observe application focus and the selected target's value/selection changes. Their records are explicitly marked as AX-only and do not claim independent DOM or screen evidence. The report states that no callback does not prove that no change occurred, and records permission, registration and interaction-filter gaps.
- The optional screen recorder remains off by default. When explicitly enabled, its ring is limited to 60 seconds, 5 frames per second, 300 frames and 80 MiB; disabling it clears retained frames. It captures no audio and uploads nothing.
- `AGENTS.md` records that a report's evidence gap should first lead to bounded automatic data collection and unattended verification, reducing repeated manual reproduction.

### Verification and delivery

| Area | Result |
| --- | --- |
| Targeted regression suites | 84 tests passed across AX document mapping, acknowledged keyboard writes, Codex injection and session coordination. |
| Full test suite | `swift test` passed: 629 tests, 0 failures. |
| Report and collection | Verified monotonic ordering, shared event IDs, notification lifecycle, first/latest failure retention across the 60-second boundary, interaction coverage fields, legacy summary decoding, and conservative mismatch reporting. |
| Screen frame policy | Policy and archive tests passed. A live Screen Recording permission/capture was not exercised in this run. |
| Safari ChatGPT | Earlier work observed a disposable composer expanding in Safari; that did not exercise the speech-input injection path. The updated app was not tested with live speech input in Safari. |
| Chrome ChatGPT | Not tested live. |
| Codex desktop | No live write was performed. App-tool access restrictions were not bypassed; automated editor replays are not presented as a real Codex confirmation. |
| App build | `./scripts/build-app.sh` passed. Version `0.5.0`, Build `214`; `codesign --verify --deep --strict` passed and the executable is present. |
| Workspace | `git diff --check` passed. Changes remain uncommitted on `codex/task-20261026`; no merge, push or install was performed. |

### Remaining evidence limit

The shared policy fix removes the app's own competing AX caret request from keyboard-owned Codex writes, and the independent editor replay verifies the resulting document order. The historical Build 211 caret jump still does not have a unique proven trigger: the report showed the wrong insertion position, but lacked an independent editor-internal state/timing signal to distinguish a delayed request from the editor moving the caret. The new report provides fuller AX timing and optional screen evidence, but screen sampling is not fast enough to prove millisecond ordering. No live Safari/Chrome/Codex speech-input result is claimed here.

### Current build artifact

- Runnable app: `dist/Rime Voice Build214.app`
- Bundle version: `0.5.0` (Build `214`)

## Finalization version and build

The prior latest release and tag were `0.5.0-macos`. This change adds new diagnostic coverage as well as the input strategy fix, so the finalized product version is `0.6.0` under the repository's version rules. The Build number advances to `215` for a fresh complete App build. `swift test` passed all 629 tests, and `./scripts/build-app.sh` produced a signed, executable `dist/Rime Voice Build215.app` with bundle version `0.6.0` / Build `215`.
