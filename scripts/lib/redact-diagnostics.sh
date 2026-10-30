# shellcheck shell=bash
# Apply before persisting build/test output, not after a raw log has been saved.
speakflow_redaction_program='BEGIN { $| = 1; @private = grep { defined && length } @ENV{qw(SPEAKFLOW_SIGNING_IDENTITY SPEAKFLOW_TEAM_ID SPEAKFLOW_NOTARY_PROFILE SPEAKFLOW_UPDATE_PRIVATE_KEY_FILE)} } for my $value (@private) { s/\Q$value\E/<SIGNING_CONFIG>/g } s#/(?:Users|home)/[^/\s:]+#<HOME>#g; s#/(?:private/)?var/folders/[^\s:]+#<TEMP_PATH>#g; s/^.*Host environment:.*$/<HOST_CONTEXT_REDACTED>/; s/ :: macOS Version.*$/ :: <HOST_CONTEXT_REDACTED>/; s/\[\d+:\d+\]/[PID:TID]/g; s/\bProcess \d+/Process <PID>/g'
redact_diagnostics() { perl -pe "$speakflow_redaction_program"; }
# Replace the filtering process so its PID can be retired without orphaning Perl.
exec_redact_diagnostics() { exec perl -pe "$speakflow_redaction_program"; }
