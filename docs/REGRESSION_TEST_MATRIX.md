# Review regression coverage

The core gate retains its existing suite list and includes these additional regressions.
Run `make test-regression-core` and the serialized full suite with muted, isolated audio.

| Contract | Coverage |
| --- | --- |
| Corrections use successfully posted text, including queue rejection and partial typing/deletion | `StreamingTextDeliveryTests` |
| Original-field evidence is required for text, deletion, and Enter | `TextInserterFieldIdentityTests` |
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
  swift test --no-parallel --filter 'ProviderKeyValidationTests|TranscriptionLanguagePickerTests|UITestHarnessTests|HotkeyNativeMonitorTests'
```

These probes render synthetic controls and dispatch synthetic input locally. They do not
record microphone audio, contact providers, or use installed-app storage. Real microphone
capture, live provider interoperability, and audible sound quality require separate opt-in
verification. Successfully posted key pairs are the insertion acknowledgment boundary;
these tests cannot prove a third-party application accepted every posted event.
