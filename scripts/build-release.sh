#!/bin/bash
set -eo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SpeakFlow Release Build Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Usage:
#   ./scripts/build-release.sh              # Local install (signed for dev)
#   ./scripts/build-release.sh --github     # GitHub release (signed + notarized + uploaded)
#   ./scripts/build-release.sh --github v1.2.3  # GitHub release with explicit version
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="SpeakFlow"
BUNDLE_ID="$SPEAKFLOW_BUNDLE_ID"
SIGNING_IDENTITY="$SPEAKFLOW_SIGNING_IDENTITY"
TEAM_ID="$SPEAKFLOW_TEAM_ID"
NOTARY_PROFILE="$SPEAKFLOW_NOTARY_PROFILE"

cd "$PROJECT_DIR"

# ─── Parse arguments ────────────────────────────────────────────────
MODE="local"
VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --github)
            MODE="github"
            shift
            ;;
        *)
            VERSION="$1"
            shift
            ;;
    esac
done

# Auto-detect version from latest git tag
if [ -z "$VERSION" ]; then
    LATEST_TAG=$(git tag --sort=-v:refname | head -1 2>/dev/null)
    VERSION="${LATEST_TAG#v}"
    VERSION="${VERSION:-0.0.0}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$MODE" = "github" ]; then
    echo "  🚀 $APP_NAME v$VERSION — GitHub Release"
    echo "     Signed + Notarized + Uploaded"
else
    echo "  🔨 $APP_NAME v$VERSION — Local Build"
    echo "     Signed for development"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Verify signing identity ────────────────────────────────────────
echo ""
echo "▸ Checking signing identity..."
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    echo "  ❌ Not found: $SIGNING_IDENTITY"
    echo "     Run: security find-identity -v -p codesigning"
    exit 1
fi
echo "  ✓ $SIGNING_IDENTITY"

# ─── GitHub mode: verify tools & credentials ────────────────────────
if [ "$MODE" = "github" ]; then
    echo ""
    echo "▸ Checking GitHub CLI..."
    if ! command -v gh &>/dev/null; then
        echo "  ❌ gh not found. Install: brew install gh"
        exit 1
    fi
    if ! gh auth status &>/dev/null 2>&1; then
        echo "  ❌ Not logged in. Run: gh auth login"
        exit 1
    fi
    echo "  ✓ gh authenticated"

    echo ""
    echo "▸ Checking notarization credentials..."
    # Try a dummy lookup — it will fail but tells us if the profile exists
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null 2>&1; then
        echo ""
        echo "  ❌ Notarization credentials not found."
        echo ""
        echo "  Set them up once (you need an app-specific password):"
        echo ""
        echo "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
        echo "      --apple-id YOUR_APPLE_ID@email.com \\"
        echo "      --team-id $TEAM_ID \\"
        echo "      --password APP_SPECIFIC_PASSWORD"
        echo ""
        echo "  Generate an app-specific password at:"
        echo "    https://appleid.apple.com/account/manage"
        echo "    → Sign In → App-Specific Passwords → +"
        exit 1
    fi
    echo "  ✓ Notarization profile '$NOTARY_PROFILE' found"

    # Check for clean git state
    echo ""
    echo "▸ Checking git state..."
    if [ -n "$(git status --porcelain)" ]; then
        echo "  ⚠️  Working directory has uncommitted changes"
        read -p "  Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "  ✓ Working directory clean"
    fi
fi

# ─── Build release binary ──────────────────────────────────────────
echo ""
echo "▸ Building release binary..."
swift build -c release --product SpeakFlow 2>&1 | grep -v "Found unhandled resource"
echo "  ✓ Build complete"

# ─── Create app bundle ──────────────────────────────────────────────
echo ""
echo "▸ Creating app bundle..."
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

# Copy binary
cp ".build/release/$APP_NAME" "$APP_NAME.app/Contents/MacOS/"

# Copy SPM resource bundle
cp -r ".build/release/${APP_NAME}_${APP_NAME}.bundle" "$APP_NAME.app/Contents/Resources/" 2>/dev/null || true

