@preconcurrency import AVFoundation
import Accelerate
import Foundation
import OSLog

// MARK: - Live Streaming Controller
//
// ## keepAlive timer
//
// Both `DeepgramStreamingSession.keepAlive()` and `MistralStreamingSession.keepAlive()`
// were implemented but never called. No timer existed to call them. Deepgram's WebSocket
// server has a ~10-12s idle timeout. If the user pauses dictating for 15+ seconds
// (thinking, reading, distracted), the server silently closes the WebSocket. This
// triggers `.closed`, `onSessionClosed`, and stops recording — the user loses their
// session without any warning.
//
// A background Task (`keepAliveTask`) sends `keepAlive()` every `keepAliveInterval`
// seconds while the session is active. The task is started in `activateSession()` and
// cancelled in `stop()`/`cancel()`. Audio data frames themselves reset the Deepgram
// idle timer, so the explicit KeepAlive message is a safety net for extended silent
// pauses that exceed the server's timeout.
//
// ## Automatic reconnection on unexpected WebSocket drop
//
// If the WebSocket drops due to a network blip (WiFi handoff, sleep/wake, brief
// connectivity loss), the session closes unexpectedly. Without reconnection, the user
// must manually restart — a frustrating experience.
//
// We implement a single reconnection attempt: store the provider and config at session
// start, and on unexpected `.closed`, attempt to reopen the session and resume
// streaming. If reconnection fails, we fall through to the normal `onSessionClosed` path.
//
// **Reconnection contract:**
// - Only attempted once (`hasAttemptedReconnect` flag).
// - Only when `isActive = true` (user didn't explicitly stop).
// - Provider and config stored as `reconnectProvider`/`reconnectConfig`.
// - Audio engine stays running during reconnection — no audio gap.
// - After reconnection, interim text state is reset (the server has no prior context).
//
// **Configuration:**
// - `keepAliveEnabled: Bool` — master switch
// - `keepAliveInterval: TimeInterval` — how often to send KeepAlive (default 8s)
// - `reconnectEnabled: Bool` — whether to attempt reconnection on unexpected close

/// Manages a live audio streaming session: captures mic audio and streams it
/// directly to a streaming transcription provider (e.g. Deepgram).
///
/// **No local VAD, no silence detection, no chunking.**
/// All speech detection and endpointing is handled server-side by the provider.
///
/// ## Reliability features
///
/// - **keepAlive timer:** Sends periodic KeepAlive messages to prevent Deepgram's
///   server-side idle timeout (~10-12s) from closing the WebSocket during user pauses.
///   Controlled by `keepAliveEnabled` and `keepAliveInterval`.
///
/// - **Automatic reconnection:** On unexpected WebSocket drop, attempts to reopen the
///   session once before surfacing the error. Controlled by `reconnectEnabled`.
@MainActor
public final class LiveStreamingController {
    private let logger = Logger(subsystem: "SpeakFlow", category: "LiveStreaming")

    // Audio capture
    private var audioEngine: AVAudioEngine?
    private var session: StreamingSession?
    private var eventTask: Task<Void, Never>?
    internal var isActive = false
    /// Increments whenever an initial startup is superseded or explicitly stopped.
    /// A provider handshake may complete after stop/cancel, so its captured
    /// generation must still match before it can activate a returned session.
    private var startupGeneration: UInt64 = 0

    // Thread-safe reference for audio callback (runs off MainActor)
    private let audioSessionRef = AudioSessionRef()

    // Interim text tracking for replacement
    private var lastInterimText = ""
    private var lastInterimCharCount = 0
    private var transcriptionEventSequence: UInt64 = 0
    private var lastTranscriptionEventAt: ContinuousClock.Instant?

    // Silence-based auto-end (server-side detection only, no local VAD)
    internal var silenceTimer: Task<Void, Never>?
    internal var hasSpeechOccurred = false

    /// Seconds of server-detected silence before auto-ending. 0 = disabled.
    public var autoEndSilenceDuration: Double = 0

    // MARK: - KeepAlive

    /// Whether to send periodic KeepAlive messages to the provider.
    /// Prevents server-side idle timeout from closing the WebSocket during user pauses.
    /// Defaults to `true`. Set to `false` for providers that don't need it (e.g., Mistral).
    public var keepAliveEnabled: Bool = true

    /// How often to send KeepAlive messages (seconds).
    /// Must be shorter than the provider's idle timeout. Deepgram's is ~10-12s.
    /// Default: 8 seconds — provides comfortable margin below Deepgram's threshold.
    public var keepAliveInterval: TimeInterval = 8.0

    /// Background task that periodically sends KeepAlive messages.
    internal var keepAliveTask: Task<Void, Never>?

    // MARK: - Reconnection

    /// Whether to attempt one automatic reconnection on unexpected WebSocket drop.
    /// Defaults to `true`. Covers WiFi glitches, sleep/wake, brief connectivity loss.
    public var reconnectEnabled: Bool = true

    // MARK: - Final Result Commit Guard

    /// Minimum number of lexical words required before committing a non-`speechFinal`
    /// final result to the text field.
    ///
    /// Short one-word non-terminal finals (for example "uh") are often revised by
    /// subsequent streaming updates. Treating them as interim reduces noisy commits.
    ///
    /// Guard rails:
    /// - `speechFinal=true` always commits (utterance boundary).
    /// - Text with terminal punctuation commits even if short (e.g. "Yes.").
    public var minimumFinalWordCount: Int = Config.defaultStreamingMinimumFinalWordCount

    /// Stored provider reference for reconnection. Set when `start()` is called.
    internal var reconnectProvider: (any StreamingTranscriptionProvider)?

