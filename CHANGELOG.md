# Changelog

## 0.4.0

Fixes text insertion going to the wrong app when switching focus during transcription, and a race condition where the completion sound could play before all text was delivered. Adds PID-based app tracking that pauses typing when the user switches away and resumes when they return, with per-keystroke focus verification so even mid-stream app switches are handled correctly. Includes comprehensive race condition tests using swift-concurrency-extras and 13 new focus management tests.

### Bug Fixes

* **Text no longer types into the wrong app** — replaced unreliable AXUIElement CFEqual comparison with PID-based app identity tracking. The old approach silently failed because the same UI element can return different accessibility refs across queries.
* **Mid-stream focus protection** — focus is now verified between every keystroke and every delete, not just at the start of each operation. Switching apps during active typing immediately pauses insertion.
* **Wait-for-focus pattern** — instead of stealing focus back (which could trigger unintended actions in the wrong app), text insertion pauses and polls until the user voluntarily returns to the original app.
* **Terminated app detection** — if the target app is quit while waiting, insertion stops immediately instead of polling forever.
* **Completion sound race condition** — the "done" sound could fire after the first text chunk was delivered but before subsequent chunks arrived. Fixed by tracking yield/consume counts across the actor-AsyncStream boundary so completion only signals after all text has been processed by the consumer.

### Test Suite

* 13 new focus management tests covering PID capture, cross-app detection, polling/pause behavior, terminated app handling, and an opt-in AX integration test.
* 3 new race condition tests using `withMainSerialExecutor` from swift-concurrency-extras for deterministic async ordering verification.
* Replaced fixed-duration `Task.sleep` assertions with polling-based `waitUntil` helper to eliminate flaky timer tests under main-actor contention.
* Test suite: **376 tests in 88 suites, all passing.**

## 0.3.1

Architecture hardening release driven by a deep code review. Fixes thread-safety issues, potential retain cycles, and a menu bar bug where "Start Dictation" could be enabled without required permissions. Adds 21 new tests (359 total) including integration tests that verify the menu bar disabled state against all permission and provider combinations.

### Bug Fixes

* **Menu bar "Start Dictation" now correctly disabled** when accessibility or microphone permissions are missing — previously it only checked for configured providers, allowing users to attempt dictation that would fail at the system level.
* **Menu bar reactivity fixed** — the menu now re-evaluates when provider configuration or permissions change, using the `refreshVersion` observation pattern already established in other views.
* **Hotkey display name** cleaned up from `⌃⌃ (double-tap)` to `⌃⌃ Double-tap` for consistency.
* **Removed non-functional keyboard shortcuts** from menu bar items — `MenuBarExtra` with `.menu` style has no window context for shortcuts.

### Thread Safety & Concurrency

* **KeyInterceptor**: consolidated four separate mutable fields into a single `OSAllocatedUnfairLock<EventTapState>`, eliminating a data-race window between the CGEvent tap callback thread and MainActor.
* **HotkeyListener**: consolidated double-tap state into `OSAllocatedUnfairLock<DoubleTapState>` with atomic double-tap detection inside the lock.
* **UnifiedAuthStorage**: replaced `NSLock` with `OSAllocatedUnfairLock` for consistency with the project's concurrency standard.
* **RecordingController**: added explicit `@MainActor in` to four fire-and-forget Tasks that previously relied on implicit isolation.
* **TranscriptionQueue**: added 30-second timeout to `waitForCompletion()` preventing indefinite hangs if flush never fires, plus overflow detection at 100 pending results.

### Memory Safety

* **RecordingController**: fixed retain cycle — `onChunkReady` callback now captures `[weak self]`.
* **AuthController**: added `[weak self]` to OAuth callback Task preventing controller from being held alive by a pending server response.

### Robustness

* **URL force-unwrap elimination**: replaced `URL(string:)!` and `URLComponents(string:)!` with static `let` constants using `preconditionFailure` in `OpenAICodexAuth`, `DeepgramProvider`, and `AboutSettingsView`.
* **Silent error logging**: replaced `try?` with `do/catch` + `Logger.debug` in `LiveStreamingController` shutdown so failures are observable.
* **VAD warm-up timeout**: added 15-second `withTaskGroup` race so a stuck model load doesn't block app startup.
* **Atomic session activation**: extracted `activateSession()` in `LiveStreamingController` to prevent partial state when activating a streaming session.

### Architecture

* **AppState DI**: `AppState` now accepts a `ProviderRegistryProviding` dependency via init, consistent with `RecordingController` and `AuthController`. Enables isolated testing without global singleton pollution.
* **`canStartDictation`** computed property extracted from `MenuBarView` into `AppState` — testable, observable, and the single source of truth for the menu bar disabled state.
* **`StubProvider`** test mock added for controllable `isConfigured` in provider-dependent tests.

### Tests

* 21 new tests across `AppStateTests` and `DictationReadinessTests`:
  - 9 unit tests for `canStartDictation` covering every permission/provider combination.
  - 12 integration tests wiring real `AppState` + `RecordingController` together, verifying UI guard and runtime guard alignment, progressive permission grants, provider config/deconfig transitions, and mid-recording stop availability.
* Test suite: **359 tests in 84 suites, all passing.**

## 0.3.0

* Fixed recording silently proceeding without a configured provider on first launch — an early configuration gate now blocks recording and shows a banner directing users to Accounts setup.
* Provider picker in transcription settings now only shows configured providers, preventing selection of unusable providers.
* Accounts view reactively updates after OAuth login, so newly authenticated providers appear immediately.
* Introduced `KeyIntercepting`, `TextInserting`, and `BannerPresenting` DI protocols for `RecordingController`, enabling proper behavioral testing with spy mocks.
* Replaced ~170 brittle source-parsing tests with ~20 behavioral tests backed by dependency injection — test suite is now 280 tests in 72 suites, all exercising real runtime behavior.

## 0.2.0

* Replaced hardcoded provider logic with an extensible protocol hierarchy (`TranscriptionProvider` → `BatchTranscriptionProvider` / `StreamingTranscriptionProvider`) and a central `ProviderRegistry`.
* Added `ProviderId` constants eliminating 12+ scattered string literals across the codebase.
* Introduced `APIKeyValidatable` protocol moving key validation from generic settings to the owning provider.
* Added provider-owned streaming config via `buildSessionConfig()`.
* Unified credential storage consolidates all provider credentials in `~/.speakflow/auth.json`.
* Extracted `TextInserter` and `KeyInterceptor` from `RecordingController` for single responsibility.
* Added `AppState.binding(for:)` generic helper eliminating 12 copy-paste binding properties.
* Split the monolithic 7,187-line `VADTests.swift` into 10 domain-specific test files.

## 0.1.0

* Initial release with ChatGPT and Deepgram transcription providers.
