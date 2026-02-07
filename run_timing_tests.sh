#!/usr/bin/env bash
set -uo pipefail

START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Starting test at $START_TS"

set +e
export SPEAKFLOW_E2E_TEST_AUTO_END=true
export SPEAKFLOW_E2E_AUTO_SPEAK_TEXT="Hello world, this is a short test of the voice activity detection system."
export SPEAKFLOW_E2E_TIMEOUT_SECONDS=15
# Use unlimited to isolate auto-end from max-duration logic
export SPEAKFLOW_E2E_CHUNK_DURATION=3600

swift run --disable-sandbox SpeakFlowLiveE2E > /tmp/e2e.out 2>&1
RC=$?
set -e

echo "E2E rc=$RC"
echo "Output:"
cat /tmp/e2e.out

echo ""
echo "---- LOGS ----"
# Show logs since start of test
log show --last 3m --style compact --info --debug \
  --predicate '((subsystem == "app.monodo.speakflow") OR (subsystem == "SpeakFlow")) && ((category == "audio") OR (category == "Session") OR (category == "VAD") OR (category == "app") OR (category == "transcription"))' \
  | egrep "🎤|🔇|⚡|🛑|VAD CONFIG DUMP|Auto-end triggered|stopRecording|hotkey|VADActive|state changed" || true