    /// Stored session config for reconnection. Set when `start()` is called.
    internal var reconnectConfig: StreamingSessionConfig?

    /// Whether a reconnection attempt is currently in progress or has already been made.
    /// Reset to `false` on successful reconnection so future drops can retry again.
    internal var hasAttemptedReconnect: Bool = false

    /// The in-flight reconnection Task, if any. Used by `stop()`/`cancel()` to
    /// interrupt an ongoing reconnect attempt.
    internal var reconnectTask: Task<Void, Never>?

    /// Suppress `onSessionClosed` when shutdown was explicitly user-initiated
    /// (stop/cancel). Cleared on (re)activation.
    internal var suppressSessionClosedCallback = false

    // Callbacks
    /// Called after local microphone capture starts, before provider readiness.
    /// Startup audio remains buffered until a streaming session is available.
    public var onAudioCaptureStarted: (() -> Void)?

    /// Called when new text should be inserted.
    /// - `textToType`: the characters to type (may be just a suffix if smart-diff applies)
    /// - `replacingChars`: how many chars to backspace before typing
    /// - `isFinal`: whether this completes a transcription segment
    /// - `fullText`: the complete text of this segment (for transcript tracking)
    public var onTextUpdate: ((_ textToType: String, _ replacingChars: Int, _ isFinal: Bool, _ fullText: String) -> Void)?

    /// Called when the provider detects the user stopped speaking (utterance boundary).
    public var onUtteranceEnd: (() -> Void)?

    /// Called when speech starts (provider-detected).
    public var onSpeechStarted: (() -> Void)?

    /// Called once per turn when configured start strategy is satisfied.
    public var onTurnStarted: ((TurnStartTrigger) -> Void)?

    /// Called each time a keepAlive ping is sent successfully.
    public var onKeepAliveSent: (() -> Void)?

    /// Called after an automatic reconnection succeeds.
    public var onReconnected: (() -> Void)?

    /// Called on error.
    public var onError: ((Error) -> Void)?

    /// Called when the session is fully closed.
    public var onSessionClosed: (() -> Void)?

    /// Called when silence auto-end timer fires (user silent for `autoEndSilenceDuration`).
    public var onAutoEnd: (() -> Void)?

    /// Correlation ID propagated from RecordingController for observability.
    public var sessionId: UUID?

    /// Strategies used to detect turn start. Default preserves current behavior.
    public var turnStartStrategies: [TurnStartStrategy] = [.providerSpeechStarted]

    private var hasStartedTurn = false

    /// When `true`, `start()` skips all `AVAudioEngine` / CoreAudio setup so unit tests
    /// never touch the real microphone, install audio taps, or consume mic permissions.
    /// Passed in by `RecordingController` when `testMode == .live`.
    private let skipAudioEngineForTesting: Bool

    public init(skipAudioEngineForTesting: Bool = false) {
        self.skipAudioEngineForTesting = skipAudioEngineForTesting
    }

    private func observabilityEvent(
        _ name: String,
        level: ObservabilityEventLevel = .info,
        metadata: @autoclosure () -> [String: String] = [:]
    ) {
        let settings = Settings.shared
        guard settings.observabilityEnabled,
              settings.observabilityVerbosity.includes(level) else { return }
        let sessionId = self.sessionId
        let payload = metadata()
        Task {
            await ObservabilityStore.shared.record(
                component: "LiveStreamingController",
                name: name,
                level: level,
                sessionId: sessionId,
                metadata: payload
            )
        }
    }

    /// Thread-safe wrapper so the audio callback (which runs on the audio thread)
    /// can check if streaming is active and send audio without touching @MainActor state.
    private final class AudioSessionRef: @unchecked Sendable {
        private struct State {
            var session: StreamingSession?
            var active: Bool = false
            var pendingAudio: ArraySlice<Data> = []
            var pendingBytes = 0
            var droppedChunks = 0
            var isShutdown = false
        }

        private static let maxBufferedAudioBytes = 1_000_000
        private let logger = Logger(subsystem: "SpeakFlow", category: "LiveStreamingAudio")
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let sendSignalContinuation: AsyncStream<Void>.Continuation
        private let sendSignalStream: AsyncStream<Void>
        private var senderTask: Task<Void, Never>?
#if DEBUG
        private var deinitHandler: (@Sendable () -> Void)?
#endif

        init() {
            var continuation: AsyncStream<Void>.Continuation!
            self.sendSignalStream = AsyncStream<Void> { c in
                continuation = c
            }
            self.sendSignalContinuation = continuation
            self.senderTask = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.runSenderLoop()
            }
        }

        deinit {
            shutdown()
#if DEBUG
            deinitHandler?()
#endif
        }

#if DEBUG
        func setDeinitHandler(_ handler: @escaping @Sendable () -> Void) {
            deinitHandler = handler
        }
#endif

        var isActive: Bool {
            state.withLock { $0.active }
        }

        var pendingChunkCount: Int {
            state.withLock { $0.pendingAudio.count }
        }

        var droppedChunkCount: Int {
            state.withLock { $0.droppedChunks }
        }

        var isShutdown: Bool {
            state.withLock { $0.isShutdown }
        }

        func set(session: StreamingSession?, active: Bool) {
            let shouldSignal = state.withLock { state in
                guard !state.isShutdown else { return false }
                state.session = session
                state.active = active
                return active && session != nil && !state.pendingAudio.isEmpty
            }
            if shouldSignal {
                sendSignalContinuation.yield(())
            }
        }

