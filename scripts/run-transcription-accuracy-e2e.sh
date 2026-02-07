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

# ────────────────────────────────────────────────────
# Transcription Accuracy E2E Suite
#
# Tests that transcription results contain the expected
# words/phrases for short, long, and multi-chunk speech.
#
# Uses the SPEAKFLOW_E2E_EXPECT_PHRASE env var to check
# that the transcript loosely matches expected output
# (50%+ word overlap required).
# ────────────────────────────────────────────────────

run_case() {
    local name="$1"
    local speak_text="$2"
    local expect_phrase="$3"
    local record_seconds="$4"
    local timeout="$5"
    local chunk_duration="${6:-3600}"  # Default unlimited
    local speak_rate="${7:-170}"
    local test_auto_end="${8:-false}"

    local slug
    slug="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
    local output_file
    output_file="$(mktemp "/tmp/speakflow-accuracy-${slug}.XXXX.log")"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: $name"
    echo "Expected phrase: \"${expect_phrase}\""
    echo "Output: $output_file"

    set +e
    (
        export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="$speak_text"
        export SPEAKFLOW_E2E_EXPECT_PHRASE="$expect_phrase"
        export SPEAKFLOW_E2E_AUTO_SPEAK_RATE="$speak_rate"
        export SPEAKFLOW_E2E_CHUNK_DURATION="$chunk_duration"
        export SPEAKFLOW_E2E_TIMEOUT_SECONDS="$timeout"

        if [[ "$test_auto_end" == "true" ]]; then
            export SPEAKFLOW_E2E_TEST_AUTO_END=true
            export SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS=3
            export SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS="$timeout"
        else
            export SPEAKFLOW_E2E_RECORD_SECONDS="$record_seconds"
        fi

        swift run --disable-sandbox SpeakFlowLiveE2E
    ) >"$output_file" 2>&1
    local rc=$?
    set -e

    # Extract transcript from output
    local transcript
    transcript="$(grep '^Transcript:' "$output_file" | head -1 | sed 's/^Transcript: //' || true)"

    # Count chunks
    local chunk_count
    chunk_count="$(grep -c '^chunk #' "$output_file" || echo 0)"

    if [[ $rc -eq 0 ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "✅ PASS ($name) — ${chunk_count} chunk(s)"
        if [[ -n "$transcript" ]]; then
            # Truncate long transcripts for display
            if [[ ${#transcript} -gt 80 ]]; then
                echo "   Transcript: ${transcript:0:80}..."
            else
                echo "   Transcript: $transcript"
            fi
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "❌ FAIL ($name)"
        echo "Last output lines:"
        tail -n 20 "$output_file"
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SpeakFlow Transcription Accuracy E2E"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1) Short phrase: "Hello world" → verify transcript contains words
SHORT_TEXT="Hello world, this is a test of the speech recognition system."
run_case \
    "Short phrase transcription" \
    "$SHORT_TEXT" \
    "hello world speech recognition" \
    8 \
    30 \
    3600 \
    180

# 2) Long paragraph: ~30s speech → verify coherent transcript
LONG_TEXT="The quick brown fox jumps over the lazy dog. This sentence contains every letter of the alphabet and has been used for decades as a typing exercise. In addition to being a useful test, it also demonstrates how well a transcription system handles common English words and phrases in a natural flowing sentence structure."
run_case \
    "Long paragraph transcription" \
    "$LONG_TEXT" \
    "quick brown fox jumps lazy dog alphabet" \
    35 \
    45 \
    3600 \
    165 \
    true

# 3) Multi-chunk: 15s chunks + 35s speech → verify all chunks transcribed
MULTI_CHUNK_TEXT="This is the first part of a multi chunk transcription test. We are speaking continuously so that the audio is split into multiple fifteen second chunks. Each chunk should be transcribed separately and the results combined into one complete transcript covering all the words we have spoken."
run_case \
    "Multi-chunk transcription (15s chunks)" \
    "$MULTI_CHUNK_TEXT" \
    "multi chunk transcription test speaking continuously fifteen second" \
    40 \
    60 \
    15 \
    165 \
    true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Transcription accuracy E2E summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
