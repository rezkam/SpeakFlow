#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.agents/tests"
FIXTURE="$(mktemp -d "$ROOT_DIR/.agents/tests/release-privacy.XXXXXX")"
printf 'portable fixture' > "$FIXTURE/binary"
bash "$ROOT_DIR/scripts/verify-artifact-privacy.sh" "$FIXTURE"
for path in '/Users/placeholder/build' '/home/placeholder/build' '/private/var/folders/fixture/build'; do
    printf '\0%s\0' "$path" > "$FIXTURE/binary"
    if bash "$ROOT_DIR/scripts/verify-artifact-privacy.sh" "$FIXTURE" >/dev/null 2>&1; then
        echo 'FAIL: private path accepted in binary artifact'
        exit 1
    fi
done
printf 'portable fixture' > "$FIXTURE/binary"
mkdir -p "$FIXTURE/Contents/Resources/Fixture.bundle"
printf '/Users/placeholder/build' > "$FIXTURE/Contents/Resources/Fixture.bundle/metadata"
if bash "$ROOT_DIR/scripts/verify-artifact-privacy.sh" "$FIXTURE" >/dev/null 2>&1; then
    echo 'FAIL: private path accepted in packaged resources'
    exit 1
fi
APP="$FIXTURE/Private.app"
mkdir -p "$APP/Contents/MacOS"
printf '/Users/placeholder/build' > "$APP/Contents/MacOS/SpeakFlow"
chmod +x "$APP/Contents/MacOS/SpeakFlow"
printf '<plist version="1.0"><dict/></plist>' > "$APP/Contents/Info.plist"
output="$(bash "$ROOT_DIR/scripts/verify-release-artifact.sh" --skip-notarization "$APP" 2>&1 || true)"
[[ "$output" == *'artifact contains a private filesystem path'* ]] || {
    echo 'FAIL: public artifact validator did not enforce private-path rejection'
    exit 1
}
mkdir -p "$FIXTURE/mockbin" "$FIXTURE/clean"
printf 'portable' > "$FIXTURE/clean/binary"
printf '#!/bin/sh\nexit 2\n' > "$FIXTURE/mockbin/grep"
chmod +x "$FIXTURE/mockbin/grep"
if PATH="$FIXTURE/mockbin:$PATH" bash "$ROOT_DIR/scripts/verify-artifact-privacy.sh" "$FIXTURE/clean" >/dev/null 2>&1; then
    echo 'FAIL: artifact scan errors must fail closed'
    exit 1
fi
ln -s /Users/placeholder/build "$FIXTURE/clean/resource-link"
if bash "$ROOT_DIR/scripts/verify-artifact-privacy.sh" "$FIXTURE/clean" >/dev/null 2>&1; then
    echo 'FAIL: private path accepted in a resource symlink'
    exit 1
fi
echo 'PASS: private binary and resource paths rejected without logging their contents'
