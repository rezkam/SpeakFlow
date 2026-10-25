#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=SCRIPTDIR/lib/e2e-result.sh
source "$ROOT_DIR/scripts/lib/e2e-result.sh"

run_case() {
    local label="$1" text="$2" minimum="$3" maximum="$4"
    e2e_prepare_scenario
    export SPEAKFLOW_E2E_TEST_AUTO_END=true
    export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="$text"
    export SPEAKFLOW_E2E_TIMEOUT_SECONDS="$maximum"
    export SPEAKFLOW_E2E_CHUNK_DURATION=3600
    export SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS="$minimum"
    export SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS="$maximum"
    e2e_run_asserted_case "$label" autoEndFired autoEndWindow
}

run_case "Short speech baseline" "Hello world, this is a short test." 5 15
run_case "Continuous speech does not end early" \
    "This is a much longer test passage designed to last approximately fifteen seconds or more. I am speaking continuously to ensure that the voice activity detection does not trigger a premature end of session while the user is still actively dictating their thoughts." \
    15 30
printf 'ALL TIMING CASES PASSED\n'
