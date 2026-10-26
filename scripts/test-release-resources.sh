#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.agents/tests"
FIXTURE="$(mktemp -d "$ROOT_DIR/.agents/tests/release-resources.XXXXXX")"
BIN="$FIXTURE/products"
DERIVED="$BIN/Fixture.build/DerivedSources"
APP="$FIXTURE/Fixture.app"
mkdir -p "$DERIVED" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BIN/Fixture.bundle" "$BIN/OtherDependency.bundle"
printf 'fixture' > "$BIN/Fixture.bundle/marker.txt"
printf 'dependency' > "$BIN/OtherDependency.bundle/marker.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIdentifier</key><string>com.example.fixture</string></dict></plist>
PLIST
cat > "$DERIVED/resource_bundle_accessor.swift" <<'SWIFT'
import Foundation
extension Foundation.Bundle {
    static var module: Bundle? {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("Fixture.bundle").path
        let buildPath = "/fixture/build/Fixture.bundle"
        return Bundle(path: mainPath) ?? Bundle(path: buildPath)
    }
}
SWIFT
cat > "$FIXTURE/main.swift" <<'SWIFT'
import Foundation
let bundle: Bundle? = Bundle.module
if let url = bundle?.url(forResource: "marker", withExtension: "txt"),
   (try? String(contentsOf: url, encoding: .utf8)) == "fixture" {
    print("PASS: packaged resource resolved without build checkout")
} else {
    print("FAIL: packaged resource lookup still depends on build checkout")
    exit(1)
}
SWIFT
swift "$ROOT_DIR/scripts/release-resources.swift" prepare "$BIN"
ln -s products "$FIXTURE/release"
if ! swift "$ROOT_DIR/scripts/release-resources.swift" package "$FIXTURE/release" "$APP"; then
    echo 'FAIL: resource packaging rejected the SwiftPM release symlink'
    exit 1
fi
[[ -f "$APP/Contents/Resources/OtherDependency.bundle/marker.txt" ]] || {
    echo 'FAIL: dependency resource bundle was not packaged'
    exit 1
}
if grep -q '/fixture/build' "$BIN/portable-resource-accessors/0.swift"; then
    echo 'FAIL: generated release accessor retains its build path'
    exit 1
fi
swiftc -vfsoverlay "$BIN/release-resources.json" "$DERIVED/resource_bundle_accessor.swift" "$FIXTURE/main.swift" -o "$APP/Contents/MacOS/Fixture"
"$APP/Contents/MacOS/Fixture"
