# Review regression coverage

The core gate retains its existing suite list and includes these additional regressions.
Run `make test-regression-core` and the serialized full suite with muted, isolated audio.

| Contract | Coverage |
| --- | --- |
| Batch results default to bounded Unicode bursts; paced typing is optional; streaming routing stays unchanged; interrupted posting withholds submit | `BatchInsertionSettingsTests`, `BatchInsertionRoutingTests`, `TextInserterBulkTests` |
| Corrections use successfully posted text, including queue rejection and partial typing/deletion | `StreamingTextDeliveryTests` |
| Original-field evidence is required for text, deletion, and Enter | `TextInserterFieldIdentityTests` |
| Prewarm accessibility off the main actor on app activation; request Electron's manual accessibility API; capture only at the hotkey and reject missing targets/app switches | `ApplicationAccessibilityPreparationTests`, `TextInserterTargetCaptureTests` |
| Batch deadline retires delivery before submit finishes | `RecordingCrossModeTests` |
| Stop remains cancellable; finalization is exclusive; deferred errors retain recording identity | `RecordingControllerSessionIdentityTests` |
| Retired tap callbacks cannot consume a new registration | `KeyInterceptorRegistrationTests` |
| Helpers and relaunches require canonical application ownership, not bundle-ID spelling | `TextInserterApplicationMatchingTests`, `KeyInterceptorRegistrationTests` |
| Incoming tap events remain borrowed | `BorrowedEventOwnershipTests` |
| Combination hotkeys use local and global monitoring, with repeat suppression and cleanup | `HotkeyLocalMonitorTests`, `HotkeyNativeMonitorTests` |
| Credentials retain snapshot generation and token/account identity; terminal rejection is nonretryable | `HTTPDataProviderTestabilityTests` |
| Key removal retires held validation; logout retires held browser attempts | `ProviderKeyValidationTests`, `AuthControllerDITests` |
| Stale sends and handshakes cannot reactivate or disable replacement connections | `StreamingConnectionIdentityTests` |
| Deferred timed segments accumulate without duplicating overlapping revisions | `EventHandlingTests` |
| Graceful finalize, close, and cancellation have deadlines; terminal receives dispose transport once | `GracefulControlDeadlineTests`, `WebSocketSessionContractTests` |
| Batch audio respects provider byte ceilings and preserves established short tails | `StreamingRecorderSendChunkIfReadyPeriodicCheckTests`, `StreamingRecorderStopCancelTests` |
| Silence-only chunks preserve the auto-end clock | `SessionControllerTests` |
| Readiness follows successful asynchronous capture startup | `RecordingControllerSessionIdentityTests` |
| Stop drains filtered, model-sized frames; cancellation discards queued audio | `StreamingRecorderStopCancelTests`, `StreamingRecorderCancelDiscardTests` |
| Validation and permission tests use injected network and trust boundaries | `MistralSharedValidationTests`, `PermissionControllerDITests` |
| Harness keyboard and button routes reach the recording owner | `UITestHarnessTests` |
| Idle feedback uses the central mute-aware sound policy | `RecorderIdleFeedbackTests`, `SoundEffectTests` |
| Realtime language is automatic while Batch language remains editable | `TranscriptionLanguagePickerTests` |
| Live runners isolate stores and fail closed on missing fixtures or assertions | `RegressionScriptTests`, offline shell contract probes |
| Packaged resources resolve without the build checkout; private paths and scan errors block publication | `RegressionScriptTests`, `ReleaseDependencyTests`, native SwiftPM packaging probe |

## Provider timing

Privacy-safe batch attempt outcomes, local phases, missing network milestones, and actual
URLSession transaction metrics are covered by `ProviderTimingTests`, `HTTPPhaseMetricsTests`,
and `ProviderTimingTransportTests`. These suites are included in the core gate.
`TranscriptionTests` also verifies original-session/request correlation across replacement.
The network fixture binds only to loopback and never uses live providers or credentials.

## Native UI probes

Native UI suites are opt-in and run in isolated child processes:

