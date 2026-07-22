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
VAD_INTEGRATION_EXPECTED=1

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
  "VADModelCacheTests"
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

vad_platform_is_available() {
  [[ "$(uname -m)" == "arm64" ]]
}

run_vad_model_prefetch() {
  if ! vad_platform_is_available; then
    VAD_INTEGRATION_EXPECTED=0
    echo "VAD model........ skipped (VAD requires arm64; current architecture: $(uname -m))"
    echo "VAD integration.. will be skipped (VAD is unavailable on this platform)"
    return 0
  fi

  local prefetch_log
  prefetch_log="$(mktemp /tmp/speakflow-vad-prefetch-XXXXXX)"
  local prefetch_cmd
  prefetch_cmd=(
    env
    SPEAKFLOW_MUTE_SOUNDS=1
    SPEAKFLOW_ISOLATE_TEST_AUDIO=1
    SPEAKFLOW_OBSERVABILITY_PROFILE="$OBS_PROFILE"
    SPEAKFLOW_OBSERVABILITY_DIR="$OBS_DIR"
    SPEAKFLOW_PREFETCH_VAD_MODEL=1
    SPEAKFLOW_VAD_MODEL_CACHE_ROOT=""
    swift
    test
    --filter
    VADModelPrefetchTests
  )
  if [[ "$SKIP_BUILD" == "1" ]]; then
    prefetch_cmd+=(--skip-build)
  fi
  if [[ -n "$SCRATCH_PATH" ]]; then
    prefetch_cmd+=(--scratch-path "$SCRATCH_PATH")
  fi

  echo "VAD model........ prefetch Silero dependency"
  if ! "${prefetch_cmd[@]}" >"$prefetch_log" 2>&1; then
    cat "$prefetch_log" >>"$LOG_FILE"
    echo "FAILED: could not provision the Silero model required by VADIntegrationTests"
    echo "See log: $LOG_FILE"
    cat "$prefetch_log"
    return 1
  fi

  cat "$prefetch_log" >>"$LOG_FILE"
  if grep -Eq 'Suite "VAD model prefetch" skipped\.' "$prefetch_log"; then
    VAD_INTEGRATION_EXPECTED=0
    echo "VAD model........ skipped (VAD is unavailable on this platform)"
    return 0
  fi
  if ! grep -Eq 'Test .* started\.' "$prefetch_log"; then
    echo "FAILED: VADModelPrefetchTests did not execute"
    echo "See log: $LOG_FILE"
    return 1
  fi
}

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "Build.............. swift build --build-tests"
  build_cmd=(swift build --build-tests)
  if [[ -n "$SCRATCH_PATH" ]]; then
    build_cmd+=(--scratch-path "$SCRATCH_PATH")
  fi
  "${build_cmd[@]}" >>"$LOG_FILE" 2>&1
fi

run_vad_model_prefetch

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
  )
  if [[ "$suite" == "VADIntegrationTests" || "$suite" == "VADModelCacheTests" ]]; then
    test_cmd+=(SPEAKFLOW_RUN_VAD_MODEL_TESTS=1)
  fi
  test_cmd+=(
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

  if [[ "$suite" == "VADIntegrationTests" ]]; then
    if [[ "$VAD_INTEGRATION_EXPECTED" == "0" ]]; then
      if ! grep -Eq 'Suite "VAD Integration .* skipped\.' "$suite_log"; then
        echo "FAILED: VADIntegrationTests should skip when VAD is unavailable"
        echo "See log: $LOG_FILE"
        return 1
      fi
      echo "VAD integration.. skipped (VAD is unavailable on this platform)"
    elif ! grep -Eq 'Test test.* started\.' "$suite_log"; then
      echo "FAILED: VADIntegrationTests did not execute after Silero prefetch"
      echo "See log: $LOG_FILE"
      return 1
    fi
  fi

  if [[ "$suite" == "VADModelCacheTests" ]]; then
    if [[ "$VAD_INTEGRATION_EXPECTED" == "0" ]]; then
      if ! grep -Eq 'Test testWarmUpIsIdempotent\(\) skipped\.' "$suite_log"; then
        echo "FAILED: VADModelCacheTests model-dependent tests should skip when VAD is unavailable"
        echo "See log: $LOG_FILE"
        return 1
      fi
      echo "VAD model cache... model-dependent tests skipped (VAD is unavailable on this platform)"
    elif ! grep -Eq 'Test testWarmUpIsIdempotent\(\) started\.' "$suite_log"; then
      echo "FAILED: VADModelCacheTests model-dependent tests did not execute after Silero prefetch"
      echo "See log: $LOG_FILE"
      return 1
    fi
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
