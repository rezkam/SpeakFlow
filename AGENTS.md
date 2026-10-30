# SpeakFlow Agent Guardrails

This file defines non-negotiable product behavior for any coding agent working in this repository.

## Commit Signing

Every commit must be cryptographically signed and verified by GitHub. Keep `commit.gpgsign`
enabled and use `git commit -S`. Re-sign commits created by rebases, cherry-picks, or amendments.
Never bypass the repository's required-signature rule.

## Prime Directive

Do not silently remove, weaken, or bypass core product behavior.

If you optimize/refactor and behavior changes, that is a regression unless:

1. The user explicitly requested the behavior change.
2. Matching tests/docs are updated in the same change with clear rationale.

## Core Feature Contracts (Do Not Regress)

These are protected product contracts mapped to regression suites.

1. Dictation readiness contract
- Dictation availability must correctly reflect permission state + provider configuration.
- Covered by: `DictationReadinessTests`, `ProviderReadinessTests`, `AppStateTests`.

2. Hotkey activation contract
- Hotkey detection and keyboard control behavior must remain correct and deterministic.
- Covered by: `HotkeyListenerTests`, `HotkeyTests`, `RecordingControllerTests`.

3. Recording lifecycle contract
- Start/stop/cancel semantics must remain correct for batch + streaming paths.
- Covered by: `RecordingControllerTests`, `StreamingRecordingTests`.

4. Enter submission contract
- While recording in the originally captured app, the first Enter press must:
  stop transcription immediately, flush remaining final text, then synthesize one Enter.
- Enter capture is one-shot per recording lifecycle; second Enter must pass through normally.
- If focus is not in the originally captured app, Enter must not be captured.
- Escape cancels the active recording from any app (the press is consumed);
  modified Escape passes through.
  The originally captured app includes its helper processes and a relaunched
  instance (same rule as focus-safe insertion).
- Enter or Escape held with Shift, Option, Command, or Control is not captured
  and does not consume the one-shot token; it passes through to the app.
- A swallowed Enter or Escape is never lost: stopping interception delivers it,
  cancelling interception discards it, and a cancel never turns into a submit.
- The key tap runs on its own thread, and each stop invalidates its tap.
- Every stop and cancel records tap vs system keyDown counts; keys the tap
  missed must leave a warning with the secure-input holder.
- Submit ordering must remain correct relative to pending text insertion.
- Covered by: `EnterSubmissionContractTests`, `KeyInterceptorEnterCaptureTests`,
  `KeyInterceptorRegistrationTests`, `HotkeyListenerRegistrationTests`.

5. Focus-safe insertion contract
- Text must target the originally captured app/field.
- If focus changes (app switch, overlay, popup, another field or conversation
  in the same app), typing must pause.
- Never follow focus into a new app during the same dictation session.
- If no target can be captured at start, recording does not start and no
  synthetic input is ever sent (fail closed).
- Cancel and reset retire every queued insertion, not only the newest one.
- Covered by: `TextInserterFocusTests`, `TextInserterCancellationTests`,
  `TextInserterFieldIdentityTests`, `RecordingControllerTargetCaptureTests`.

5a. Batch insertion contract
- Batch results default to bounded Unicode text bursts without clipboard access or per-character playback delays.
- Users can enable Type batch results to use existing simulated typing instead.
- Streaming interim text and corrections keep their existing typing path regardless of this setting.
- Bulk insertion retains captured-field focus, modifier, queue ordering, and recording cancellation checks.
- Missing targets or interrupted event posting show an error, stop further bulk delivery, and withhold submit Enter.
- Covered by: `BatchInsertionSettingsTests`, `BatchInsertionRoutingTests`, `TextInserterBulkTests`, `BatchInsertionNativeTests`.

6. Modifier-safe typing contract
- Never synthesize text while `Command`, `Control`, `Option`, or `Shift` is active.
- Prevent accidental shortcut combos from generated typing (for example `Cmd+Q`).
- Covered by: `TextInserterModifierSafetyTests`.

7. No focus stealing contract
- Do not steal/force focus to inject text.
- Focus recovery must be user-driven (wait until user returns).
- Covered by: `TextInserterFocusTests`.

8. VAD and chunk gating contract
- VAD state machine, smoothing, drift reset, and silence gating behavior must hold.
- Covered by: `VADStateMachineTests`, `VADIntegrationTests`, `VADTests`.

