#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"
source "$ROOT_DIR/scripts/lib/e2e-result.sh"
source "$ROOT_DIR/scripts/lib/noise-suite.sh"
e2e_execute_runner() {
    swift run --disable-sandbox SpeakFlowLiveE2E --silence-only
}
e2e_run_noise_suite multitone
