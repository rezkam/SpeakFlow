#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
args=(-c release --product SpeakFlow --disable-local-rpath
      -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
      -Xcc "-ffile-prefix-map=$PWD=." "$@")
BIN="$(swift build "${args[@]}" --show-bin-path)"
OVERLAY="$BIN/release-resources.json"
mkdir -p "$BIN"
printf '{"version":0,"roots":[]}' > "$OVERLAY"
args+=(-Xswiftc -vfsoverlay -Xswiftc "$OVERLAY")
# SwiftPM can regenerate accessors during planning. Override compiler input,
# rather than modifying generated files or dependency sources in place.
swift build "${args[@]}" --print-manifest-job-graph >/dev/null
swift "$SCRIPT_DIR/release-resources.swift" prepare "$BIN"
swift build "${args[@]}"
BINARY="$BIN/SpeakFlow"
strip -S "$BINARY"
while IFS= read -r path; do
    case "$path" in
        /Users/*|/home/*|/private/var/folders/*|/var/folders/*)
            install_name_tool -delete_rpath "$path" "$BINARY"
            ;;
    esac
done < <(otool -l "$BINARY" | awk '
    /cmd LC_RPATH/ { rpath = 1; next }
    rpath && /^[[:space:]]*path / {
        sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0
    }')
# Keep the CLI executable runnable after modifying signed Mach-O load commands.
# The app receives its Developer ID signature later in the packaging flow.
codesign --force --sign - "$BINARY"
