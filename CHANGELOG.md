# Changelog

## 0.7.10 — Runtime Diagnostics & Release Guardrails

### Bug Fixes

* **Environment API keys now count toward provider readiness** - Deepgram and Mistral providers now use the same API key lookup for readiness checks and session startup, so `DEEPGRAM_API_KEY` and `MISTRAL_API_KEY` configurations are not incorrectly blocked before recording starts.
* **Auto-end timeout settings now preserve `0` as disabled** - No-speech timeout and max continuous speech safety settings now distinguish a stored zero from a missing preference, so users can actually disable those safeguards from settings.
* **Enter capture now fails closed if active key interception is unavailable** - SpeakFlow no longer falls back to a passive global key monitor when the CGEvent tap cannot be created, avoiding duplicate Enter submission in environments where keys cannot be suppressed.
* **Text insertion queue depth is protected against stale completions** - Queue depth bookkeeping now stays synchronous and session-generation guarded, preventing reset or cancel races from corrupting later queue limits.
* **Batch session metrics now stay open through finalization** - Batch dictation now records submitted chunks, successful chunks, STT latency, and produced words before ending the metrics session.
* **Normal recording stops no longer appear as errors** - Routine stop requests now log at info level instead of polluting system error logs.
* **Silence auto-end no longer reports itself as VAD-only** - Auto-ended recordings now use the generic `SILENCE_AUTO_END` reason so streaming provider silence timers are not mislabeled as local VAD decisions.
* **Default silence auto-end now waits longer** - The default silence threshold is now 10 seconds, reducing premature stops during thinking pauses or delayed streaming provider boundary events.

### Diagnostics

* **Structured observability logs now rotate** - Verbosity is unchanged, but `events.jsonl` now rotates at a bounded size and keeps a small set of backups to prevent unbounded growth when verbose diagnostics or text payload capture are enabled.
* **Hotkey and Enter interception now emit structured diagnostics** - Activation listener registration, registration failures, event tap disable/reenable events, hotkey detection, handler invocation, Enter capture, Enter pass-through, and focus-mismatch pass-through are now recorded in hotkey logs and observability events.
* **Observability timestamps now include milliseconds** - JSONL event timestamps now preserve millisecond precision, making provider boundary events, silence timers, and stop ordering easier to compare.
* **Observability events now include build provenance** - Each structured event now records the build git description, exact git commit, and display version, including RC suffixes.
* **Streaming silence timers now log start, cancel, and fire events** - Streaming auto-end diagnostics now show whether timers came from `speechFinal` or `utteranceEnd`, how long they were armed for, and why they were cancelled.

### CI / Release Process

* **Final releases now require explicit local RC test confirmation** - Production release publishing requires the caller to provide the exact HEAD SHA that was locally tested as an RC, in addition to the existing notarization, stapling, and artifact validation gates.
* **Local `make check` is deterministic across machines** - The default check gate now runs build and tests only. SwiftLint remains available as an explicit `make lint` gate instead of depending on whether SwiftLint is installed locally.

---

## 0.7.9 — Release Validation & Distribution Safety

### Bug Fixes

* **Homebrew-installed app now passes Finder Gatekeeper checks** - Release builds now notarize and staple the app bundle before packaging it into the DMG, then notarize and staple the DMG itself. This prevents Homebrew installs from extracting a valid but unstapled app that Finder refuses to open.
* **Typing cadence is now a middle ground between speed and stability** - The safer typing defaults remain slower than the older caret-jump-prone cadence, but are less sluggish than the first 0.7.9 RC.
* **Release versions now come from the changelog instead of loose tags** - The release script now treats the GitHub release as the source of truth. If a release tag is missing, the release creation step creates it at the current commit. If a tag already exists but points somewhere else, the release stops and requires a version bump.

### CI / Release Process

* **Added release artifact validation for GitHub and Homebrew** - A shared validation script checks that the DMG and contained app are Developer ID signed, Gatekeeper accepted, stapled, and have the expected bundle id, team id, and version before the Homebrew tap is updated.
* **Release builds now fail closed on test uncertainty** - The release script runs the Swift test suite serially with bounded timeouts and heartbeat output, then blocks production releases if tests fail or time out.

---

## 0.7.8 — Typing Stability & Queue Serialization

### Bug Fixes

* **More conservative synthesized typing cadence** — Slowed per-character typing, reduced batch size, and increased the pause between bursts of synthesized keystrokes. This gives slower editors and browser-backed fields more time to settle between events, reducing cases where the caret jumps and later dictated text lands in the middle of already-inserted text.

