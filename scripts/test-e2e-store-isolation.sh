#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
BINARY="${1:-.build/debug/SpeakFlowLiveE2E}"
[[ -x "$BINARY" ]] || { echo 'FAIL: missing SpeakFlowLiveE2E executable; pass its active build path'; exit 1; }
mkdir -p .agents/tests
fixture="$(mktemp -d "$ROOT_DIR/.agents/tests/store-isolation.XXXXXX")"
mkdir -p "$fixture/.speakflow"
printf 'synthetic fixture home\n' > "$fixture/fixture-home-marker"
for store in auth statistics session_metrics; do
    printf 'synthetic production sentinel: %s\n' "$store" > "$fixture/.speakflow/$store.json"
done
before="$(cksum "$fixture"/.speakflow/*.json)"
for mode in storage silence; do
    args=(--storage-isolation-probe)
    if [[ "$mode" == silence ]]; then args=(--authenticated-silence-probe --silence-only); fi
    rc=0
    output="$(env -u SPEAKFLOW_ISOLATED_STORAGE -u SPEAKFLOW_UI_TEST_MODE \
        -u SPEAKFLOW_RUN_LIVE_MISTRAL -u SPEAKFLOW_RUN_VAD_MODEL_TESTS \
        HOME="$fixture" CFFIXED_USER_HOME="$fixture" \
        SPEAKFLOW_OBSERVABILITY_DIR=/dev/null/speakflow-observability \
        "$BINARY" "${args[@]}" 2>&1)" || rc=$?
    [[ "$(cksum "$fixture"/.speakflow/*.json)" == "$before" ]] || {
        echo 'FAIL: production file sentinels changed'; exit 1;
    }
    if [[ "$rc" != 0 ]]; then
        case "$output" in
            *'FAIL: authenticated silence mode attempted a request'*)
                echo 'FAIL: authenticated silence mode attempted a request' ;;
            *'FAIL: authenticated silence audio assertions failed'*)
                printf '%s\n' "$output" | grep '^FAIL: authenticated silence audio assertions failed' ;;
            *'FAIL: configured silence audio assertions failed'*)
                echo 'FAIL: configured silence audio assertions failed' ;;
            *'FAIL: isolated file contents did not preserve mutations'*)
                echo 'FAIL: isolated file contents did not preserve mutations' ;;
            *'FAIL: synthetic authenticated state was not established'*)
                echo 'FAIL: synthetic authenticated state was not established' ;;
            'FAIL: defaults stores did not preserve production sentinels'|'FAIL: isolated store operation failed'|'FAIL: file stores did not write isolated artifacts')
                printf '%s\n' "$output" ;;
            *) echo "FAIL: actual executable $mode probe failed" ;;
        esac
        exit 1
    fi
    [[ "$output" == *'PASS: six persistent stores isolated and defaults sentinels preserved'* ]] || {
        echo 'FAIL: missing executable storage assertions'; exit 1;
    }
    if [[ "$mode" == silence ]]; then
        [[ "$output" == *'PASS: authenticated silence mode emitted audio without auth or transcription requests'* ]] || {
            echo 'FAIL: missing authenticated silence assertions'; exit 1;
        }
    fi
    echo "PASS: $mode executable preserves all six production-store sentinels while isolated stores mutate"
done
