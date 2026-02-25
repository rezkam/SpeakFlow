# SpeakFlow Current Feature Spec (Source of Truth)

Date: 2026-02-23  
Repository: SpeakFlow  
Audience: product/engineering QA review

## 1. Purpose and Scope

This document describes the **current implemented behavior** of SpeakFlow, end-to-end, based on code and tests in this repository.  
It is written as an operational spec: what the app does now, how it does it, and which test suites guard each behavior.

This spec covers:
- Startup and readiness gating
- Recording lifecycle (batch and streaming)
- Focus-safe text insertion and keyboard safety
- Enter submission behavior
- VAD, chunking, auto-end, thinking pause, classifier, idle nudge
- Streaming reliability (keepAlive/reconnect) and commit rules
- Provider/auth behavior
- Metrics and test UX safety
- User stories with acceptance criteria

## 2. System Overview

SpeakFlow is a macOS menu bar dictation app with two runtime paths:

1. **Batch path**  
- Audio captured locally
- Local VAD (`VADProcessor` + `SessionController`) controls speech state/chunking/auto-end
- Chunks are transcribed by a batch provider (ChatGPT or Mistral batch)
- Ordered text output is inserted via `TextInserter`

what we expect here is user starts the app setup a provider that is batch-base and then presses the hotkey to start the dictation and then captured audio is processed locally for VAD and chunking and then sent to the batch provider chunk by chunk then we inset the transcribed text into the target app in a focus-safe way which means we just enter the text in the same app that transcription was started from and if user switch to another app we pause the insertion until user switch back to the original app and also we have the auto-end feature which means if user stop speaking for a certain amount of time (we need to be sure with a high configurable accrecy) that they really stoped talking then we automatically end the session and stop the recording and also we have the thinking pause extension which means if the transcript ends with an incomplete marker like a trailing conjunction we will extend the auto-end timer to give user more time to finish their thought before we end the session but we need to make sure these two are not coliding each other and cause premature auto-end on berif pauses or VAD issues due to long recordings and also make sure to avoid long running wait. Generally it's better to no end the session than ending too early and cause user frustration but we also want to avoid extremely long sessions that never end due to VAD issues or user forgetting to end the session so that needs to be balanced carefully and tested with various edge cases fully tested and also be configurable for different user preferences and use cases. 

in the chuncked model we need to make sure that chunck transctiptions are written to the users input in order no matter on the order they are returned from the provider and we also need to do timeouts and retry for chuncks that are making too much time to get back but in a adaptive matter for the timeout depanding the chunck durations as logger chuncks take more time to get transcribed. all of the behaviors that we have should be configurable from the configurator and have good defaults.

2. **Streaming path**  
- Audio streamed live via WebSocket (Deepgram or Mistral realtime)
- Server events (`interim`, `final`, `speechStarted`, `utteranceEnd`) drive insertion and auto-end timer
- Reliability layer handles keepAlive and one-shot reconnect for transient drops and ensures pending audio is not lost.

the streaming options should also have the option of auto ending the idea is the same and should be applied to both the difference is in chuncked based after stoping we need to get the transaction full text and type it.


## 3. Core Behavioral Contracts (Current)

This section mirrors the protected contracts in `AGENTS.md` and their current implementation.

### 3.1 Dictation Readiness Contract

Dictation is start-ready only when all are true:
- Accessibility granted
- Microphone granted
- At least one configured provider exists otherwise we need to guide the user to set up these and help them with clear instructions.


### 3.2 Hotkey Activation Contract

Supported hotkeys:
- `⌃⌃` (double-tap control button)
- `⌃⌥D`
- `⌃⌥Space`
- `⇧⌘D`

Behavior:
- Hotkey toggles start/stop recording
- While recording pressing the hotkey will stop the recording. 
- During processing-final, hotkey behavior depends on `hotkeyRestartsRecording`
`

### 3.4 Enter Submission Contract

Current behavior: 
Enter capture is a feature to make it easy to stop the recoding and submit the text when the full transcrition text is ready. this feature should be configurable in the setings and enabled by default. 
- Enter capture is **focus-scoped** to the original target app PID we should not cature enter button or escape or any other button other than the hotkey if the user switch to another app and press enter we should not capture it and let it pass through to the current app the only universal capture is the hotkey which is used to start and stop the recording and it should work regardless of the current focused app.
- Enter capture is **one-shot per recording lifecycle**. so if user press the enter we go through getting full text and then we emit one synthetic enter to submit the text and if user press enter again we should not capture it again and let it pass through to the current app so we don't want to capture enter button multiple times and cause multiple submission or other unexpected behavior if user press enter more than 1 times means we should cancel the transcription of remaing text and just submit the current text and also we should make sure that if user press enter button while the focus is not in the target app we should not capture it and let it pass through to the current app because we don't want to interfere with user's normal behavior in other apps.
- First captured Enter:
  - if recording: triggers submit-stop flow (`stopRecordingAndSubmit`)
  - if processing-final: arms single `shouldPressEnterOnComplete`
- Second Enter in same lifecycle passes through normally (not captured by interceptor token).
- Synthetic Enter is emitted once, after pending insertion settles.


### 3.5 Focus-Safe Insertion Contract

Text target is captured at recording start (`captureTarget()`):
- Focused accessibility element
- owning PID
- owning bundle ID

During typing:
- App never force-focuses target app So we don't want to, like, force any focused app or anything like that. If you're not looking for doing these kind of things. We just want to, if the user changes the focused app, Not type something that is for somewhere else. And keep it in memory. But we don't wanna keep it in memory for a very long time. And so we just should have a maximum, like, maximum age for this thing that we we have. Like, we say we keep it for ten minutes. So we can add this as an as a setting as well. That is that is the thing. The other other thing that I would like to have is okay, if you switch the app and you talk, we just keep the buffer for you and until you come back and then start writing. But then if you go to another app, and then press the hotkey okay. We stop. And we keep the text until you come back. But then if you don't come back within a certain amount of time, we just discard the text. So we can have this as a setting as well. So we can say, okay, if you switch the app, we keep the text for you for up to 10 minutes. And then if you come back within 5 min or 10 minutes, we just write it for you.
- If focus leaves target app, insertion pauses and waits for user return before resuming.
- Wait timeout uses `focusWaitTimeout` (default 5m, configurable)
- If timeout expires, pending insertion is discarded
- If app relaunches with new PID but same bundle, target PID is recovered

### 3.6 Modifier-Safe Typing Contract

Typing loop checks hardware modifiers each char:
- Command / Control / Option / Shift
So our intention from this one is to make sure that if we are in the middle of typing and user presses any button on their keyboard. We don't want that to make a combination or anything with with the key presses that we are simulating. So what we do is if we detect anything, we just stop and make sure that the keys are released and then continue. 
If any active:
- Waits up to 100 attempts × 10ms (1s total) for release
- Re-checks focus after release
- Prevents generated shortcut combos (e.g. Cmd+Q)

### 3.7 No Focus-Stealing Contract

No call path brings target app frontmost for insertion.  
Focus recovery is user-driven only.


### 3.8 VAD and Chunk Gating Contract (Batch)

Current VAD features:
- Silero via FluidAudio (`VADProcessor`)
- periodic model state reset (default 5s)
- smoothed RMS volume signal
- speechStart dual gate (probability + smoothed volume)
- speechStart rollback when gate suppresses event

Chunk decision path (`SessionController` + recorder):
- `shouldSendChunk()` requires duration threshold and non-speaking state
- considers post-speech silence boundary
- includes potential-speech hold guard
- force-chunk safety at `maxChunkDuration * 2.0` during continuous speech
- skips silent chunks based on VAD probability threshold if no speech in session
`