        func enqueueAudio(_ data: Data) {
            guard !data.isEmpty else { return }
            let shouldSignal = state.withLock { state in
                guard !state.isShutdown else { return false }
                if data.count > Self.maxBufferedAudioBytes {
                    state.droppedChunks &+= 1
                    return false
                }

                while state.pendingBytes + data.count > Self.maxBufferedAudioBytes,
                      !state.pendingAudio.isEmpty {
                    let dropped = state.pendingAudio.removeFirst()
                    state.pendingBytes -= dropped.count
                    state.droppedChunks &+= 1
                }

                state.pendingAudio.append(data)
                state.pendingBytes += data.count
                return state.active && state.session != nil
            }
            if shouldSignal {
                sendSignalContinuation.yield(())
            }
        }

        func deactivatePreservingBuffer() {
            state.withLock {
                guard !$0.isShutdown else { return }
                $0.session = nil
                $0.active = false
            }
        }

        func clear() {
            state.withLock {
                $0.session = nil
                $0.active = false
                $0.pendingAudio.removeAll()
                $0.pendingBytes = 0
            }
        }

        /// Terminates the sender task and permanently invalidates this reference.
        /// Reconnect uses `deactivatePreservingBuffer()` instead so the sender stays reusable.
        func shutdown() {
            let shouldFinish = state.withLock { state in
                guard !state.isShutdown else { return false }
                state.isShutdown = true
                state.session = nil
                state.active = false
                state.pendingAudio.removeAll()
                state.pendingBytes = 0
                return true
            }
            guard shouldFinish else { return }
            senderTask?.cancel()
            senderTask = nil
            sendSignalContinuation.finish()
        }

        private func runSenderLoop() async {
            for await _ in sendSignalStream {
                while let (session, frame) = dequeueFrameIfActive() {
                    do {
                        try await session.sendAudio(frame)
                    } catch {
                        logger.warning("Audio send failed: \(error.localizedDescription, privacy: .public)")
                        state.withLock { $0.active = false }
                        break
                    }
                }

                if Task.isCancelled {
                    break
                }
            }
        }