9. Session auto-end + thinking pause contract
- Auto-end timing and silence boundaries must remain correct.
- Thinking-pause detection behavior must remain correct.
- Covered by: `SessionControllerTests`, `SettingsAutoEndTests`, `ThinkingPauseDetectorTests`.

10. Live streaming reliability contract
- keepAlive, reconnect flow, and backpressure/ordering resilience must hold.
- Covered by: `LiveStreamingKeepAliveTests`, `WebSocketSessionContractTests`, `WebSocketReconnectIntegrationTests`, `CorrectnessTests`, `AudioPipelineTests`.

11. Streaming final-commit safety contract
- Short non-terminal streaming finals must not be committed prematurely.
- `speechFinal` and punctuated short commands must still commit.
- Covered by: `AudioPipelineTests` (LiveStreaming event handling).

12a. Recording identity contract
- Callbacks, chunks, queued text, and finalization belong to the recording
  that produced them; late work from a stopped, cancelled, or replaced
  recording never acts on the current one.
- Finalization owns its submit Enter and cleanup until both are done.
- Cancelled audio is discarded before anything can emit it for upload.
- Covered by: `RecordingControllerSessionIdentityTests`,
  `TranscriptionQueueSessionDeliveryTests`, `StreamingRecorderCancelDiscardTests`.

12. Transcription ordering contract
- Ordered delivery and completion semantics must remain correct.
- Covered by: `TranscriptionQueueTests`, `TranscriptionTests`.

13. Provider protocol/API contract
- Deepgram + Mistral message parsing and protocol behavior must remain compliant.
- Covered by: `WebSocketSessionContractTests`, `DeepgramSessionTests`, `MistralSessionTests`, `MistralBatchProviderTests`, `MistralRealtimeRegressionTests`.

14. Auth/OAuth safety contract
- Auth flows, callback handling, and token lifecycle behavior must remain safe.
- Covered by: `AuthTests`, `AuthControllerDITests`.

15. Performance-sensitive audio contract
- Performance-critical audio conversion/processing invariants must be preserved.
- Covered by: `PerformanceOptimizationTests`.

16. Metrics and latency observability contract
- STT latency must be recorded, and per-session metrics must remain collectable.
- Usage statistics must preserve daily, weekly, monthly, and yearly period buckets for totals, provider breakdowns, language breakdowns, and latency summaries.
- Covered by: `StatisticsTests`, `SessionMetricsStoreTests`, `ObservabilityTests`, `TranscriptionTests`.

17. Test UX safety contract
- Automated tests must run muted by default (no UX sounds).
- Covered by: `SoundEffectTests` and test scripts using `SPEAKFLOW_MUTE_SOUNDS=1`.

18a. Credential safety contract
- Logout is final: a refresh or login exchange that started earlier never
  restores credentials. Credential write failures are reported, and an
  unreadable credential file is never overwritten.
- Covered by: `CredentialStorageTests`, `AuthControllerCredentialFailureTests`,
  `HTTPDataProviderTestabilityTests`.

18. Test/runtime isolation contract
- Test runs must not pollute installed-app data paths or steal live user capture resources by default.
- UI-test launches and test executables use isolated storage too
  (`RuntimeIsolation`).
- Covered by: `ArchitectureTests`, `ObservabilityTests`, `StreamingRecordingTests`,
  `RuntimeIsolationTests`.

19. Menu bar residency contract
- Closing the control panel through the window close button, `Command-Q`, the control-panel menu action, or Dock Quit must keep the app and menu bar item running.
- Shutdown, restart, logout, and system-wide Quit All must still terminate normally.
- Covered by: `AppLifecycleTests`.

## Regression Gates

Mandatory gates for core behavior:

1. `make test-regression-core`
2. `swift test`

When touching insertion/focus/submit behavior, run at minimum:

- `swift test --filter TextInserterFocusTests`
- `swift test --filter TextInserterModifierSafetyTests`
- `swift test --filter EnterSubmissionContractTests`
- `swift test --filter SoundEffectTests`

When touching transcription/metrics behavior, run at minimum:

- `swift test --filter TranscriptionTests`
- `swift test --filter StatisticsTests`
- `swift test --filter SessionMetricsStoreTests`
- `swift test --filter ObservabilityTests`

### Main Regression-Core Suite Set (Must Stay Intact)

These suite filters define the main-feature safety net and must not be removed without replacement:

- `DictationReadinessTests`
- `ProviderReadinessTests`
- `AppStateTests`
- `AppLifecycleTests`
- `HotkeyListenerTests`
- `HotkeyListenerRegistrationTests`
- `HotkeyTests`
- `PermissionControllerDITests`
- `AuthControllerDITests`
- `RecordingControllerTests`
- `StreamingRecordingTests`
- `EnterSubmissionContractTests`
- `KeyInterceptorEnterCaptureTests`
- `KeyInterceptorRegistrationTests`
- `TextInserterFocusTests`
- `TextInserterModifierSafetyTests`
- `SoundEffectTests`
- `SessionControllerTests`
- `SettingsAutoEndTests`
- `ThinkingPauseDetectorTests`
- `VADStateMachineTests`
- `VADIntegrationTests`
- `VADTests`
- `LiveStreamingKeepAliveTests`
- `WebSocketSessionContractTests`
- `WebSocketReconnectIntegrationTests`
- `CorrectnessTests`
- `AudioPipelineTests`
- `TranscriptionQueueTests`
- `TranscriptionTests`
- `StatisticsTests`
- `SessionMetricsStoreTests`
- `ObservabilityTests`
- `AuthTests`
- `DeepgramSessionTests`
- `MistralSessionTests`
- `MistralBatchProviderTests`
- `MistralRealtimeRegressionTests`
- `PerformanceOptimizationTests`

## Agent Change Policy

1. Any change to core behavior requires tests in the same commit or patch.
2. Do not delete/disable regression suites to get green CI.
3. Do not narrow assertions to hide regressions.
4. If a new core feature is added, add regression tests and update:
- `docs/REGRESSION_TEST_MATRIX.md`
- `scripts/test-regression-core.sh` (when it is part of the main feature gate)
- this `AGENTS.md` contract list

## High-Risk Files

- `Sources/App/TextInserter.swift`
- `Sources/App/KeyInterceptor.swift`
- `Sources/App/RecordingController.swift`
- `Sources/SpeakFlowCore/Audio/StreamingRecorder.swift`
- `Sources/SpeakFlowCore/VAD/SessionController.swift`
- `Sources/SpeakFlowCore/VAD/VADProcessor.swift`
- `Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift`
- `Sources/SpeakFlowCore/Providers/LiveStreamingController.swift`
- `Sources/SpeakFlowCore/Providers/DeepgramProvider.swift`
- `Sources/SpeakFlowCore/Providers/MistralProvider.swift`
- `Sources/SpeakFlowCore/Providers/WebSocketSessionCore.swift`
- `Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift`
- `Sources/SpeakFlowCore/SoundEffect.swift`
- `Tests/TextInserterFocusTests.swift`
- `Tests/TextInserterModifierSafetyTests.swift`
- `Tests/EnterSubmissionContractTests.swift`
- `docs/REGRESSION_TEST_MATRIX.md`

## Development and Delivery

- Develop in an isolated Git worktree on a development branch. Keep the primary checkout
  available for the user and preserve unrelated work.
- This repository does not use pull requests. Do not create a PR or require PR readiness
  as part of delivery. Generic PR workflows do not apply here.
- Commit only the requested change and its necessary tests and documentation.
- Develop and finalize a local RC first. Agents may run automated, native UI, and live
  checks when authorized, and must honor user instructions to skip testing.
- The user performs the final RC test and confirms both the exact tested commit and the
  release version. Agent verification does not replace this final user approval.
- After the user approves the RC, version, and release notes, push the tested commit
  directly to remote `main` with a fast-forward. Do not create a merge commit, use a PR
  merge flow, or rewrite the tested commit.
- Create the release version and tag from that same user-tested commit. If application
  changes are needed afterward, build a new RC and obtain a new user confirmation.

## Local model consent and readiness