### 3.9 Session Auto-End + Thinking Pause Contract (Batch)
So for session auto end, in the back mode, we rely on voice activity detection. But voice activity detection is used for another thing as well. Imagine that we have chunk size of thirty seconds. And we want to, like, end this chunk and send it to the transcription API. But we do not want to send it in the middle of a sentence. So we just wanna make sure that we have We have a we we are restoring this at at a point that user had stopped or start thinking or closed the current like, sentence because that will give the transcription model better context to create a better transcription, which is the power of these batch models because they have the whole like, audio. So they they don't have to rely on the lower probability intrem Results. So for the end of turn, we need to make sure that user is actually silent for the full time that we are checking for the silent. For example, if we if the user has five second silence, that means that user should be fully silent for that five second. And we should okay. There's there should there could be, like, keyboard noises and other type of noises in the environment. But we need to actually, like, with a high probability think that these are not user, like, human voice. And then decide about it and say, this is silence. So we need to make sure that thinking process are used for sending chunks So if you want to send with that thirty second example, if you want to send the the chunk and then we didn't detect a thinking pass or end of sentence, then we can extend it a little bit to a maximum of two times the chunk size. That is the maximum that we can extend it. And then we have to or two times or anything. I think it can be configurable. Criteria. So if yeah. So if if it if it's like, if if we extend it for, like, two second and then we have the full sentence, that will result in a better transcription. That is what we want. 

Auto-end core gates:
- master enabled
- optional no-speech timeout
- optional require-speech-first
- must not be actively speaking
- minimum session duration
- silence threshold after speech end
- fallback path if no speechEnd ever observed

Safety:
- max continuous speaking timeout force-clears stuck speaking state

Thinking pause extension:
- transcript suffix checked by `ThinkingPauseDetector`
- if incomplete pattern detected, silence threshold is extended

Optional turn classifier extension:
- classifier evaluated after minimum silence
- incomplete probability extends threshold

Optional idle nudge sequence:
- emits nudge/final-warning before expiration callback


### 3.10 Live Streaming Reliability Contract
For end of session detection  for the real-time APIs. We can we can rely on the voice activity detection, silence detection, but also since we are having the API will give us back text, we can just detect what is the status of the user if the API gives us voice activity detection statuses or if we don't get any text back. That means silence. So we can increase the chance of actually detecting right amount of silence. Like if the user wants five seconds, we have two signals that we can match together. And yeah, so then we can kind of create probability between them and then we sure that yeah with a higher probability we have the better detection of silence for the user because we don't get texts out of the real-time API but we don't detect anything locally as well. But not just one of them, because there might be issues at the moment with the transcription API, which means that we need to resolve it at a network layer and retry. Like connecting or things like that, but we need to make sure that we are not losing any voice in terms of network issues and like that, but also we do not prematurely and a turn because of network issues and not getting anything back of the like real-time API. So that's the reason that we match this with the voice activity detection that we have locally. And these two together are giving us an amazing model that is working great.

Live streaming controller provides:
- keepAlive task (configurable interval, default 8s)
- one-shot reconnect attempt after unexpected close
- cancellation-safe reconnect task behavior
- queued audio backpressure with bounded pending bytes and dropped-chunk counter
We need to make sure that real-time streaming models are handling the network layer in a very consistent and reliable way. Because the network is... Not predictable, it can be slow, we can have a lot of back pressure or we can get a lot of issues, but we do not want to lose any of the voice that we have. So we need to make sure that we are keeping the voice. Safe and try try to reconnect and send everything and keep and get back the results making sure that we are handling all the requests at network layer in a reliable way reconnecting having timeouts with a good default and trying them. To get to get a good result out of the provider.

### 3.11 Streaming Final Commit Safety Contract

This applies to **streaming transcription events** (not audio chunks).

For each incoming `finalResult` event:
- If it is short (`lexicalWordCount < minimumFinalWordCount`), non-terminal (no strong end punctuation), and `speechFinal == false`, SpeakFlow may **treat it as interim** instead of committing it as a stable final.
- Short text that *does* end with terminal punctuation still commits.
- `speechFinal == true` always commits (utterance boundary from provider).

Purpose:
- Prevent premature commits of unstable short finals (for example fillers) that are often revised by subsequent streaming updates.
- Preserve immediate commit at true utterance boundaries.


### 3.12 Transcription Ordering Contract

`TranscriptionQueue` enforces ordered output by sequence:
- results may arrive out-of-order
- outputs are flushed strictly in-sequence
- stale ticket/session generations are rejected after reset
- completion only signaled after flushed + consumed

Source:
Internal provider/session/transcription implementation.

Guarded by:
- `TranscriptionQueueTests`
- `TranscriptionTests`

### 3.13 Provider Protocol/API Contract

Current providers:
- ChatGPT batch (OAuth)
- Deepgram streaming (API key)
- Mistral realtime streaming (API key)
- Mistral batch (API key, shared with realtime)

Provider behaviors include message parsing and protocol-specific finalize/close semantics.

Source:
Internal provider adapters and transport clients.

Guarded by:
- `DeepgramSessionTests`
- `MistralSessionTests`
- `MistralBatchProviderTests`
- `MistralRealtimeRegressionTests`

### 3.14 Auth/OAuth Safety Contract

ChatGPT auth:
- OAuth PKCE flow
- callback server with expected state
- refresh token coordination to coalesce concurrent refresh requests
- unified credentials storage in `~/.speakflow/auth.json`

Source:
Internal auth controller and credential storage implementation.

Guarded by:
- `AuthTests`
- `AuthControllerDITests`

### 3.15 Performance-Sensitive Audio Contract

Hot path optimizations include:
- vectorized float->int16 conversion in live tap path
- bounded audio queues and caps
- reduced per-sample overhead
- WAV encoder utility using Accelerate

Source:
Internal streaming transport and audio encoding implementation.

Guarded by:
- `PerformanceOptimizationTests`

### 3.16 Metrics and Latency Observability Contract

Lifetime stats:
- seconds transcribed
- words/chars
- API calls
- STT latency samples P50/P95/P99

Per-session metrics:
- words, keepalives, reconnects
- chunk submission/success/fail
- STT latencies

Source:
Internal metrics/statistics and transcription orchestration implementation.

Guarded by:
- `StatisticsTests`
- `SessionMetricsStoreTests`
- `TranscriptionTests`

### 3.17 Test UX Safety Contract

Sounds are muted by default in test/automation contexts:
- xctest env/args detection
- explicit mute env vars
- UI test harness mode

Source:
Runtime sound layer plus test harness mute/automation behavior.

Guarded by:
- `SoundEffectTests`

## 4. End-to-End Flows

### 4.1 App Startup Flow

1. App sets regular activation policy and registers providers.
2. Recording/Auth/Permission controllers are initialized.
3. On normal run:
- permission status is read (no forced prompt at launch)
- optional VAD model warm-up runs in background (if enabled/available)
- optional audio subsystem pre-warm runs only if mic already authorized
4. Hotkey listener is configured from settings.
5. Transcription callbacks are wired.
6. AppState refreshes and settings window is shown.

