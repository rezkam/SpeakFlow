#!/bin/bash
# Verify SpeakFlow release artifacts before publishing or tap updates.
# Checks the DMG signature, notarization ticket, mounted app signature,
# app stapling, bundle identifier, team id, and version.
set -euo pipefail

APP_NAME="${SPEAKFLOW_APP_NAME:-SpeakFlow}"
EXPECTED_VERSION=""
EXPECTED_DISPLAY_VERSION=""
EXPECTED_BUNDLE_ID="${SPEAKFLOW_BUNDLE_ID:-}"
EXPECTED_TEAM_ID="${SPEAKFLOW_TEAM_ID:-}"
REQUIRE_NOTARIZATION=1
TARGET=""
MOUNTS=()

ok() { printf '  ✓ %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options] <SpeakFlow.dmg|SpeakFlow.app>

Options:
  --expected-version VERSION     Expected CFBundleShortVersionString
  --expected-display-version VERSION
                                  Expected SpeakFlowDisplayVersion
  --expected-bundle-id ID        Expected CFBundleIdentifier
  --expected-team-id TEAMID      Expected Developer ID team identifier
  --skip-notarization            Verify code signing only, skip Gatekeeper and stapler checks
  --require-notarization         Require Gatekeeper acceptance and stapled tickets (default)
USAGE
}

cleanup() {
    [ "${#MOUNTS[@]}" -eq 0 ] && return 0
    for mount_point in "${MOUNTS[@]}"; do
        if [ -n "$mount_point" ]; then
            real_mount_point=$(cd "$mount_point" 2>/dev/null && pwd -P || printf '%s' "$mount_point")
            hdiutil detach "$mount_point" -quiet 2>/dev/null \
                || hdiutil detach "$real_mount_point" -quiet 2>/dev/null \
                || true
            rm -rf "$mount_point" 2>/dev/null || true
        fi
    done
    return 0
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --expected-version)
            [ "$#" -ge 2 ] || fail "Missing value for --expected-version"
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        --expected-display-version)
            [ "$#" -ge 2 ] || fail "Missing value for --expected-display-version"
            EXPECTED_DISPLAY_VERSION="$2"
            shift 2
            ;;
        --expected-bundle-id)
            [ "$#" -ge 2 ] || fail "Missing value for --expected-bundle-id"
            EXPECTED_BUNDLE_ID="$2"
            shift 2
            ;;
        --expected-team-id)
            [ "$#" -ge 2 ] || fail "Missing value for --expected-team-id"
            EXPECTED_TEAM_ID="$2"
            shift 2
            ;;
        --skip-notarization)
            REQUIRE_NOTARIZATION=0
            shift
            ;;
        --require-notarization)
            REQUIRE_NOTARIZATION=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            fail "Unknown option: $1"
            ;;
        *)
            if [ -n "$TARGET" ]; then
                fail "Only one artifact path is supported"
            fi
            TARGET="$1"
            shift
            ;;
    esac
done

[ -n "$TARGET" ] || { usage; exit 1; }
[ "$(uname -s)" = "Darwin" ] || fail "Release artifact validation requires macOS"

for cmd in codesign spctl xcrun hdiutil shasum; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done
[ -x /usr/libexec/PlistBuddy ] || fail "Missing required command: /usr/libexec/PlistBuddy"

plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

require_developer_id_signature() {
    local artifact="$1"
    local label="$2"
    local signature

    if ! signature=$(codesign -dv --verbose=4 "$artifact" 2>&1); then
        printf '%s\n' "$signature" | sed 's/^/  /'
        fail "$label signature metadata could not be read"
    fi

    if printf '%s\n' "$signature" | grep -q '^Signature=adhoc$'; then
        fail "$label is ad-hoc signed, expected Developer ID"
    fi

    if ! printf '%s\n' "$signature" | grep -q '^Authority=Developer ID Application:'; then
        printf '%s\n' "$signature" | sed 's/^/  /'
        fail "$label is not signed with a Developer ID Application certificate"
    fi

    if [ -n "$EXPECTED_TEAM_ID" ] && ! printf '%s\n' "$signature" | grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$"; then
        printf '%s\n' "$signature" | sed 's/^/  /'
        fail "$label is not signed by expected team $EXPECTED_TEAM_ID"
    fi
}