### Test Coverage

* **Added a regression for multi-chunk typing serialization** — New coverage verifies that if a second chunk arrives while the first chunk is still typing, SpeakFlow keeps the work strictly serialized instead of starting the second insertion early.
* **Locked in the safer typing defaults** — Added assertions for the slower keystroke delay, smaller typing batches, and longer inter-batch yield so future refactors do not silently restore the more aggressive pacing.

---

## 0.7.7 — Batch Dictation Auto-End Reliability

### Bug Fixes

* **Batch dictation no longer idles out while speech is still being captured** — Fixed a failure mode where long or quiet dictation could accumulate valid speech audio and still be treated as "no speech detected," causing sessions to auto-stop at the 10-second idle timeout. Recent speech-like VAD activity now suppresses that idle timeout instead of letting a missed formal `speechStart` kill the session.
* **Resumed speech after a thinking pause now resets the silence clock** — Fixed a regression where SpeakFlow could detect `speechEnd`, extend the wait using thinking-pause logic, then continue counting stale silence even after the user started talking again. Speech-like activity after a pause now restarts the post-speech silence window so auto-end requires a fresh full silence period.

### Dependencies

* **Updated FluidAudio to 0.13.6** — Refreshed the bundled audio/VAD dependency while validating SpeakFlow against the newer release.

### Test Coverage

* **Added regressions for missed speech-start and resumed-speech auto-end bugs** — New tests cover both bad production patterns: active speech that would previously trip the 10-second no-speech timeout, and resumed speech after a thinking pause that would previously inherit a stale silence timer.

---

## 0.7.6 — Auto-End Silence Fix

### Bug Fixes

* **Auto-end now respects the full silence duration after speech ends** — Fixed a regression in batch dictation where recording could stop almost immediately after the user finished speaking, even though auto-end was configured to wait 5 seconds. This happened in the early-chunk path after `speechEnd`, where the session could fall into a fallback auto-end path instead of honoring the configured silence boundary.
* **Early chunk emission no longer causes premature session end** — After a chunk is sent at a speech boundary, SpeakFlow now restarts silence timing from that chunk boundary. This preserves the intended behavior: transcription can still start early for better responsiveness, but recording will not stop until the full post-speech silence threshold has actually elapsed.

### Test Coverage

* **Added regression coverage for premature auto-end after chunk send** — New tests reproduce the real installed-app failure mode: long dictation → speech end → early chunk send → auto-end poll. SpeakFlow now verifies that recording does not stop immediately and only auto-ends after the full configured silence duration.

---

## 0.7.5 — ChatGPT Reliability Fix

### Bug Fixes

* **ChatGPT transcription no longer hangs on a stalled API** — The ChatGPT transcription endpoint sometimes accepts a connection but never sends a response back, causing recordings to silently fail after 35–47 seconds. SpeakFlow now enforces a hard 15-second deadline per attempt using a dedicated `URLSession` that is forcibly invalidated when the deadline fires (simply cancelling a Swift Task was not enough — the OS-level HTTP connection stayed alive regardless). On timeout, the request is retried up to 3 times with a 1-second pause between attempts. Total worst-case wait is 47 seconds instead of one silent failure, and if all retries are exhausted, a clear error banner explains what happened.

---

## 0.7.4 — Error Banners & Batch Provider Fixes

### Bug Fixes

* **Batch provider dispatch** — Fixed a critical bug where batch recordings were always sent to the ChatGPT endpoint regardless of the user's selected provider. Mistral Batch now correctly routes audio to Mistral's transcription API.
* **Transcription error banners** — When a transcription fails (due to an expired token, invalid API key, rate limit, or network error), SpeakFlow no longer just plays an error sound and silently fails. It now displays an actionable, user-friendly error banner explaining exactly what went wrong and how to fix it. These banners automatically dismiss upon the next successful transcription.

### Documentation

* **Homebrew installation** — Added official `brew tap` installation, upgrade, and uninstall instructions to the README.

---

## 0.7.3 — Structured Observability & Reliability

### Features

* **Structured observability** — SpeakFlow now writes a structured JSONL event log to `~/.speakflow/observability/app/events.jsonl`. Every meaningful moment in the recording lifecycle — session start/stop, provider messages, text insertions, focus changes, errors — is recorded as a correlated, timestamped event. A new `observability-session-timeline.py` script renders a readable per-session timeline from the log. Observability settings (verbosity, payload capture, snapshots) are exposed in General Settings under a new *Observability* section.