Key runtime component:
- app startup/orchestration layer

### 4.2 Batch Dictation Flow (ChatGPT or Mistral Batch)

1. User presses hotkey.
2. `RecordingController.startRecording()` checks readiness and configured provider.
3. Target insertion context is captured (`TextInserter.captureTarget()`).
4. Key interceptor starts for target PID.
5. `StreamingRecorder.start()`:
- AVAudioEngine starts
- optional noise gate configured
- VAD + SessionController initialized
- 50ms processing timer and 500ms periodic decision timer start
6. Audio tap buffers float samples; recorder processes queued batches:
- applies optional filter
- appends to AudioBuffer
- runs VAD in 4096-sample chunks
7. VAD events update SessionController speech state.
8. Chunk send occurs on boundary conditions (`shouldSendChunk` / early speechEnd / max duration / force cap).
9. Chunk WAV emitted to Transcription coordinator.
10. Transcription result delivered in strict sequence via queue bridge.
11. `RecordingController` appends transcript and enqueues text insertion.
12. Auto-end may fire based on SessionController rules; controller stops recording.
13. On stop, recorder flushes pending samples and optionally emits final chunk.
14. Completion flow waits for queue + pending insertion, then resets session.
15. If submit Enter was armed, one synthetic Enter is sent once.

### 4.3 Streaming Dictation Flow (Deepgram or Mistral Realtime)

1. User presses hotkey.
2. Same readiness + target capture + key interceptor startup.
3. `LiveStreamingController.start()`:
- audio engine + tap installed
- provider session opened (WebSocket)
- event loop starts
- session activated (audio dispatch enabled)
- keepAlive timer starts if enabled
4. Server events drive text behavior:
- interim: smart suffix diff updates
- final: commit and clear interim state
- speechStarted: cancel silence timer
- utteranceEnd / speechFinal: start silence timer
5. Silence timer auto-ends session if no resumed speech within configured duration.
6. Unexpected close:
- if reconnect enabled and not attempted, performs one reconnect attempt
- otherwise closes and notifies session closed callback
7. Stop flow finalizes and closes session with short wait for trailing finals.
8. Cancel flow closes immediately and removes interim text if needed.

## 5. Input and Text Insertion Spec

### 5.1 Capture and Targeting

At recording start, SpeakFlow captures:
- focused AX element
- target PID
- target bundle identifier

All insertion operations are serialized by task chaining.

### 5.2 Focus-Safe Behavior

Before typing/deleting/enter:
- ensures target app still owns keyboard focus (AX-focused element PID first, frontmost fallback)
- waits for user return if focus moved
- never activates app itself
- aborts operation after timeout

### 5.3 Typing Mechanics

- Text is sanitized to printable/whitespace symbols.
- Insertions are bounded by max length.
- Per-char unicode key events posted with small delay.
- Batch yields keep run loop responsive.

### 5.4 Deletion and Interim Diff

Streaming interim/final updates use suffix diff:
- delete changed tail
- type replacement suffix

This avoids full rewrites/flicker.

### 5.5 Enter Behavior (Current Contract)

While active lifecycle and focus in target app:
- First Enter captured and consumed (one-shot token)
- Second Enter is pass-through

Submit behavior:
- If recording: stop now, finish pending text, then emit one Enter
- If processing-final: arm one Enter emission at completion
- Enter emission happens before text inserter reset

If focus is not in target app:
- interceptor does not capture Enter/Escape; keys behave normally in current app

## 6. VAD / Auto-End Detailed Behavior

### 6.1 VAD Processing

For each chunk:
- compute instant RMS
- update smoothed RMS
- periodic Silero state reset (when safe to reset)
- process via FluidAudio
- apply speechStart volume gate
- rollback triggered state if speechStart suppressed
- emit speech events accordingly

### 6.2 Potential Speech Guard

Recorder marks potential speech-like frames (probability + volume floors) so SessionController can block chunk send/auto-end briefly even before formal `speechStart`.

### 6.3 Auto-End Decision Order (Batch)

When polled:
1. `enabled` check
2. stuck-speaking safety clear
3. no-speech timeout
4. require-speech-first guard
5. speaking guard + potential speech hold guard
6. min session duration
7. silence-after-speech with effective threshold:
- base silence
- plus thinking pause extension if incomplete transcript
- plus classifier extension if predicted incomplete
8. fallback duration path if no speech end seen

## 7. Streaming Event Handling Spec

### 7.0 Realtime Terminology (Streaming)

Streaming mode is continuous WebSocket audio; it does **not** use local audio chunk uploads.

Key terms:
- `interim`
  - A temporary transcription hypothesis from the provider.
  - Can be replaced by later `interim` or `finalResult`.
  - In SpeakFlow, interim updates use suffix diff (delete changed tail + type new tail).
- `finalResult`
  - A provider message that the current segment text is stabilized (subject to provider semantics).
  - SpeakFlow usually commits it, except when short-final safety downgrades it to interim.
- `speechFinal`
  - A boolean on `finalResult` indicating the provider detected an utterance boundary (user stopped speaking for that turn).
  - In SpeakFlow, `speechFinal=true` forces commit and starts post-speech silence timing.
- `speechStarted`
  - Provider event indicating speech has started/resumed.
  - In SpeakFlow, this cancels silence auto-end timer.
- `utteranceEnd`
  - Provider event indicating end of utterance.
  - In SpeakFlow, this starts silence auto-end timer and resets turn-start state.
- `segment`
  - Provider-specific finalized unit of transcript text.
  - Deepgram and Mistral both produce segment/final-style events but with different wire formats.
- `commit`
  - SpeakFlow treats text as stable output and finalizes interim tracking for that segment.
- `downgrade to interim`
  - A `finalResult` is processed as if it were interim when it is likely unstable (short, non-terminal, not `speechFinal`).
- `turn`
  - A user speech phase bounded by provider signals (`speechStarted` → `speechFinal` / `utteranceEnd`).
- `silence timer`
  - Streaming auto-end timer that runs after turn-end signals and is canceled by resumed speech/interim activity.

### 7.1 Interim

- empty interim ignored
- non-empty interim:
  - cancels silence timer
  - computes diff from previous interim
  - applies minimal delete/type operations

### 7.2 Final

- may be downgraded to interim if short non-terminal final rule matches
- otherwise:
  - commits diff against last interim
  - clears interim tracking
  - if `speechFinal`: emits utterance-end callback + starts silence timer

### 7.3 Speech Events

- `speechStarted`: marks speech occurred, cancels silence timer, emits callback
- `utteranceEnd`: starts silence timer, resets turn-start state

### 7.4 Reliability

- keepAlive task sends periodic session keepalive
- unexpected close can trigger one reconnect attempt
- reconnect preserves running audio engine and buffered frames

## 8. Configuration Surface (Current UI-Exposed Settings)

### 8.1 General Tab

- Hotkey choice
- Hotkey restarts recording
- Focus wait timeout
- Launch at login

### 8.2 Transcription Tab - Shared Batch

