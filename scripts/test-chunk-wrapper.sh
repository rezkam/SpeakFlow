#!/usr/bin/env bash
# Offline executable contract probes. Fixtures and logs stay in the repository.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .agents/tests
TEST_DIR="$(mktemp -d "$ROOT_DIR/.agents/tests/chunk-wrapper.XXXXXX")"
mkdir -p "$TEST_DIR/bin"
export WRAPPER_CALLS="$TEST_DIR/calls"
cat > "$TEST_DIR/bin/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'run --disable-sandbox SpeakFlowLiveE2E' ]] || exit 65
printf '%s:%s:%s\n' "${SPEAKFLOW_E2E_CHUNK_DURATION:-}" "${SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS:-}" "${SPEAKFLOW_E2E_EXPECT_MAX_CHUNKS:-}" >> "$WRAPPER_CALLS"
assertions=chunkRange
if [[ "${SPEAKFLOW_E2E_TEST_AUTO_END:-false}" == true ]]; then
    [[ -n "${SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS:-}" && -n "${SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS:-}" ]] || exit 64
    assertions=autoEndFired,autoEndWindow
else
    [[ -n "${SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS:-}" ]] || exit 64
    if [[ "${SPEAKFLOW_E2E_CHUNK_DURATION}" == 3600 ]]; then
        [[ "$SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS" == 1 && "${SPEAKFLOW_E2E_EXPECT_MAX_CHUNKS:-}" == 1 ]] || exit 64
    else
        [[ "$SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS" == 2 && -z "${SPEAKFLOW_E2E_EXPECT_MAX_CHUNKS:-}" ]] || exit 64
    fi
fi
case "$WRAPPER_SCENARIO" in
    pass) echo "E2E_RESULT status=pass assertions=$assertions chunks=2 auto_end_seconds=none" ;;
    missing-result) echo 'chunk #1'; echo 'chunk #2' ;;
    missing-assertion) echo 'E2E_RESULT status=pass assertions=none chunks=2 auto_end_seconds=none' ;;
    failure-verdict) echo 'E2E_RESULT status=fail assertions=chunkRange chunks=2 auto_end_seconds=none' ;;
    process-failure) echo "E2E_RESULT status=pass assertions=$assertions chunks=2 auto_end_seconds=none"; exit 23 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/swift"
export PATH="$TEST_DIR/bin:$PATH"
for wrapper in run_chunk_tests.sh run_timing_tests.sh run_comprehensive_tests.sh; do
    # Do not run an old wrapper that persists system logs outside the repository.
    if grep -Eq '/tmp/|log (show|stream)' "scripts/$wrapper"; then
        echo "FAIL: $wrapper uses unsafe ambient diagnostic capture"
        exit 1
    fi
    expected_calls=1
    [[ "$wrapper" != run_chunk_tests.sh ]] || expected_calls=3
    [[ "$wrapper" != run_comprehensive_tests.sh ]] || expected_calls=2
    for scenario in pass missing-result missing-assertion failure-verdict process-failure; do
    : > "$WRAPPER_CALLS"
    rc=0
    WRAPPER_SCENARIO="$scenario" bash "scripts/$wrapper" > "$TEST_DIR/$wrapper-$scenario.log" 2>&1 || rc=$?
    if [[ "$scenario" == pass ]]; then
        [[ "$rc" == 0 ]] || { echo "FAIL: successful asserted runner rejected (exit=$rc)"; exit 1; }
        [[ "$(wc -l < "$WRAPPER_CALLS" | tr -d ' ')" == "$expected_calls" ]] || { echo 'FAIL: not all cases ran'; exit 1; }
    else
        [[ "$rc" != 0 ]] || { echo "FAIL: wrapper accepted $scenario"; exit 1; }
    fi
    echo "PASS: $wrapper $scenario"
    done
done