* **Atomic tail replacement** — Streaming interim corrections now use a new `replaceTail(replacingChars:with:)` operation that queues the delete and re-type as a single atomic item. Previously, under queue pressure the deletion could be accepted while the matching insertion was dropped (or vice versa), corrupting the correction order mid-dictation. This is now impossible.

* **Adaptive batch finalization timeout** — Batch-mode finalization no longer uses a fixed retry loop. The deadline is now computed as `clamp(base + maxChunkDuration × perChunkFactor, _, maxTimeout)`, so short recordings finish faster and long ones get proportionally more time. The queue's `onAllComplete` callback also triggers an immediate fast-path completion when all chunks resolve naturally, with no polling wait.

### Bug Fixes

* **Streaming recorder test isolation** — `StreamingRecorder` and `LiveStreamingController` now detect the test runtime via `SPEAKFLOW_ISOLATE_TEST_AUDIO` and skip all `AVAudioEngine` / CoreAudio setup in that context. Tests no longer risk touching the real microphone or consuming audio permissions.

* **Streaming minimum final word count** — Default raised from 1 to 2 words before a non-`speechFinal` streaming result commits. Eliminates premature commits of single-word clause fragments during fast speech.

---

## 0.7.2 — Focus Fix & UI Polish

### Bug Fixes

* **More reliable focus detection** — Restored Accessibility (AX) framework as the primary source of keyboard-focus ownership in `isTargetAppFrontmost`. Some apps route their UI through helper processes whose PID differs from the main app PID; AX correctly identifies these, whereas NSWorkspace does not. Text insertion now works correctly in apps like this without losing focus mid-dictation.

### UI

* **Cleaner Mistral account page** — Removed the per-minute API pricing numbers from the Voxtral Realtime and Voxtral Mini capability badges. The pricing was stale and better consulted directly on the Mistral console.

### Test & CI Reliability

* Fixed three load-sensitive test flakes in the parallel regression suite (`stopReturnsEarlyWhenNoTrailingEventsArrive`, `audioBackpressureUsesBoundedQueue`, `testFullPipelineWithFailedChunk`).
* Fixed a potential test deadlock in `testFullPipelineWithFailedChunk` where an actor-hop race could leave an `AsyncStream` continuation unfinished.
* CI now prints failing test output directly to stdout for easier diagnosis.

---

## 0.7.1 — Polish & Reliability

Small but satisfying fixes to a couple of rough edges introduced by the menu-bar-only mode in 0.7.0.

### Bug Fixes

* **Reopening the app now works** — If SpeakFlow is already running in your menu bar and you double-click the app icon in Finder (for example, after dragging in a fresh download), the Settings window now appears reliably instead of nothing happening.
* **App icon always shows up** — The dock icon and menu bar icon now load correctly regardless of where the app is installed or how macOS resolves the resource bundle. No more blank icon on first launch in certain setups.

---

## 0.7.0 — Advanced VAD Controls & Streaming Reliability

Major update exposing advanced Voice Activity Detection (VAD) and auto-end settings, alongside significant reliability improvements for streaming transcription and text insertion.

### Features
* **Advanced VAD Settings** — Exposed comprehensive UI controls for VAD thresholds, noise gating, volume smoothing, and state reset intervals.
* **Smart Auto-End Controls** — Added "Thinking Pause" extension, Turn Classifier for incomplete sentences, and Idle Nudge to intelligently delay auto-end when you pause mid-thought.
* **Streaming Reliability** — Added configurable WebSocket keep-alive pings and automatic reconnect on drop to maintain long-running live transcription sessions.
* **Metrics & Observability** — Added per-session metrics store and Speech-to-Text (STT) latency tracking.
* **Audio Noise Gate** — Added a pluggable pre-VAD audio filter with a noise gate to reject background noise before detection.

### Bug Fixes
* **Focus Recovery** — Improved PID matching and added bundle ID tracking so text correctly inserts even if an app relaunches or uses a helper process.
* **Text Insertion Safety** — Fixed Enter submission to wait for pending text insertions, and added per-character modifier safety.
* **Session Lifecycle** — Hardened OAuth flow, audio buffering, stream reconnects, and fixed transcription cancellation handling.
* **VAD Accuracy** — Defer Silero state reset during active speech to prevent dropouts, and added a "potential speech" hold guard against premature auto-end.

