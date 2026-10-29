#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.agents/tests"
FIXTURE="${1:-$(mktemp -d "$ROOT_DIR/.agents/tests/portable-release.XXXXXX")}"
mkdir -p "$FIXTURE/Sources/SpeakFlow" "$FIXTURE/Fixture.app/Contents/MacOS"
cat > "$FIXTURE/Package.swift" <<'SWIFT'
// swift-tools-version:6.0
import PackageDescription
// A private-pattern synthetic rpath makes the privacy regression independent
// of where the selected Swift toolchain happens to be installed.
let package = Package(name: "Fixture", targets: [.executableTarget(
    name: "SpeakFlow", resources: [.copy("marker.txt")],
    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/home/fixture-toolchain/swift runtime"])])])
SWIFT
printf 'fixture' > "$FIXTURE/Sources/SpeakFlow/marker.txt"
cat > "$FIXTURE/Sources/SpeakFlow/main.swift" <<'SWIFT'
import Foundation
let url = Bundle.module.url(forResource: "marker", withExtension: "txt")!
if (try? String(contentsOf: url, encoding: .utf8)) == "fixture" {
    print("PASS: native SwiftPM resource resolved from packaged app")
} else { exit(1) }
SWIFT
cat > "$FIXTURE/Fixture.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>SpeakFlow</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIdentifier</key><string>com.example.fixture</string></dict></plist>
PLIST
(
    cd "$FIXTURE"
    bash "$ROOT_DIR/scripts/build-portable-release.sh"
    BIN="$(swift build -c release --show-bin-path)"
    swift "$ROOT_DIR/scripts/release-resources.swift" package "$BIN" "$FIXTURE/Fixture.app"
    cp "$BIN/SpeakFlow" "$FIXTURE/Fixture.app/Contents/MacOS/SpeakFlow"
)
bash "$ROOT_DIR/scripts/verify-artifact-privacy.sh" "$FIXTURE/Fixture.app"
mv "$FIXTURE/.build" "$FIXTURE/retired-build"
"$FIXTURE/Fixture.app/Contents/MacOS/SpeakFlow"
