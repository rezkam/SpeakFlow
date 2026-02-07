#!/usr/bin/env bash
set -euo pipefail

unset -f git 2>/dev/null || true

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild is required for UI E2E tests."
    exit 1
fi

XCODE_PROJECT="${SPEAKFLOW_XCODE_PROJECT:-SpeakFlow.xcodeproj}"
XCODE_SCHEME="${SPEAKFLOW_UI_TEST_SCHEME:-SpeakFlowUITests}"
DERIVED_DATA_PATH="${SPEAKFLOW_UI_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-derived}"
RESULT_BUNDLE_PATH="${SPEAKFLOW_UI_RESULT_BUNDLE_PATH:-$ROOT_DIR/.build/uitests.xcresult}"

if [ ! -d "$XCODE_PROJECT" ]; then
  cat <<'EOF'
Missing SpeakFlow.xcodeproj (or SPEAKFLOW_XCODE_PROJECT override).

One-time setup in Xcode:
1) Open this repository.
2) Add a macOS "UI Testing Bundle" target named SpeakFlowUITests.
3) Add files from UITests/.
4) Save the project as SpeakFlow.xcodeproj.
EOF
  exit 1
fi

xcodebuild \
    -project "$XCODE_PROJECT" \
    -scheme "$XCODE_SCHEME" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    test