### Release Infrastructure & Testing
* Rewrote release scripts with `rc` (release candidate) commands, `--yes` non-interactive mode, and robust CI timeouts/heartbeats.
* Added extensive regression test suites for core behavior contracts (focus, modifier safety, VAD state machine).

---

## 0.6.1 — Bug fixes & test reliability

Patch release fixing one production bug and hardening the test suite against
timing-dependent failures on macOS 26 (Xcode 26.0).

### Bug Fix

- **OAuth callback startup race** — `AuthController.startLoginFlow()` previously
  opened the browser before the local callback server had bound its socket. On a
  heavily loaded system the provider's redirect could arrive before the server
  was listening, causing authentication to fail silently. The server now binds
  synchronously via `OAuthCallbackServer.prepareForCallback()` before the browser
  is opened. A new `waitForPreparedCallback()` entry point encodes the
  precondition in its name so the correct call sequence is self-documenting.

### Test Reliability

Five categories of flaky tests eliminated across two CI runners
(macOS 15 / Xcode 16.4 and macOS 26 / Xcode 26.0):

- **RateLimiter cancellation** — replaced elapsed-time assertion with a
  deterministic pre-cancel pattern; 60s interval ensures the task cannot
  complete naturally.
- **TranscriptionQueue real-time delivery** — rewrote sleep+poll loop as a
  direct `for await` consumer; natural rendezvous, zero sleeps.
- **Silence auto-end timer** — increased silence duration (150ms → 300ms) and
  `waitUntil` timeout (3s → 5s) to give the unstructured timer task reliable
  headroom on loaded CI runners.
- **OAuth callback server tests** — converted to `async let` concurrent
  pattern so the `CheckedContinuation` is always installed before the HTTP
  request can be accepted; removed all fixed-duration sleeps.
- **VAD model cache tests** — network requests to `huggingface.co` are now
  skipped gracefully when the CI runner has no outbound access
  (`NSURLErrorCancelled` / `NSURLErrorNotConnectedToInternet`, domain-checked).

### Code Quality

- `OAuthCallbackServer` public API tightened: removed the footgun `autoStart`
  boolean parameter; callers now choose between `waitForCallback()` (auto-starts)
  or the explicit `prepareForCallback()` + `waitForPreparedCallback()` sequence.
- Error domain verified alongside error code in all network-skip catch clauses
  (`error.domain == NSURLErrorDomain`) so non-network errors with coincident
  codes cannot silently swallow real failures.
- `defer { collectTask.cancel() }` added to stream lifecycle test so a dropped
  submit produces a clean failure instead of an indefinite hang.

---

## 0.6.0 — Mistral Voxtral Provider

Adds Mistral as a fully supported transcription provider in two modes — realtime streaming and batch — bringing the total to four transcription modes across three providers. Includes a comprehensive settings UI for Mistral-specific features, robust session lifecycle handling, and 1,836 lines of new test coverage.

### New: Mistral Voxtral Realtime

Real-time streaming transcription via WebSocket using Mistral's `voxtral-mini-transcribe-realtime-2602` model. Text appears word-by-word as you speak, with sub-500ms latency on a good connection. Like the Deepgram streaming provider, interim results display immediately and are refined as the model becomes more confident — so you see your words appear live rather than waiting for a pause.

### New: Mistral Voxtral Mini (Batch)

Batch transcription using Mistral's REST API, sending completed audio chunks for transcription. Supports Mistral-specific features not available in other providers:

- **Context bias** — provide a list of words, names, or domain terms that the model should weight more heavily. Useful for technical jargon, product names, or unusual proper nouns that models tend to mishear.
- **Speaker diarization** — attribute speech to multiple speakers when multiple people are talking (experimental; incompatible with context bias).
- **Temperature** — control transcription creativity/determinism.
- **Language** — select from Mistral's benchmarked languages or a broader set of additional supported languages, with Auto-Detect as the default.

### Settings UI

Both Mistral modes share a single API key configured in **Settings → Accounts → Mistral**. The **Transcription** settings panel adds a full Mistral section covering:

- Mode selection (Realtime vs Batch)
- Language selection grouped by benchmarked vs additionally supported
- Context bias text editor (batch only, with character guidance)
- Diarization toggle with notes on provider compatibility constraints

### Bug Fixes

