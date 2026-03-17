# WIP: Transcription Error Banners & Batch Provider Dispatch Fix

**Branch:** `fix/transcription-error-banners-and-batch-provider-dispatch`
**Date started:** 2026-03-17
**Status:** In progress — code changes done, tests need verification + additional tests needed

---

## Problem Summary

Two distinct issues were identified from production logs on a system where the latest Homebrew-installed SpeakFlow was failing silently on every transcription attempt:

### Issue 1: No user-visible feedback on transcription failure

When transcription fails (e.g. expired OAuth tokens, invalid API key, HTTP 403), the app plays an error sound but **never tells the user what went wrong or how to fix it**. The user sees: recording starts → recording stops → error sound → nothing happens. There is no banner, no message, no guidance.

**Evidence from logs** (`~/.speakflow/observability/app/events.jsonl`):
```json
{"name":"chunk_failed","level":"error","metadata":{"error":"HTTP 403: Unknown error","latencyMs":"4742.51"}}
{"name":"chunk_failed","level":"error","metadata":{"error":"HTTP 403: Unknown error","latencyMs":"142.31"}}
{"name":"chunk_failed","level":"error","metadata":{"error":"HTTP 403: Unknown error","latencyMs":"3757.16"}}
{"name":"chunk_failed","level":"error","metadata":{"error":"HTTP 403: Unknown error","latencyMs":"7301.02"}}
```

Every session ended with `"hadTranscript":"false"` and zero words produced. The user had no way to know what was wrong.

### Issue 2: Batch provider dispatch always goes to ChatGPT endpoint (critical bug)

The `Transcription` coordinator always sends audio through `TranscriptionService.shared`, which **hardcodes the ChatGPT endpoint** (`https://chatgpt.com/backend-api/transcribe`). When the user selects **Mistral Batch** as the active provider:

1. `RecordingController.startRecording()` correctly resolves the `MistralBatchProvider`
2. `startBatchRecording()` is called, but **the provider is not passed**
3. Chunks go through `Transcription.transcribe()` → `TranscriptionService.transcribe(audio:)` → ChatGPT endpoint
4. `MistralBatchProvider.transcribe(audio:)` (which calls `https://api.mistral.ai/v1/audio/transcriptions`) is **never invoked**

The Mistral API key is correctly stored in `~/.speakflow/auth.json` under `"mistral": {"api_key": "..."}` and was never the problem — the code path simply never reaches it.

**Contrast with streaming:** The streaming path correctly passes the provider:
```swift
if let streaming = provider as? any StreamingTranscriptionProvider {
    startStreamingRecording(provider: streaming)  // ← provider passed ✅
} else if provider is any BatchTranscriptionProvider {
    startBatchRecording()  // ← provider NOT passed ❌
}
```

---

## Changes Made

### 1. Error banner on transcription failure (Issue 1)

**Files changed:**
- `Sources/SpeakFlowCore/Transcription/TranscriptionError.swift` — Added `isAuthenticationError` property to `TranscriptionError` and a new `TranscriptionErrorKind` enum that classifies any provider error (ChatGPT, Mistral, Deepgram) into `authentication`, `rateLimited`, `network`, or `other`.
- `Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift` — Added `onChunkError: ((Error) -> Void)?` callback to `TranscriptionQueueBridge`.
- `Sources/SpeakFlowCore/Transcription/Transcription.swift` — Calls `queueBridge.onChunkError?(error)` when a chunk fails with a non-cancellation error.
- `Sources/App/RecordingController.swift` — Wires `onChunkError` in `setupTranscriptionCallbacks()` to show a user-facing error banner via `appState.showBanner()`. Error messages are tailored by provider and error kind:
  - **Auth errors (401/403):** "your ChatGPT session has expired. Please re-login in Accounts." or "your Mistral API key is invalid or expired. Check Accounts settings."
  - **Rate limited:** "please wait a moment and try again"
  - **Network errors:** "check your internet connection"
  - **Other:** shows the raw error description