verify_app() {
    local app="$1"
    local info_plist="$app/Contents/Info.plist"
    local executable="$app/Contents/MacOS/$APP_NAME"
    local version display_version bundle_id

    [ -d "$app" ] || fail "App bundle not found: $app"
    [ -f "$info_plist" ] || fail "Info.plist not found in app: $app"
    [ -x "$executable" ] || fail "Executable not found or not executable: $executable"

    info "Verifying app: $app"

    codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed 's/^/  /' \
        || fail "App code signature verification failed"
    require_developer_id_signature "$app" "App"
    ok "App is signed with Developer ID"

    bundle_id=$(plist_value "$info_plist" "CFBundleIdentifier")
    if [ -n "$EXPECTED_BUNDLE_ID" ] && [ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]; then
        fail "Bundle id mismatch, expected $EXPECTED_BUNDLE_ID, got ${bundle_id:-missing}"
    fi
    [ -n "$bundle_id" ] || fail "Bundle id missing"
    ok "Bundle id: $bundle_id"

    version=$(plist_value "$info_plist" "CFBundleShortVersionString")
    [ -n "$version" ] || fail "CFBundleShortVersionString missing"
    if [ -n "$EXPECTED_VERSION" ] && [ "$version" != "$EXPECTED_VERSION" ]; then
        fail "Version mismatch, expected $EXPECTED_VERSION, got $version"
    fi
    ok "Version: $version"

    display_version=$(plist_value "$info_plist" "SpeakFlowDisplayVersion")
    if [ -n "$EXPECTED_DISPLAY_VERSION" ] && [ -n "$display_version" ] && [ "$display_version" != "$EXPECTED_DISPLAY_VERSION" ]; then
        fail "Display version mismatch, expected $EXPECTED_DISPLAY_VERSION, got $display_version"
    fi
    [ -z "$display_version" ] || ok "Display version: $display_version"

    if [ "$REQUIRE_NOTARIZATION" -eq 1 ]; then
        spctl --assess --type execute --verbose=4 "$app" 2>&1 | sed 's/^/  /' \
            || fail "App Gatekeeper assessment failed"
        ok "App Gatekeeper assessment accepted"

        xcrun stapler validate "$app" 2>&1 | sed 's/^/  /' \
            || fail "App notarization ticket is not stapled"
        ok "App notarization ticket is stapled"
    else
        info "Skipping app Gatekeeper and stapler checks"
    fi
}

verify_dmg() {
    local dmg="$1"
    local mount_point app_count app_path sha

    [ -f "$dmg" ] || fail "DMG not found: $dmg"
    info "Verifying DMG: $dmg"

    sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
    ok "DMG SHA-256: $sha"

    codesign --verify --verbose=2 "$dmg" 2>&1 | sed 's/^/  /' \
        || fail "DMG code signature verification failed"
    require_developer_id_signature "$dmg" "DMG"
    ok "DMG is signed with Developer ID"

    if [ "$REQUIRE_NOTARIZATION" -eq 1 ]; then
        spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1 | sed 's/^/  /' \
            || fail "DMG Gatekeeper assessment failed"
        ok "DMG Gatekeeper assessment accepted"

        xcrun stapler validate "$dmg" 2>&1 | sed 's/^/  /' \
            || fail "DMG notarization ticket is not stapled"
        ok "DMG notarization ticket is stapled"
    else
        info "Skipping DMG Gatekeeper and stapler checks"
    fi

    mount_point=$(mktemp -d /tmp/speakflow-artifact-mount-XXXXXX)
    MOUNTS+=("$mount_point")
    hdiutil attach "$dmg" -mountpoint "$mount_point" -nobrowse -readonly -quiet

    app_count=$(find "$mount_point" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')
    [ "$app_count" = "1" ] || fail "Expected exactly one app in DMG, found $app_count"
    app_path=$(find "$mount_point" -maxdepth 1 -type d -name '*.app' | head -1)
    verify_app "$app_path"
}

case "$TARGET" in
    *.app)
        verify_app "$TARGET"
        ;;
    *.dmg)
        verify_dmg "$TARGET"
        ;;
    *)
        if [ -d "$TARGET" ] && [ "${TARGET##*.}" = "app" ]; then
            verify_app "$TARGET"
        elif [ -f "$TARGET" ]; then
            verify_dmg "$TARGET"
        else
            fail "Unsupported artifact type: $TARGET"
        fi
        ;;
esac

ok "Release artifact validation passed"