- Chunk duration
- Skip silent chunks
- VAD enable
- VAD sensitivity threshold
- VAD volume gate enable
- VAD min speech volume
- VAD volume smoothing factor
- VAD state reset interval
- Pre-VAD noise gate enable
- Noise gate RMS threshold
- Auto-end enable
- Auto-end silence duration
- Auto-end min session duration
- Require speech before auto-end
- No-speech timeout
- Max continuous speech safety timeout
- Thinking pause extension enable + seconds
- Turn classifier enable + min silence + extension + threshold
- Idle nudge enable + delay + interval + count
- Minimum speech ratio

### 8.3 Transcription Tab - Shared Streaming

- Streaming auto-end enable
- Silence duration (shared setting key)
- keepAlive enabled
- keepAlive interval
- reconnect enabled
- minimum final words

### 8.4 Provider-Specific

- Deepgram model/language/interim/smart-format/endpointing
- Mistral realtime model/language
- Mistral batch model/language/temperature/diarization/context bias

## 9. Data, Storage, and Persistence

- Settings: UserDefaults (test runs use isolated suite)
- Auth/API keys: `~/.speakflow/auth.json` (0600 permissions)
- Statistics: `~/.speakflow/statistics.json`
- Session metrics: `~/.speakflow/session_metrics.json`

## 10. Regression Gates (Behavior Protection)

Mandatory gates:
1. `make test-regression-core`
2. `swift test`

Behavior guard references:
- Regression matrix for core behavior
- Agent behavior contract for non-regression requirements

## 11. User Stories (Detailed Spec)

Each story is current expected behavior.

### Story 1: Dictation readiness

As a user, I can only start dictation when permissions and provider setup are complete.

Acceptance:
- Given accessibility is off, when I press hotkey, recording does not start.
- Given mic is off, when I press hotkey, recording does not start.
- Given no configured provider, when I press hotkey, recording does not start and an error banner is shown.
- Given all prerequisites are met, when I press hotkey, recording starts.

### Story 2: Start captures the target safely

As a user, text should go to the app/context I started from.

Acceptance:
- Given I start dictation in app A, when recording starts, target PID/bundle are captured.
- Given focus later moves to app B, insertion waits and does not type into B.

### Story 3: Focus loss pauses typing

As a user, if I switch apps during dictation output, typing pauses until I return.

Acceptance:
- Given pending output and target app not focused, insertion loop pauses.
- Given I return to target app before timeout, insertion resumes.
- Given I do not return before timeout, pending insertion is discarded.

### Story 4: Modifier-safe typing

As a user, while holding modifiers, generated text should not trigger shortcuts.

Acceptance:
- Given I hold Command during output, typing waits.
- Given I release Command before timeout, typing continues.
- Given modifiers stay held through timeout, char is not injected under modifier state.

### Story 5: Escape cancel

As a user, pressing Escape during recording cancels transcription flow.

Acceptance:
- Given active recording, when Escape is captured in target app, recording cancels, pending insertion resets, and no final submission occurs.

### Story 6: Enter submit one-shot

As a user, first Enter during active lifecycle submits once; second Enter passes through.

Acceptance:
- Given active recording in target app, when I press Enter first time, recording stops and submit is armed.
- Given I press Enter again in same lifecycle, it is not captured again.
- Given processing finishes, exactly one synthetic Enter is emitted.
- Given focus is not in target app, Enter is not intercepted.

### Story 7: Ordered transcription output

As a user, text appears in recording order even if API responses arrive out-of-order.

Acceptance:
- Given chunk N+1 returns before N, queue buffers N+1.
- When N arrives, N then N+1 emit in order.
- Stale results from previous session generation are discarded.

### Story 8: Batch VAD suppresses noise starts

As a user, keyboard/fan noise should not keep session in false speaking state.

Acceptance:
- Given high probability but low smoothed volume noise frames, speechStart is suppressed.
- Given real speech follows, speechStart emits and session proceeds.
- speechEnd is never blocked by volume gate.

### Story 9: Batch auto-end respects silence rules

As a user, session should end after configured sustained silence, not while speaking.

Acceptance:
- Given user is speaking, auto-end does not fire.
- Given speaking ended and silence >= threshold, auto-end fires.
- Given new speech before threshold, timer effectively resets.

### Story 10: Stuck-speaking safety timeout

As a user, session should not hang forever if VAD gets stuck in speaking.

Acceptance:
- Given speaking flag exceeds max continuous speech duration, SessionController force-clears speaking and resumes normal auto-end path.

### Story 11: Thinking pause extension

As a user, if transcript ends mid-thought, session should wait longer before auto-ending.

Acceptance:
- Given transcript ends with incomplete marker (e.g., trailing conjunction), effective silence threshold is extended.
- Given transcript is complete/punctuated, base threshold applies.

### Story 12: Turn classifier gating (optional)

As a user, with classifier enabled, incomplete turns get extra wait.

Acceptance:
- Given classifier enabled and evaluated probability below threshold, auto-end threshold extends.
- Given probability above threshold, no classifier extension applied.

### Story 13: Idle nudge before auto-end (optional)

As a user, I can receive progressive nudges before expiration.

Acceptance:
- Given idle nudge enabled, auto-end condition starts nudge sequence instead of immediate end.
- After configured nudges, expiration callback triggers auto-end.
- Speech/activity cancels monitoring.

### Story 14: Streaming interim refinement

As a user, streaming text updates should be smooth and minimal.

Acceptance:
- Interim updates use suffix diff (minimal delete/type).
- Identical consecutive interim produces no-op.

### Story 15: Streaming short-final guard

As a user, short non-terminal finals should not be committed too early.

Acceptance:
- Given short non-`speechFinal` without terminal punctuation and word count below threshold, treat as interim.
- Given punctuated short final or `speechFinal`, commit.

### Story 16: Streaming auto-end

As a user, live session ends after sustained post-speech silence when enabled.

Acceptance:
- Given speech occurred and silence timer reaches duration, onAutoEnd fires once.
- Given speech resumes or interim arrives before expiry, silence timer is canceled.

### Story 17: Streaming keepAlive

As a user, long silent pauses should not drop session unexpectedly.

Acceptance:
- Given keepAlive enabled, periodic keepAlive sends while active.
- On stop/cancel/close, keepAlive task is canceled.

### Story 18: Streaming reconnect

As a user, transient WebSocket drops should recover automatically once.

Acceptance:
- Given unexpected close and reconnect enabled, one reconnect attempt is made.
- Given reconnect success, streaming resumes and callback signals reconnection.
- Given reconnect fail or second close, session closes and callback fires.

### Story 19: Auth and account management

As a user, I can authenticate providers safely and switch providers.

Acceptance:
- ChatGPT login uses OAuth flow with callback state validation.
- API keys are validated before save (Deepgram/Mistral).
- Removing active provider key falls back to another configured provider if available.

### Story 20: Test runs are silent

As a developer, automated tests should not play UX sounds.

Acceptance:
- Under xctest/UI test env, `SoundEffect.play()` is suppressed unless explicitly overridden.
- Regression script runs tests with `SPEAKFLOW_MUTE_SOUNDS=1`.

## 12. Notes on Current Defaults and Practical Behavior

- `streamingAutoEndEnabled` defaults to true.
- Batch auto-end silence has min clamp of 3s.
- VAD min-silence-after-speech is currently 3.0s in batch pipeline.
- keepAlive default interval is 8s.
- reconnect default is enabled.
- minimum streaming final word count defaults to 1 (guard effectively off unless raised).
- Turn classifier default is disabled unless user enables it.
- Idle nudge default is disabled unless user enables it.