```sh
SPEAKFLOW_RUN_UI_PROBES=1 SPEAKFLOW_MUTE_SOUNDS=1 SPEAKFLOW_ISOLATE_TEST_AUDIO=1 \
  swift test --no-parallel --filter 'ProviderKeyValidationTests|TranscriptionLanguagePickerTests|UITestHarnessTests|HotkeyNativeMonitorTests|TextInserterNativeEditorTests'
```

These probes render synthetic controls and dispatch synthetic input locally. They do not
record microphone audio, contact providers, or use installed-app storage. Real microphone
capture, live provider interoperability, and audible sound quality require separate opt-in
verification. Streaming insertion retains the 0.8.4 posted-key behavior: absent or stale accessibility text does not block live typing. The stricter per-character text/caret acknowledgement policy was removed because it caused first-character truncation in supported editors. Focus identity, modifier checks, recording generation, queued final delivery, and Enter ordering remain enforced. `TextInserterOwnershipTests` covers stale or absent accessibility values, clearing completed text, Unicode corrections, focus changes, cancellation, and withheld Enter after incomplete posting. Posted keys do not prove application consumption. Same-field manual caret moves or edits during an interim correction are not protected by content ownership checks.

`TextInserterNativeEditorTests` opens a synthetic AppKit editor and checks actual native corrections and continued typing after clearing through a local event adapter. It does not test WindowServer delivery or cross-process accessibility. Final-event timeout submission protection is covered by `StreamingEventDrainTests`.

`BatchInsertionNativeTests` verifies selection replacement in an AppKit editor using the
batch Unicode event payload through a local event adapter. Run it with
`SPEAKFLOW_RUN_UI_PROBES=1 swift test --no-parallel --filter BatchInsertionNativeTests`.
The batch path never accesses the clipboard or requires readable/writable Accessibility
text and selection attributes. It posts Unicode text in bounded bursts without the
per-character delay. Focus and modifier checks still gate each burst, cancellation retires
queued work, and interrupted posting withholds submit Enter. Embedded newlines are not
mapped to synthetic Return keys. The typing toggle retains the original paced path.
Streaming behavior is unchanged. Posted events do not prove target application consumption;
cross-process compatibility requires manual validation in the target editor or terminal.

## Explicit local model installation

`LocalVADConsentTests` verifies that missing assets explain installation and corrupt VAD
refuses capture. `LocalVADReadinessTests` distinguishes batch VAD dependencies from cloud
streaming endpointing. `VADInstallControllerTests` rejects stale availability checks.
`LocalModelManifestTests` verifies root and nested export paths, exact repository components,
reserved receipts and file-directory collisions on case-insensitive storage.
`LocalSpeechCatalogTests` verifies the two reviewed English exports (Parakeet 0.6B v2 batch and
Nemotron 1120 ms streaming), complete byte totals, strict catalog membership and rejection of
the retired Parakeet 110M identifier. Runtime and controller fixtures use the remaining models
for selection, load failure and lease coverage. `LocalSpeechAccelerationTests` checks the explicit CPU plus Neural Engine
configuration and rejects conflicting library compute overrides, including under CI.
`ExplicitModelInstallerTests` covers verified installation of both export layouts, denied or changed consent,
checksums, receipts, unsafe paths, symlinks, cancellation and insufficient storage.
`ModelArtifactFileTests` covers streamed SHA-256 and Git blob verification, changed tails,
size mismatches, symlinks and LFS stubs. `ModelArtifactTransportTests` checks incremental disk
progress, oversized and truncated bodies, redirect rejection before following, HTTP failures,
existing-file preservation and cancellation of a stalled transfer. Cancelled installations retain
inert partials without publishing a receipt or usable destination. Installation exposes separate
download, verification and preparation phases.

`LocalSpeechRuntimeTests` covers idle residency, exact selection, last-lease release, expired
work, non-cooperative load cancellation and timeout, cleanup exclusion and serialized inference.
`LocalSpeechProviderTests` covers the recording WAV format, malformed audio rejection,
cumulative streaming corrections, one trailing final, cancellation during native work and
ordered final delivery through the existing live controller. Native session closure retains
its owning recording lease until insertion and submit finish. Selecting another provider
invalidates pending local selection without cancelling the recording already in progress.

