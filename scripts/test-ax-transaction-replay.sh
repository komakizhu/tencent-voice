#!/usr/bin/env bash
set -euo pipefail

# All generated files stay in this checkout's ignored .build directory.
replay_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
replay_package="$replay_root/.build/ax-transaction-replay"
mkdir -p "$replay_package/Sources/TencentVoiceMVP" "$replay_package/Tests/AXTransactionReplayTests"
cp "$replay_root/TestSupport/AXTransactionReplay/Package.swift" "$replay_package/Package.swift"
cp "$replay_root/TestSupport/AXTransactionReplay/SessionError.swift" "$replay_package/Sources/TencentVoiceMVP/SessionError.swift"
for source in TextTarget.swift TextInputDiagnostic.swift AXTextDocument.swift AcknowledgedKeyboardWriter.swift; do
    cp "$replay_root/Sources/TencentVoiceMVP/$source" "$replay_package/Sources/TencentVoiceMVP/$source"
done
for test in AXTransactionReplayModel.swift AXTransactionReplayTests.swift KeyboardSelectionTransactionTests.swift KeyboardCaretSynchronizerTests.swift; do
    cp "$replay_root/Tests/TencentVoiceMVP/$test" "$replay_package/Tests/AXTransactionReplayTests/$test"
done
swift test --package-path "$replay_package" "$@"