## 13. Default Settings Matrix (Current)

### 13.1 General / Behavior

| Setting | Default |
|---|---|
| Hotkey | `doubleTapControl` (`⌃⌃`) |
| Hotkey Restarts Recording | `true` |
| Focus Wait Timeout | `60s` |
| Launch at Login | `false` (unless user enables) |

### 13.2 Batch Recording / VAD / Auto-End

| Setting | Default |
|---|---|
| Chunk Duration | `1 minute` (`chunkDuration = .minute1`) |
| Skip Silent Chunks | `true` |
| VAD Enabled | `true` |
| VAD Threshold | `0.15` |
| VAD Min Silence After Speech | `3.0s` |
| VAD Min Speech Duration | `0.25s` |
| VAD Volume Gate Enabled | `true` |
| VAD Min Volume For Speech | `0.008` |
| VAD Volume Smoothing | `0.2` |
| VAD State Reset Interval | `5.0s` |
| Pre-VAD Noise Gate Enabled | `true` |
| Pre-VAD Noise Gate RMS Threshold | `0.002` |
| Auto-End Enabled | `true` |
| Auto-End Silence Duration | `5.0s` (clamped min 3.0) |
| Auto-End Min Session Duration | `2.0s` |
| Auto-End Require Speech First | `true` |
| Auto-End No-Speech Timeout | `10.0s` |
| Auto-End Max Continuous Speech Duration | `180.0s` |
| Thinking Pause Enabled | `true` |
| Thinking Pause Extension | `+5.0s` |
| Turn Classifier Enabled | `false` |
| Turn Classifier Min Silence | `1.5s` |
| Turn Classifier Incomplete Extension | `+3.0s` |
| Turn Classifier Threshold | `0.5` |
| Idle Nudge Enabled | `false` |
| Idle Nudge Initial Delay | `0.0s` |
| Idle Nudge Interval | `3.0s` |
| Idle Nudge Max Count | `2` |
| Min Speech Ratio | `0.01` |

### 13.3 Streaming Reliability / Auto-End

| Setting | Default |
|---|---|
| Streaming Auto-End Enabled | `true` |
| Streaming Silence Duration | Uses shared auto-end silence (`5.0s` default) |
| Streaming KeepAlive Enabled | `true` |
| Streaming KeepAlive Interval | `8.0s` |
| Streaming Reconnect Enabled | `true` |
| Streaming Minimum Final Word Count | `1` |

### 13.4 Provider-Specific Defaults

| Setting | Default |
|---|---|
| Deepgram Model | `nova-3` |
| Deepgram Language | `en-US` |
| Deepgram Interim Results | `true` |
| Deepgram Smart Format | `true` |
| Deepgram Endpointing | `300ms` |
| Mistral Realtime Model | `voxtral-mini-transcribe-realtime-2602` |
| Mistral Language | `en` |
| Mistral Batch Model | `voxtral-mini-latest` |
| Mistral Temperature | `0.0` |
| Mistral Diarization | `false` |
| Mistral Context Bias | empty |

## 14. Terminology Dictionary (Detailed)

This appendix defines runtime terminology exactly as used in code paths.

### 14.1 Session / Lifecycle Terms

| Term | Type | Where it exists | Exact meaning | Primary side effects |
|---|---|---|---|---|
| Recording session | lifecycle scope | `RecordingController` | One user dictation run from start until stop/cancel/finalization completes | Owns target capture, key interception, provider session, transcript accumulation |
| `isRecording` | state flag | `RecordingController` | Active capture/streaming phase | Hotkey toggles to stop path when true |
| `isProcessingFinal` | state flag | `RecordingController` | Post-stop finalization phase while flushing pending work | Enter-submit can still be armed once |
| Start | transition | `startRecording()` | Enter recording mode after readiness/provider checks | Captures target, starts key interception, starts batch or streaming path |
| Stop | transition | `stopRecording(reason:)` | Graceful end preserving final text paths | Waits pending insertions; may synthesize one Enter if requested |
| Cancel | transition | `cancelRecording()` | Immediate abort/discard path | Cancels insertion/recording/transcription and clears transcript |
| Shutdown | lifecycle teardown | `shutdown()` | App termination cleanup | Stops listeners/tasks, flushes stores, resets controller state |
| Recording lifecycle | lifecycle token boundary | key interceptor + controller flags | Boundaries over which one-shot behaviors apply | Enter capture token and `hasCapturedSubmitEnter` reset per lifecycle |

### 14.2 Batch Audio / VAD Terms

| Term | Type | Producer | Meaning | Notes |
|---|---|---|---|---|
| Audio frame | sample block | audio tap | Small PCM sample block from mic callback | Buffered in queue before actor processing |
| Chunk (batch) | upload unit | `StreamingRecorder` | WAV payload sent to batch transcription API | Not used in streaming path |
| Chunk duration | config | `Settings.chunkDuration` | Target maximum span before send decisions | Influences `maxChunkDuration`, `minChunkDuration` |
| `speechStart` | VAD event | `VADProcessor` | Transition to speaking state | May be suppressed by volume gate |
| `speechEnd` | VAD event | `VADProcessor` | Transition to non-speaking after sustained silence | Not volume-gated |
| Potential speech activity | helper signal | `StreamingRecorder` | Speech-like frame signal before formal `speechStart` | Blocks premature chunk/auto-end briefly |
| VAD probability | model output | Silero via FluidAudio | Speech likelihood for processed chunk | Used in skip-silent decisions and logs |
| Smoothed volume | derived signal | `VADProcessor` | Exponential-smoothed RMS used by volume gate | Reduces transient noise false triggers |
| Volume gate | filter gate | `VADProcessor` | Requires smoothed volume >= min threshold before forwarding `speechStart` | Prevents non-vocal starts |
| State reset interval | model maintenance | `VADProcessor` | Periodic hidden-state reset cadence | Mitigates long-session drift |
| Silence threshold (auto-end) | decision threshold | `SessionController` | Required post-speech silence before auto-end | Extended by thinking/classifier logic when enabled |
| Thinking pause | linguistic heuristic | `ThinkingPauseDetector` | Transcript suffix indicates incomplete thought | Extends silence requirement |
| Turn classifier | optional completion scorer | `TurnClassifier` | Probability turn is complete/incomplete | Can extend auto-end threshold |
| Idle nudge | optional feedback sequence | `IdleNudgeController` | Progressive warning callbacks before expiration | Optional; disabled by default |

### 14.3 Streaming (Realtime) Event Terms

