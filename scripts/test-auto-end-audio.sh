#!/usr/bin/env bash
# Explicit real-model, file-audio checks. No microphone or transcription requests.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source scripts/lib/e2e-result.sh
[[ "${SPEAKFLOW_RUN_VAD_MODEL_TESTS:-0}" == 1 ]] || {
    echo 'FAIL: explicitly opt into the isolated VAD model before running audio checks'; exit 1;
}
BINARY="${1:-.build/debug/SpeakFlowLiveE2E}"
command -v timeout >/dev/null || { echo 'FAIL: GNU timeout is required for the process watchdog'; exit 1; }
mkdir -p .agents/e2e
fixtures="$(mktemp -d .agents/e2e/auto-end-audio.XXXXXX)"
ffmpeg -y -f lavfi -i 'anullsrc=r=16000:cl=mono' -t 12 "$fixtures/silence.wav" >/dev/null 2>&1

run_case() {
    local name="$1" minimum="$2" maximum="$3" timeout="$4" failure="$5" delay="${6:-0}" rc=0
    local output="$fixtures/$name.log"
    (
        e2e_prepare_scenario
        export SPEAKFLOW_E2E_AUDIO_FILE_PATH="$fixtures/silence.wav"
        export SPEAKFLOW_E2E_TEST_AUTO_END=true
        export SPEAKFLOW_E2E_DEBUG_TIMING=1
        export SPEAKFLOW_E2E_STARTUP_DELAY_SECONDS="$delay"
        export SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS="$minimum"
        export SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS="$maximum"
        export SPEAKFLOW_E2E_TIMEOUT_SECONDS="$timeout"
        export SPEAKFLOW_ISOLATE_TEST_AUDIO=1
        export SPEAKFLOW_OBSERVABILITY_DIR=/dev/null/speakflow-observability
        unset SPEAKFLOW_RUN_LIVE_MISTRAL
        timeout --foreground --kill-after=5 "$((timeout + delay + 15))" "$BINARY" --silence-only
    ) 2>&1 | redact_diagnostics > "$output" || rc=$?
    if [[ "$rc" == 124 || "$rc" == 137 ]]; then
        echo "FAIL: $name exceeded the external process deadline ($output)"
        return 1
    fi
    grep -q '^E2E_DEBUG_TIMING idle_sleep_protection=active$' "$output" || {
        echo "FAIL: $name lacks idle-sleep protection ($output)"; return 1;
    }
    grep -q 'VAD initialized with provided model' "$output" || {
        echo "FAIL: $name did not initialize the real model"; return 1;
    }
    if [[ -z "$failure" ]]; then
        [[ "$rc" == 0 ]] && e2e_check "$output" autoEndFired autoEndWindow || {
            echo "FAIL: $name did not satisfy the positive timing assertions ($output)"; return 1;
        }
    else
        [[ "$rc" != 0 ]] && grep -q '^E2E_RESULT status=fail ' "$output" && grep -Fq "$failure" "$output" || {
            echo "FAIL: $name did not reject the expected timing violation ($output)"; return 1;
        }
    fi
    echo "PASS: $name (real model, actual file-audio lifecycle)"
}
run_case slow-startup 8 14 16 '' 18
run_case valid-window 8 14 16 ''
run_case too-early 12 14 16 'before 12.0s'
run_case too-late 1 8 16 'after 8.0s'
run_case missing-auto-end 8 14 2 'autoEndFired: auto-end did not fire'