- **Auth fallback on key removal** — removing the Mistral API key while the Mistral Batch variant is active now correctly falls back to the next configured provider rather than leaving an unconfigured provider selected.
- **Realtime session close handling** — improved detection of expected vs unexpected WebSocket closes. A user-facing banner now appears when the session closes before any transcription is produced (e.g. connection failure), rather than failing silently.
- **Log message fix** — streaming error logs previously said "Deepgram error" regardless of which provider was active; corrected to "Streaming error".

### Release Infrastructure

- Signing credentials (`SIGNING_IDENTITY`, `TEAM_ID`, `NOTARY_PROFILE`, `BUNDLE_ID`) moved out of the release script into environment variables — no developer-specific values are committed to the repository.
- Post-notarization validation added: `stapler validate` and `spctl` Gatekeeper checks on both the app and DMG run automatically before upload, so a broken build fails loudly before reaching GitHub.
- RC build mode: `make release` now installs a timestamped release candidate (e.g. `v0.6.0-rc.20260220`) for local testing before cutting the GitHub release with `make release-github`.

### Tests

- 4 new test files, 1,836 lines of new coverage:
  - `MistralAPITests` — live integration tests for API key validation
  - `MistralBatchProviderTests` — request building, audio validation, settings dependency injection
  - `MistralSessionTests` — WebSocket message parsing edge cases, close/flush lifecycle
  - `MistralRealtimeRegressionTests` — normal-close classification, API spec compliance
- Auth fallback regression test: explicit test for shared-key removal with active variant
- Test suite: **471 tests in 100 suites, all passing.**

---

## 0.5.1 — Developer ID & Notarization

- **Developer ID signing** — app is now signed with a Developer ID Application certificate instead of ad-hoc, so macOS Gatekeeper trusts it on all Macs without warnings.
- **Notarized by Apple** — submitted to and accepted by Apple's notary service; the notarization ticket is stapled directly to the DMG so verification works fully offline.
- **Permissions persist across updates** — Accessibility and Microphone grants are preserved when upgrading, no re-grant needed on every release.
- **Hardened Runtime** — `SpeakFlow.entitlements` added for microphone access and Apple Events under hardened runtime, as required for notarization.
- **Bundle ID changed** — `app.monodo.speakflow` → `nu.rez.speakflow`. First upgrade from 0.5.0 or earlier requires a one-time re-grant of Accessibility and Microphone permissions.
- **Release script** — `make release` for local signed builds, `make release-github` for the full signed + notarized + uploaded flow.

---

## 0.4.2 — System Input Fix

- **Fixed system-wide input freeze** — a bug introduced in 0.4.1 caused keyboard input to freeze system-wide during transcription in certain configurations. Resolved by enabling Swift's `IsolatedDeinit` feature and fixing `@MainActor` call sites to eliminate actor isolation violations that caused the event tap to deadlock.

---

## 0.4.1 — Focus Wait & Hotkey Restart

- **Configurable focus wait timeout** — `ensureTargetFocused()` now times out after a configurable duration (default 60s) instead of polling indefinitely when the user switches apps, with pending text discarded on expiry.
- **Hotkey restart during processing** — pressing the hotkey while transcription is in progress now cancels and starts a new recording session immediately, configurable via Settings → General → Behavior.
- Test suite: **379 tests in 87 suites, all passing.**

---

## 0.4.0 — Focus Protection & Completion Ordering

Fixes text being typed into the wrong app when focus changes during transcription, and a race condition where the completion sound could fire before all text was delivered.

### Bug Fixes

- **Text no longer types into the wrong app** — replaced unreliable AXUIElement `CFEqual` comparison with PID-based app identity tracking. The old approach silently failed because the same UI element can return different accessibility refs across queries.
- **Mid-stream focus protection** — focus is now verified between every keystroke and every deletion, not just at the start of each operation. Switching apps during active typing immediately pauses insertion.
- **Wait-for-focus pattern** — instead of stealing focus back (which could trigger unintended actions in the wrong app), text insertion pauses and polls until the user returns to the original app.
- **Terminated app detection** — if the target app quits while insertion is paused, typing stops immediately instead of polling indefinitely.
- **Completion sound race condition** — the success sound could fire after the first chunk was delivered but before later chunks arrived. Fixed by tracking yield/consume counts across the actor–AsyncStream boundary so completion only signals after all text has been consumed.

### Tests