- `Sources/App/RecordingController.swift` — Also dismisses the error banner on successful text delivery (`onTextReady`), so if a subsequent transcription succeeds, the error clears automatically.
- `Sources/App/Protocols/BannerPresenting.swift` — Added `dismissBanner()` to the protocol (already existed on `AppState`, just needed protocol exposure).

### 2. Batch provider dispatch fix (Issue 2)

**Files changed:**
- `Sources/SpeakFlowCore/Transcription/Transcription.swift` — Added `activeBatchProvider: (any BatchTranscriptionProvider)?` property. When set, `transcribe(ticket:chunk:)` dispatches through this provider instead of the default ChatGPT-only `TranscriptionService`. Cleared on `cancelAll()`.
- `Sources/SpeakFlowCore/Protocols/TranscriptionCoordinating.swift` — Added `setActiveBatchProvider(_:)` to the protocol with a default no-op implementation.
- `Sources/App/RecordingController.swift` — `startBatchRecording()` now accepts a `provider: any BatchTranscriptionProvider` parameter and calls `transcription.setActiveBatchProvider(provider)`. The provider is cleared in `completeBatchFinalization()` and `cancelAll()`.

### 3. Test mock updates

**Files changed:**
- `Tests/Mocks/SpyBannerPresenter.swift` — Added `dismissCount` tracking and `dismissBanner()` implementation.
- `Tests/Mocks/SpyTranscription.swift` — Added `activeBatchProvider` tracking and `setActiveBatchProvider(_:)` implementation.

---

## What Still Needs to Be Done

### Tests (required before merge)

1. **Build & test verification** — The full test suite (`make test` or `swift test`) should be run. A build was verified (`swift build` succeeded). The full test suite was started but did not complete within the session — it needs to be run and verified:
   ```bash
   SPEAKFLOW_MUTE_SOUNDS=1 SPEAKFLOW_ISOLATE_TEST_AUDIO=1 swift test
   ```

2. **New tests needed for error banner behavior:**
   - Test that `onChunkError` callback is fired when `Transcription.transcribe()` encounters a non-cancellation failure (add to `Tests/TranscriptionTests.swift`)
   - Test that `onChunkError` is NOT fired on cancellation errors
   - Test that `RecordingController` shows an error banner via `SpyBannerPresenter` when `onChunkError` fires
   - Test that the banner is dismissed when `onTextReady` fires (successful transcription)
   - Test `RecordingController.userFacingMessage(for:providerId:)` returns correct messages for each error kind × provider combination

3. **New tests needed for batch provider dispatch:**
   - Test that `Transcription` dispatches through `activeBatchProvider` when set
   - Test that `Transcription` falls back to default `service` when `activeBatchProvider` is nil
   - Test that `cancelAll()` clears `activeBatchProvider`
   - Test that `RecordingController` calls `setActiveBatchProvider` when starting batch recording with a non-ChatGPT provider (verify via `SpyTranscription.activeBatchProvider`)

4. **Existing test patterns to follow:**
   - `Tests/TranscriptionTests.swift` — `StubTranscriptionService` pattern for injecting failures
   - `Tests/RecordingControllerTests.swift` — `makeTestRecordingController()` factory with `SpyBannerPresenter`
   - `Tests/Mocks/StubProvider.swift` — existing stub provider for tests

### Streaming error banners

The streaming path (`LiveStreamingController`) already has some error handling:
- `onError` callback fires and stops recording
- `onSessionClosed` without text shows a Mistral-specific banner

However, it may benefit from the same `TranscriptionErrorKind`-based classification for consistency. This is a separate enhancement, not blocking.

### Regression test gate

After adding tests, verify the regression gate passes:
```bash
SPEAKFLOW_MUTE_SOUNDS=1 SPEAKFLOW_ISOLATE_TEST_AUDIO=1 make test-regression-core
```

---

