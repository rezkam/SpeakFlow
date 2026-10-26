#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=SCRIPTDIR/lib/e2e-result.sh
source "$ROOT_DIR/scripts/lib/e2e-result.sh"
e2e_prepare_scenario
export SPEAKFLOW_E2E_TEST_AUTO_END=true
export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="Hello world, this is a short test of the voice activity detection system."
export SPEAKFLOW_E2E_TIMEOUT_SECONDS=15
export SPEAKFLOW_E2E_CHUNK_DURATION=3600
export SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS=5
export SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS=15
e2e_run_asserted_case "Short speech auto-end timing" autoEndFired autoEndWindow
