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

    // Thread-safe reference for audio callback (runs off MainActor)
    private let audioSessionRef = AudioSessionRef()

    // Interim text tracking for replacement
    private var lastInterimText = ""
    private var lastInterimCharCount = 0

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

    // Callbacks
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

    /// Called on error.
    public var onError: ((Error) -> Void)?

    /// Called when the session is fully closed.
    public var onSessionClosed: (() -> Void)?

    /// Called when silence auto-end timer fires (user silent for `autoEndSilenceDuration`).
    public var onAutoEnd: (() -> Void)?

    public init() {}

    /// Thread-safe wrapper so the audio callback (which runs on the audio thread)
    /// can check if streaming is active and send audio without touching @MainActor state.
    private final class AudioSessionRef: @unchecked Sendable {
        private struct State {
            var session: StreamingSession?
            var active: Bool = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        var isActive: Bool {
            state.withLock { $0.active }
        }

        func set(session: StreamingSession?, active: Bool) {
            state.withLock {
                $0.session = session
                $0.active = active
            }
        }

        func sendAudio(_ data: Data) async throws {
            let (s, a) = state.withLock { ($0.session, $0.active) }
            guard a, let s else { return }
            try await s.sendAudio(data)
        }

        func clear() {
            state.withLock {
                $0.session = nil
                $0.active = false
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
            return false
        }

        // Store for reconnection 
        reconnectProvider = provider
        reconnectConfig = config
        hasAttemptedReconnect = false

        do {
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
                guard sessionRef.isActive else { return }

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
                // The 3-step pipeline is byte-identical to the old scalar loop.
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

                Task {
                    try? await sessionRef.sendAudio(pcmData)
                }
            }

            try engine.start()
            self.audioEngine = engine

            // NOW connect to provider (async WebSocket) — audio engine is already running
            // and buffered via sessionRef.isActive being false until we set it below.
            logger.info("Connecting to \(provider.displayName, privacy: .public)...")
            let streamSession = try await provider.startSession(config: config)
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
            return true

        } catch {
            logger.error("Failed to start streaming: \(error.localizedDescription)")
            onError?(error)
            await cleanup()
            return false
        }
    }

    /// Stop streaming: close mic, finalize and close provider session.
    public func stop() async {
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
        audioSessionRef.clear()

        guard isActive else { return }
        isActive = false
        cancelSilenceTimer()
        cancelKeepAliveTimer()

        logger.info("Stopping live streaming...")

        // Flush any pending audio on the server
        do { try await session?.finalize() }
        catch { logger.debug("Session finalize failed: \(error.localizedDescription)") }

        // Wait briefly for final results after finalize
        try? await Task.sleep(for: .seconds(2))

        // Close the WebSocket
        do { try await session?.close() }
        catch { logger.debug("Session close failed: \(error.localizedDescription)") }
        session = nil

        eventTask?.cancel()
        eventTask = nil

        // Clear interim state
        lastInterimText = ""
        lastInterimCharCount = 0
        hasSpeechOccurred = false

        logger.info("Live streaming stopped")
    }

    /// Cancel without waiting for final results.
    public func cancel() async {
        // Cancel any in-flight reconnection attempt so it doesn't resume after we cancel.
        reconnectTask?.cancel()
        reconnectTask = nil

        // ALWAYS tear down mic capture — same rationale as stop().
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioSessionRef.clear()

        guard isActive else { return }
        isActive = false
        cancelSilenceTimer()
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
        hasSpeechOccurred = false

        logger.info("Live streaming cancelled")
    }

    // MARK: - Event Handling

    /// Process a transcription event. Internal for testing.
    internal func handleEvent(_ event: TranscriptionEvent) {
        switch event {
        case .interim(let result):
            guard !result.transcript.isEmpty else { return }
            let newText = result.transcript

            // Speech activity — cancel any silence timer
            hasSpeechOccurred = true
            cancelSilenceTimer()

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
            let newText = result.transcript
            let previousInterimCount = lastInterimCharCount

            // Speech activity — cancel silence timer (will restart on utteranceEnd)
            if !newText.isEmpty {
                hasSpeechOccurred = true
                cancelSilenceTimer()
            }

            // Smart diff: only fix what changed from the last interim
            let (charsToDelete, suffixToType) = diffFromEnd(
                old: lastInterimText, new: newText
            )

            // Final commits the segment — clear interim tracking
            lastInterimText = ""
            lastInterimCharCount = 0

            if !newText.isEmpty {
                if charsToDelete > 0 || !suffixToType.isEmpty {
                    // Text differs from interim — fix the tail
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
                startSilenceTimer()
            }

        case .utteranceEnd:
            logger.info("UtteranceEnd — user stopped speaking")
            onUtteranceEnd?()
            startSilenceTimer()

        case .speechStarted:
            // Speech resumed — cancel silence timer
            hasSpeechOccurred = true
            cancelSilenceTimer()
            onSpeechStarted?()

        case .error(let error):
            logger.error("Provider error: \(error.localizedDescription)")
            onError?(error)

        case .closed:
            logger.info("Provider session closed")
            cancelSilenceTimer()
            cancelKeepAliveTimer()

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
                            // hasAttemptedReconnect remains true — allows ONE retry per unexpected drop
                            // Reset it only on explicit stop/cancel so next unexpected drop also retries
                        } else if Task.isCancelled {
                            // User cancelled during reconnect() — not an unexpected failure.
                            self.logger.info("Reconnect cancelled during provider handshake — no onSessionClosed")
                            await self.cleanup()
                        } else {
                            // Genuine reconnection failure — surface to consumers.
                            self.logger.error("Reconnection failed — surfacing session closed")
                            await self.cleanup()
                            self.onSessionClosed?()
                        }
                    }
                } else {
                    // No reconnection: explicit stop, or already tried, or reconnect disabled
                    if hasAttemptedReconnect {
                        logger.warning("Second close event after reconnect attempt — giving up")
                    }
                    isActive = false
                    Task { @MainActor in
                        await cleanup()
                        onSessionClosed?()
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
    private func startSilenceTimer() {
        guard autoEndSilenceDuration > 0, hasSpeechOccurred else { return }
        cancelSilenceTimer()
        let duration = autoEndSilenceDuration
        silenceTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
                guard let self, self.isActive, !Task.isCancelled else { return }
                self.logger.info("Silence auto-end: \(duration)s of silence after speech")
                self.onAutoEnd?()
            } catch {
                // Task cancelled — speech resumed before timer fired
            }
        }
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
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
        let suffixToType = String(newChars[commonLen...])

        return (charsToDelete, suffixToType)
    }

    /// Atomically transition to the active streaming state.
    /// Groups all related property mutations to prevent inconsistent intermediate state
    /// if `cancel()` is called from another Task during the transition.
    ///
    /// Also starts the keepAlive timer.
    private func activateSession(_ streamSession: StreamingSession) {
        isActive = true
        audioSessionRef.set(session: streamSession, active: true)
        lastInterimText = ""
        lastInterimCharCount = 0
        startKeepAliveTimer()
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
                } catch {
                    // keepAlive failure is non-fatal — connection will drop on its own
                    // if the server has already closed, which triggers .closed event
                    self.logger.warning("KeepAlive send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cancelKeepAliveTimer() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
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
            let newSession = try await provider.startSession(config: config)

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
            return true
        } catch {
            logger.error("Reconnection failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cleanup helpers

    private func cleanup() async {
        cancelKeepAliveTimer()
        audioSessionRef.clear()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        session = nil
        eventTask?.cancel()
        eventTask = nil
        isActive = false
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
        cancelKeepAliveTimer()
        audioSessionRef.clear()
        do { try await session?.close() }
        catch { logger.debug("Session close during reconnect: \(error.localizedDescription)") }
        session = nil
        eventTask?.cancel()
        eventTask = nil
    }
}

// MARK: - Debug / Test Helpers

#if DEBUG
extension LiveStreamingController {
    /// Whether the audio tap reference is currently marked active.
    /// When false, the audio tap silently discards audio instead of sending.
    // swiftlint:disable:next identifier_name
    public var _testAudioSessionRefActive: Bool {
        audioSessionRef.isActive
    }

    /// Whether the audio engine is still allocated (mic capture is running).
    /// nil means the engine has been torn down and mic capture has stopped.
    // swiftlint:disable:next identifier_name
    public var _testAudioEngineIsNil: Bool {
        audioEngine == nil
    }

    /// Inject a dummy audio engine to simulate active mic capture in tests.
    // swiftlint:disable:next identifier_name
    public func _testSetAudioEngine(_ engine: AVAudioEngine?) {
        audioEngine = engine
    }

    /// Force set the audio session ref state for tests.
    // swiftlint:disable:next identifier_name
    public func _testSetAudioSessionRefActive(_ active: Bool, session: StreamingSession) {
        if active {
            audioSessionRef.set(session: session, active: true)
        } else {
            audioSessionRef.clear()
        }
    }
}
#endif
