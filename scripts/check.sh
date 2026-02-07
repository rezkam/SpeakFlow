#!/usr/bin/env bash
set -u

unset -f git 2>/dev/null || true

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Optional module-cache overrides — skip in sandboxed environments
if mkdir -p "$ROOT_DIR/.build" 2>/dev/null; then
    export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"
    export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
    mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH" 2>/dev/null || true
fi

LOG_FILE="${SPEAKFLOW_CHECK_LOG_FILE:-$(mktemp /tmp/speakflow-check-XXXXXX).log}"
: > "$LOG_FILE"

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

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SpeakFlow Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_step "Build............" swift build
run_step "Core tests......." swift run SpeakFlowTestRunner
run_step "Swift tests......" swift test
run_step "UI E2E tests...." ./scripts/run-ui-tests.sh

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAILED" -eq 0 ]; then
    echo "Status: ALL OK"
else
    echo "Status: FAILED (${FAILED_STEPS[*]})"
fi
echo "Log: $LOG_FILE"
echo ""

exit "$FAILED"
