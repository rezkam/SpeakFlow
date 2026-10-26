#!/usr/bin/env bash
# Offline wrapper contracts, never capture microphone or call a provider.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .agents/tests
TEST_DIR="$(mktemp -d "$ROOT_DIR/.agents/tests/noise-wrapper.XXXXXX")"
mkdir -p "$TEST_DIR/bin"
export WRAPPER_CALLS="$TEST_DIR/calls"
cat > "$TEST_DIR/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
format=''
while (( $# > 1 )); do
    case "$1" in
        -f) format="$2"; shift 2 ;;
        -i)
            [[ "$format" == lavfi ]] || exit 70
            format=''
            shift 2
            ;;
        *) shift ;;
    esac
done
[[ "$WRAPPER_SCENARIO" != fixture-failure ]] || exit 24
[[ "$WRAPPER_SCENARIO" != missing-fixture ]] || exit 0
printf 'synthetic fixture' > "${!#}"
STUB
cat > "$TEST_DIR/bin/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'case\n' >> "$WRAPPER_CALLS"
expected='run --disable-sandbox SpeakFlowLiveE2E --silence-only'
[[ "$WRAPPER_NAME" != test-noise-rejection.sh ]] || expected='run -c release --disable-sandbox SpeakFlowLiveE2E --silence-only'
[[ "$*" == "$expected" ]] || exit 65
[[ "${SPEAKFLOW_ISOLATED_STORAGE:-}" == 1 && "${SPEAKFLOW_MUTE_SOUNDS:-}" == 1 ]] || exit 66
[[ "${SPEAKFLOW_E2E_TEST_NOISE_REJECTION:-}" == 1 ]] || exit 67
[[ -z "${SPEAKFLOW_E2E_EXPECT_PHRASE:-}" ]] || exit 68
[[ -s "${SPEAKFLOW_E2E_AUDIO_FILE_PATH:-}" ]] || exit 69
case "$WRAPPER_SCENARIO" in
    pass) echo 'E2E_RESULT status=pass assertions=noChunks chunks=0 auto_end_seconds=none' ;;
    missing-result) echo 'Done' ;;
    missing-assertion) echo 'E2E_RESULT status=pass assertions=none chunks=0 auto_end_seconds=none' ;;
    failure-verdict) echo 'E2E_RESULT status=fail assertions=noChunks chunks=0 auto_end_seconds=none' ;;
    process-failure) echo 'E2E_RESULT status=pass assertions=noChunks chunks=0 auto_end_seconds=none'; exit 23 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/ffmpeg" "$TEST_DIR/bin/swift"
export PATH="$TEST_DIR/bin:$PATH"
for wrapper in run-noise-rejection-e2e.sh test-noise-rejection.sh; do
    if grep -Eq '/tmp/|TEST_AUDIO_DIR="/tmp"' "scripts/$wrapper"; then
        echo "FAIL: $wrapper persists fixtures or diagnostics outside the repository"
        exit 1
    fi
    for scenario in pass missing-result missing-assertion failure-verdict process-failure fixture-failure missing-fixture; do
        : > "$WRAPPER_CALLS"
        rc=0
        SPEAKFLOW_E2E_EXPECT_PHRASE=inherited WRAPPER_NAME="$wrapper" WRAPPER_SCENARIO="$scenario" bash "scripts/$wrapper" > "$TEST_DIR/$wrapper-$scenario.log" 2>&1 || rc=$?
        if [[ "$scenario" == pass ]]; then
            [[ "$rc" == 0 ]] || { echo "FAIL: $wrapper rejected asserted pass (exit=$rc)"; exit 1; }
            [[ "$(wc -l < "$WRAPPER_CALLS" | tr -d ' ')" == 4 ]] || { echo 'FAIL: not all four fixtures ran'; exit 1; }
        else
            [[ "$rc" != 0 ]] || { echo "FAIL: $wrapper accepted $scenario"; exit 1; }
            if [[ "$scenario" == fixture-failure || "$scenario" == missing-fixture ]]; then
                [[ ! -s "$WRAPPER_CALLS" ]] || { echo "FAIL: $wrapper ran before required fixtures were ready"; exit 1; }
            fi
        fi
        echo "PASS: $wrapper $scenario"
    done
done