| Term | Type | Producer | Meaning in runtime | App behavior |
|---|---|---|---|---|
| Streaming session | transport session | provider WebSocket | Continuous mic stream + event stream | Managed by `LiveStreamingController` |
| `interim` | text event | provider | Provisional text hypothesis | Diff-updates displayed text; cancel silence timer |
| `finalResult` | text event | provider | Stabilized segment text event | Usually committed unless short-final safety downgrades |
| `speechFinal` | flag on `finalResult` | provider | Provider-level utterance boundary marker | Always commits; starts silence timer |
| `speechStarted` | event | provider | Speech resumed/started | Cancels silence timer |
| `utteranceEnd` | event | provider | End of utterance segment | Starts silence timer, resets turn-start state |
| Segment | provider concept | provider | Finalized portion of transcript | Mistral emits `transcription.segment`; Deepgram final results + speech markers |
| Commit | local action | app logic | Treat text as stable output | Clears interim tracking state for that segment |
| Downgrade to interim | local action | app safety heuristic | Process a short non-terminal final as interim | Avoids premature commit noise |
| Silence timer (streaming) | timer task | `LiveStreamingController` | Auto-end countdown after turn-end signals | Canceled by speech/interim activity |
| KeepAlive | transport maintenance | `LiveStreamingController` | Periodic ping to avoid idle socket closure | Configurable interval and toggle |
| Reconnect attempt | transport recovery | `LiveStreamingController` | Single automatic recovery after unexpected close | One-shot per drop path; callback on success |
| Backpressure queue | transport buffer | `AudioSessionRef` | Pending audio frames awaiting send | Bounded byte cap; drops oldest when saturated |

### 14.4 Text Insertion / Input Safety Terms

| Term | Type | Meaning | Safety contract |
|---|---|---|---|
| Target element | accessibility object | Focused AX element captured at start | Insertion tied to original context |
| Target PID | process identity | Owning PID of target element/app | Interception and focus checks scope to this app |
| Focus-safe insertion | insertion policy | Type only when target app owns keyboard focus | Pause on app switch; never force focus |
| Focus wait timeout | behavior setting | Max wait for user to return to target app | Expiry discards pending text |
| Modifier-safe typing | typing guard | Blocks synthetic typing while modifiers held | Prevents generated shortcuts (Cmd+Q, etc.) |
| Enter capture (one-shot) | interception policy | First Enter consumed once per lifecycle | Second Enter passes through |
| Synthetic Enter | insertion action | Programmatic Enter key press after text flush | Used for submit behavior |

### 14.5 Queue / Ordering Terms

| Term | Type | Meaning | Outcome |
|---|---|---|---|
| Sequence (`seq`) | ordering key | Monotonic chunk order in session | Enforces in-order output |
| Session generation | stale-result guard | Incremented on queue reset | Rejects late/stale results from previous session |
| Ticket (`session`, `seq`) | result routing token | Attached to each chunk request | Safe accept/reject logic in queue |
| Flush-ready | queue state | Next expected seq is present | Emits contiguous ordered results |
| Fully delivered | completion condition | Queue flushed and stream consumer consumed yields | Triggers completion callback exactly once |

### 14.6 Auth / Provider Terms

| Term | Type | Meaning | Where |
|---|---|---|---|
| OAuth PKCE | auth mechanism | Secure code flow for ChatGPT auth | `OpenAICodexAuth` |
| API key provider | auth mode | Provider requires stored API key | Deepgram, Mistral |
| Active provider | routing setting | Current provider ID used by recording | `ProviderSettings.activeProviderId` |
| Provider mode | provider capability | `batch` or `streaming` | `TranscriptionProvider.mode` |
| Configured provider | readiness state | Credential/setup complete | Gating for dictation start |

## 15. Full Configuration and Settings Dictionary (Detailed)

This section includes user-visible settings, persisted keys, and internal constants that directly affect behavior.

### 15.1 User-Persisted Settings (`Settings` / UserDefaults)

| Setting property | UserDefaults key | Type | Default | Meaning | Main consumers |
|---|---|---|---|---|---|
| `chunkDuration` | `settings.chunkDuration` | enum | `.minute1` | Target recording chunk window in batch mode | `StreamingRecorder`, UI |
| `skipSilentChunks` | `settings.skipSilentChunks` | Bool | `true` | Skip sending chunk if judged silent and no speech seen in session | `StreamingRecorder.sendChunkIfReady` |
| `vadEnabled` | `settings.vadEnabled` | Bool | `true` | Enables local VAD pipeline in batch mode | `StreamingRecorder.initializeVAD` |
| `vadThreshold` | `settings.vadThreshold` | Float | `0.15` | Silero speech probability threshold | `VADConfiguration` |
| `vadVolumeGateEnabled` | `settings.vad.volumeGateEnabled` | Bool | `true` | Enable dual-gate speechStart filtering | `VADProcessor` |
| `vadMinVolumeForSpeech` | `settings.vad.minVolumeForSpeech` | Float | `0.008` | Min smoothed RMS for speechStart pass | `VADProcessor` |
| `vadVolumeSmoothingFactor` | `settings.vad.volumeSmoothingFactor` | Float | `0.2` | RMS smoothing responsiveness | `VADProcessor` |
| `vadStateResetInterval` | `settings.vad.stateResetInterval` | Double | `5.0` | Periodic VAD model state reset cadence | `VADProcessor` |
| `autoEndEnabled` | `settings.autoEndEnabled` | Bool | `true` | Master auto-end switch (batch) | `SessionController` |
| `autoEndSilenceDuration` | `settings.autoEndSilenceDuration` | Double | `5.0` (clamped >=3) | Required silence after speech for auto-end | `SessionController` |
| `autoEndMinSessionDuration` | `settings.autoEndMinSessionDuration` | Double | `2.0` | Minimum session age before auto-end checks | `SessionController` |
| `autoEndRequireSpeechFirst` | `settings.autoEndRequireSpeechFirst` | Bool | `true` | Blocks auto-end until first speech seen | `SessionController` |
| `autoEndNoSpeechTimeout` | `settings.autoEndNoSpeechTimeout` | Double | `10.0` | End if no speech occurs at all | `SessionController` |
| `autoEndMaxContinuousSpeechDuration` | `settings.autoEndMaxContinuousSpeechDuration` | Double | `180.0` | Stuck-speaking safety force-clear threshold | `SessionController` |
| `thinkingPauseEnabled` | `settings.autoEnd.thinkingPauseEnabled` | Bool | `true` | Enables transcript-based silence extension | `SessionController` |
| `thinkingPauseExtensionSeconds` | `settings.autoEnd.thinkingPauseExtensionSeconds` | Double | `5.0` | Extra wait when incomplete linguistic suffix found | `SessionController` |
| `turnClassifierEnabled` | `settings.autoEnd.turnClassifierEnabled` | Bool | `false` | Enables classifier-assisted completion gating | `SessionController`, `StreamingRecorder` |
| `turnClassifierMinimumSilence` | `settings.autoEnd.turnClassifierMinimumSilence` | Double | `1.5` | Silence before classifier evaluation | `SessionController` |
| `turnClassifierIncompleteExtensionSeconds` | `settings.autoEnd.turnClassifierIncompleteExtensionSeconds` | Double | `3.0` | Extra silence when classifier predicts incomplete | `SessionController` |
| `turnClassifierThreshold` | `settings.autoEnd.turnClassifierThreshold` | Float | `0.5` | Probability cutoff for complete vs incomplete | `SessionController` |
| `idleNudgeEnabled` | `settings.autoEnd.idleNudgeEnabled` | Bool | `false` | Enables nudge sequence before expiration | `StreamingRecorder` |
| `idleNudgeInitialDelay` | `settings.autoEnd.idleNudgeInitialDelay` | Double | `0.0` | Delay before first nudge after condition reached | `IdleNudgeController` |
| `idleNudgeInterval` | `settings.autoEnd.idleNudgeInterval` | Double | `3.0` | Interval between nudge callbacks | `IdleNudgeController` |
| `idleNudgeMaxCount` | `settings.autoEnd.idleNudgeMaxCount` | Int | `2` | Number of nudges before expire callback | `IdleNudgeController` |
| `audioNoiseGateEnabled` | `settings.audio.noiseGateEnabled` | Bool | `true` | Enables pre-VAD noise gate | `StreamingRecorder` |
| `audioNoiseGateRmsThreshold` | `settings.audio.noiseGateRmsThreshold` | Float | `0.002` | RMS cutoff for zeroing low-energy frames | `NoiseGateFilter` |
| `streamingAutoEndEnabled` | `settings.streaming.autoEndEnabled` | Bool | `true` | Enables auto-end timer in streaming mode | `RecordingController` -> `LiveStreamingController` |
| `streamingKeepAliveEnabled` | `settings.streaming.keepAliveEnabled` | Bool | `true` | Enables keepAlive task | `LiveStreamingController` |
| `streamingKeepAliveInterval` | `settings.streaming.keepAliveInterval` | Double | `8.0` | Seconds between keepalive pings | `LiveStreamingController` |
| `streamingReconnectEnabled` | `settings.streaming.reconnectEnabled` | Bool | `true` | Enables one-shot reconnect path | `LiveStreamingController` |
| `streamingMinimumFinalWordCount` | `settings.streaming.minimumFinalWordCount` | Int | `1` | Threshold for short-final downgrade logic | `LiveStreamingController` |
| `minSpeechRatio` | `settings.minSpeechRatio` | Float | `0.01` | Energy ratio fallback setting (legacy/aux use) | UI + compatibility |
| `focusWaitTimeout` | `settings.focusWaitTimeout` | Double | `60.0` | Max wait for user to return focus | `TextInserter` |
| `hotkeyRestartsRecording` | `settings.hotkeyRestartsRecording` | Bool | `true` | Hotkey behavior while processing final | `RecordingController` |
| `deepgramInterimResults` | `settings.deepgram.interimResults` | Bool | `true` | Request interim events from Deepgram | `DeepgramProvider.buildSessionConfig` |
| `deepgramSmartFormat` | `settings.deepgram.smartFormat` | Bool | `true` | Request smart punctuation/casing | `DeepgramProvider.buildSessionConfig` |
| `deepgramEndpointingMs` | `settings.deepgram.endpointingMs` | Int | `300` | Endpointing aggressiveness (ms) | `DeepgramProvider.buildSessionConfig` |
| `deepgramModel` | `settings.deepgram.model` | String | `"nova-3"` | Deepgram model selection | `DeepgramProvider` |
| `deepgramLanguage` | `settings.deepgram.language` | String | `"en-US"` | Deepgram language setting | `DeepgramProvider` |
| `mistralModel` | `settings.mistral.model` | String | `"voxtral-mini-transcribe-realtime-2602"` | Mistral realtime model | `MistralProvider` |
| `mistralBatchModel` | `settings.mistral.batchModel` | String | `"voxtral-mini-latest"` | Mistral batch model | `MistralBatchProvider` |
| `mistralLanguage` | `settings.mistral.language` | String | `"en"` | Mistral language setting (empty allows auto-detect in UI) | Mistral providers |
| `mistralTemperature` | `settings.mistral.temperature` | Float | `0.0` | Batch transcription variability | `MistralBatchProvider` |
| `mistralDiarize` | `settings.mistral.diarize` | Bool | `false` | Speaker diarization toggle (batch) | `MistralBatchProvider` |
| `mistralContextBias` | `settings.mistral.contextBias` | String | `""` | Comma-separated vocabulary hints | `MistralBatchProvider` |

