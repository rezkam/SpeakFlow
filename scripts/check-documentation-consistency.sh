#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
README="$ROOT_DIR/README.md"
SPEC="$ROOT_DIR/docs/CURRENT_FEATURE_SPEC.md"
errors=0

fail() {
  printf 'Documentation consistency error: %s\n' "$*" >&2
  errors=1
}

require_readme() {
  local text=$1
  grep -Fq -- "$text" "$README" || fail "README.md must state: $text"
}

reject_readme() {
  local pattern=$1
  local description=$2
  if grep -Ein -- "$pattern" "$README"; then
    fail "README.md contains stale claim: $description"
  fi
}

if [[ -n "$(git -C "$ROOT_DIR" ls-files docs)" ]]; then
  fail "docs/ must contain only ignored local documentation; remove tracked docs files with git rm --cached."
fi

reject_readme 'Accounts(\*\*)?[[:space:]]+tab' 'Accounts tab (plain or Markdown-emphasized)'
reject_readme 'Whisper API' 'Whisper API'
reject_readme 'monolingual' 'Deepgram monolingual support'
reject_readme 'streaming mode.*off by default' 'streaming auto-end off by default'
reject_readme '(defaults? to|after) 5\+? seconds' 'five-second auto-end default or pipeline threshold'
reject_readme '(defaults? to|after) 5s' 'five-second auto-end default or pipeline threshold'

require_readme 'Providers tab'
require_readme 'enabled by default in both streaming and batch modes'
require_readme 'shared silence duration defaults to 10 seconds and is configurable from 1–30 seconds'
require_readme 'with the selected language'
require_readme 'ChatGPT transcription backend (GPT-4o Transcribe)'
require_readme 'configured silence duration (default 10 seconds)'

if [[ -e "$SPEC" ]]; then
  if grep -Ein -- 'focusWaitTimeout.*default 5m|default 5m.*focusWaitTimeout' "$SPEC"; then
    fail "docs/CURRENT_FEATURE_SPEC.md contains stale focusWaitTimeout default 5m claim"
  fi
  grep -Fq -- 'focusWaitTimeout` (default 60s, configurable, minimum 10s)' "$SPEC" \
    || fail "docs/CURRENT_FEATURE_SPEC.md must state focusWaitTimeout default 60s and minimum 10s"
fi

if (( errors )); then
  exit 1
fi

printf 'Documentation consistency check passed.\n'