## Architecture Notes

### How batch transcription flows (before this fix)

```
User presses hotkey
  → RecordingController.startRecording()
    → resolves provider from ProviderRegistry (e.g. MistralBatchProvider)
    → startBatchRecording()  ← provider was DROPPED here
      → StreamingRecorder captures audio → onChunkReady
        → Transcription.transcribe(ticket, chunk)
          → TranscriptionService.transcribe(audio)  ← ALWAYS ChatGPT endpoint
            → POST https://chatgpt.com/backend-api/transcribe
```

### How batch transcription flows (after this fix)

```
User presses hotkey
  → RecordingController.startRecording()
    → resolves provider from ProviderRegistry (e.g. MistralBatchProvider)
    → startBatchRecording(provider: MistralBatchProvider)
      → transcription.setActiveBatchProvider(provider)
      → StreamingRecorder captures audio → onChunkReady
        → Transcription.transcribe(ticket, chunk)
          → activeBatchProvider.transcribe(audio)  ← Correct provider
            → POST https://api.mistral.ai/v1/audio/transcriptions
```

### Error banner flow (new)

```
Chunk fails (HTTP 403, network error, etc.)
  → Transcription.transcribe() catch block
    → SoundEffect.error.play()  (existing)
    → queueBridge.onChunkError?(error)  (NEW)
      → RecordingController callback
        → TranscriptionErrorKind.classify(error)
        → userFacingMessage(for:providerId:) → tailored message
        → appState.showBanner(message, style: .error, duration: 8)

Chunk succeeds later
  → queueBridge.onTextReady?(text)
    → appState.dismissBanner()  (NEW — clears previous error)
```

### Key files reference

| File | Purpose |
|------|---------|
| `Sources/SpeakFlowCore/Transcription/Transcription.swift` | Coordinator that dispatches chunks to providers |
| `Sources/SpeakFlowCore/Transcription/TranscriptionService.swift` | ChatGPT-only HTTP client (hardcoded endpoint) |
| `Sources/SpeakFlowCore/Transcription/TranscriptionError.swift` | Error types + new classification enum |
| `Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift` | Ordered queue + callbacks (onTextReady, onChunkError) |
| `Sources/SpeakFlowCore/Providers/MistralBatchProvider.swift` | Mistral batch — has its own `transcribe()` that was never called |
| `Sources/SpeakFlowCore/Providers/ChatGPTBatchProvider.swift` | ChatGPT batch — wraps TranscriptionService |
| `Sources/App/RecordingController.swift` | Orchestrates recording, wires callbacks, shows banners |
| `Sources/App/AppState.swift` | Observable state + banner display |
| `~/.speakflow/auth.json` | Unified credential storage (OAuth + API keys) |
| `~/.speakflow/observability/app/events.jsonl` | Structured event log for debugging |

---

## How to Verify the Fix Manually

1. Build and install: `swift build -c release --product SpeakFlow`
2. Copy to Applications: `cp -R .build/release/SpeakFlow /Applications/SpeakFlow.app/Contents/MacOS/`
3. Or build the full app bundle: `bash scripts/build-release.sh 0.0.0-dev`

**Test Mistral Batch:**
1. Open Settings → Accounts → verify Mistral API key is present
2. Open Settings → Transcription → select "Mistral — Batch"
3. Press hotkey → speak → press hotkey to stop
4. Expected: transcription appears (was failing before)
5. If API key is bad: red error banner says "your Mistral API key is invalid or expired"

**Test ChatGPT with expired session:**
1. Open Settings → Transcription → select "ChatGPT — Batch"
2. If OAuth tokens are expired, press hotkey → speak → stop
3. Expected: red error banner says "your ChatGPT session has expired. Please re-login in Accounts."

**Test error banner dismissal:**
1. Trigger a failure (e.g. disconnect network briefly)
2. See error banner appear
3. Reconnect and try again
4. On success, the error banner should auto-dismiss
