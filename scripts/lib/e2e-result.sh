# shellcheck shell=bash
# Shared result checks for the live E2E wrapper scripts.
#
# The runner (SpeakFlowLiveE2E) prints machine-readable lines at column 0:
#   E2E_CHUNK index=<n> seconds=<s> speech=<pct>
#   E2E_AUTO_END seconds=<s>
#   E2E_TRANSCRIPT <text>
#   E2E_RESULT status=pass|fail assertions=<a,b,...> chunks=<n> auto_end_seconds=<s|none>
#
# A wrapper passes a case only when E2E_RESULT says pass AND every assertion
# the wrapper asked for actually executed, so a run that ignored the request
# (or skipped an assertion it could not run) cannot pass.

# e2e_check <output_file> <required assertion>...
e2e_check() {
    local output_file="$1"
    shift
    local line
    line="$(grep '^E2E_RESULT ' "$output_file" | tail -n 1 || true)"
    if [[ -z "$line" ]]; then
        echo "no E2E_RESULT line in output"
        return 1
    fi
    if [[ "$line" != *" status=pass "* ]]; then
        echo "$line"
        return 1
    fi
    local assertions
    assertions="$(sed -n 's/.* assertions=\([^ ]*\) .*/\1/p' <<<"$line")"
    local required
    for required in "$@"; do
        if [[ ",${assertions}," != *",${required},"* ]]; then
            echo "assertion '${required}' did not execute (${line})"
            return 1
        fi
    done
}

e2e_chunk_count() {
    grep -c '^E2E_CHUNK ' "$1" || true
}

e2e_auto_end_seconds() {
    sed -n 's/^E2E_AUTO_END seconds=//p' "$1" | tail -n 1
}

e2e_transcript() {
    sed -n 's/^E2E_TRANSCRIPT //p' "$1" | tail -n 1
}
