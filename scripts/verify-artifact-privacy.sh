#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --files || "${1:-}" == --links ]]; then
    mode="$1"
    shift
    for file in "$@"; do
        status=0
        if [[ "$mode" == --links ]]; then
            target="$(readlink "$file" 2>/dev/null)" || { echo 'FAIL: artifact cannot be scanned'; exit 1; }
            printf '%s' "$target" | LC_ALL=C grep -aqE '/Users/|/home/|/(private/)?var/folders/' || status=$?
        else
            LC_ALL=C grep -aqE '/Users/|/home/|/(private/)?var/folders/' -- "$file" 2>/dev/null || status=$?
        fi
        case "$status" in
            0) echo 'FAIL: artifact contains a private filesystem path'; exit 1 ;;
            1) ;;
            *) echo 'FAIL: artifact cannot be scanned'; exit 1 ;;
        esac
    done
    exit 0
fi
[[ $# == 1 && -d "$1" ]] || { echo 'FAIL: expected an artifact directory'; exit 1; }
first="$(find "$1" -type f -print -quit 2>/dev/null)" || { echo 'FAIL: artifact cannot be scanned'; exit 1; }
[[ -n "$first" ]] || { echo 'FAIL: artifact is empty'; exit 1; }
find "$1" -type f -exec bash "$0" --files {} + 2>/dev/null || {
    echo 'FAIL: artifact privacy scan failed'
    exit 1
}
find "$1" -type l -exec bash "$0" --links {} + 2>/dev/null || {
    echo 'FAIL: artifact privacy scan failed'
    exit 1
}
echo 'PASS: artifact contains no private filesystem paths'
