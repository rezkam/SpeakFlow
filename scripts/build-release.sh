#!/bin/bash
# =============================================================================
# SpeakFlow Release Script
# =============================================================================
#
# USAGE
#   ./scripts/build-release.sh rc               — build, sign, install a local RC for testing
#   ./scripts/build-release.sh local            — build, sign, validate, and install a production-version app locally
#   ./scripts/build-release.sh release          — build, sign, notarize, publish to GitHub
#   ./scripts/build-release.sh release --yes    — same, skip all confirmations (non-interactive)
#   ./scripts/build-release.sh release -y       — shorthand for --yes
#
# REQUIRED ENVIRONMENT VARIABLES (never hardcoded here)
#   SPEAKFLOW_BUNDLE_ID          e.g. com.example.speakflow
#   SPEAKFLOW_SIGNING_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#   SPEAKFLOW_TEAM_ID            e.g. ABCDE12345
#   SPEAKFLOW_NOTARY_PROFILE     name of keychain notarytool profile (release only)
#   SPEAKFLOW_CONFIRMED_LOCAL_RC_TESTED_SHA
#                                exact HEAD SHA that the user tested as an RC (release only)
#
# Add to ~/.bash_profile so every bash login shell sees them:
#   export SPEAKFLOW_BUNDLE_ID="..."
#   export SPEAKFLOW_SIGNING_IDENTITY="..."
#   export SPEAKFLOW_TEAM_ID="..."
#   export SPEAKFLOW_NOTARY_PROFILE="..."
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials "$SPEAKFLOW_NOTARY_PROFILE" \
#     --apple-id YOUR_APPLE_ID \
#     --team-id "$SPEAKFLOW_TEAM_ID" \
#     --password APP_SPECIFIC_PASSWORD
# =============================================================================
set -eo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
fail() { printf "  ${RED}✗${RESET} %s\n" "$*"; exit 1; }
info() { printf "  ${DIM}%s${RESET}\n" "$*"; }
step() { printf "\n${BOLD}▸ %s${RESET}\n" "$*"; }
warn() { printf "  ${YELLOW}⚠${RESET}  %s\n" "$*"; }

install_and_verify() {
    # Install the just-built, just-signed app to /Applications and verify it.
    # Called from local-install and release paths.
    step "Installing to /Applications"

    if pgrep -x "$APP_NAME" &>/dev/null; then
        info "Quitting running $APP_NAME..."
        osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
        sleep 1
        if pgrep -x "$APP_NAME" &>/dev/null; then
            killall -9 "$APP_NAME" 2>/dev/null || true
            sleep 1
        fi
    fi

    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP_NAME.app" "/Applications/$APP_NAME.app"
    touch "/Applications/$APP_NAME.app"

    INSTALLED_BINARY="/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"
    INSTALLED_SHA256=$(shasum -a 256 "$INSTALLED_BINARY" | awk '{print $1}')

    if [ "$INSTALLED_SHA256" = "$BINARY_SHA256" ]; then
        ok "Installed binary hash matches build"
        info "SHA-256: $INSTALLED_SHA256"
    else
        fail "Hash mismatch — installed binary does not match build output
       Built:     $BINARY_SHA256
       Installed: $INSTALLED_SHA256"
    fi

    codesign --verify --deep --strict "/Applications/$APP_NAME.app" 2>&1 \
        | sed 's/^/  /' || fail "Installed app signature invalid"
    ok "Installed app signature valid"

    VERIFY_NOTARY_FLAG="--require-notarization"
    if [[ "$MODE" != "release" ]]; then
        VERIFY_NOTARY_FLAG="--skip-notarization"
    fi
    ./scripts/verify-release-artifact.sh \
        "$VERIFY_NOTARY_FLAG" \
        --expected-version "$MARKETING_VERSION" \
        --expected-display-version "$DISPLAY_VERSION" \
        --expected-bundle-id "$BUNDLE_ID" \
        --expected-team-id "$SPEAKFLOW_TEAM_ID" \
        "/Applications/$APP_NAME.app" 2>&1 | sed 's/^/  /' \
        || fail "Installed app artifact validation failed"
    ok "Installed app artifact validation passed"

    INSTALLED_VERSION=$(defaults read \
        "/Applications/$APP_NAME.app/Contents/Info" \
        CFBundleShortVersionString 2>/dev/null || echo "unknown")
    if [ "$INSTALLED_VERSION" = "$MARKETING_VERSION" ]; then
        ok "Version string correct: $INSTALLED_VERSION"
    else
        fail "Version mismatch — expected $MARKETING_VERSION, got $INSTALLED_VERSION"
    fi

    step "Launch smoke test"
    SMOKE_LOG="$(mktemp /tmp/speakflow-launch-smoke-XXXXXX.log)"
    "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" >"$SMOKE_LOG" 2>&1 &
    SMOKE_PID=$!
    sleep 2

    if kill -0 "$SMOKE_PID" 2>/dev/null; then
        ok "Installed app process starts successfully"
        kill -TERM "$SMOKE_PID" 2>/dev/null || true
        wait "$SMOKE_PID" 2>/dev/null || true
    else
        warn "Launch smoke-test log:"
        tail -n 60 "$SMOKE_LOG" | sed 's/^/  /'
        fail "Installed app exited during launch smoke test"
    fi
}