`LocalRecordingPreparationTests` and `KeyInterceptorPendingTests` cover microphone-off
preparation, Enter pass-through and Escape cancellation, unavailable keyboard interception,
late target/provider changes, sleep, and pending keys drained before recording starts.
`LocalModelsControllerTests`, `LocalModelSelectionTests` and `VADInstallControllerTests`
cover explicit action eligibility, exact consent, selection after successful load, failed-load
preservation, unload without deletion, and in-use locks. `LocalModelRemovalTests` rejects
unexpected nested symlinks before removal. Tests inject removal callbacks and retain fixtures.
`LocalModelResourceMonitorTests` checks sleep, wake and thermal notification routing.
Memory pressure cancels pending native loads and releases idle ASR/VAD handles while keeping
active inference alive until its owners finish. Wake never restarts microphone capture.
Startup keeps both speech and VAD cold unless preload is explicitly enabled. Batch preload
loads required VAD first and stops on dependency failure. The configured idle interval
applies to both caches; VAD expiry retains files and cannot retire an active processor lease.
`LocalStreamingReliabilityTests` verifies that the existing bounded queue fails visibly for
local inference instead of silently dropping old audio. Cloud buffering and reconnect retain
their existing policy. Required native and hardware checks remain distinct from these suites.

`LocalModelVersionTests` covers manual source metadata, unreviewed revisions, strict
catalog compatibility and duplicate rejection. The preferred and retained app catalogs
are the only installation authority. `LocalModelsControllerTests` exercises browsing a
retained version without activation, explicit Load for rollback, offline check failure,
and named partial cleanup. First-release retained metadata is empty; no extra checkpoint
is silently approved. Cleanup reports logical file bytes and validates named targets again
at confirmation, preserving other revisions and shared dependencies.

Local capture overflow, overlapping batch requests, local inference errors and forced
finalization deadlines cancel delivery and withhold submit. Existing cloud queue behavior
remains covered by its original suites. No new release RAM limit is inferred from these
correctness bounds.

`LocalSpeechPacedIntegrationTests` is a separate opt-in public-fixture probe through the
production live controller at capture pace. It saves numeric timing and memory counters
only to an explicitly supplied metric descriptor. Process footprint and system page counters
are not complete attribution of shared accelerator memory. Live Instruments evidence and
real microphone/insertion checks are still required separately.

`LocalSpeechEngineIntegrationTests` is an explicit installed-assets probe. Set
`SPEAKFLOW_RUN_LOCAL_SPEECH_PROBES=1`, `SPEAKFLOW_LOCAL_MODEL_CACHE_ROOT` to a previously
approved isolated model store, and `SPEAKFLOW_PUBLIC_SPEECH_FIXTURE` to an approved generic
mono 16 kHz speech fixture. Run `swift test --no-parallel --filter LocalSpeechEngineIntegrationTests`.
The probe exercises Parakeet 0.6B v2 and native Nemotron through production runtime/provider
adapters, without microphone capture or transcript persistence. It never downloads missing
assets. Default tests skip it. Network-denied execution and the actual application are
separate required release evidence; mock suites do not establish those results.

`make test-regression-core` never provisions models. Install the reviewed VAD manifest
explicitly first, then point `SPEAKFLOW_VAD_MODEL_CACHE_ROOT` at that isolated app-owned
store. The gate verifies the installed assets and runs the existing real-model suites.
Missing assets on supported hardware fail the gate rather than silently skipping coverage.

`ModelsScreenTests` opens the production Models view with synthetic isolated state,
drives controller state through confirmation, cancellation and failed transfer, and checks retry
availability and actual window geometry. It does not assume SwiftUI controls are `NSButton` subviews.
Enable it with `SPEAKFLOW_RUN_UI_PROBES=1`. Captures contain only the synthetic test view.
The persistent `ModelsVisualProbe` test fixture supports separate Computer checks of the actual
Download, Cancel, Confirm download and Escape interactions without a network-capable transport.
