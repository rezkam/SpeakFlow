#!/usr/bin/env bash
set -euo pipefail

unset -f git 2>/dev/null || true

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH" .build

PASS_COUNT=0
FAIL_COUNT=0

SHORT_TEXT="Hello world. This is a short speech test."
LONG_TEXT="This is a long continuous speech passage intended to run for many seconds without interruption so we can confirm that auto end does not trigger while speech is still active in the session."
PAUSE_TEXT_1="First part before a short pause. We are validating pause handling."
PAUSE_TEXT_2="Second part after the pause. Auto end should only trigger after this part finishes."
VERY_LONG_TEXT=""
# 12 sentences (~228 words). At 165 wpm this is ~80-90s of speech,
# leaving enough timeout headroom for trailing silence + auto-end detection.
for i in {1..12}; do
    VERY_LONG_TEXT+="This is sustained dictation sentence ${i} used to verify that no premature auto end happens during long continuous speech. "
done

run_case() {
    local name="$1"
    local timeout="$2"
    local min_expected="$3"
    local max_expected="$4"
    local rate="$5"
    local text1="$6"
    local text2="${7:-}"
    local gap_seconds="${8:-0}"

    local slug
    slug="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
    local output_file
    output_file="$(mktemp "/tmp/speakflow-autoend-${slug}.XXXX.log")"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: $name"
    echo "Expected auto-end window: ${min_expected}s-${max_expected}s"
    echo "Output: $output_file"

    set +e
    (
        export SPEAKFLOW_E2E_TEST_AUTO_END=true
        export SPEAKFLOW_E2E_CHUNK_DURATION=3600
        export SPEAKFLOW_E2E_TIMEOUT_SECONDS="$timeout"
        export SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS="$min_expected"
        export SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS="$max_expected"
        export SPEAKFLOW_E2E_AUTO_SPEAK_RATE="$rate"
        export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="$text1"

        if [[ -n "$text2" ]]; then
            export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT_PART2="$text2"
            export SPEAKFLOW_E2E_AUTO_SPEAK_GAP_SECONDS="$gap_seconds"
        else
            unset SPEAKFLOW_E2E_AUTO_SPEAK_TEXT_PART2
            unset SPEAKFLOW_E2E_AUTO_SPEAK_GAP_SECONDS
        fi

        swift run --disable-sandbox SpeakFlowLiveE2E
    ) >"$output_file" 2>&1
    local rc=$?
    set -e

    local elapsed
    elapsed="$(grep -Eo 'AUTO-END triggered after [0-9]+\.[0-9]+s' "$output_file" | tail -n 1 | awk '{print $4}' | sed 's/s$//' || true)"

    if [[ $rc -eq 0 ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "✅ PASS ($name)${elapsed:+ — auto-end=${elapsed}s}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "❌ FAIL ($name)"
        echo "Last output lines:"
        tail -n 30 "$output_file"
    fi
}

# 1) Short speech + silence (~2s speech + 5s silence)
run_case "Short speech + silence" 20 6 14 230 "$SHORT_TEXT"

# 2) Long speech + silence (~15s speech + 5s silence)
run_case "Long speech + silence" 45 16 35 170 "$LONG_TEXT"

# 3) Speech with short pause (no auto-end during ~2s pause)
run_case "Speech with 2s pause" 40 12 30 175 "$PAUSE_TEXT_1" "$PAUSE_TEXT_2" 2

# 4) Very long speech (60s+), no premature auto-end
run_case "Very long speech" 150 60 135 165 "$VERY_LONG_TEXT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Auto-end timing E2E summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