banner() {
    local title="$1" subtitle="$2"
    printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    printf "${BOLD}  %s${RESET}\n" "$title"
    [ -n "$subtitle" ] && printf "${DIM}  %s${RESET}\n" "$subtitle"
    printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

confirm() {
    # confirm <prompt>  — skipped silently when YES=1, otherwise prompts y/N
    local prompt="$1"
    if [[ "${YES:-0}" == "1" ]]; then
        printf "\n${DIM}  ? %s [auto-yes]${RESET}\n" "$prompt"
        return 0
    fi
    printf "\n${YELLOW}  ? %s [y/N]${RESET} " "$prompt"
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        printf "${RED}  Aborted.${RESET}\n\n"
        exit 1
    fi
}

notarize_file() {
    # notarize_file <artifact-path> <label>
    local artifact_path="$1"
    local label="$2"

    NOTARIZE_LOG="$(mktemp)"
    set +e
    xcrun notarytool submit "$artifact_path" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$NOTARIZE_LOG" | sed 's/^/  /'
    NOTARIZE_STATUS=${PIPESTATUS[0]}
    set -e

    if [ "$NOTARIZE_STATUS" -eq 0 ] && grep -q "status: Accepted" "$NOTARIZE_LOG"; then
        ok "$label notarization accepted by Apple"
    else
        SUBMISSION_ID=$(grep -E "^[[:space:]]*id:" "$NOTARIZE_LOG" | head -1 | awk '{print $2}')
        [ -n "$SUBMISSION_ID" ] && \
            xcrun notarytool log "$SUBMISSION_ID" \
                --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/  /'
        rm -f "$NOTARIZE_LOG"
        fail "$label notarization rejected, see log above"
    fi
    rm -f "$NOTARIZE_LOG"
}

# ── Mode & flags ──────────────────────────────────────────────────────────────
MODE="${1:-}"
YES=0
for arg in "$@"; do
    [[ "$arg" == "--yes" || "$arg" == "-y" ]] && YES=1
done

if [[ "$MODE" != "rc" && "$MODE" != "local" && "$MODE" != "release" ]]; then
    printf "${RED}Usage: %s rc | local | release [--yes|-y]${RESET}\n" "$(basename "$0")" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="SpeakFlow"
cd "$PROJECT_DIR"

# ── Required env vars ─────────────────────────────────────────────────────────
# Die immediately with a clear message if any are missing.
# Values are NEVER printed — only their presence is checked.
: "${SPEAKFLOW_BUNDLE_ID:?SPEAKFLOW_BUNDLE_ID is not set — see script header}"
: "${SPEAKFLOW_SIGNING_IDENTITY:?SPEAKFLOW_SIGNING_IDENTITY is not set — see script header}"
: "${SPEAKFLOW_TEAM_ID:?SPEAKFLOW_TEAM_ID is not set — see script header}"
if [[ "$MODE" == "release" ]]; then
    : "${SPEAKFLOW_NOTARY_PROFILE:?SPEAKFLOW_NOTARY_PROFILE is not set — see script header}"
fi

BUNDLE_ID="$SPEAKFLOW_BUNDLE_ID"
SIGNING_IDENTITY="$SPEAKFLOW_SIGNING_IDENTITY"
NOTARY_PROFILE="${SPEAKFLOW_NOTARY_PROFILE:-}"

# ── Version ───────────────────────────────────────────────────────────────────
# Version comes from the release notes, not from tags. This prevents orphan tags
# from becoming the source of truth. A GitHub release will create the tag when it
# does not already exist.
CHANGELOG_VERSION=$(awk '/^## [0-9]+\.[0-9]+\.[0-9]+( |$)/ { print $2; exit }' CHANGELOG.md 2>/dev/null || true)
BASE_VERSION="${SPEAKFLOW_RELEASE_VERSION:-$CHANGELOG_VERSION}"

if [[ -z "$BASE_VERSION" ]]; then
    LATEST_TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]' | head -1 2>/dev/null || true)
    BASE_VERSION="${LATEST_TAG#v}"
