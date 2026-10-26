#!/usr/bin/env bash
# Exercise real executable entries without network, credentials, or capture.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
unset SPEAKFLOW_ISOLATED_STORAGE SPEAKFLOW_MUTE_SOUNDS SPEAKFLOW_ISOLATE_TEST_AUDIO DEEPGRAM_API_KEY
for product in DeepgramE2E DeepgramTest; do
    output="$(".build/debug/$product" --runtime-policy-probe)"
    [[ "$output" == *'isolated=true muted=true'* ]] || { echo "FAIL: $product entry is not isolated and muted"; exit 1; }
    if [[ "$product" == DeepgramTest ]]; then
        [[ "$output" == *'microphone_allowed=false'* ]] || { echo 'FAIL: microphone enabled by default'; exit 1; }
        output="$(.build/debug/DeepgramTest --runtime-policy-probe --allow-microphone)"
        [[ "$output" == *'microphone_allowed=true'* ]] || { echo 'FAIL: explicit capture opt-in ignored'; exit 1; }
    fi
    echo "PASS: $product isolated and muted"
done
# A synthetic inherited key must not trigger permission requests or capture.
rc=0
output="$(DEEPGRAM_API_KEY=synthetic-test-key .build/debug/DeepgramTest 2>&1)" || rc=$?
[[ "$rc" != 0 && "$output" == *'Microphone capture requires --allow-microphone'* ]] || { echo 'FAIL: default executable did not refuse capture'; exit 1; }
echo 'PASS: inherited provider key does not authorize microphone capture'
