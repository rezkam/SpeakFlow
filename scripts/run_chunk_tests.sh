#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=SCRIPTDIR/lib/e2e-result.sh
source "$ROOT_DIR/scripts/lib/e2e-result.sh"
e2e_prepare_scenario transcription
export SPEAKFLOW_E2E_TEST_AUTO_END=false
SPEAKFLOW_E2E_AUTO_SPEAK_TEXT=""
for _ in {1..24}; do
    SPEAKFLOW_E2E_AUTO_SPEAK_TEXT+="This synthetic passage continues speaking to verify duration based audio chunk splitting. "
done
export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT

run_test() {
    local duration="$1" seconds="$2" minimum="$3" maximum="${4:-}"
    export SPEAKFLOW_E2E_CHUNK_DURATION="$duration"
    export SPEAKFLOW_E2E_RECORD_SECONDS="$seconds"
    export SPEAKFLOW_E2E_TIMEOUT_SECONDS="$((seconds + 10))"
    export SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS="$minimum"
    unset SPEAKFLOW_E2E_EXPECT_MAX_CHUNKS
    if [[ -n "$maximum" ]]; then export SPEAKFLOW_E2E_EXPECT_MAX_CHUNKS="$maximum"; fi

    e2e_run_asserted_case "chunk duration=$duration range=$minimum..${maximum:-unbounded}" chunkRange
}

run_test 15 35 2
run_test 30 65 2
run_test 3600 45 1 1
printf 'ALL CHUNK TESTS PASSED\n'
