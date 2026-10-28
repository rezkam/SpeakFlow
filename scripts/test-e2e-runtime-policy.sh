#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
BINARY="${1:-.build/debug/SpeakFlowLiveE2E}"
[[ -x "$BINARY" ]] || { echo 'FAIL: missing SpeakFlowLiveE2E executable; pass its active build path'; exit 1; }
unset SPEAKFLOW_ISOLATED_STORAGE SPEAKFLOW_UI_TEST_MODE
for mode in default silence; do
    args=(--runtime-policy-probe)
    expected=true
    if [[ "$mode" == silence ]]; then args+=(--silence-only); expected=false; fi
    rc=0
    output="$("$BINARY" "${args[@]}" 2>&1)" || rc=$?
    [[ "$rc" == 0 ]] || { echo "FAIL: $mode runtime isolation is not unconditional"; exit 1; }
    [[ "$output" == "E2E_RUNTIME isolated=true transcription_allowed=$expected muted=true" ]] || {
        echo "FAIL: $mode runtime policy mismatch"; exit 1;
    }
    echo "PASS: $mode entry isolation and transcription policy"
done
