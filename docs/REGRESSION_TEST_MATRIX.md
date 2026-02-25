# SpeakFlow Regression Test Matrix

This matrix maps main product features to enforceable regression suites.

## Mandatory gates

1. `make test-regression-core`  
2. `swift test` (full suite)

CI runs both gates on every PR and push to `main`.

## Main feature coverage

| Main Feature | Regression Suites | Layer |
|---|---|---|
| Dictation readiness (permissions + provider config) | `DictationReadinessTests`, `AppStateTests` | Integration |
| Hotkey activation and keyboard control behavior | `HotkeyListenerTests`, `HotkeyTests`, `RecordingControllerTests` | Integration |
| Recording lifecycle (start/stop/cancel, streaming path) | `RecordingControllerTests`, `StreamingRecordingTests` | Integration |
| Enter submit contract (focus-scoped one-shot capture, second-press pass-through, ordering) | `EnterSubmissionContractTests`, `KeyInterceptorEnterCaptureTests` | Integration |
| Focus-safe text insertion + queue behavior | `TextInserterFocusTests`, `TextInserterModifierSafetyTests` | Integration |
| Test UX safety (muted audio in automation) | `SoundEffectTests` | Behavioral |
| VAD gating, state machine, smoothing, drift reset | `VADStateMachineTests`, `VADIntegrationTests`, `VADTests` | Behavioral + Integration |
| Session auto-end, silence boundaries, thinking pause | `SessionControllerTests`, `ThinkingPauseDetectorTests` | Behavioral + Integration |
| Live streaming reliability (keepAlive, reconnect, backpressure, short-final guard) | `LiveStreamingKeepAliveTests`, `CorrectnessTests`, `AudioPipelineTests` | Integration |
| Ordered transcription delivery and completion semantics | `TranscriptionQueueTests`, `TranscriptionTests` | Integration |
| Metrics and latency observability | `StatisticsTests`, `SessionMetricsStoreTests`, `TranscriptionTests` | Behavioral + Integration |
| Provider protocol/parsing correctness (Deepgram + Mistral) | `DeepgramSessionTests`, `MistralSessionTests`, `MistralBatchProviderTests`, `MistralRealtimeRegressionTests` | Integration |
| Auth + OAuth safety-critical behavior | `AuthTests`, `AuthControllerDITests` | Behavioral + Integration |
| Performance-sensitive audio conversion invariants | `PerformanceOptimizationTests` | Behavioral |

## Live E2E (manual/pre-release)

These are not run in normal CI because they require mic/API/runtime setup, but they are part of release validation:

- `make test-live-e2e`
- `make test-live-e2e-autoend`
- `make test-live-e2e-chunks`
- `make test-live-e2e-accuracy`
- `make test-live-e2e-noise`
- `make test-live-e2e-all`

## Notes

- `scripts/test-regression-core.sh` runs critical suites and verifies each filter matches at least one test (prevents false-green filter drift).
- The script also stress-runs `EnterSubmissionContractTests` multiple times to catch ordering/race regressions.
- If local SwiftPM lock contention exists, run with an isolated scratch path:
  `SPEAKFLOW_SWIFT_SCRATCH_PATH=/tmp/speakflow-regression-build make test-regression-core`.
