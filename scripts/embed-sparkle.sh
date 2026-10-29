#!/usr/bin/env bash
# Embed all updater helpers, preserve framework symlinks, and sign nested code first.
set -euo pipefail
PRODUCTS="$1"
APP="$2"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$PRODUCTS/Sparkle.framework" ]] || { echo 'Missing Sparkle build product' >&2; exit 1; }
[[ ! -e "$FRAMEWORK" ]] || { echo 'Sparkle destination already exists; use a fresh app bundle' >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$PRODUCTS/Sparkle.framework" "$FRAMEWORK"
SIGN_ARGS=(--force --sign "${SPEAKFLOW_SIGNING_IDENTITY:--}")
if [[ "${SPEAKFLOW_SIGNING_IDENTITY:--}" != '-' ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
# Sign from the inside out. Do not use --deep to create signatures.
for target in \
    "$FRAMEWORK/Versions/B/Autoupdate" \
    "$FRAMEWORK/Versions/B/Updater.app" \
    "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK"; do
    [[ -e "$target" ]] || { echo 'Missing updater helper' >&2; exit 1; }
    codesign "${SIGN_ARGS[@]}" "$target" 2>/dev/null || { echo 'Updater helper signing failed' >&2; exit 1; }
done
codesign --verify --deep --strict "$FRAMEWORK" 2>/dev/null
printf 'Updater framework and helper signatures verified.\n'
