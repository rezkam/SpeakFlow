#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
args=(-c release --product SpeakFlow --disable-local-rpath
      -Xlinker -rpath -Xlinker @executable_path/../Frameworks
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
# Materialize the load commands before mutating the executable. Fail closed if
# inspection fails, rather than hiding a producer failure in process substitution.
LOAD_COMMANDS="$(otool -l "$BINARY")"
rpath=false
# Parse in the shell, independent of the awk implementation selected by PATH.
# read trims otool's indentation, while the capture preserves spaces in paths.
while read -r line; do
    case "$line" in
        'cmd LC_RPATH') rpath=true ;;
        cmd\ *) rpath=false ;;
        path\ *)
            if [[ "$rpath" == true ]]; then
                [[ "$line" =~ ^path\ (.*)\ \(offset\ [0-9]+\)$ ]] || {
                    echo 'FAIL: malformed LC_RPATH load command' >&2; exit 1;
                }
                path="${BASH_REMATCH[1]}"
                case "$path" in
                    /Users/*|/home/*|/private/var/folders/*|/var/folders/*)
                        install_name_tool -delete_rpath "$path" "$BINARY" ;;
                esac
                rpath=false
            fi ;;
    esac
done <<< "$LOAD_COMMANDS"
# Keep the CLI executable runnable after modifying signed Mach-O load commands.
# The app receives its Developer ID signature later in the packaging flow.
codesign --force --sign - "$BINARY"
