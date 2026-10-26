#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
BINARY="${1:-.build/debug/SpeakFlowLiveE2E}"
[[ -x "$BINARY" ]] || { echo 'FAIL: build SpeakFlowLiveE2E first'; exit 1; }
mkdir -p .agents/tests
TEST_DIR="$(mktemp -d "$ROOT_DIR/.agents/tests/e2e-fixtures.XXXXXX")"
# Foundation may ignore TMPDIR on macOS. Query the executable's actual root.
# Keep this machine-specific value in memory, never in a saved log.
NATIVE_TEMP="$("$BINARY" --fixture-root-probe)"
[[ -d "$NATIVE_TEMP" ]] || { echo 'FAIL: native fixture root unavailable'; exit 1; }
# A 0.1-second mono PCM WAV, generated without external media dependencies.
perl -e 'print pack("a4Va4a4VvvVVvva4V", "RIFF", 3236, "WAVE", "fmt ", 16, 1, 1, 16000, 32000, 2, 16, "data", 3200); print "\0" x 3200;' > "$TEST_DIR/silence.wav"
for variable in ${!SPEAKFLOW_E2E_@}; do unset "$variable"; done
export SPEAKFLOW_ISOLATED_STORAGE=1 SPEAKFLOW_ISOLATE_TEST_AUDIO=1 SPEAKFLOW_MUTE_SOUNDS=1
export SPEAKFLOW_OBSERVABILITY_DIR=/dev/null/disabled
for scenario in success failed-verdict missing-fixture; do
    mkdir -p "$TEST_DIR/$scenario"
    export TMPDIR="$TEST_DIR/$scenario/"
    export SPEAKFLOW_E2E_AUDIO_FILE_PATH="$TEST_DIR/silence.wav"
    export SPEAKFLOW_E2E_RECORD_SECONDS=0 SPEAKFLOW_E2E_TIMEOUT_SECONDS=0
    export SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS=0 SPEAKFLOW_E2E_EXPECT_MAX_CHUNKS=0
    if [[ "$scenario" == failed-verdict ]]; then
        export SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS=1 SPEAKFLOW_E2E_EXPECT_MAX_CHUNKS=1
    elif [[ "$scenario" == missing-fixture ]]; then
        export SPEAKFLOW_E2E_AUDIO_FILE_PATH="$TEST_DIR/missing.wav"
    fi
    rc=0
    "$BINARY" > >(perl -pe 's/\Q$ENV{HOME}\E/<HOME>/g; s#/(?:private/)?var/folders/[^\s:]+#<TEMP_PATH>#g; s/^.*(?:Host environment:|:: macOS Version).*$/<ENVIRONMENT_REDACTED>/' > "$TEST_DIR/$scenario.log") 2>&1 &
    child_pid=$!
    wait "$child_pid" || rc=$?
    if [[ "$scenario" == success ]]; then
        [[ "$rc" == 0 ]] || { echo "FAIL: $scenario exit=$rc"; exit 1; }
    else
        [[ "$rc" != 0 ]] || { echo "FAIL: $scenario falsely succeeded"; exit 1; }
    fi
    if [[ -d "$NATIVE_TEMP/SpeakFlowE2E_$child_pid" ]]; then
        echo "FAIL: $scenario leaked its native fixture directory"
        exit 1
    fi
    leaked="$(find "$TMPDIR" -maxdepth 1 -type d -name 'SpeakFlowE2E_*' -print | wc -l | tr -d ' ')"
    [[ "$leaked" == 0 ]] || { echo "FAIL: $scenario left $leaked fixture directory"; exit 1; }
    echo "PASS: $scenario cleanup and exit status"
done
