#!/bin/bash
# =============================================================================
# SpeakFlow Release Script
# =============================================================================
#
# USAGE
#   ./scripts/build-release.sh rc               — build, sign, install locally for testing
#   ./scripts/build-release.sh release          — build, sign, notarize, publish to GitHub
#   ./scripts/build-release.sh release --yes    — same, skip all confirmations (non-interactive)
#   ./scripts/build-release.sh release -y       — shorthand for --yes
#
# REQUIRED ENVIRONMENT VARIABLES (never hardcoded here)
#   SPEAKFLOW_BUNDLE_ID          e.g. com.example.speakflow
#   SPEAKFLOW_SIGNING_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#   SPEAKFLOW_TEAM_ID            e.g. ABCDE12345
#   SPEAKFLOW_NOTARY_PROFILE     name of keychain notarytool profile (release only)
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

# ── Mode & flags ──────────────────────────────────────────────────────────────
MODE="${1:-}"
YES=0
for arg in "$@"; do
    [[ "$arg" == "--yes" || "$arg" == "-y" ]] && YES=1
done

if [[ "$MODE" != "rc" && "$MODE" != "release" ]]; then
    printf "${RED}Usage: %s rc | release [--yes|-y]${RESET}\n" "$(basename "$0")" >&2
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
LATEST_TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]' | head -1 2>/dev/null || true)
BASE_VERSION="${LATEST_TAG#v}"
BASE_VERSION="${BASE_VERSION:-0.0.0}"

if [[ "$MODE" == "rc" ]]; then
    RC_TIMESTAMP=$(date +%Y%m%d%H%M)
    DISPLAY_VERSION="${BASE_VERSION}-rc.${RC_TIMESTAMP}"
    BUNDLE_VERSION="$DISPLAY_VERSION"
else
    DISPLAY_VERSION="$BASE_VERSION"
    BUNDLE_VERSION="$BASE_VERSION"
fi

# ── Header ────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "rc" ]]; then
    banner "🔨 SpeakFlow $DISPLAY_VERSION — Release Candidate" \
           "Local install only · nothing pushed · nothing uploaded"
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

    # 1d. Notary profile
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null 2>&1; then
        fail "Notary profile '$NOTARY_PROFILE' not found in keychain"
    fi
    ok "Notary profile found"

    # 1e. Clean git working tree
    if [ -n "$(git status --porcelain)" ]; then
        warn "Working directory has uncommitted changes"
        confirm "Release anyway?"
    else
        ok "Git working tree clean"
    fi

    # 1f. Tag exists on origin (checked via gh API — no SSH needed)
    if ! gh api "repos/{owner}/{repo}/git/refs/tags/v${DISPLAY_VERSION}" \
            --silent &>/dev/null 2>&1; then
        warn "Tag v${DISPLAY_VERSION} not found on origin"
        confirm "Continue without tag on origin?"
    else
        ok "Tag v${DISPLAY_VERSION} exists on origin"
    fi
fi

# =============================================================================
# STAGE 2 — Tests
# =============================================================================
step "Running test suite"
if swift test --quiet 2>&1 | tail -3 | grep -qE "passed|0 failures"; then
    ok "All tests passed"
else
    warn "Tests may have failures — check output above"
    confirm "Release anyway?"
fi

# =============================================================================
# STAGE 3 — Build
# =============================================================================
step "Building release binary"
swift build -c release --product SpeakFlow 2>&1 \
    | grep -v "^Found unhandled resource" \
    | grep -v "^$" \
    | sed 's/^/  /' \
    || fail "Build failed"

