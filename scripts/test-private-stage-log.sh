#!/usr/bin/env bash
set -euo pipefail
if ((BASH_VERSINFO[0] < 5)); then exec bash "$0" "$@"; fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.agents/tests"
FIXTURE="$(mktemp -d "$ROOT_DIR/.agents/tests/private-stage-log.XXXXXX")"
source "$ROOT_DIR/scripts/lib/redact-diagnostics.sh"
export SPEAKFLOW_SIGNING_IDENTITY='synthetic-signing-value'
export SPEAKFLOW_TEAM_ID='synthetic-team-value'
export SPEAKFLOW_NOTARY_PROFILE='synthetic-notary-value'
printf '%s\n' "$SPEAKFLOW_SIGNING_IDENTITY" "$SPEAKFLOW_TEAM_ID" "$SPEAKFLOW_NOTARY_PROFILE" \
    '/Users/placeholder/build.swift: diagnostic' | redact_diagnostics > "$FIXTURE/secrets.log"
if grep -qE 'synthetic-(signing|team|notary)-value|/Users/' "$FIXTURE/secrets.log"; then
    echo 'FAIL: signing configuration or private paths reached the log'
    exit 1
fi
echo 'PASS: signing configuration and private paths redacted before persistence'

source "$ROOT_DIR/scripts/lib/private-stage-log.sh"
open_private_log "$FIXTURE/failure.log"
(printf '/home/placeholder/fixture.swift: diagnostic\nlast fragment'; exit 23) >&"$SPEAKFLOW_PRIVATE_LOG_FD" 2>&1 &
COMMAND_PID=$!
close_private_log_writer
set +e
wait "$COMMAND_PID"
COMMAND_STATUS=$?
finish_private_log "$COMMAND_STATUS"
STATUS=$?
set -e
[[ "$STATUS" == 23 ]]
grep -q '<HOME>/fixture.swift: diagnostic' "$FIXTURE/failure.log"
[[ "$(tail -c 13 "$FIXTURE/failure.log")" == 'last fragment' ]]
echo 'PASS: child failure and final unterminated output preserved'

mkdir "$FIXTURE/not-a-log"
open_private_log "$FIXTURE/not-a-log"
true >&"$SPEAKFLOW_PRIVATE_LOG_FD" 2>&1 &
COMMAND_PID=$!
close_private_log_writer
wait "$COMMAND_PID"
if finish_private_log 0; then echo 'FAIL: log-filter failure was hidden'; exit 1; fi
echo 'PASS: failed log persistence blocks a successful command'

open_private_log "$FIXTURE/terminated.log"
sleep 30 >&"$SPEAKFLOW_PRIVATE_LOG_FD" 2>&1 &
COMMAND_PID=$!
close_private_log_writer
kill -KILL "$COMMAND_PID"
set +e
wait "$COMMAND_PID" 2>/dev/null
COMMAND_STATUS=$?
finish_private_log "$COMMAND_STATUS"
STATUS=$?
set -e
[[ "$STATUS" == 137 ]]
if kill -0 "$COMMAND_PID" 2>/dev/null; then echo 'FAIL: terminated command remains live'; exit 1; fi
echo 'PASS: the original command handle and termination status are preserved'

open_private_log "$FIXTURE/held-stream.log"
sleep 30 >&"$SPEAKFLOW_PRIVATE_LOG_FD" 2>&1 &
HELD_PID=$!
close_private_log_writer
START=$SECONDS
set +e
finish_private_log 0
STATUS=$?
set -e
kill -TERM "$HELD_PID" 2>/dev/null || true
wait "$HELD_PID" 2>/dev/null || true
[[ "$STATUS" != 0 && $((SECONDS - START)) -lt 8 ]]
echo 'PASS: an inherited writer cannot hold log cleanup open indefinitely'
