#!/bin/bash
set -eo pipefail

# SpeakFlow Release Build Script
# Creates a signed .app bundle and optional DMG installer

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="SpeakFlow"
BUNDLE_ID="app.monodo.speakflow"
VERSION="${1:-1.0.0}"

cd "$PROJECT_DIR"

echo "Building $APP_NAME v$VERSION..."

# Build release binary
swift build -c release --product SpeakFlow 2>&1 | grep -v "Found unhandled resource"

# Create app bundle structure
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

# Copy binary
cp ".build/release/$APP_NAME" "$APP_NAME.app/Contents/MacOS/"

# Copy SPM resource bundle (contains DockIcon, MenuBarIcon, AppIcon via Bundle.module)
cp -r ".build/release/${APP_NAME}_${APP_NAME}.bundle" "$APP_NAME.app/Contents/Resources/" 2>/dev/null || true

# Generate .icns from the high-res logo
echo "Creating app icon..."
mkdir -p AppIcon.iconset
sips -z 16 16 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_16x16.png 2>/dev/null
sips -z 32 32 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png 2>/dev/null
sips -z 32 32 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_32x32.png 2>/dev/null
sips -z 64 64 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png 2>/dev/null
sips -z 128 128 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_128x128.png 2>/dev/null
sips -z 256 256 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png 2>/dev/null
sips -z 256 256 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_256x256.png 2>/dev/null
sips -z 512 512 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png 2>/dev/null
sips -z 512 512 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_512x512.png 2>/dev/null
sips -z 1024 1024 Sources/Resources/AppIcon.png --out AppIcon.iconset/icon_512x512@2x.png 2>/dev/null
iconutil -c icns AppIcon.iconset -o "$APP_NAME.app/Contents/Resources/AppIcon.icns"
rm -rf AppIcon.iconset

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

# Ad-hoc sign the app
echo "Signing app..."
codesign --force --deep --sign - "$APP_NAME.app"

# Create DMG if create-dmg is available
if command -v create-dmg &> /dev/null; then
    echo "Creating DMG..."
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
    echo ""
    echo "Done! App: $APP_NAME.app | DMG: $APP_NAME.dmg"
    ls -lh "$APP_NAME.dmg"
else
    echo ""
    echo "Done! App: $APP_NAME.app"
    echo ""
    echo "To install: cp -r $APP_NAME.app /Applications/"
    echo "To create a DMG: brew install create-dmg && bash $0 $VERSION"
fi

echo ""
echo "Next steps:"
echo "  1. Drag SpeakFlow.app to /Applications"
echo "  2. Launch SpeakFlow — settings window opens automatically"
echo "  3. Grant Accessibility and Microphone from the General tab"
echo "  4. Add a transcription provider from the Accounts tab"