fi

BASE_VERSION="${BASE_VERSION:-0.0.0}"
if [[ ! "$BASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "Invalid release version '$BASE_VERSION'. Use SPEAKFLOW_RELEASE_VERSION=X.Y.Z or add a top CHANGELOG.md section."
fi

if [[ "$MODE" == "rc" ]]; then
    RC_TIMESTAMP=$(date +%Y%m%d%H%M)
    DISPLAY_VERSION="${BASE_VERSION}-rc.${RC_TIMESTAMP}"
    MARKETING_VERSION="$BASE_VERSION"
    BUNDLE_VERSION="$RC_TIMESTAMP"
else
    DISPLAY_VERSION="$BASE_VERSION"
    MARKETING_VERSION="$BASE_VERSION"
    BUNDLE_VERSION="$BASE_VERSION"
fi

BUILD_GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || printf 'unknown')
BUILD_GIT_DESCRIBE=$(git describe --tags --always --dirty 2>/dev/null || printf '%s' "$BUILD_GIT_COMMIT")

# ── Header ────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "rc" ]]; then
    banner "🔨 SpeakFlow $DISPLAY_VERSION — Release Candidate" \
           "Local install only · nothing pushed · nothing uploaded"
elif [[ "$MODE" == "local" ]]; then
    banner "🔨 SpeakFlow $DISPLAY_VERSION — Local Production Build" \
           "Signed · Installed locally · nothing pushed, uploaded, or notarized"
else
    banner "🚀 SpeakFlow $DISPLAY_VERSION — Production Release" \
           "Signed · Notarized · Published to GitHub"
fi

# =============================================================================
# STAGE 1 — Preflight checks
# =============================================================================
step "Preflight checks"

# 1a. Signing identity exists in keychain
if security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
    ok "Signing identity found"
else
    fail "Signing identity not found in keychain: $SIGNING_IDENTITY"
fi

# 1b. create-dmg available
if ! command -v create-dmg &>/dev/null; then
    info "Installing create-dmg..."
    brew install create-dmg &>/dev/null || fail "Could not install create-dmg"
fi
ok "create-dmg available"

# 1c. gh CLI (release only)
if [[ "$MODE" == "release" ]]; then
    if ! command -v gh &>/dev/null; then
        fail "gh CLI not found — install with: brew install gh"
    fi
    if ! gh auth status &>/dev/null 2>&1; then
        fail "gh not authenticated — run: gh auth login"
    fi
    ok "GitHub CLI authenticated"

    # 1d. Notary profile + service access
    set +e
    NOTARY_CHECK_OUTPUT="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"
    NOTARY_CHECK_STATUS=$?
    set -e
    if [ "$NOTARY_CHECK_STATUS" -ne 0 ]; then
        if printf '%s' "$NOTARY_CHECK_OUTPUT" | grep -qiE "(not found in the keychain|No Keychain password item found|keychain profile.*not found|The specified item could not be found in the keychain)"; then
            fail "Notary profile '$NOTARY_PROFILE' not found in keychain"
        elif printf '%s' "$NOTARY_CHECK_OUTPUT" | grep -qi "required agreement is missing or has expired"; then
            printf '%s\n' "$NOTARY_CHECK_OUTPUT" | sed 's/^/  /'
            fail "Apple notary service rejected profile '$NOTARY_PROFILE' because a required Apple Developer agreement is missing or expired. Sign in to developer.apple.com / App Store Connect, accept the pending agreement for team $SPEAKFLOW_TEAM_ID, then rerun release."
        else
            printf '%s\n' "$NOTARY_CHECK_OUTPUT" | sed 's/^/  /'
            fail "Could not validate notary profile '$NOTARY_PROFILE' against Apple's notary service"
        fi
    fi
    ok "Notary profile found and Apple notary access works"

    # 1e. Clean git working tree. Release artifacts must match an immutable
    # GitHub commit, not local uncommitted changes.
    if [ -n "$(git status --porcelain)" ]; then
        git status --short | sed 's/^/  /'
        fail "Working directory has uncommitted changes. Commit and push before release."
    else
        ok "Git working tree clean"
    fi

    RELEASE_HEAD_SHA=$(git rev-parse HEAD)
    if gh api "repos/{owner}/{repo}/git/commits/$RELEASE_HEAD_SHA" --silent &>/dev/null 2>&1; then
        ok "HEAD exists on GitHub: $RELEASE_HEAD_SHA"
    else
        fail "HEAD $RELEASE_HEAD_SHA is not present on GitHub. Push main before release."
    fi

    if [ "${SPEAKFLOW_CONFIRMED_LOCAL_RC_TESTED_SHA:-}" != "$RELEASE_HEAD_SHA" ]; then
        fail "Final release requires user-tested local RC from this exact commit. Build an RC from clean HEAD, have the user test it, then rerun with SPEAKFLOW_CONFIRMED_LOCAL_RC_TESTED_SHA=$RELEASE_HEAD_SHA."
    fi
    ok "User-tested local RC confirmed for HEAD"

    # 1f. Release/tag safety.
    # The release is the source of truth. If the tag is absent, gh release create
    # will create it at HEAD. If it already exists, it must point at HEAD.
    RELEASE_TAG="v${DISPLAY_VERSION}"

    if gh release view "$RELEASE_TAG" &>/dev/null 2>&1; then
        fail "GitHub release $RELEASE_TAG already exists. Bump CHANGELOG.md or SPEAKFLOW_RELEASE_VERSION."
    fi
    ok "GitHub release $RELEASE_TAG does not exist yet"

    if TAG_TYPE=$(gh api "repos/{owner}/{repo}/git/refs/tags/$RELEASE_TAG" --jq '.object.type' 2>/dev/null); then
        TAG_SHA=$(gh api "repos/{owner}/{repo}/git/refs/tags/$RELEASE_TAG" --jq '.object.sha')
        if [ "$TAG_TYPE" = "tag" ]; then
            TAG_COMMIT_SHA=$(gh api "repos/{owner}/{repo}/git/tags/$TAG_SHA" --jq '.object.sha')
        else
            TAG_COMMIT_SHA="$TAG_SHA"
        fi

        if [ "$TAG_COMMIT_SHA" != "$RELEASE_HEAD_SHA" ]; then
            fail "Tag $RELEASE_TAG already exists but points at $TAG_COMMIT_SHA, not HEAD $RELEASE_HEAD_SHA. Bump the version instead of reusing the tag."
        fi
        ok "Existing tag $RELEASE_TAG points at HEAD"
    else
        ok "Tag $RELEASE_TAG does not exist yet, GitHub release creation will create it"
    fi
fi

# =============================================================================
# STAGE 2 — Tests
# =============================================================================
step "Running test suite"
TEST_LOG="$(mktemp /tmp/speakflow-release-tests-XXXXXX.log)"
TEST_TIMEOUT_SECONDS="${SPEAKFLOW_RC_TEST_TIMEOUT_SECONDS:-900}"
SCRATCH_PATH="${SPEAKFLOW_SWIFT_SCRATCH_PATH:-/tmp/speakflow-rc-build}"
OBS_PROFILE="${SPEAKFLOW_OBSERVABILITY_PROFILE:-rc-tests-$(date +%Y%m%d%H%M%S)-$$}"
OBS_DIR="${SPEAKFLOW_OBSERVABILITY_DIR:-/tmp/speakflow-observability-tests/$OBS_PROFILE}"
mkdir -p "$OBS_DIR"

info "Test log: $TEST_LOG"
info "Timeout: ${TEST_TIMEOUT_SECONDS}s (override with SPEAKFLOW_RC_TEST_TIMEOUT_SECONDS)"
info "Observability: $OBS_DIR"
if [[ -n "$SCRATCH_PATH" ]]; then
    info "Scratch: $SCRATCH_PATH"
    mkdir -p "$SCRATCH_PATH"
fi

set +e
test_cmd=(
    env
    SPEAKFLOW_MUTE_SOUNDS=1
    SPEAKFLOW_ISOLATE_TEST_AUDIO=1
    SPEAKFLOW_OBSERVABILITY_PROFILE="$OBS_PROFILE"
    SPEAKFLOW_OBSERVABILITY_DIR="$OBS_DIR"
    swift
    test
    --no-parallel
)
if [[ -n "$SCRATCH_PATH" ]]; then
    test_cmd+=(--scratch-path "$SCRATCH_PATH")
fi
"${test_cmd[@]}" >"$TEST_LOG" 2>&1 &
TEST_PID=$!
TEST_START_TS=$(date +%s)
LAST_HEARTBEAT_TS="$TEST_START_TS"
TEST_TIMED_OUT=0

while kill -0 "$TEST_PID" 2>/dev/null; do
    sleep 2
    NOW_TS=$(date +%s)
    ELAPSED_SECONDS=$((NOW_TS - TEST_START_TS))

    # Heartbeat every 20 seconds so RC does not look stuck.
    if [ $((NOW_TS - LAST_HEARTBEAT_TS)) -ge 20 ]; then
        LAST_HEARTBEAT_TS="$NOW_TS"
        LAST_TEST_LINE="$(tail -n 1 "$TEST_LOG" 2>/dev/null | tr -d '\r')"
        if [ -n "$LAST_TEST_LINE" ]; then
            info "Tests running (${ELAPSED_SECONDS}s): $LAST_TEST_LINE"
        else
            info "Tests running (${ELAPSED_SECONDS}s)..."
        fi
    fi

    if [ "$ELAPSED_SECONDS" -ge "$TEST_TIMEOUT_SECONDS" ]; then
        TEST_TIMED_OUT=1
        warn "Test suite timed out after ${TEST_TIMEOUT_SECONDS}s — stopping test process"
        kill -TERM "$TEST_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$TEST_PID" 2>/dev/null || true
        break
    fi
done

wait "$TEST_PID"
TEST_STATUS=$?
set -e

tail -n 5 "$TEST_LOG" 2>/dev/null | sed 's/^/  /'

if [ "$TEST_STATUS" -eq 0 ] && [ "$TEST_TIMED_OUT" -eq 0 ]; then
    ok "All tests passed"
else
    if [ "$TEST_TIMED_OUT" -eq 1 ]; then
        warn "Tests timed out — see log: $TEST_LOG"
    else
        warn "Tests failed — see log: $TEST_LOG"
    fi
    if [[ "$MODE" != "rc" ]]; then
        fail "Local production build and release are blocked because the test suite did not pass"
    fi
    confirm "Continue with RC build anyway?"
fi

# =============================================================================
# STAGE 3 — Build
# =============================================================================
step "Building release binary"
build_cmd=(swift build -c release --product SpeakFlow)
if [[ -n "$SCRATCH_PATH" ]]; then
    build_cmd+=(--scratch-path "$SCRATCH_PATH")
fi
BUILD_LOG="$(mktemp /tmp/speakflow-release-build-XXXXXX.log)"
BUILD_TIMEOUT_SECONDS="${SPEAKFLOW_RC_BUILD_TIMEOUT_SECONDS:-1800}"
info "Build log: $BUILD_LOG"
info "Build timeout: ${BUILD_TIMEOUT_SECONDS}s (override with SPEAKFLOW_RC_BUILD_TIMEOUT_SECONDS)"

set +e
"${build_cmd[@]}" >"$BUILD_LOG" 2>&1 &
BUILD_PID=$!
BUILD_START_TS=$(date +%s)
LAST_BUILD_HEARTBEAT_TS="$BUILD_START_TS"
BUILD_TIMED_OUT=0

while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 2
    NOW_TS=$(date +%s)
    ELAPSED_SECONDS=$((NOW_TS - BUILD_START_TS))

    if [ $((NOW_TS - LAST_BUILD_HEARTBEAT_TS)) -ge 20 ]; then
        LAST_BUILD_HEARTBEAT_TS="$NOW_TS"
        LAST_BUILD_LINE="$(tail -n 1 "$BUILD_LOG" 2>/dev/null | tr -d '\r')"
        if [ -n "$LAST_BUILD_LINE" ]; then
            info "Build running (${ELAPSED_SECONDS}s): $LAST_BUILD_LINE"
        else
            info "Build running (${ELAPSED_SECONDS}s)..."
        fi
    fi

    if [ "$ELAPSED_SECONDS" -ge "$BUILD_TIMEOUT_SECONDS" ]; then
        BUILD_TIMED_OUT=1
        warn "Build timed out after ${BUILD_TIMEOUT_SECONDS}s — stopping build process"
        kill -TERM "$BUILD_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$BUILD_PID" 2>/dev/null || true
        break
    fi
done

wait "$BUILD_PID"
BUILD_STATUS=$?
set -e

tail -n 10 "$BUILD_LOG" 2>/dev/null \
    | grep -v "^Found unhandled resource" \
    | grep -v "^$" \
    | sed 's/^/  /'

if [ "$BUILD_STATUS" -ne 0 ] || [ "$BUILD_TIMED_OUT" -eq 1 ]; then
    fail "Build failed or timed out — see log: $BUILD_LOG"
fi

BUILD_ROOT=".build"
if [[ -n "$SCRATCH_PATH" ]]; then
    BUILD_ROOT="$SCRATCH_PATH"
fi

BUILT_BINARY="$BUILD_ROOT/release/$APP_NAME"
[ -f "$BUILT_BINARY" ] || fail "Binary not found after build: $BUILT_BINARY"
ok "Build complete"
# Hash captured after signing (stage 5) once codesign has written its seal

# =============================================================================
# STAGE 4 — Assemble app bundle
# =============================================================================
step "Assembling app bundle"

rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

# Binary
cp "$BUILT_BINARY" "$APP_NAME.app/Contents/MacOS/"

# SPM resource bundle (optional)
if [ -d "$BUILD_ROOT/release/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -r "$BUILD_ROOT/release/${APP_NAME}_${APP_NAME}.bundle" \
        "$APP_NAME.app/Contents/Resources/"
fi

# App icon
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
SRC_ICON="Sources/Resources/AppIcon.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC_ICON" \
        --out "$ICONSET_DIR/icon_${size}x${size}.png" &>/dev/null
    dbl=$((size * 2))
    sips -z $dbl $dbl "$SRC_ICON" \
        --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" &>/dev/null
done
iconutil -c icns "$ICONSET_DIR" \
    -o "$APP_NAME.app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

# Info.plist — no local values; only BUNDLE_ID and version are substituted
cat > "$APP_NAME.app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleVersion</key>         <string>$BUNDLE_VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$MARKETING_VERSION</string>
    <key>SpeakFlowDisplayVersion</key> <string>$DISPLAY_VERSION</string>
    <key>SpeakFlowBuildGitCommit</key> <string>$BUILD_GIT_COMMIT</string>
    <key>SpeakFlowBuildGitDescribe</key> <string>$BUILD_GIT_DESCRIBE</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSMicrophoneUsageDescription</key>
        <string>$APP_NAME needs microphone access to transcribe your voice.</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

ok "App bundle assembled"

# =============================================================================
# STAGE 5 — Code sign
# =============================================================================
step "Code signing"

# Sign embedded framework/plugin bundles that contain a Mach-O executable.
# Pure resource bundles (images only) are not signable and are skipped.
EMBEDDED_BUNDLE="$APP_NAME.app/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$EMBEDDED_BUNDLE" ]; then
    # Count Mach-O payloads without nested `sh -c` to avoid shell parsing edge cases.
    EXEC_COUNT=$(find "$EMBEDDED_BUNDLE" -type f -print0 2>/dev/null \
        | xargs -0 file 2>/dev/null \
        | grep -c "Mach-O" || true)
    if [ "$EXEC_COUNT" -gt 0 ]; then
        codesign --force --options runtime --timestamp \
            --sign "$SIGNING_IDENTITY" \
            "$EMBEDDED_BUNDLE" 2>&1 | sed 's/^/  /' \
            || fail "Failed to sign embedded bundle"
    else
        info "Skipping resource-only bundle (no Mach-O)"
    fi
fi

# Sign the app
codesign --force --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/$APP_NAME.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_NAME.app" 2>&1 | sed 's/^/  /' || fail "Failed to sign app"

# Verify
codesign --verify --deep --strict "$APP_NAME.app" 2>&1 | sed 's/^/  /' \
    || fail "Code signature verification failed"

# Capture binary hash NOW — after codesign has written the signature seal
BINARY_SHA256=$(shasum -a 256 "$APP_NAME.app/Contents/MacOS/$APP_NAME" | awk '{print $1}')
ok "App signed and verified"
info "Signed binary SHA-256: $BINARY_SHA256"

./scripts/verify-release-artifact.sh \
    --skip-notarization \
    --expected-version "$MARKETING_VERSION" \
    --expected-display-version "$DISPLAY_VERSION" \
    --expected-bundle-id "$BUNDLE_ID" \
    --expected-team-id "$SPEAKFLOW_TEAM_ID" \
    "$APP_NAME.app" 2>&1 | sed 's/^/  /' \
    || fail "Signed app artifact validation failed"
ok "Signed app artifact validation passed"

# =============================================================================
# STAGE 6 — App notarization (release only)
# =============================================================================
if [[ "$MODE" == "release" ]]; then
    step "Notarizing app bundle"
    info "Submitting app bundle to Apple notary service before DMG packaging..."

    APP_ZIP="$(mktemp /tmp/speakflow-app-XXXXXX).zip"
    ditto -c -k --keepParent "$APP_NAME.app" "$APP_ZIP" \
        || fail "Failed to create app notarization zip"

    notarize_file "$APP_ZIP" "App"
    rm -f "$APP_ZIP"

    xcrun stapler staple "$APP_NAME.app" 2>&1 | sed 's/^/  /' \
        || fail "App stapling failed"
    xcrun stapler validate "$APP_NAME.app" 2>&1 | sed 's/^/  /' \
        || fail "App stapler validation failed"

    ./scripts/verify-release-artifact.sh \
        --expected-version "$MARKETING_VERSION" \
        --expected-display-version "$DISPLAY_VERSION" \
        --expected-bundle-id "$BUNDLE_ID" \
        --expected-team-id "$SPEAKFLOW_TEAM_ID" \
        "$APP_NAME.app" 2>&1 | sed 's/^/  /' \
        || fail "Notarized app artifact validation failed"
    ok "App ticket stapled and validated"
fi

# =============================================================================
# STAGE 7 — DMG (RC and release only)
# =============================================================================
if [[ "$MODE" != "local" ]]; then
step "Creating DMG"

rm -f "$APP_NAME.dmg"
create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 150 185 \
    --app-drop-link 450 185 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$APP_NAME.dmg" \
    "$APP_NAME.app" 2>&1 | grep -v "^$" | sed 's/^/  /'

[ -f "$APP_NAME.dmg" ] || fail "DMG not created"

# Sign the DMG
codesign --force --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_NAME.dmg" 2>&1 | sed 's/^/  /' || fail "Failed to sign DMG"

DMG_SHA256=$(shasum -a 256 "$APP_NAME.dmg" | awk '{print $1}')
DMG_SIZE=$(du -sh "$APP_NAME.dmg" | awk '{print $1}')
ok "DMG created and signed ($DMG_SIZE)"
info "DMG SHA-256: $DMG_SHA256"

./scripts/verify-release-artifact.sh \
    --skip-notarization \
    --expected-version "$MARKETING_VERSION" \
    --expected-display-version "$DISPLAY_VERSION" \
    --expected-bundle-id "$BUNDLE_ID" \
    --expected-team-id "$SPEAKFLOW_TEAM_ID" \
    "$APP_NAME.dmg" 2>&1 | sed 's/^/  /' \
    || fail "Signed DMG artifact validation failed"
ok "Signed DMG artifact validation passed"
fi

# =============================================================================
# STAGE 8 — DMG notarization (release only)
# =============================================================================
if [[ "$MODE" == "release" ]]; then
    step "Notarizing DMG with Apple"
    info "Submitting DMG to Apple notary service (usually 1–5 minutes)..."

    notarize_file "$APP_NAME.dmg" "DMG"

    step "Stapling notarization ticket"
    xcrun stapler staple "$APP_NAME.dmg" 2>&1 | sed 's/^/  /' \
        || fail "Stapling failed"
    xcrun stapler validate "$APP_NAME.dmg" 2>&1 | sed 's/^/  /' \
        || fail "Stapler validation failed"
    ok "DMG ticket stapled and validated"

    step "Release artifact validation"
    ./scripts/verify-release-artifact.sh \
        --expected-version "$MARKETING_VERSION" \
        --expected-display-version "$DISPLAY_VERSION" \
        --expected-bundle-id "$BUNDLE_ID" \
        --expected-team-id "$SPEAKFLOW_TEAM_ID" \
        "$APP_NAME.dmg" 2>&1 | sed 's/^/  /' \
        || fail "Final release artifact validation failed"
    ok "Final release artifact validation passed"

    # Re-capture DMG hash after stapling (ticket changes the file)
    DMG_SHA256=$(shasum -a 256 "$APP_NAME.dmg" | awk '{print $1}')
    info "Stapled DMG SHA-256: $DMG_SHA256"
fi

# =============================================================================
# STAGE 9 — Install verification (RC/local) / Release notes confirmation (release)
# =============================================================================
if [[ "$MODE" == "rc" || "$MODE" == "local" ]]; then
    install_and_verify

else
    # ── Release: show release notes and ask for confirmation ──────────────────
    step "Release notes review"

    # Extract the section for this version from CHANGELOG.md.
    # Match heading "## VERSION" (anything after), collect until the next "## " heading.
    NOTES=$(awk \
        "BEGIN{found=0} /^## ${DISPLAY_VERSION}( |$)/{found=1; next} found && /^## /{exit} found{print}" \
        CHANGELOG.md)

    if [ -z "$NOTES" ]; then
        warn "No CHANGELOG entry found for v${DISPLAY_VERSION}"
        confirm "Publish release without changelog notes?"
        NOTES="See CHANGELOG.md"
    else
        printf "\n${CYAN}%s${RESET}\n" "$NOTES"
    fi

    confirm "Publish v${DISPLAY_VERSION} to GitHub with these release notes?"

    # ==========================================================================
    # STAGE 10 — Publish to GitHub
    # ==========================================================================
    step "Publishing GitHub release v${DISPLAY_VERSION}"

    if gh release view "v${DISPLAY_VERSION}" &>/dev/null 2>&1; then
        fail "Release v${DISPLAY_VERSION} already exists. Refusing to mutate an existing release."
    fi

    info "Creating release v${DISPLAY_VERSION}..."
    NOTES_FILE="$(mktemp)"
    printf '%s' "$NOTES" > "$NOTES_FILE"
    gh release create "v${DISPLAY_VERSION}" "$APP_NAME.dmg" \
        --target "$(git rev-parse HEAD)" \
        --title "v${DISPLAY_VERSION}" \
        --notes-file "$NOTES_FILE" \
        2>&1 | sed 's/^/  /'
    rm -f "$NOTES_FILE"
    ok "Published to GitHub"

    step "Verifying GitHub release asset"
    # Download the published DMG and verify its hash matches what we uploaded
    VERIFY_DIR="$(mktemp -d)"
    gh release download "v${DISPLAY_VERSION}" \
        --pattern "*.dmg" \
        --dir "$VERIFY_DIR" 2>&1 | sed 's/^/  /'
    DOWNLOADED_DMG="$VERIFY_DIR/$APP_NAME.dmg"

    if [ -f "$DOWNLOADED_DMG" ]; then
        DOWNLOADED_SHA256=$(shasum -a 256 "$DOWNLOADED_DMG" | awk '{print $1}')
        if [ "$DOWNLOADED_SHA256" = "$DMG_SHA256" ]; then
            ok "Downloaded DMG hash matches uploaded file"
            info "SHA-256: $DOWNLOADED_SHA256"
            ./scripts/verify-release-artifact.sh \
                --expected-version "$MARKETING_VERSION" \
                --expected-display-version "$DISPLAY_VERSION" \
                --expected-bundle-id "$BUNDLE_ID" \
                --expected-team-id "$SPEAKFLOW_TEAM_ID" \
                "$DOWNLOADED_DMG" 2>&1 | sed 's/^/  /' \
                || fail "Downloaded GitHub release artifact validation failed"
            ok "Downloaded GitHub release artifact validation passed"
        else
            fail "Hash mismatch after upload
       Uploaded:   $DMG_SHA256
       Downloaded: $DOWNLOADED_SHA256"
        fi
    else
        fail "Could not download DMG from GitHub release"
    fi
    rm -rf "$VERIFY_DIR"

    install_and_verify
fi

# =============================================================================
# Done
# =============================================================================
printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
if [[ "$MODE" == "rc" ]]; then
    printf "${GREEN}${BOLD}  ✅ RC ready: SpeakFlow $DISPLAY_VERSION${RESET}\n"
    printf "${DIM}     Installed at /Applications/SpeakFlow.app${RESET}\n"
    printf "${DIM}     Binary SHA-256: $BINARY_SHA256${RESET}\n"
    printf "${DIM}     Nothing was pushed or uploaded.${RESET}\n"
elif [[ "$MODE" == "local" ]]; then
    printf "${GREEN}${BOLD}  ✅ Local production build ready: SpeakFlow $DISPLAY_VERSION${RESET}\n"
    printf "${DIM}     Installed at /Applications/SpeakFlow.app${RESET}\n"
    printf "${DIM}     Binary SHA-256: $BINARY_SHA256${RESET}\n"
    printf "${DIM}     Nothing was pushed, uploaded, or notarized.${RESET}\n"
else
    printf "${GREEN}${BOLD}  ✅ Released: SpeakFlow v$DISPLAY_VERSION${RESET}\n"
    REPO_URL=$(gh repo view --json url -q .url 2>/dev/null || echo "https://github.com")
    printf "${DIM}     ${REPO_URL}/releases/tag/v${DISPLAY_VERSION}${RESET}\n"
    printf "${DIM}     DMG SHA-256: $DMG_SHA256${RESET}\n"
    printf "${DIM}     Installed at /Applications/SpeakFlow.app${RESET}\n"
fi
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n\n"