        private func dequeueFrameIfActive() -> (StreamingSession, Data)? {
            state.withLock { state in
                guard state.active,
                      let session = state.session,
                      !state.pendingAudio.isEmpty else { return nil }
                let frame = state.pendingAudio.removeFirst()
                state.pendingBytes -= frame.count
                return (session, frame)
            }
        }
    }

    public var recording: Bool { isActive }

    /// Start streaming: open mic, connect to provider, stream audio.
    ///
    /// Stores the provider and config for potential reconnection.
    public func start(provider: StreamingTranscriptionProvider, config: StreamingSessionConfig = .default) async -> Bool {
        guard !isActive else {
            logger.warning("Already streaming")
            observabilityEvent("start_rejected_already_active", level: .warning)
            return false
        }
        observabilityEvent(
            "start_requested",
            metadata: [
                "providerId": provider.id,
                "sampleRate": String(config.sampleRate),
                "encoding": config.encoding.rawValue,
                "skipAudioEngineForTesting": skipAudioEngineForTesting ? "true" : "false"
            ]
        )

        // New session lifecycle begins; unexpected close callbacks are allowed again.
        suppressSessionClosedCallback = false
        startupGeneration &+= 1
        let generation = startupGeneration

        // Store for reconnection 
        reconnectProvider = provider
        reconnectConfig = config
        hasAttemptedReconnect = false

        do {
            // --- Audio engine setup (skipped in unit tests) ---
            // skipAudioEngineForTesting is set by RecordingController when testMode == .live
            // so tests never touch the real microphone, install CoreAudio taps, or hold
            // mic permissions.  All logic below this block runs in both paths.
            if !skipAudioEngineForTesting {
            // Set up audio engine FIRST — synchronously, before any await.
            // AVAudioEngine / CoreAudio internally asserts on dispatch_get_main_queue().
            // After an await, Swift concurrency may resume on a cooperative thread pool
            // thread that satisfies @MainActor but isn't the real main dispatch queue,
            // causing "BUG IN CLIENT OF LIBDISPATCH" assertion failures.
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(config.sampleRate),
                channels: 1,
                interleaved: false
            ) else {
                logger.error("Failed to create audio format")
                return false
            }

            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                logger.error("Failed to create audio converter")
                return false
            }

            let sampleRate = Double(config.sampleRate)
            let sessionRef = self.audioSessionRef

            // Install audio tap — runs on audio thread, uses thread-safe sessionRef.
            // Must NOT capture self or any @MainActor state — Swift 6 inserts
            // isolation checks that crash on the audio thread.
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { @Sendable buffer, _ in
                let inputSampleRate = inputFormat.sampleRate
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / inputSampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }

                var error: NSError?
                nonisolated(unsafe) var consumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, status in
                    if consumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    status.pointee = .haveData
                    return buffer
                }

                guard let channelData = convertedBuffer.floatChannelData?[0] else { return }
                let frames = Int(convertedBuffer.frameLength)

                // ── Vectorised float→int16 PCM conversion ─────────────────────────
                //
                // Previous: per-sample loop with 341 iterations, each calling
                //   `withUnsafeBytes(of:) { pcmData.append(contentsOf: $0) }`
                //   → 341 function calls + bounds checks per 21ms tap callback
                //   → ~16,000 calls/sec on the real-time audio thread
                //
                // Now: vDSP 3-step pipeline + one Data copy — zero per-sample overhead.
                //   1. vDSP_vclip: clamp to [-1, 1]  (= max(-1, min(1, x)))
                //   2. vDSP_vsmul: multiply by 32767  (= scale to Int16 range)
                //   3. vDSP_vfix16: truncate to Int16  (= Int16(Float) truncation)
                //
                // This is the hottest code path in the app (fires every ~21ms).
                // All three vDSP calls operate in-place on a stack-like scratch buffer,
                // keeping the real-time audio thread allocation-free and branch-free.
                //
                // NOTE: vDSP_vfixr16 (rounds instead of truncates) is NOT used here —
                // it would collapse [-1,1] to {-1,0,1} without a pre-scale step.
                // The 3-step pipeline keeps conversion deterministic and allocation-free.
                let n = vDSP_Length(frames)
                // `UnsafeBufferPointer` → mutable scratch. channelData is owned by
                // convertedBuffer which lives for the full closure scope.
                var scratch = [Float](UnsafeBufferPointer(start: channelData, count: frames))
                var low: Float = -1.0, high: Float = 1.0, scale: Float = 32767.0
                vDSP_vclip(scratch, 1, &low, &high, &scratch, 1, n)
                vDSP_vsmul(scratch, 1, &scale, &scratch, 1, n)
                var int16Buffer = [Int16](repeating: 0, count: frames)
                vDSP_vfix16(scratch, 1, &int16Buffer, 1, n)
                let pcmData = int16Buffer.withUnsafeBytes { Data($0) }
                sessionRef.enqueueAudio(pcmData)
            }

            try engine.start()
            self.audioEngine = engine
            onAudioCaptureStarted?()
            observabilityEvent("audio_capture_started", metadata: ["providerId": provider.id])
            } else {
                // Test mode has no physical engine, but it models a successful local
                // capture start so controller-level lifecycle tests cover this boundary.
                onAudioCaptureStarted?()
            } // end if !skipAudioEngineForTesting

            // NOW connect to provider (async WebSocket) — audio engine is already running
            // and buffered via sessionRef.isActive being false until we set it below.
            logger.info("Connecting to \(provider.displayName, privacy: .public)...")
            let streamSession = try await provider.startSession(config: config)

            // Provider connection is asynchronous. If the user stopped or
            // cancelled while it was in flight, do not revive capture with this
            // late session. Closing it prevents an orphan WebSocket.
            guard generation == startupGeneration, !Task.isCancelled else {
                logger.info("Initial streaming start invalidated before provider session became ready")
                observabilityEvent("start_invalidated_after_handshake", level: .debug)
                try? await streamSession.close()
                return false
            }

            await streamSession.setObservabilitySessionId(sessionId)

            // Setting transport observability can suspend too. Recheck the same
            // lifecycle generation before storing or activating the session.
            guard generation == startupGeneration, !Task.isCancelled else {
                logger.info("Initial streaming start invalidated while configuring provider session")
                observabilityEvent("start_invalidated_during_session_configuration", level: .debug)
                try? await streamSession.close()
                return false
            }

            self.session = streamSession

            // Start listening to events
            eventTask = Task { [weak self] in
                for await event in streamSession.events {
                    self?.handleEvent(event)
                }
            }

            // Activate streaming — audio tap will now send data to provider
            activateSession(streamSession)

            logger.info("Live streaming started: \(provider.displayName, privacy: .public), \(config.sampleRate)Hz, \(config.encoding.rawValue)")
            observabilityEvent("start_succeeded", metadata: ["providerId": provider.id])
            return true

        } catch {
            guard generation == startupGeneration, !Task.isCancelled else {
                logger.info("Initial streaming start ended after invalidation")
                return false
            }
            logger.error("Failed to start streaming: \(error.localizedDescription)")
            observabilityEvent(
                "start_failed",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            onError?(error)
            await cleanup()
            return false
        }
    }

    /// Stop streaming: close mic, finalize and close provider session.
    public func stop(trailingFinalTimeout: Double = 2.0) async {
        observabilityEvent(
            "stop_requested",
            metadata: ["trailingFinalTimeout": String(format: "%.3f", trailingFinalTimeout)]
        )
        // Explicit user action: suppress onSessionClosed for this shutdown path.
        suppressSessionClosedCallback = true
        startupGeneration &+= 1

        // Cancel any in-flight reconnection attempt so it doesn't resume after we stop.
        reconnectTask?.cancel()
        reconnectTask = nil

        // ALWAYS tear down mic capture, even if isActive is false.
        // During reconnection, isActive is temporarily false but the audio engine
        // is intentionally left running for seamless reconnect. If the user presses
        // stop during that window, we must immediately stop capture — leaving the
        // mic open violates the user's expectation that stop means stop.
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioSessionRef.shutdown()

        // It is possible we're already inactive (e.g. during a reconnect window).
        // But we still need to tear down the session and timers.
        isActive = false
        cancelSilenceTimer(reason: "stopRequested")
        cancelKeepAliveTimer()

        logger.info("Stopping live streaming...")

        // A start that is still connecting has no session and therefore no
        // server-side finals to flush. Do not hold the UI in processing-final
        // for the normal trailing timeout in that case.
        if let activeSession = session {
            do { try await activeSession.finalize() }
            catch { logger.debug("Session finalize failed: \(error.localizedDescription)") }

            // Wait briefly for post-finalize trailing finals, but close early once
            // transcription events have gone quiet.
            await waitForTrailingFinals(maxWait: trailingFinalTimeout)

            // Close the WebSocket
            do { try await activeSession.close() }
            catch { logger.debug("Session close failed: \(error.localizedDescription)") }
        }
        session = nil

        eventTask?.cancel()
        eventTask = nil

        // Clear interim state
        lastInterimText = ""
        lastInterimCharCount = 0
        transcriptionEventSequence = 0
        lastTranscriptionEventAt = nil
        hasSpeechOccurred = false

        logger.info("Live streaming stopped")
        observabilityEvent("stop_completed")
    }

    /// Cancel without waiting for final results.
    public func cancel() async {
        observabilityEvent("cancel_requested", level: .warning)
        // Explicit user action: suppress onSessionClosed for this shutdown path.
        suppressSessionClosedCallback = true
        startupGeneration &+= 1

        // Cancel any in-flight reconnection attempt so it doesn't resume after we cancel.
        reconnectTask?.cancel()
        reconnectTask = nil

        // ALWAYS tear down mic capture — same rationale as stop().
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioSessionRef.shutdown()

        // Just like stop(), tear down the rest even if already inactive.
        isActive = false
        cancelSilenceTimer(reason: "cancelRequested")
        cancelKeepAliveTimer()

        try? await session?.close()
        session = nil

        eventTask?.cancel()
        eventTask = nil

        // If there's interim text showing, tell the caller to remove it
        if lastInterimCharCount > 0 {
            onTextUpdate?("", lastInterimCharCount, true, "")
        }
        lastInterimText = ""
        lastInterimCharCount = 0
        transcriptionEventSequence = 0
        lastTranscriptionEventAt = nil
        hasSpeechOccurred = false

        logger.info("Live streaming cancelled")
        observabilityEvent("cancel_completed", level: .warning)
    }

    /// Wait for trailing transcription events after finalize.
    /// Honors the full configured timeout when nothing new arrives, but closes
    /// early once actual post-finalize transcription activity has gone quiet.
    private func waitForTrailingFinals(maxWait: Double) async {
        let boundedMaxWait = max(0.0, maxWait)
        guard boundedMaxWait > 0 else { return }
        observabilityEvent(
            "trailing_finals_wait_start",
            level: .debug,
            metadata: ["maxWait": String(format: "%.3f", boundedMaxWait)]
        )

        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + .seconds(boundedMaxWait)
        let sequenceAtFinalize = transcriptionEventSequence

        // Once trailing events stop changing, close quickly.
        let quietWindowSeconds = min(boundedMaxWait, 0.22)
        let pollIntervalSeconds = min(boundedMaxWait, 0.02)

        while clock.now < deadline {
            if Task.isCancelled { break }

            if transcriptionEventSequence != sequenceAtFinalize,
               let lastEventAt = lastTranscriptionEventAt {
                if clock.now >= lastEventAt + .seconds(quietWindowSeconds) {
                    break
                }
            }

            if pollIntervalSeconds > 0 {
                try? await Task.sleep(for: .seconds(pollIntervalSeconds))
            } else {
                await Task.yield()
            }
        }
        observabilityEvent("trailing_finals_wait_end", level: .debug)
    }

    // MARK: - Event Handling

    /// Process a transcription event. Internal for testing.
    // swiftlint:disable:next cyclomatic_complexity
    internal func handleEvent(_ event: TranscriptionEvent) {
        evaluateTurnStartIfNeeded(for: event)

        switch event {
        case .interim(let result):
            guard !result.transcript.isEmpty else { return }
            markTranscriptionActivity()
            observabilityEvent(
                "event_interim",
                level: .debug,
                metadata: ["characters": String(result.transcript.count)]
            )
            let newText = result.transcript

            // Treat every interim as fresh activity: restart the silence countdown
            // from full duration. This guarantees auto-end fires exactly
            // `autoEndSilenceDuration` after the last text event — even for
            // providers (e.g. Mistral) that never emit `speechFinal`/`utteranceEnd`
            // mid-stream.
            hasSpeechOccurred = true
            startSilenceTimer(source: "interim")

            // Smart diff: only delete/retype the suffix that changed
            let (charsToDelete, suffixToType) = diffFromEnd(
                old: lastInterimText, new: newText
            )
            lastInterimText = newText
            lastInterimCharCount = newText.count

            if charsToDelete > 0 || !suffixToType.isEmpty {
                onTextUpdate?(suffixToType, charsToDelete, false, newText)
            }

        case .finalResult(let result):
            observabilityEvent(
                "event_final",
                level: .debug,
                metadata: [
                    "characters": String(result.transcript.count),
                    "speechFinal": result.speechFinal ? "true" : "false"
                ]
            )
            if shouldTreatFinalAsInterim(result) {
                logger.debug("Short non-terminal final treated as interim: '\(result.transcript, privacy: .private(mask: .hash))'")
                let downgraded = TranscriptionResult(
                    transcript: result.transcript,
                    confidence: result.confidence,
                    start: result.start,
                    duration: result.duration,
                    words: result.words,
                    isFinal: false,
                    speechFinal: false
                )
                handleEvent(.interim(downgraded))
                return
            }

            markTranscriptionActivity()
            let newText = result.transcript
            let previousInterimCount = lastInterimCharCount

            // Speech activity — restart silence timer so it counts down from this
            // event. The full duration always elapses between the last text event
            // and auto-end firing.
            if !newText.isEmpty {
                hasSpeechOccurred = true
                startSilenceTimer(source: "final")
            }

            // Smart diff: update only what changed from the last interim
            let (charsToDelete, suffixToType) = diffFromEnd(
                old: lastInterimText, new: newText
            )

            // Final commits the segment — clear interim tracking
            lastInterimText = ""
            lastInterimCharCount = 0

            if !newText.isEmpty {
                if charsToDelete > 0 || !suffixToType.isEmpty {
                    // Text differs from interim — update only the tail
                    onTextUpdate?(suffixToType, charsToDelete, true, newText)
                } else {
                    // Identical to interim — just commit (no keystrokes needed)
                    onTextUpdate?("", 0, true, newText)
                }
            } else if previousInterimCount > 0 {
                // Empty final but we had interim text — remove it all
                onTextUpdate?("", previousInterimCount, true, "")
            }

            // If speech_final, the user stopped speaking — start silence timer
            if result.speechFinal {
                logger.info("speech_final detected — user stopped speaking")
                onUtteranceEnd?()
                startSilenceTimer(source: "speechFinal")
                resetTurnStartState()
            }

        case .utteranceEnd:
            logger.info("UtteranceEnd — user stopped speaking")
            observabilityEvent("event_utterance_end", level: .debug)
            onUtteranceEnd?()
            startSilenceTimer(source: "utteranceEnd")
            resetTurnStartState()

        case .speechStarted:
            // Speech resumed — cancel silence timer
            hasSpeechOccurred = true
            cancelSilenceTimer(reason: "speechStarted")
            observabilityEvent("event_speech_started", level: .debug)
            onSpeechStarted?()

        case .error(let error):
            logger.error("Provider error: \(error.localizedDescription)")
            observabilityEvent(
                "event_error",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            onError?(error)

        case .closed:
            logger.info("Provider session closed")
            observabilityEvent("event_closed")
            cancelSilenceTimer(reason: "providerClosed")
            cancelKeepAliveTimer()
            resetTurnStartState()

            if isActive {
                // ── Reconnection attempt ────────────────────────────
                // On unexpected close (user didn't call stop()), attempt one reconnect
                // before surfacing the error. This covers WiFi blips, sleep/wake,
                // and brief connectivity loss.
                //
                // Guard: only reconnect if we haven't already tried (prevents loops)
                // and reconnectEnabled is true.
                if reconnectEnabled, !hasAttemptedReconnect,
                   let provider = reconnectProvider, let config = reconnectConfig {
                    hasAttemptedReconnect = true
                    isActive = false  // temporarily mark inactive during reconnect
                    logger.warning("WebSocket closed unexpectedly — attempting reconnection")
                    observabilityEvent("reconnect_attempt_started", level: .warning)

                    // Store the reconnect task so stop()/cancel() can interrupt it.
                    // If cancelled, the task will exit early and NOT resume streaming.
                    reconnectTask = Task { @MainActor [weak self] in
                        guard let self else { return }

                        // Check for cancellation before proceeding.
                        // Do NOT call onSessionClosed here — cancellation means the user
                        // explicitly called stop()/cancel(), which is a deliberate action,
                        // not an unexpected failure. stop()/cancel() already handles their
                        // own cleanup and the caller knows the session is ending.
                        // Firing onSessionClosed would mislead consumers into showing
                        // error UX for a normal user-initiated stop.
                        if Task.isCancelled {
                            self.logger.info("Reconnect cancelled by user stop/cancel — no onSessionClosed")
                            await self.cleanup()
                            return
                        }

                        // Clean up the dead session (but keep audio engine running)
                        await self.cleanupSessionOnly()

                        // Check for cancellation again after cleanup
                        if Task.isCancelled {
                            self.logger.info("Reconnect cancelled by user stop/cancel — no onSessionClosed")
                            await self.cleanup()
                            return
                        }

                        // Attempt to reopen the session
                        let success = await self.reconnect(provider: provider, config: config)
                        if success {
                            self.logger.info("Reconnection successful")
                            self.observabilityEvent("reconnect_succeeded", level: .warning)
                            // hasAttemptedReconnect remains true — allows ONE retry per unexpected drop
                            // Reset it only on explicit stop/cancel so next unexpected drop also retries
                        } else if Task.isCancelled {
                            // User cancelled during reconnect() — not an unexpected failure.
                            self.logger.info("Reconnect cancelled during provider handshake — no onSessionClosed")
                            await self.cleanup()
                        } else {
                            // Genuine reconnection failure — surface to consumers.
                            self.logger.error("Reconnection failed — surfacing session closed")
                            self.observabilityEvent("reconnect_failed", level: .error)
                            await self.cleanup()

                            // If user stop/cancel raced with reconnect failure, suppress callback.
                            if !Task.isCancelled && !self.suppressSessionClosedCallback {
                                self.onSessionClosed?()
                            }
                        }
                    }
                } else {
                    // No reconnection: explicit stop, or already tried, or reconnect disabled
                    if hasAttemptedReconnect {
                        logger.warning("Second close event after reconnect attempt — giving up")
                        observabilityEvent("reconnect_exhausted", level: .error)
                    }
                    isActive = false
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        
                        // User might have explicitly stopped/cancelled right as close arrived.
                        if self.suppressSessionClosedCallback {
                            await self.cleanup()
                            return
                        }
                        
                        await self.cleanup()
                        self.onSessionClosed?()
                    }
                }
            }

        case .metadata:
            break
        }
    }

    // MARK: - Silence Auto-End Timer

    /// Start (or restart) the silence timer. If no speech event arrives within
    /// `autoEndSilenceDuration` seconds, fires `onAutoEnd`.
    /// Only fires if the user has spoken at least once (don't auto-end pure silence).
    private func startSilenceTimer(source: String) {
        guard autoEndSilenceDuration > 0, hasSpeechOccurred else { return }
        cancelSilenceTimer(reason: "timerRestartedBy\(source.capitalized)")
        let duration = autoEndSilenceDuration
        observabilityEvent(
            "streaming_silence_timer_started",
            level: .debug,
            metadata: [
                "source": source,
                "durationSeconds": String(format: "%.3f", duration),
                "durationMilliseconds": String(format: "%.0f", duration * 1000.0)
            ]
        )
        silenceTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
                guard let self, self.isActive, !Task.isCancelled else { return }
                self.logger.info("Silence auto-end: \(duration)s of silence after speech")
                self.observabilityEvent(
                    "streaming_silence_timer_fired",
                    metadata: [
                        "source": source,
                        "durationSeconds": String(format: "%.3f", duration),
                        "durationMilliseconds": String(format: "%.0f", duration * 1000.0)
                    ]
                )
                self.onAutoEnd?()
            } catch {
                // Task cancelled — speech resumed before timer fired
            }
        }
    }

    private func cancelSilenceTimer(reason: String) {
        let hadTimer = silenceTimer != nil
        silenceTimer?.cancel()
        silenceTimer = nil
        if hadTimer {
            observabilityEvent(
                "streaming_silence_timer_cancelled",
                level: .debug,
                metadata: ["reason": reason]
            )
        }
    }

    private func resetTurnStartState() {
        hasStartedTurn = false
    }

    private func evaluateTurnStartIfNeeded(for event: TranscriptionEvent) {
        guard !hasStartedTurn else { return }
        for strategy in turnStartStrategies {
            switch strategy {
            case .providerSpeechStarted:
                if case .speechStarted = event {
                    hasStartedTurn = true
                    onTurnStarted?(.providerSpeechStarted)
                    return
                }
            case .firstTranscription:
                if transcriptText(from: event).isEmpty { continue }
                hasStartedTurn = true
                onTurnStarted?(.firstTranscription)
                return
            case .minimumWords(let minWords):
                let text = transcriptText(from: event)
                guard !text.isEmpty else { continue }
                if lexicalWordCount(in: text) >= max(1, minWords) {
                    hasStartedTurn = true
                    onTurnStarted?(.minimumWords(minWords))
                    return
                }
            }
        }
    }

    private func transcriptText(from event: TranscriptionEvent) -> String {
        switch event {
        case .interim(let result):
            return result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        case .finalResult(let result):
            return result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return ""
        }
    }

    // MARK: - Final Commit Heuristics

    /// Returns true when a short non-terminal "final" should be treated like interim text.
    ///
    /// This prevents one-word fillers from being committed prematurely while preserving
    /// intentional short commands/sentences that are punctuated or speech-final.
    private func shouldTreatFinalAsInterim(_ result: TranscriptionResult) -> Bool {
        guard minimumFinalWordCount > 1 else { return false }
        guard !result.speechFinal else { return false }
        let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return false }
        guard lexicalWordCount(in: transcript) < minimumFinalWordCount else { return false }
        return !hasTerminalPunctuation(transcript)
    }

    /// Counts lexical tokens (letters/digits with optional apostrophes).
    private func lexicalWordCount(in text: String) -> Int {
        var count = 0
        var inToken = false

        for scalar in text.unicodeScalars {
            let isWord = CharacterSet.alphanumerics.contains(scalar) || scalar == "'"
            if isWord {
                if !inToken {
                    count += 1
                    inToken = true
                }
            } else {
                inToken = false
            }
        }
        return count
    }

    /// True when the trimmed text ends in strong terminal punctuation.
    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let trailingClosers = CharacterSet(charactersIn: "\"'”’)]}")
        let terminalPunctuation = CharacterSet(charactersIn: ".!?;:…")
        var scalars = Array(text.unicodeScalars)

        while let last = scalars.last, trailingClosers.contains(last) {
            scalars.removeLast()
        }
        guard let last = scalars.last else { return false }
        return terminalPunctuation.contains(last)
    }

    private func markTranscriptionActivity() {
        transcriptionEventSequence &+= 1
        lastTranscriptionEventAt = ContinuousClock.now
    }

    // MARK: - Smart Diff

    /// Compare old and new text, find the common prefix, and return:
    /// - `charsToDelete`: how many chars to backspace from the end of old text
    /// - `suffixToType`: the new text to type after deleting
    ///
    /// Example: old="Hello worl", new="Hello world!" → delete 0, type "d!"
    /// Example: old="Hello world", new="Hello world" → delete 0, type "" (no-op)
    /// Example: old="Helo world", new="Hello world" → delete 6, type "lo world"
    /// Visible for testing.
    internal func diffFromEnd(old: String, new: String) -> (charsToDelete: Int, suffixToType: String) {
        // Find length of common prefix
        let oldChars = Array(old)
        let newChars = Array(new)
        let commonLen = zip(oldChars, newChars).prefix(while: { $0 == $1 }).count

        let charsToDelete = oldChars.count - commonLen
        let suffixToType = commonLen < newChars.count ? String(newChars[commonLen...]) : ""

        return (charsToDelete, suffixToType)
    }

    /// Atomically transition to the active streaming state.
    /// Groups all related property mutations to prevent inconsistent intermediate state
    /// if `cancel()` is called from another Task during the transition.
    ///
    /// Also starts the keepAlive timer.
    private func activateSession(_ streamSession: StreamingSession) {
        suppressSessionClosedCallback = false
        isActive = true
        audioSessionRef.set(session: streamSession, active: true)
        lastInterimText = ""
        lastInterimCharCount = 0
        transcriptionEventSequence = 0
        lastTranscriptionEventAt = nil
        startKeepAliveTimer()
        observabilityEvent("session_activated", level: .debug)
    }

    // MARK: - KeepAlive timer

    /// Start (or restart) the keepAlive timer.
    ///
    /// Sends a KeepAlive message to the provider every `keepAliveInterval` seconds.
    /// This prevents Deepgram's server-side idle timeout (~10-12s) from closing the
    /// WebSocket when the user is silent (reading, thinking, distracted).
    ///
    /// Audio frames themselves keep the connection alive — this timer is a safety net
    /// for extended silent pauses that exceed the server's timeout.
    ///

    private func startKeepAliveTimer() {
        guard keepAliveEnabled, keepAliveInterval > 0 else { return }
        cancelKeepAliveTimer()
        observabilityEvent(
            "keep_alive_timer_started",
            level: .debug,
            metadata: ["interval": String(format: "%.3f", keepAliveInterval)]
        )

        let interval = keepAliveInterval
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break  // Task cancelled
                }
                guard let self, self.isActive, !Task.isCancelled else { break }
                do {
                    try await self.session?.keepAlive()
                    self.logger.debug("KeepAlive sent (interval=\(interval)s)")
                    self.observabilityEvent("keep_alive_sent", level: .debug)
                    self.onKeepAliveSent?()
                } catch {
                    // keepAlive failure is non-fatal — connection will drop on its own
                    // if the server has already closed, which triggers .closed event
                    self.logger.warning("KeepAlive send failed: \(error.localizedDescription)")
                    self.observabilityEvent(
                        "keep_alive_failed",
                        level: .warning,
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        }
    }

    private func cancelKeepAliveTimer() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        observabilityEvent("keep_alive_timer_cancelled", level: .debug)
    }

    // MARK: - Reconnection

    /// Attempt to reopen the provider session after an unexpected WebSocket close.
    ///
    /// This method:
    /// 1. Opens a new session with the same provider and config
    /// 2. Wires the new session's event stream
    /// 3. Reactivates streaming (audio engine is already running, tap stays installed)
    ///
    /// Returns `true` on success, `false` if the reconnect attempt itself fails.
    ///

    private func reconnect(provider: any StreamingTranscriptionProvider, config: StreamingSessionConfig) async -> Bool {
        do {
            logger.info("Reconnecting to \(provider.displayName)...")
            observabilityEvent("reconnect_attempt_connecting", level: .warning)
            let newSession = try await provider.startSession(config: config)
            await newSession.setObservabilitySessionId(sessionId)

            // CRITICAL: Check for cancellation after the await returns.
            // If the user pressed stop/cancel while startSession was in flight,
            // the Task is now cancelled but startSession returned normally.
            // Without this check, activateSession would resume streaming
            // against explicit user intent.
            guard !Task.isCancelled else {
                logger.info("Reconnect cancelled after provider.startSession returned — closing new session")
                try? await newSession.close()
                return false
            }

            self.session = newSession

            // Wire the new event stream
            let newEventTask = Task { [weak self] in
                for await event in newSession.events {
                    self?.handleEvent(event)
                }
            }
            eventTask?.cancel()
            eventTask = newEventTask

            // Reactivate — audio tap is still installed and running
            activateSession(newSession)
            logger.info("Reconnection complete: \(provider.displayName)")
            onReconnected?()
            return true
        } catch {
            logger.error("Reconnection failed: \(error.localizedDescription)")
            observabilityEvent(
                "reconnect_attempt_failed",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    // MARK: - Cleanup helpers

    private func cleanup() async {
        observabilityEvent("cleanup_full", level: .debug)
        cancelKeepAliveTimer()
        audioSessionRef.shutdown()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        session = nil
        eventTask?.cancel()
        eventTask = nil
        isActive = false
        transcriptionEventSequence = 0
        lastTranscriptionEventAt = nil
    }

    /// Clean up only the session (WebSocket) while keeping the audio engine running.
    /// Used during reconnection to avoid an audio gap.
    ///
    /// IMPORTANT: Must clear audioSessionRef so the audio tap stops dispatching
    /// sendAudio calls to the dead WebSocket. Without this, the tap keeps seeing
    /// the session ref as active (the lock-guarded `active` flag was set by
    /// `activateSession`) and sends audio into the void — silently dropping speech
    /// during the reconnect window and doing unnecessary work.
    /// `activateSession()` re-arms the ref when the new session is ready.
    private func cleanupSessionOnly() async {
        observabilityEvent("cleanup_session_only", level: .debug)
        cancelKeepAliveTimer()
        audioSessionRef.deactivatePreservingBuffer()
        do { try await session?.close() }
        catch { logger.debug("Session close during reconnect: \(error.localizedDescription)") }
        session = nil
        eventTask?.cancel()
        eventTask = nil
        transcriptionEventSequence = 0
        lastTranscriptionEventAt = nil
    }
}

// MARK: - Test Helpers

#if DEBUG
extension LiveStreamingController {
    // swiftlint:disable identifier_name
    /// Whether the audio tap reference is currently marked active.
    /// When false, the audio tap silently discards audio instead of sending.
    public var _testAudioSessionRefActive: Bool {
        audioSessionRef.isActive
    }

    /// Whether the audio engine is still allocated (mic capture is running).
    /// nil means the engine has been torn down and mic capture has stopped.
    public var _testAudioEngineIsNil: Bool {
        audioEngine == nil
    }

    /// Inject a dummy audio engine to simulate active mic capture in tests.
    public func _testSetAudioEngine(_ engine: AVAudioEngine?) {
        audioEngine = engine
    }

    /// Force set the audio session ref state for tests.
    public func _testSetAudioSessionRefActive(_ active: Bool, session: StreamingSession) {
        if active {
            audioSessionRef.set(session: session, active: true)
        } else {
            audioSessionRef.clear()
        }
    }

    public func _testEnqueueAudioFrame(_ data: Data) {
        audioSessionRef.enqueueAudio(data)
    }

    public var _testPendingAudioChunkCount: Int {
        audioSessionRef.pendingChunkCount
    }

    public var _testDroppedAudioChunkCount: Int {
        audioSessionRef.droppedChunkCount
    }

    public var _testAudioSessionRefIsShutdown: Bool {
        audioSessionRef.isShutdown
    }

    public func _testSetAudioSessionRefDeinitHandler(_ handler: @escaping @Sendable () -> Void) {
        audioSessionRef.setDeinitHandler(handler)
    }

    public func _testArmSilenceTimer() {
        self.hasSpeechOccurred = true
        self.startSilenceTimer(source: "test")
    }
    // swiftlint:enable identifier_name
}
#endif