- Startup, warm-up, recording, retry and regression gates never download model assets.
- Initialize the library offline guard once before any loader starts. Never disable it for installation.
- Only an explicit confirmation of the exact immutable manifest authorizes the independent installer.
- Verify app-owned receipts, file sizes and hashes before local loading. External caches are not adopted.
- Missing or corrupt required VAD blocks affected recording with actionable guidance. No silent fallback.
- Core regression verifies a previously approved installation and fails if it is missing on supported hardware.
- CI uses the approved Silero fixture in `Tests/Fixtures/SileroVAD`, excluded from SwiftPM targets and app packaging. Gates verify this checked-in fixture offline and never provision model files.
- Transfer and integrity verification use bounded app-managed buffers. Cancellation retains only inert partial files.
- The bundled ASR catalog contains only reviewed immutable exports with complete download totals.
- The release offers Parakeet 0.6B v2 batch and Nemotron 1120 ms streaming. Parakeet 110M is retired; a saved retired selection stays unavailable until the user explicitly loads a replacement.
- Local ASR configuration explicitly requests CPU plus Neural Engine; conflicting library overrides fail visibly.
- Local engines serialize inference. Recording leases outlive native session closure and protect finalization; cancelled or timed-out native work cannot reselect a model or release an engine still in use.
- Startup keeps speech and VAD cold unless preload is explicitly enabled. Batch preload requires VAD readiness first. Both caches honor the configured idle interval.
- Memory pressure releases idle handles without deleting weights or interrupting active leases. Sleep cancels local capture and insertion; wake never resumes them automatically.
- A local streaming backlog fails visibly at the existing bounded queue limit. Never silently discard local audio or submit after a local inference failure.
- Upstream checks are manual metadata only. Only bundled reviewed manifests authorize installations or compatible retained-version rollback. A changed source SHA never activates itself.
- Named partial cleanup and installation removal require current exact-target confirmation; changed measured targets and symbolic links are refused. Other revisions and shared VAD remain untouched.
- Local batch producers await inference and serialize timer/VAD emissions. Stop waits for any active emission before draining its final audio. Short nonempty Parakeet tails receive silence padding to the SDK minimum without changing captured duration. Covered by `LocalBatchDeliveryTests`.
- Local batch inference rejects overlapping requests instead of retaining an unbounded audio backlog. Capture overflow, inference failure and local finalization deadlines cancel delivery and withhold submit.
- Exact revisions cannot reuse another revision's resident engine. Replacement is blocked during active leases or native jobs.
- Covered by `LocalRecordingPreparationTests`, `KeyInterceptorPendingTests`, `LocalModelsControllerTests`, `LocalModelSelectionTests`, `LocalModelVersionTests`, `VADInstallControllerTests`, `LocalModelRemovalTests`, `LocalModelResourceMonitorTests` and `LocalStreamingReliabilityTests`.
- Covered by `LocalSpeechRuntimeTests` and `LocalSpeechProviderTests`. Real installed-engine probes are opt-in and never provision assets.
- Covered by `LocalSpeechCatalogTests`, `LocalSpeechAccelerationTests`, `LocalVADConsentTests`, `LocalVADReadinessTests`, `ExplicitModelInstallerTests`,
  `ModelArtifactFileTests`, `ModelArtifactTransportTests`, `LocalModelManifestTests`, `VADModelVerificationTests`, `VADModelCacheTests` and `ModelsScreenTests`.

## RC and Release

Use `scripts/build-release.sh` from the repository root. During active development,
building, signing with the configured identity, replacing, installing, and opening a local RC
are authorized without asking again. Publication requires the user's final RC confirmation
and approval of the release version and notes. Do not publish before that approval.

- Put Bash 5 and a Swift toolchain supporting `Testing` and CryptoKit on PATH.
  Invoke `bash scripts/build-release.sh`, not the script's `/bin/bash` shebang or a login shell.
- Set `SPEAKFLOW_BUNDLE_ID`, `SPEAKFLOW_SIGNING_IDENTITY`, and `SPEAKFLOW_TEAM_ID`.
  Release also requires `SPEAKFLOW_NOTARY_PROFILE`, `SPEAKFLOW_UPDATE_PUBLIC_KEY`, and
  `SPEAKFLOW_UPDATE_PRIVATE_KEY_FILE`. Reuse the established signing identity and updater keys;
  never print or commit their values or the private key.
- Set `SPEAKFLOW_SWIFT_SCRATCH_PATH` and `SPEAKFLOW_OBSERVABILITY_DIR` under `.agents/`,
  plus `SPEAKFLOW_ISOLATED_STORAGE=1`. The script keeps stage logs and temporary resources under `.agents/`, redacts diagnostics
  before persistence, and writes `SpeakFlow.app` and `SpeakFlow.dmg` in the worktree root.

### RC

1. Commit the changes locally, then run `bash scripts/build-release.sh rc` from that clean
   commit. Pushing is not required. Use `rc --skip-tests` only when the user explicitly asks to
   skip tests; the flag is rejected for other modes. RCs are signed and installed locally, never notarized
   or published, and have updates disabled.
2. Confirm the installed `SpeakFlowBuildGitCommit`. Agents may verify behavior and visual
   consistency before handoff, subject to the user's testing instructions. Report checks
   actually performed and any verification left to the user.
3. Ask the user to try the installed RC and choose the release version. Their confirmation
   applies to that exact SHA. Keep that commit unchanged for publication.

### Release

