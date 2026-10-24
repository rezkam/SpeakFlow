#!/usr/bin/env bash
set -euo pipefail

unset -f git 2>/dev/null || true

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH" .build

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SpeakFlow Live E2E"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Runs the built-in scenario suite on generated audio (no microphone)."
echo "Transcription scenarios need a ChatGPT login; pass --silence-only to run"
echo "only the silence and auto-end scenarios."
echo ""
echo "To run one configured scenario, set SPEAKFLOW_E2E_* variables (see"
echo "Sources/LiveE2EKit/LiveE2EContract.swift); the runner then prints"
echo "E2E_RESULT with the assertions that executed."
echo ""

swift run SpeakFlowLiveE2E "$@"
