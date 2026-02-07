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
echo "Uses real microphone capture and real transcription API."
echo "Optional env:"
echo "  SPEAKFLOW_E2E_RECORD_SECONDS=6"
echo "  SPEAKFLOW_E2E_TIMEOUT_SECONDS=35"
echo "  SPEAKFLOW_E2E_EXPECT_PHRASE='hello world'"
echo "  SPEAKFLOW_E2E_AUTO_SPEAK_TEXT='hello world'   # requires audio loopback to mic"
echo "  SPEAKFLOW_E2E_AUTO_SPEAK_TEXT_PART2='second phrase'"
echo "  SPEAKFLOW_E2E_AUTO_SPEAK_GAP_SECONDS=2"
echo "  SPEAKFLOW_E2E_AUTO_SPEAK_RATE=180"
echo "  SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS=6"
echo "  SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS=14"
echo ""

swift run SpeakFlowLiveE2E
