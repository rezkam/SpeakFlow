#!/usr/bin/env bash
# Exercise real executable entries without network, credentials, or capture.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
unset SPEAKFLOW_ISOLATED_STORAGE SPEAKFLOW_MUTE_SOUNDS SPEAKFLOW_ISOLATE_TEST_AUDIO DEEPGRAM_API_KEY
E2E_BINARY="${1:-.build/debug/DeepgramE2E}"
TEST_BINARY="${2:-.build/debug/DeepgramTest}"
for binary in "$E2E_BINARY" "$TEST_BINARY"; do
    [[ -x "$binary" ]] || { echo 'FAIL: missing provider probe executable; pass both product paths'; exit 1; }
done
for product in DeepgramE2E DeepgramTest; do
    binary="$E2E_BINARY"
    [[ "$product" != DeepgramTest ]] || binary="$TEST_BINARY"
    output="$("$binary" --runtime-policy-probe)"
    [[ "$output" == *'isolated=true muted=true'* ]] || { echo "FAIL: $product entry is not isolated and muted"; exit 1; }
    if [[ "$product" == DeepgramTest ]]; then
        [[ "$output" == *'microphone_allowed=false'* ]] || { echo 'FAIL: microphone enabled by default'; exit 1; }
        output="$("$TEST_BINARY" --runtime-policy-probe --allow-microphone)"
        [[ "$output" == *'microphone_allowed=true'* ]] || { echo 'FAIL: explicit capture opt-in ignored'; exit 1; }
    fi
    echo "PASS: $product isolated and muted"
done
# A synthetic inherited key must not trigger permission requests or capture.
rc=0
output="$(DEEPGRAM_API_KEY=synthetic-test-key "$TEST_BINARY" 2>&1)" || rc=$?
[[ "$rc" != 0 && "$output" == *'Microphone capture requires --allow-microphone'* ]] || { echo 'FAIL: default executable did not refuse capture'; exit 1; }
echo 'PASS: inherited provider key does not authorize microphone capture'