### 15.2 App-Level Preferences (outside `Settings`)

| Property | Storage | Default | Meaning | Consumer |
|---|---|---|---|---|
| `HotkeySettings.currentHotkey` | UserDefaults (`activationHotkey`) | `doubleTapControl` | Selected global hotkey | `HotkeyListener`, UI |
| `ProviderSettings.activeProviderId` | UserDefaults (`provider.active`) | `ProviderId.chatGPT` | Active provider route for recording | `RecordingController` |

### 15.3 Internal Runtime Constants (`Config`) Not Directly User-Editable

| Constant | Default | Purpose | Used by |
|---|---|---|---|
| `silenceThreshold` | `0.003` | Base RMS silence discriminator in tap paths | Recorder/tap fallbacks |
| `silenceDuration` | `2.0` | Fallback non-VAD silence send cadence | Recorder fallback path |
| `minVADSpeechProbability` | `0.20` | Skip-silent cutoff when VAD active | `StreamingRecorder` |
| `sampleRate` | `16000` | Capture/transcription target sample rate | audio pipeline |
| `minRecordingDurationMs` | `250` | Minimum valid final recording duration | stop/final chunk checks |
| `maxAudioSizeBytes` | `25_000_000` | Hard upload cap | transcription providers |
| `maxFullRecordingDuration` | `3600.0` | Buffer capacity guard baseline | `AudioBuffer` |
| `minTimeBetweenRequests` | `10.0` | Base rate-limiter spacing | `RateLimiter` |
| `timeout` | `10.0` | Base transcription timeout | `TranscriptionService` |
| `maxTimeout` | `30.0` | Max scaled timeout | `TranscriptionService` |
| `baseTimeoutDataSize` | `480000` | Size threshold for timeout scaling | `TranscriptionService` |
| `maxRetries` | `3` | Retry attempts for batch requests | `TranscriptionService` |
| `retryBaseDelay` | `1.5` | Exponential backoff base | `TranscriptionService` |
| `maxQueuedTextInsertions` | `10` | Bound insertion task chain depth | `TextInserter` |
| `vadMinSilenceAfterSpeech` | `3.0` | VAD speech-end debounce | `VADConfiguration` |
| `vadMinSpeechDuration` | `0.25` | VAD speech-start debounce | `VADConfiguration` |
| `autoEndSilenceDuration` | `5.0` | Default silence auto-end target | `Settings` defaults |
| `autoEndMinSessionDuration` | `2.0` | Default minimum session age | `Settings` defaults |
| `forceSendChunkMultiplier` | `2.0` | Hard upper bound factor for continuous speech buffering | `StreamingRecorder` |

### 15.4 Streaming Event Fields (Data Contract Reference)

| Event / Field | Data shape | Meaning | Consumed by |
|---|---|---|---|
| `TranscriptionEvent.interim(TranscriptionResult)` | text + metadata | Interim hypothesis | `LiveStreamingController.handleEvent` |
| `TranscriptionEvent.finalResult(TranscriptionResult)` | text + metadata + flags | Stable segment event | `LiveStreamingController.handleEvent` |
| `TranscriptionResult.transcript` | String | Segment text | insertion diff logic |
| `TranscriptionResult.isFinal` | Bool | Provider-stable segment marker | provider semantics/logging |
| `TranscriptionResult.speechFinal` | Bool | Utterance boundary marker | final commit + silence timer |
| `TranscriptionEvent.speechStarted(timestamp:)` | Double timestamp | Speech resumed signal | cancel silence timer |
| `TranscriptionEvent.utteranceEnd(lastWordEnd:)` | Double time | End-of-utterance signal | start silence timer |
| `TranscriptionEvent.metadata(requestId:)` | String | Session metadata | diagnostics |
| `TranscriptionEvent.closed` | no payload | Transport closed | reconnect/close handling |
| `TranscriptionEvent.error(Error)` | error object | Provider/runtime error | error path + stop behavior |

