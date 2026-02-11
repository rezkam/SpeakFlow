@preconcurrency import AVFoundation
import Foundation
import OSLog

// MARK: - Live Streaming Controller

/// Manages a live audio streaming session: captures mic audio and streams it
/// directly to a streaming transcription provider (e.g. Deepgram).
///
/// **No local VAD, no silence detection, no chunking.**
/// All speech detection and endpointing is handled server-side by the provider.
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
    public func start(provider: StreamingTranscriptionProvider, config: StreamingSessionConfig = .default) async -> Bool {
        guard !isActive else {
            logger.warning("Already streaming")
            return false
        }

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

                var pcmData = Data(capacity: frames * 2)
                for i in 0..<frames {
                    let sample = Int16(max(-1, min(1, channelData[i])) * 32767)
                    withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
                }

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
            self.isActive = true
            self.audioSessionRef.set(session: streamSession, active: true)
            self.lastInterimText = ""
            self.lastInterimCharCount = 0

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
        guard isActive else { return }
        isActive = false
        audioSessionRef.clear()
        cancelSilenceTimer()

        logger.info("Stopping live streaming...")

        // Stop mic capture first
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Flush any pending audio on the server
        try? await session?.finalize()

        // Wait briefly for final results after finalize
        try? await Task.sleep(for: .seconds(2))

        // Close the WebSocket
        try? await session?.close()
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
        guard isActive else { return }
        isActive = false
        audioSessionRef.clear()
        cancelSilenceTimer()

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

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
            if isActive {
                // Unexpected close
                isActive = false
                Task { @MainActor in
                    await cleanup()
                    onSessionClosed?()
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

    private func cleanup() async {
        audioSessionRef.clear()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        session = nil
        eventTask?.cancel()
        eventTask = nil
        isActive = false
    }
}