BUILT_BINARY=".build/release/$APP_NAME"
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
if [ -d ".build/release/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -r ".build/release/${APP_NAME}_${APP_NAME}.bundle" \
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
    <key>CFBundleShortVersionString</key> <string>$DISPLAY_VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>15.0</string>
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
    EXEC_COUNT=$(find "$EMBEDDED_BUNDLE" -type f \
        -exec sh -c 'file "$1" | grep -q "Mach-O"' _ {} \; -print 2>/dev/null | wc -l)
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

# =============================================================================
# STAGE 6 — DMG
# =============================================================================
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

# =============================================================================
# STAGE 7 — Notarize (release only)
# =============================================================================
if [[ "$MODE" == "release" ]]; then
    step "Notarizing with Apple"
    info "Submitting to Apple notary service (usually 1–5 minutes)..."

    NOTARIZE_LOG="$(mktemp)"
    xcrun notarytool submit "$APP_NAME.dmg" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$NOTARIZE_LOG" | sed 's/^/  /'

    if grep -q "status: Accepted" "$NOTARIZE_LOG"; then
        ok "Notarization accepted by Apple"
    else
        SUBMISSION_ID=$(grep -E "^\s*id:" "$NOTARIZE_LOG" | head -1 | awk '{print $2}')
        [ -n "$SUBMISSION_ID" ] && \
            xcrun notarytool log "$SUBMISSION_ID" \
                --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/  /'
        fail "Notarization rejected — see log above"
    fi
    rm -f "$NOTARIZE_LOG"

    step "Stapling notarization ticket"
    xcrun stapler staple "$APP_NAME.dmg" 2>&1 | sed 's/^/  /' \
        || fail "Stapling failed"
    xcrun stapler validate "$APP_NAME.dmg" 2>&1 | sed 's/^/  /' \
        || fail "Stapler validation failed"
    ok "Ticket stapled and validated"

    step "Gatekeeper check"
    spctl --assess --type open --context context:primary-signature \
        "$APP_NAME.dmg" 2>&1 | sed 's/^/  /' \
        || fail "Gatekeeper assessment failed"
    ok "Gatekeeper: Notarized Developer ID"

    # Re-capture DMG hash after stapling (ticket changes the file)
    DMG_SHA256=$(shasum -a 256 "$APP_NAME.dmg" | awk '{print $1}')
    info "Stapled DMG SHA-256: $DMG_SHA256"
fi

# =============================================================================
# STAGE 8 — Install verification (RC) / Release notes confirmation (release)
# =============================================================================
if [[ "$MODE" == "rc" ]]; then
    step "Installing to /Applications"

    # Quit any running instance
    if pgrep -x "$APP_NAME" &>/dev/null; then
        info "Quitting running $APP_NAME..."
        osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
        sleep 1
        if pgrep -x "$APP_NAME" &>/dev/null; then
            killall -9 "$APP_NAME" 2>/dev/null || true
            sleep 1
        fi
    fi

    # Install
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP_NAME.app" "/Applications/$APP_NAME.app"
    touch "/Applications/$APP_NAME.app"

    # Verify installed binary hash matches what was built
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

    # Verify code signature of installed app
    codesign --verify --deep --strict "/Applications/$APP_NAME.app" 2>&1 \
        | sed 's/^/  /' || fail "Installed app signature invalid"
    ok "Installed app signature valid"

    # Verify version string in installed Info.plist
    INSTALLED_VERSION=$(defaults read \
        "/Applications/$APP_NAME.app/Contents/Info" \
        CFBundleShortVersionString 2>/dev/null || echo "unknown")
    if [ "$INSTALLED_VERSION" = "$DISPLAY_VERSION" ]; then
        ok "Version string correct: $INSTALLED_VERSION"
    else
        fail "Version mismatch — expected $DISPLAY_VERSION, got $INSTALLED_VERSION"
    fi

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
    # STAGE 9 — Publish to GitHub
    # ==========================================================================
    step "Publishing GitHub release v${DISPLAY_VERSION}"

    if gh release view "v${DISPLAY_VERSION}" &>/dev/null 2>&1; then
        info "Release v${DISPLAY_VERSION} already exists — uploading DMG..."
        gh release upload "v${DISPLAY_VERSION}" "$APP_NAME.dmg" --clobber \
            2>&1 | sed 's/^/  /'
    else
        info "Creating release v${DISPLAY_VERSION}..."
        NOTES_FILE="$(mktemp)"
        printf '%s' "$NOTES" > "$NOTES_FILE"
        gh release create "v${DISPLAY_VERSION}" "$APP_NAME.dmg" \
            --title "v${DISPLAY_VERSION}" \
            --notes-file "$NOTES_FILE" \
            2>&1 | sed 's/^/  /'
        rm -f "$NOTES_FILE"
    fi
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
        else
            fail "Hash mismatch after upload
       Uploaded:   $DMG_SHA256
       Downloaded: $DOWNLOADED_SHA256"
        fi
    else
        fail "Could not download DMG from GitHub release"
    fi
    rm -rf "$VERIFY_DIR"
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
else
    printf "${GREEN}${BOLD}  ✅ Released: SpeakFlow v$DISPLAY_VERSION${RESET}\n"
    REPO_URL=$(gh repo view --json url -q .url 2>/dev/null || echo "https://github.com")
    printf "${DIM}     ${REPO_URL}/releases/tag/v${DISPLAY_VERSION}${RESET}\n"
    printf "${DIM}     DMG SHA-256: $DMG_SHA256${RESET}\n"
fi
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n\n"