# Generate .icns from the high-res logo
echo "  Creating app icon..."
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET_DIR"
sips -z 16 16 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_16x16.png" 2>/dev/null
sips -z 32 32 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_16x16@2x.png" 2>/dev/null
sips -z 32 32 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_32x32.png" 2>/dev/null
sips -z 64 64 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_32x32@2x.png" 2>/dev/null
sips -z 128 128 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_128x128.png" 2>/dev/null
sips -z 256 256 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_128x128@2x.png" 2>/dev/null
sips -z 256 256 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_256x256.png" 2>/dev/null
sips -z 512 512 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_256x256@2x.png" 2>/dev/null
sips -z 512 512 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_512x512.png" 2>/dev/null
sips -z 1024 1024 Sources/Resources/AppIcon.png --out "$ICONSET_DIR/icon_512x512@2x.png" 2>/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_NAME.app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

# Create Info.plist
cat > "$APP_NAME.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>$APP_NAME needs microphone access to record your voice for transcription.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
echo "  ✓ App bundle created"

# ─── Code sign ──────────────────────────────────────────────────────
echo ""
echo "▸ Signing app with Developer ID..."

# Sign embedded bundles first, then the app itself
# --options runtime enables Hardened Runtime (required for notarization)
# --timestamp uses Apple's secure timestamp server
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_NAME.app/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle" 2>/dev/null || true

codesign --force --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/$APP_NAME.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_NAME.app"

echo "  ✓ App signed"

# Verify
echo "  Verifying..."
codesign --verify --deep --strict "$APP_NAME.app" 2>&1
echo "  ✓ Signature valid"

# ─── Create DMG ─────────────────────────────────────────────────────
echo ""
echo "▸ Creating DMG..."
if ! command -v create-dmg &>/dev/null; then
    echo "  Installing create-dmg..."
    brew install create-dmg
fi

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
    "$APP_NAME.app"

# Sign the DMG
codesign --force --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_NAME.dmg"

echo "  ✓ DMG created and signed"
ls -lh "$APP_NAME.dmg"

# ─── Notarize (GitHub mode only) ───────────────────────────────────
if [ "$MODE" = "github" ]; then
    echo ""
    echo "▸ Submitting to Apple for notarization..."
    echo "  (this usually takes 1–5 minutes)"

    xcrun notarytool submit "$APP_NAME.dmg" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee /tmp/speakflow-notarize.txt

    if grep -q "status: Accepted" /tmp/speakflow-notarize.txt; then
        echo "  ✓ Notarization accepted!"

        echo ""
        echo "▸ Stapling notarization ticket..."
        xcrun stapler staple "$APP_NAME.dmg"
        echo "  ✓ Ticket stapled to DMG"
    else
        echo ""
        echo "  ❌ Notarization failed!"
        SUBMISSION_ID=$(grep "id:" /tmp/speakflow-notarize.txt | head -1 | awk '{print $2}')
        if [ -n "$SUBMISSION_ID" ]; then
            echo ""
            echo "  Log:"
            xcrun notarytool log "$SUBMISSION_ID" \
                --keychain-profile "$NOTARY_PROFILE" 2>&1
        fi
        exit 1
    fi
fi

# ─── GitHub Release ─────────────────────────────────────────────────
if [ "$MODE" = "github" ]; then
    echo ""
    echo "▸ Creating GitHub release v$VERSION..."

    # Create release (gh creates the tag automatically)
    if gh release view "v$VERSION" &>/dev/null 2>&1; then
        echo "  Release v$VERSION exists — uploading DMG..."
        gh release upload "v$VERSION" "$APP_NAME.dmg" --clobber
    else
        echo "  Creating release v$VERSION with DMG..."
        gh release create "v$VERSION" "$APP_NAME.dmg" \
            --title "v$VERSION" \
            --generate-notes
    fi

    echo "  ✓ Release published!"
    echo ""
    gh release view "v$VERSION" --web 2>/dev/null || true
fi

# ─── Local install ──────────────────────────────────────────────────
if [ "$MODE" = "local" ]; then
    echo ""

    # Quit running instance
    if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
        echo "▸ Quitting running $APP_NAME..."
        osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || killall "$APP_NAME" 2>/dev/null || true
        sleep 1
    fi

    # Install
    echo "▸ Installing to /Applications..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -r "$APP_NAME.app" "/Applications/$APP_NAME.app"
    echo "  ✓ Installed to /Applications/$APP_NAME.app"
fi

# ─── Done ───────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$MODE" = "github" ]; then
    echo "  ✅ $APP_NAME v$VERSION — Released to GitHub!"
    echo "     https://github.com/rezkam/SpeakFlow/releases/tag/v$VERSION"
else
    echo "  ✅ $APP_NAME v$VERSION — Installed locally!"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
