# shellcheck shell=bash
# Keep the command itself as $! so existing stage deadlines retain their target.
source "$(dirname "${BASH_SOURCE[0]}")/redact-diagnostics.sh"

open_private_log() {
    exec {SPEAKFLOW_PRIVATE_LOG_FD}> >(exec_redact_diagnostics > "$1")
    SPEAKFLOW_PRIVATE_LOG_FILTER_PID=$!
}

close_private_log_writer() {
    exec {SPEAKFLOW_PRIVATE_LOG_FD}>&-
}

finish_private_log() {
    local command_status="$1" filter_status=0 attempt
    for ((attempt = 0; attempt < 40; attempt++)); do
        if ! kill -0 "$SPEAKFLOW_PRIVATE_LOG_FILTER_PID" 2>/dev/null; then break; fi
        sleep 0.05
    done
    if kill -0 "$SPEAKFLOW_PRIVATE_LOG_FILTER_PID" 2>/dev/null; then
        kill -TERM "$SPEAKFLOW_PRIVATE_LOG_FILTER_PID" 2>/dev/null || true
        sleep 0.05
        kill -KILL "$SPEAKFLOW_PRIVATE_LOG_FILTER_PID" 2>/dev/null || true
        wait "$SPEAKFLOW_PRIVATE_LOG_FILTER_PID" 2>/dev/null || true
        echo 'Diagnostic stream did not close; stage log is incomplete.' >&2
        filter_status=74
    else
        wait "$SPEAKFLOW_PRIVATE_LOG_FILTER_PID" || filter_status=$?
    fi
    if [[ "$command_status" != 0 ]]; then return "$command_status"; fi
    return "$filter_status"
}
