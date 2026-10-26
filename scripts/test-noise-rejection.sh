#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/e2e-result.sh"
source "$ROOT_DIR/scripts/lib/noise-suite.sh"
e2e_execute_runner() {
    swift run -c release --disable-sandbox SpeakFlowLiveE2E --silence-only
}
e2e_run_noise_suite typing