### 15.5 Session/Auto-End Decision Inputs

| Input variable | Meaning | Scope |
|---|---|---|
| `isUserSpeaking` | Current speech-state truth in `SessionController` | batch auto-end + chunk send gates |
| `lastSpeechEndTime` | Timestamp of most recent speech end | silence threshold computation |
| `speakingStartTime` | Timestamp of speech start for stuck-state safety | force-clear safety check |
| `hasSpeechOccurredInSession` | Session-level speech occurrence latch | require-speech-first + skip behavior |
| `lastTranscript` | Current transcript text snapshot | thinking-pause + classifier context |
| `lastTurnCompletionProbability` | Optional completion score | classifier-based threshold extension |
| `lastPotentialSpeechActivityTime` | Recent speech-like frame marker | temporary anti-premature-end guard |

### 15.6 Behavior of Key Threshold Settings (Operational)

| Setting | Lower values generally do | Higher values generally do |
|---|---|---|
| `vadThreshold` | More sensitive to quiet speech/noise | Stricter speech detection |
| `vadMinVolumeForSpeech` | Allows quieter speech starts | Rejects more low-volume transients |
| `vadVolumeSmoothingFactor` | Heavier damping, slower reaction | Faster reaction, less smoothing |
| `autoEndSilenceDuration` | Ends sooner after pauses | Waits longer, fewer premature ends |
| `autoEndNoSpeechTimeout` | Ends idle session sooner | Waits longer before idle-end |
| `autoEndMaxContinuousSpeechDuration` | Triggers safety clear sooner | Allows longer uninterrupted speaking state |
| `streamingKeepAliveInterval` | More frequent keepalive traffic | Less frequent ping traffic |
| `streamingMinimumFinalWordCount` | More short finals downgraded | Fewer short-final downgrades |
| `focusWaitTimeout` | Discards pending text sooner after app switch | Retains pending text longer |

### 15.7 How to Review and Validate Settings Behavior

When reviewing whether settings do what they claim, validate in this order:
- UI label meaning: confirm the label matches the behavioral description in this spec.
- Runtime effect: change one setting at a time and verify only the intended behavior changes.
- Boundary behavior: test minimum, typical, and high values for timing and threshold settings.
- Cross-feature interactions: check that auto-end, focus-safe insertion, and enter-capture rules still hold together.
- Regression safety: run the regression suites after any settings changes.

## 16. External Technologies and Terminology (Human Guide)

This section explains external services/libraries and platform technologies in plain language: what they are, why SpeakFlow uses them, and what behavior they control.

### 16.1 Speech and Audio Intelligence

| Term | What it is | Why SpeakFlow uses it | Practical effect |
|---|---|---|---|
| Silero VAD | A speech activity detector model that estimates whether audio contains human speech | Detect speaking vs silence in local (batch) mode | Drives speech start/end logic, chunk boundaries, and auto-end decisions |
| VAD Probability | The model confidence score (0 to 1) that current audio is speech | Lets the app tune sensitivity instead of using a binary trigger only | Higher threshold reduces false starts; lower threshold catches quieter speech |
| VAD State Reset | Periodic refresh of model internal state during long sessions | Prevents long-session drift where noise can be misread as speech | More stable behavior over multi-minute dictation |
| Thinking Pause Detector | Linguistic heuristic on transcript endings (e.g., trailing conjunctions/fillers) | Reduces premature end when user pauses mid-thought | Extends silence wait when text looks incomplete |
| Turn Classifier (optional) | Additional completion scorer that estimates if the turn is done | Improves end-of-turn quality when enabled | Adds a second gate before auto-end in uncertain pauses |

### 16.2 Audio Processing and Performance

| Term | What it is | Why SpeakFlow uses it | Practical effect |
|---|---|---|---|
| AVAudioEngine | Apple real-time audio graph/capture framework | Reliable microphone capture and low-latency audio tap | Stable live audio ingestion for both batch and streaming |
| Accelerate / vDSP | Apple optimized signal-processing math library | Fast RMS and sample conversion operations | Lower CPU overhead, smoother realtime behavior |
| Noise Gate | Amplitude-based filter that zeros very low-energy frames | Suppress low-level ambient noise before VAD decisions | Fewer non-voice triggers in quiet/noisy environments |
| WAV Encoding | Standard PCM packaging format for audio uploads | Batch providers expect standard audio payloads | Consistent provider compatibility and predictable transcription input |

### 16.3 Realtime Provider Terminology

| Term | Meaning | Why it matters |
|---|---|---|
| Streaming Session | A live WebSocket connection carrying audio up and text/events down | It is the core lifecycle unit in realtime mode |
| Interim | Provider hypothesis text that may still change | Useful for responsiveness; must not be treated as fully stable |
| Final Result | Provider-stabilized text segment | Usually safe to commit into the target app |
| Speech Final | Provider boundary marker that current spoken segment is complete | Strong commit signal; also starts silence countdown |
| Speech Started | Provider signal that user speech resumed | Cancels silence countdown and prevents accidental auto-end |
| Utterance End | Provider signal that the current utterance boundary ended | Starts silence countdown for possible session auto-end |

### 16.4 Network Reliability Terms

| Term | What it means | Why SpeakFlow uses it |
|---|---|---|
| WebSocket KeepAlive | Periodic ping/message to keep idle connections alive | Avoids silent disconnects during pauses/thinking time |
| Reconnect (one-shot) | Automatic single recovery attempt after unexpected close | Handles transient network drops without forcing user restart |
| Backpressure | Outgoing audio produced faster than network can send | Bounded queue avoids unbounded memory growth |
| Pending Audio Buffer | Audio frames waiting to be sent | Preserves continuity across short network delays |

### 16.5 Auth and Security Terms

| Term | What it is | Why it matters |
|---|---|---|
| OAuth PKCE | Secure login flow using proof key challenge | Enables user account auth without exposing long-lived secrets in app flow |
| API Key Auth | Provider access with user-provided key | Needed for providers that do not use interactive OAuth |
| Credential Storage | Local persisted auth data with strict permissions | Keeps provider access durable between app launches |

### 16.6 macOS Input and Safety Terms

| Term | Meaning | Why it matters |
|---|---|---|
| Accessibility Target | The UI element/app captured at dictation start | Ensures insertion returns to original context |
| Focus-Scoped Insertion | Type only when target app is active | Prevents text leaking into the wrong app |
| Modifier-Safe Typing | Pause synthetic typing while user modifier keys are held | Prevents accidental shortcuts such as Cmd+Q |
| Enter Capture (One-Shot) | First Enter can trigger submit-stop flow; next Enter passes through | Prevents repeated interception and preserves user control |

### 16.7 External Provider Roles (Conceptual)

| Provider role | Purpose in product |
|---|---|
| Batch transcription provider | Higher-context transcription from buffered audio chunks |
| Realtime transcription provider | Live event stream for low-latency dictation and immediate feedback |
| Auth-enabled provider | Uses user login flow for access |
| Key-based provider | Uses stored API key for access |