- 13 new focus management tests: PID capture, cross-app detection, polling/pause behavior, terminated app handling, and AX integration.
- 3 new race condition tests using `withMainSerialExecutor` from swift-concurrency-extras for deterministic ordering.
- Test suite: **376 tests in 88 suites, all passing.**

---

## 0.3.1 — Thread Safety & Architecture Hardening

Architecture hardening release driven by a deep code review. Fixes thread-safety issues, potential retain cycles, and a menu bar bug where "Start Dictation" could be enabled without required permissions.

### Bug Fixes

- **"Start Dictation" correctly disabled** when Accessibility or Microphone permissions are missing — previously it only checked for a configured provider.
- **Menu bar reactivity** — the menu now re-evaluates when provider configuration or permissions change.
- **Hotkey display** cleaned up from `⌃⌃ (double-tap)` to `⌃⌃ Double-tap`.
- **Removed non-functional keyboard shortcuts** from menu bar items (`MenuBarExtra` with `.menu` style has no window context for shortcuts).

### Thread Safety

- `KeyInterceptor`: four separate mutable fields consolidated into a single `OSAllocatedUnfairLock<EventTapState>`, eliminating a data-race window between the CGEvent tap thread and MainActor.
- `HotkeyListener`: double-tap state consolidated into `OSAllocatedUnfairLock<DoubleTapState>` with atomic detection inside the lock.
- `UnifiedAuthStorage`: `NSLock` replaced with `OSAllocatedUnfairLock` for consistency.
- `RecordingController`: explicit `@MainActor in` added to four Tasks that previously relied on implicit isolation.
- `TranscriptionQueue`: 30-second timeout added to `waitForCompletion()`, preventing indefinite hangs; overflow detection at 100 pending results.

### Memory Safety

- `RecordingController`: fixed retain cycle — `onChunkReady` captures `[weak self]`.
- `AuthController`: `[weak self]` added to OAuth callback Task.
- URL `force-unwrap` elimination across `OpenAICodexAuth`, `DeepgramProvider`, and `AboutSettingsView`.

### Tests

- 21 new tests: 9 unit tests for `canStartDictation` across every permission/provider combination, 12 integration tests wiring `AppState` + `RecordingController`.
- Test suite: **359 tests in 84 suites, all passing.**

---

## 0.3.0 — Provider Configuration Gate & Behavioral Test Suite

- **Recording blocked without a provider** — an early configuration gate now prevents recording when no transcription provider is configured, showing a banner directing users to Accounts setup. Previously, recording would silently proceed and fail.
- **Provider picker filters to configured providers only** — prevents selecting a provider with no credentials.
- **Accounts view live updates** — newly authenticated providers appear immediately after OAuth login.
- **DI protocols for `RecordingController`** — introduced `KeyIntercepting`, `TextInserting`, and `BannerPresenting` protocols enabling proper behavioral testing with spy mocks.
- **Test suite rewrite** — replaced ~170 brittle source-parsing tests with ~20 behavioral tests backed by dependency injection. Test suite: **280 tests in 72 suites.**

---

## 0.2.0 — SOLID Architecture Refactoring

- **Protocol-driven provider system** — `TranscriptionProvider` base protocol with `BatchTranscriptionProvider` and `StreamingTranscriptionProvider` specialisations; central `ProviderRegistry` replaces scattered conditionals.
- **`ProviderId` constants** — eliminates 12+ string literals across the codebase.
- **`APIKeyValidatable` protocol** — moves key validation from generic settings into the owning provider.
- **Provider-owned streaming config** — `buildSessionConfig()` on each provider.
- **Unified credential storage** — all provider credentials consolidated in `~/.speakflow/auth.json`.
- **`TextInserter` and `KeyInterceptor` extracted** from `RecordingController` for single responsibility.
- **`AppState.binding(for:)` generic helper** — eliminates 12 copy-paste binding properties.
- **Test split** — monolithic 7,187-line `VADTests.swift` split into 10 domain-specific files.

---

## 0.1.0 — Initial Release

- Menu bar dictation app for macOS 15+, Apple Silicon.
- ChatGPT (GPT-4o) batch transcription.
- Deepgram Nova-3 streaming transcription with real-time interim results.
- On-device Voice Activity Detection via Apple Neural Engine (FluidAudio / Silero).
- VAD-based auto-chunking and auto-end of session.
- Double-tap Control hotkey (configurable).
- Enter to stop and submit, Escape to cancel.
- Launch at login.
- Per-provider language, chunk duration, silence threshold settings.