1. Obtain the user's final confirmation of the tested RC, release version, and release notes.
   Add a matching CHANGELOG section before the final RC if notes must appear in-app;
   otherwise the feed uses "See CHANGELOG.md" and GitHub notes can be supplied separately.
2. Fast-forward remote `main` directly to the tested SHA with `git push origin <sha>:main`.
   Do not open or merge a PR. If `main` has diverged, reconcile in a development worktree,
   rebuild the RC, and obtain user confirmation of the new commit before proceeding.
3. From that clean, pushed SHA, run:
   `SPEAKFLOW_RELEASE_VERSION=X.Y.Z SPEAKFLOW_CONFIRMED_LOCAL_RC_TESTED_SHA=<sha> bash scripts/build-release.sh release --yes`
   `--yes` skips script prompts, not user approval. Release signs, notarizes, staples, publishes
   the DMG and appcast, verifies the downloaded artifact, and installs it locally.
4. Verify the Homebrew tap workflow succeeded and its version and checksum match the release.
   Editing GitHub notes afterward does not change the appcast's in-app notes.

### Menu bar icon missing (macOS 26)

Treat this as a recurring development-launch issue. Do not ask the user to rediscover
these steps or assume the app's own enabled toggle proves its icon is visible.

Control Center can associate SpeakFlow's status item with its launcher, including Codex
or Ghostty. A blocked launcher can hide the icon even when SpeakFlow's standalone
registration is allowed. Compiling alone is not evidence of the cause; inspect the
stored associations and runtime logs.

#### Diagnose from configuration first

1. Identify the running executable and derive its bundle identifier from the installed
   app's `Contents/Info.plist`. Check for additional running instances and installed or
   development copies. Prefer `/Applications/SpeakFlow.app` as the installed app; do not
   remove build copies, test preferences, or app bundles without specific approval.
2. Inspect the app's `NSStatusItem VisibleCC Item-0` preference, but do not stop there.
   The authoritative association store is
   `$HOME/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`.
   Its `trackedApplications` value is Data containing a nested binary property list,
   not JSON. Decode it with Foundation's `PropertyListSerialization`.
3. Find every reference to the derived bundle identifier, especially inside
   `menuItemLocations` on records whose `location` belongs to another app. Check Codex,
   Ghostty, other development launchers, and any ad-hoc executable registrations.
   Compare nearby `.bak-*` files read-only if a prior repair is relevant.
4. A standalone bundle identity record and its separate allowed location record are
   normal, not duplicate apps. The desired state is one standalone SpeakFlow ownership
   registration with `isAllowed = true`, without SpeakFlow listed under launchers.
   Do not collapse the store into one raw record.

#### Targeted repair

1. Explain the exact launcher associations found and obtain approval before removing
   them. Obtain permission for a timestamped backup of the current plist, which may
   contain local paths. Preserve existing backups; never restore an entire old backup
   over the current settings just to repair SpeakFlow.
2. Remove only SpeakFlow's entry from the approved launchers' `menuItemLocations` arrays.
   Preserve each launcher's permission, other menu items, unrelated records, and the
   standalone allowed SpeakFlow registration. Do not enable the launcher globally.
   An empty launcher menu-item array can remain; deleting the launcher is unnecessary.
3. Serialize the updated nested array back to binary-plist Data. Update only
   `trackedApplications` using a preferences-aware write, such as `defaults write` with
   the plist path (without `.plist`) and `-data` containing the serialized hex bytes.
   Avoid a raw on-disk edit that the preferences cache may overwrite.
4. Restart `ControlCenter` to reload its associations. Re-read and decode the live
   plist afterward: the approved launcher references must be absent, SpeakFlow's own
   registration must remain allowed, and unrelated settings must be unchanged.
   Control Center may reorder records on reload; compare their contents as a multiset,
   not by array index, while still checking that no records were added or lost.
5. Inspect `com.apple.controlcenter:appStatusItems` logs for SpeakFlow being unblocked
   and added to displayable items, rather than "Moving host to blocked list". If the
   user requested config-only inspection, respect that boundary and report visual
   visibility as unverified instead of claiming the icon is visible.

#### Prevent recurrence during development

Launch the installed app through Finder or Launch Services (`open -a SpeakFlow`), not by
executing a build binary directly from a development launcher. Keep one intended running
instance. After installing or launching an RC, repeat the association check before
handoff; Launch Services alone is not proof that ownership stayed correct. If stale
launcher ownership returns, report it and apply the targeted repair only with the
required approval. Never silently delete registrations or unrelated app copies.
