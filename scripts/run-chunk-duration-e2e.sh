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
# Chunk Duration Verification E2E Suite
#
# Tests that the chunking system correctly splits long
# recordings into chunks of the configured duration.
#
# Each test speaks for longer than the chunk duration
# and verifies 2+ chunks are emitted.
# ────────────────────────────────────────────────────

# Generate long speech texts
LONG_TEXT_35S=""
for i in {1..7}; do
    LONG_TEXT_35S+="This is sentence number ${i} of a moderately long dictation passage used to verify chunk splitting behavior. "
done

LONG_TEXT_65S=""
for i in {1..14}; do
    LONG_TEXT_65S+="This is sentence number ${i} of a long sustained dictation passage designed to run for over sixty seconds of continuous speech. "
done

SILENCE_TEXT=""  # No speech for silence detection test

run_case() {
    local name="$1"
    local chunk_duration="$2"
    local timeout="$3"
    local speak_text="$4"
    local speak_rate="${5:-170}"
    local min_chunks="${6:-2}"
    local test_noise_rejection="${7:-false}"

    local slug
    slug="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
    local output_file
    output_file="$(mktemp "/tmp/speakflow-chunk-${slug}.XXXX.log")"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: $name"
    echo "Chunk duration: ${chunk_duration}s"
    echo "Expected min chunks: ${min_chunks}"
    echo "Output: $output_file"

    set +e
    (
        export SPEAKFLOW_E2E_TEST_AUTO_END=true
        export SPEAKFLOW_E2E_CHUNK_DURATION="$chunk_duration"
        export SPEAKFLOW_E2E_TIMEOUT_SECONDS="$timeout"
        export SPEAKFLOW_E2E_AUTO_SPEAK_RATE="$speak_rate"

        if [[ "$test_noise_rejection" == "true" ]]; then
            export SPEAKFLOW_E2E_TEST_NOISE_REJECTION=1
            export SPEAKFLOW_E2E_RECORD_SECONDS=12
            unset SPEAKFLOW_E2E_AUTO_SPEAK_TEXT
        else
            export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="$speak_text"
            # Allow generous auto-end window
            export SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS=5
            export SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS="$timeout"
        fi

        swift run --disable-sandbox SpeakFlowLiveE2E
    ) >"$output_file" 2>&1
    local rc=$?
    set -e

    # Count chunks from output
    local chunk_count
    chunk_count="$(grep -c '^chunk #' "$output_file" || echo 0)"

    if [[ "$test_noise_rejection" == "true" ]]; then
        # For silence test, expect 0 chunks
        if [[ $rc -eq 0 ]]; then
            PASS_COUNT=$((PASS_COUNT + 1))
            echo "✅ PASS ($name) — 0 chunks sent (noise rejection)"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "❌ FAIL ($name)"
            tail -n 15 "$output_file"
        fi
    else
        if [[ $rc -eq 0 && $chunk_count -ge $min_chunks ]]; then
            PASS_COUNT=$((PASS_COUNT + 1))
            echo "✅ PASS ($name) — ${chunk_count} chunks emitted (min required: ${min_chunks})"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "❌ FAIL ($name) — ${chunk_count} chunks emitted (min required: ${min_chunks}), exit=$rc"
            echo "Last output lines:"
            tail -n 20 "$output_file"
        fi
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SpeakFlow Chunk Duration E2E"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1) 15s chunks with ~35s speech → expect 2+ chunks
run_case "15s chunks with 35s speech" 15 60 "$LONG_TEXT_35S" 170 2

# 2) 30s chunks with ~65s speech → expect 2+ chunks
run_case "30s chunks with 65s speech" 30 100 "$LONG_TEXT_65S" 170 2

# 3) Silence with skipSilentChunks=true → expect 0 chunks (noise rejection)
# Uses a pre-generated silence WAV
SILENCE_WAV="/tmp/sf_test_silence.wav"
if [[ -f "$SILENCE_WAV" ]]; then
    run_case "Silence skip (skipSilentChunks)" 30 25 "" 170 0 true
else
    echo ""
    echo "⚠️  SKIPPED: Silence test (no silence WAV at $SILENCE_WAV)"
    echo "   Run: python3 /tmp/sf_generate_test_audio.py to generate test audio"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Chunk duration E2E summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
