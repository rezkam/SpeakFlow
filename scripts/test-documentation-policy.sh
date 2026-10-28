#!/usr/bin/env bash
# Exercise the real repository policy, then a fresh index containing an extra doc.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.agents/tests"
FIXTURE="$(mktemp -d "$ROOT_DIR/.agents/tests/documentation-policy.XXXXXX")"
bash "$ROOT_DIR/scripts/check-documentation-consistency.sh"
echo 'PASS: protected regression matrix is allowed in the real repository'
mkdir -p "$FIXTURE/scripts" "$FIXTURE/docs"
cp "$ROOT_DIR/scripts/check-documentation-consistency.sh" "$FIXTURE/scripts/"
cp "$ROOT_DIR/README.md" "$FIXTURE/"
cp "$ROOT_DIR/docs/REGRESSION_TEST_MATRIX.md" "$FIXTURE/docs/"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" add README.md scripts docs
bash "$FIXTURE/scripts/check-documentation-consistency.sh"
printf 'unapproved\n' > "$FIXTURE/docs/unapproved.md"
git -C "$FIXTURE" add docs/unapproved.md
if bash "$FIXTURE/scripts/check-documentation-consistency.sh" > "$FIXTURE/output" 2>&1; then
    echo 'FAIL: unexpected tracked documentation was accepted'; exit 1
fi
grep -Fq 'docs/unapproved.md' "$FIXTURE/output"
echo 'PASS: unexpected tracked documentation remains rejected'
