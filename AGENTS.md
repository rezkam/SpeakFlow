# SpeakFlow Agent Guardrails

This file defines non-negotiable product behavior for any coding agent working in this repository.

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

1. Any change to core behavior requires tests in the same PR/patch.
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

## RC and Release

Use `scripts/build-release.sh` for both. Never publish without the user's go-ahead.

### Environment

- Signing env (`SPEAKFLOW_BUNDLE_ID`, `SPEAKFLOW_SIGNING_IDENTITY`, `SPEAKFLOW_TEAM_ID`,
  `SPEAKFLOW_NOTARY_PROFILE`) must be set. Never print or commit their values.
- `swift` on PATH must ship the `Testing` module (Xcode or a swift.org toolchain).
  Command Line Tools `/usr/bin/swift` fails with `no such module 'Testing'`.
- Run under bash 5, not `/bin/bash` 3.2. Do not wrap in `bash -lc`: a login shell can
  put 3.2 first, and `set -u` then breaks on empty arrays.
- Keep build output under `.agents/`: set `SPEAKFLOW_SWIFT_SCRATCH_PATH`,
  `SPEAKFLOW_OBSERVABILITY_DIR`, and `TMPDIR`, plus `SPEAKFLOW_ISOLATED_STORAGE=1`.

### RC

1. Build from a clean, pushed commit: `./scripts/build-release.sh rc`. It replaces
   `/Applications/SpeakFlow.app` and does not upload anything.
2. Confirm the installed app's `SpeakFlowBuildGitCommit` (Info.plist) is that commit.
3. The user tests the RC. Their confirmation is tied to that exact SHA.

### Release

1. Put the tested SHA on `main` unchanged: fast-forward with
   `git push origin <sha>:main`. GitHub merge buttons create a new SHA, which fails
   the tested-RC gate.
2. Pick the version with the user. CHANGELOG.md is not bumped per release, so pass it:
   `SPEAKFLOW_RELEASE_VERSION=X.Y.Z SPEAKFLOW_CONFIRMED_LOCAL_RC_TESTED_SHA=<sha> ./scripts/build-release.sh release --yes`
3. The script tests, builds, signs, notarizes, staples, publishes `vX.Y.Z` with the DMG,
   re-downloads and verifies it, then installs it.
4. Without a CHANGELOG section the notes read "See CHANGELOG.md". Replace them with
   `gh release edit vX.Y.Z --notes-file <file>` (Features and Fixes, user-facing).
5. The Homebrew tap updates the cask automatically. Check its `sha256` matches the DMG.

### Menu bar icon missing (macOS 26)

Control Center can file SpeakFlow under the app that launched it (for example a terminal
or agent app). If that app is not allowed in System Settings > Menu Bar, the icon is
hidden. Launch SpeakFlow from Finder or `open -a`. Check the
`com.apple.controlcenter:appStatusItems` log for "Moving host to blocked list".
