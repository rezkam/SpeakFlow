#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .agents/tests
TEST_DIR="$(mktemp -d "$ROOT_DIR/.agents/tests/modern-wrappers.XXXXXX")"
mkdir -p "$TEST_DIR/bin"
export WRAPPER_CALLS="$TEST_DIR/calls"
printf '{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","accountId":"fixture-account","lastRefresh":0}' > "$TEST_DIR/auth.json"
export SPEAKFLOW_E2E_AUTH_FILE="$TEST_DIR/auth.json"
export WRAPPER_EXPECT_AUTH="$SPEAKFLOW_E2E_AUTH_FILE"
# A mistaken network/tool path must fail, never contact a provider.
for command in curl wget nc; do
    printf '#!/bin/sh\nexit 98\n' > "$TEST_DIR/bin/$command"
    chmod +x "$TEST_DIR/bin/$command"
done
cat > "$TEST_DIR/bin/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'run --disable-sandbox SpeakFlowLiveE2E' ]] || exit 65
[[ "${SPEAKFLOW_ISOLATED_STORAGE:-}" == 1 && "${SPEAKFLOW_MUTE_SOUNDS:-}" == 1 ]] || exit 66
[[ -z "${SPEAKFLOW_E2E_UNRELATED:-}" ]] || exit 67
[[ "${SPEAKFLOW_E2E_AUTH_FILE:-}" == "$WRAPPER_EXPECT_AUTH" && -s "$SPEAKFLOW_E2E_AUTH_FILE" ]] || exit 72
assertions=none
if [[ "${SPEAKFLOW_E2E_TEST_NOISE_REJECTION:-}" == 1 ]]; then
    [[ -s "${SPEAKFLOW_E2E_AUDIO_FILE_PATH:-}" ]] || exit 68
    assertions=noChunks
else
    [[ -z "${SPEAKFLOW_E2E_AUDIO_FILE_PATH:-}" ]] || exit 69
    if [[ "${SPEAKFLOW_E2E_TEST_AUTO_END:-}" == true ]]; then
        [[ -n "${SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS:-}" && -n "${SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS:-}" ]] || exit 70
        if [[ "$WRAPPER_TARGET" == run-auto-end-timing-e2e.sh ]]; then
            [[ "${SPEAKFLOW_E2E_AUTO_END_SILENCE_SECONDS:-}" == 5 ]] || exit 71
        fi
        assertions=autoEndFired,autoEndWindow
    fi
    [[ -z "${SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS:-}" ]] || assertions+=,chunkRange
    [[ -z "${SPEAKFLOW_E2E_EXPECT_PHRASE:-}" ]] || assertions+=,phrase
fi
printf 'case\n' >> "$WRAPPER_CALLS"
case "$WRAPPER_SCENARIO" in
    pass) echo "E2E_RESULT status=pass assertions=$assertions chunks=2 auto_end_seconds=10" ;;
    missing-result) echo 'Done' ;;
    missing-assertion) echo 'E2E_RESULT status=pass assertions=none chunks=2 auto_end_seconds=10' ;;
    failure-verdict) echo "E2E_RESULT status=fail assertions=$assertions chunks=2 auto_end_seconds=10" ;;
    process-failure) echo "E2E_RESULT status=pass assertions=$assertions chunks=2 auto_end_seconds=10"; exit 23 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/swift"
export PATH="$TEST_DIR/bin:$PATH"
for wrapper in run-auto-end-timing-e2e.sh run-chunk-duration-e2e.sh run-transcription-accuracy-e2e.sh; do
    export WRAPPER_TARGET="$wrapper"
    if grep -q '/tmp/' "scripts/$wrapper"; then
        echo "FAIL: $wrapper uses external temporary artifacts"
        exit 1
    fi
    expected=3
    [[ "$wrapper" != run-auto-end-timing-e2e.sh ]] || expected=4
    for scenario in pass missing-result missing-assertion failure-verdict process-failure; do
        : > "$WRAPPER_CALLS"
        rc=0
        SPEAKFLOW_E2E_UNRELATED=inherited SPEAKFLOW_E2E_AUDIO_FILE_PATH=inherited WRAPPER_SCENARIO="$scenario" bash "scripts/$wrapper" > "$TEST_DIR/$wrapper-$scenario.log" 2>&1 || rc=$?
        if [[ "$scenario" == pass ]]; then
            [[ "$rc" == 0 ]] || { echo "FAIL: $wrapper rejected asserted pass (exit=$rc)"; exit 1; }
            [[ "$(wc -l < "$WRAPPER_CALLS" | tr -d ' ')" == "$expected" ]] || { echo "FAIL: $wrapper skipped a scenario"; exit 1; }
        else
            [[ "$rc" != 0 ]] || { echo "FAIL: $wrapper accepted $scenario"; exit 1; }
        fi
        echo "PASS: $wrapper $scenario"
    done
done
