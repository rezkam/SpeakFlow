#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${1:?pass the active SpeakFlowLiveE2E executable}"
mkdir -p "$ROOT_DIR/.agents/tests"
FIXTURE="$(mktemp -d "$ROOT_DIR/.agents/tests/auth-bootstrap.XXXXXX")"
mkdir -p "$FIXTURE/home/.speakflow"
printf '{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","accountId":"fixture-account","lastRefresh":0}' > "$FIXTURE/credentials.json"
printf '{"chatgpt":{"tokens":{"access_token":"synthetic-installed-access","refresh_token":"synthetic-installed-refresh","account_id":"fixture-installed-account"},"last_refresh":"2001-01-01T00:00:00.000Z"}}' > "$FIXTURE/installed-sentinel.json"
cp "$FIXTURE/installed-sentinel.json" "$FIXTURE/home/.speakflow/auth.json"
probe() { HOME="$FIXTURE/home" SPEAKFLOW_E2E_AUTH_FILE= "$BINARY" --auth-bootstrap-probe "$@"; }
output="$(probe)"
[[ "$output" == *'AUTH_BOOTSTRAP logged_in=false requests=0'* ]]
echo 'PASS: installed credentials are never implicitly imported'
output="$(probe --auth-file "$FIXTURE/credentials.json")"
[[ "$output" == *'AUTH_BOOTSTRAP logged_in=true requests=0'* ]]
echo 'PASS: explicit file bootstraps isolated authentication without network'
output="$(HOME="$FIXTURE/home" SPEAKFLOW_E2E_AUTH_FILE="$FIXTURE/credentials.json" "$BINARY" --auth-bootstrap-probe)"
[[ "$output" == *'AUTH_BOOTSTRAP logged_in=true requests=0'* ]]
echo 'PASS: wrappers can explicitly select an isolated authentication file'
for args in missing invalid silence duplicate; do
    case "$args" in
        missing) params=(--auth-file) ;;
        invalid) params=(--auth-file "$FIXTURE/absent") ;;
        silence) params=(--silence-only --auth-file "$FIXTURE/credentials.json") ;;
        duplicate) params=(--auth-file "$FIXTURE/credentials.json" --auth-file "$FIXTURE/credentials.json") ;;
    esac
    if output="$(probe "${params[@]}" 2>&1)"; then echo 'FAIL: invalid bootstrap accepted'; exit 1; fi
    [[ "$output" == *'Authentication bootstrap refused'* && "$output" != *'synthetic-access'* && "$output" != *"$FIXTURE"* ]]
done
cmp "$FIXTURE/installed-sentinel.json" "$FIXTURE/home/.speakflow/auth.json"
echo 'PASS: invalid bootstrap fails closed with sanitized errors and installed sentinel unchanged'
