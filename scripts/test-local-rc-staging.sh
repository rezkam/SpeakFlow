#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.agents/tests"
FIXTURE="$(mktemp -d "$ROOT_DIR/.agents/tests/local-rc.XXXXXX")"
mkdir -p "$FIXTURE/guards"
# Any accidental reuse of the install/publication flow fails immediately.
for command in osascript kill killall pkill rm open security gh xcrun hdiutil ditto sudo; do
    printf '#!/bin/sh\necho "FAIL: forbidden staging side effect" >&2\nexit 97\n' > "$FIXTURE/guards/$command"
    chmod +x "$FIXTURE/guards/$command"
done
# Reuse a genuinely built, private-path-free resource fixture.
source "$ROOT_DIR/scripts/lib/redact-diagnostics.sh"
bash "$ROOT_DIR/scripts/test-portable-release.sh" "$FIXTURE/portable" 2>&1 | redact_diagnostics > "$FIXTURE/portable.log"
BIN="$FIXTURE/portable/retired-build/release"
[[ -d "$BIN" ]]
stage() { PATH="$FIXTURE/guards:$PATH" bash "$ROOT_DIR/scripts/stage-local-rc.sh" "$@"; }
stage "$FIXTURE/stage" "$BIN"
APP="$FIXTURE/stage/SpeakFlow.app"
[[ -x "$APP/Contents/MacOS/SpeakFlow" ]]
/usr/bin/codesign --verify --deep --strict "$APP"
bash "$ROOT_DIR/scripts/verify-artifact-privacy.sh" "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" == 'nu.rez.speakflow.local-review' ]]
echo 'PASS: local artifact assembled and ad-hoc verified without install or publication'
for target in "$FIXTURE/stage" "$ROOT_DIR" "$ROOT_DIR/.agents/../outside-rc"; do
    if stage "$target" "$BIN" 2>&1 | redact_diagnostics > "$FIXTURE/refusal.log"; then echo 'FAIL: unsafe output accepted'; exit 1; fi
done
ln -s "$ROOT_DIR" "$FIXTURE/escape"
if stage "$FIXTURE/escape/stage" "$BIN" 2>&1 | redact_diagnostics > "$FIXTURE/refusal.log"; then echo 'FAIL: symlink escape accepted'; exit 1; fi
echo 'PASS: existing outputs, traversal and symlink escapes refused'
