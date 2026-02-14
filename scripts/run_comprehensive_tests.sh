#!/usr/bin/env bash
set -uo pipefail

START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Starting COMPREHENSIVE tests at $START_TS"

# Clean previous logs
echo "" > /tmp/speakflow_logs.txt

# Start log capture in background
log stream --style compact --info --debug \
  --predicate '((subsystem == "app.monodo.speakflow") OR (subsystem == "SpeakFlow")) && ((category == "audio") OR (category == "Session") OR (category == "VAD") OR (category == "app") OR (category == "transcription"))' \
  >> /tmp/speakflow_logs.txt &
LOG_PID=$!

function cleanup {
    echo "Stopping log capture (PID $LOG_PID)..."
    kill $LOG_PID 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------
# TEST 1: Short Speech (Baseline)
# ------------------------------------------------------------------
echo "RUNNING TEST 1: Short Speech (Baseline)"
echo "Expect: Auto-end after ~5s silence"
export SPEAKFLOW_E2E_TEST_AUTO_END=true
export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="Hello world, this is a short test."
export SPEAKFLOW_E2E_TIMEOUT_SECONDS=15
export SPEAKFLOW_E2E_CHUNK_DURATION=3600

swift run --disable-sandbox SpeakFlowLiveE2E > /tmp/test1.out 2>&1 || echo "Test 1 failed (expected?)"

# ------------------------------------------------------------------
# TEST 2: Long Continuous Speech
# ------------------------------------------------------------------
echo "RUNNING TEST 2: Long Continuous Speech"
echo "Expect: NO auto-end during 15s of speech"
export SPEAKFLOW_E2E_TEST_AUTO_END=true
# ~15 seconds of speech
export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="This is a much longer test passage designed to last approximately fifteen seconds or more. I am speaking continuously to ensure that the voice activity detection does not trigger a premature end of session while the user is still actively dictating their thoughts."
export SPEAKFLOW_E2E_TIMEOUT_SECONDS=30

swift run --disable-sandbox SpeakFlowLiveE2E > /tmp/test2.out 2>&1 || echo "Test 2 failed"

# ------------------------------------------------------------------
# ANALYSIS
# ------------------------------------------------------------------
echo ""
echo "==== LOG ANALYSIS ===="
grep -E "🎤|🔇|⚡|🛑|VAD CONFIG DUMP|Auto-end triggered" /tmp/speakflow_logs.txt | grep -v "Filtering"

