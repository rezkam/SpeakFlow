#!/usr/bin/env bash
set -u

unset -f git 2>/dev/null || true

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH" .build

LOG_FILE="${SPEAKFLOW_TEST_LOG_FILE:-$(mktemp /tmp/speakflow-test-XXXXXX).log}"
if [ "${SPEAKFLOW_TEST_LOG_APPEND:-0}" = "1" ]; then
    touch "$LOG_FILE"
else
    : > "$LOG_FILE"
fi

FAILED=0
FAILED_STEPS=()

run_step() {
    local label="$1"
    shift

    printf "%-18s " "$label"
    if "$@" >>"$LOG_FILE" 2>&1; then
        echo "OK"
    else
        echo "ERROR"
        FAILED=1
        FAILED_STEPS+=("$label")
    fi
}

if [ "${SPEAKFLOW_TEST_PRINT_HEADER:-1}" = "1" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  SpeakFlow Test"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

run_step "Core tests......." swift run SpeakFlowTestRunner
run_step "Swift tests......" swift test
run_step "UI E2E tests...." ./scripts/run-ui-tests.sh

if [ "${SPEAKFLOW_TEST_PRINT_HEADER:-1}" = "1" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "Status: ALL OK"
else
    echo "Status: FAILED (${FAILED_STEPS[*]})"
fi
echo "Log: $LOG_FILE"
echo ""

exit "$FAILED"
