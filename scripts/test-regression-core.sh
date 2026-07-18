#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Optional module-cache overrides — required in sandboxed environments
if mkdir -p "$ROOT_DIR/.build" 2>/dev/null; then
  export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"
  export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
  mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH" 2>/dev/null || true
fi

LOG_FILE="${SPEAKFLOW_REGRESSION_LOG_FILE:-$(mktemp /tmp/speakflow-regression-core-XXXXXX)}"
: > "$LOG_FILE"

OBS_PROFILE="${SPEAKFLOW_OBSERVABILITY_PROFILE:-regression-$(date +%Y%m%d%H%M%S)-$$}"
OBS_DIR="${SPEAKFLOW_OBSERVABILITY_DIR:-/tmp/speakflow-observability-tests/$OBS_PROFILE}"
mkdir -p "$OBS_DIR"

SKIP_BUILD="${SPEAKFLOW_REGRESSION_SKIP_BUILD:-0}"
STRESS_RUNS="${SPEAKFLOW_REGRESSION_STRESS_RUNS:-3}"
SCRATCH_PATH="${SPEAKFLOW_SWIFT_SCRATCH_PATH:-}"

REGRESSION_SUITES=(
  "DictationReadinessTests"
  "ProviderReadinessTests"
  "AppStateTests"
  "HotkeyListenerTests"
  "HotkeyTests"
  "PermissionControllerDITests"
  "AuthControllerDITests"
  "RecordingControllerTests"
  "StreamingRecordingTests"
  "EnterSubmissionContractTests"
  "KeyInterceptorEnterCaptureTests"
  "TextInserterFocusTests"
  "TextInserterModifierSafetyTests"
  "SoundEffectTests"
  "SessionControllerTests"
  "SettingsAutoEndTests"
  "ThinkingPauseDetectorTests"
  "VADStateMachineTests"
  "VADIntegrationTests"
  "VADTests"
  "LiveStreamingKeepAliveTests"
  "WebSocketSessionContractTests"
  "WebSocketReconnectIntegrationTests"
  "CorrectnessTests"
  "AudioPipelineTests"
  "TranscriptionQueueTests"
  "TranscriptionTests"
  "StatisticsTests"
  "SessionMetricsStoreTests"
  "ObservabilityTests"
  "AuthTests"
  "DeepgramSessionTests"
  "MistralSessionTests"
  "MistralBatchProviderTests"
  "MistralRealtimeRegressionTests"
  "PerformanceOptimizationTests"
)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SpeakFlow Main Feature Regression"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Log: $LOG_FILE"
echo "Observability.... $OBS_DIR"
if [[ -n "$SCRATCH_PATH" ]]; then
  echo "Scratch.......... $SCRATCH_PATH"
  mkdir -p "$SCRATCH_PATH"
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "Build.............. swift build --build-tests"
  build_cmd=(swift build --build-tests)
  if [[ -n "$SCRATCH_PATH" ]]; then
    build_cmd+=(--scratch-path "$SCRATCH_PATH")
  fi
  "${build_cmd[@]}" >>"$LOG_FILE" 2>&1
fi

run_suite() {
  local suite="$1"
  local suite_log
  suite_log="$(mktemp /tmp/speakflow-reg-suite-XXXXXX)"
  local test_cmd
  test_cmd=(
    env
    SPEAKFLOW_MUTE_SOUNDS=1
    SPEAKFLOW_ISOLATE_TEST_AUDIO=1
    SPEAKFLOW_OBSERVABILITY_PROFILE="$OBS_PROFILE"
    SPEAKFLOW_OBSERVABILITY_DIR="$OBS_DIR"
    swift
    test
    --filter
    "$suite"
  )
  if [[ "$SKIP_BUILD" == "1" ]]; then
    test_cmd+=(--skip-build)
  fi
  if [[ -n "$SCRATCH_PATH" ]]; then
    test_cmd+=(--scratch-path "$SCRATCH_PATH")
  fi

  printf "%-18s %s\n" "Suite............" "$suite"
  if ! "${test_cmd[@]}" >"$suite_log" 2>&1; then
    cat "$suite_log" >>"$LOG_FILE"
    echo "FAILED: $suite"
    echo "See log: $LOG_FILE"
    echo "--- begin test output ---"
    cat "$suite_log"
    echo "--- end test output ---"
    return 1
  fi

  cat "$suite_log" >>"$LOG_FILE"
  local count
  count="$(grep -Eo 'Test run with [0-9]+ tests?' "$suite_log" | tail -n1 | awk '{print $4}')"
  if [[ -z "$count" || "$count" == "0" ]]; then
    echo "FAILED: $suite matched 0 tests"
    echo "See log: $LOG_FILE"
    return 1
  fi
}

for suite in "${REGRESSION_SUITES[@]}"; do
  run_suite "$suite"
done

echo "Stress............. EnterSubmissionContractTests x$STRESS_RUNS"
for ((i = 1; i <= STRESS_RUNS; i++)); do
  stress_cmd=(
    env
    SPEAKFLOW_MUTE_SOUNDS=1
    SPEAKFLOW_ISOLATE_TEST_AUDIO=1
    SPEAKFLOW_OBSERVABILITY_PROFILE="$OBS_PROFILE"
    SPEAKFLOW_OBSERVABILITY_DIR="$OBS_DIR"
    swift
    test
    --filter
    EnterSubmissionContractTests
  )
  if [[ "$SKIP_BUILD" == "1" ]]; then
    stress_cmd+=(--skip-build)
  fi
  if [[ -n "$SCRATCH_PATH" ]]; then
    stress_cmd+=(--scratch-path "$SCRATCH_PATH")
  fi

  if ! "${stress_cmd[@]}" >>"$LOG_FILE" 2>&1; then
    echo "FAILED: EnterSubmissionContractTests stress run #$i"
    echo "See log: $LOG_FILE"
    exit 1
  fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Status: ALL OK"
echo "Log: $LOG_FILE"
echo ""
