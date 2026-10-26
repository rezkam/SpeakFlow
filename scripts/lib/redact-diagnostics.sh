# shellcheck shell=bash
# Apply before persisting build/test output, not after a raw log has been saved.
redact_diagnostics() {
    perl -pe 'BEGIN { $| = 1 } s#/(?:Users|home)/[^/\s:]+#<HOME>#g; s#/(?:private/)?var/folders/[^\s:]+#<TEMP_PATH>#g; s/^.*Host environment:.*$/<HOST_CONTEXT_REDACTED>/; s/ :: macOS Version.*$/ :: <HOST_CONTEXT_REDACTED>/; s/\[\d+:\d+\]/[PID:TID]/g; s/\bProcess \d+/Process <PID>/g'
}
