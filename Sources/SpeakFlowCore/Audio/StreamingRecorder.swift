import AVFoundation
import Accelerate
import OSLog
import os

/// Audio chunk with metadata
public struct AudioChunk: Sendable {
    public let wavData: Data
    public let durationSeconds: Double
    public let speechProbability: Float

    public init(wavData: Data, durationSeconds: Double, speechProbability: Float = 0) {
        self.wavData = wavData
        self.durationSeconds = durationSeconds
        self.speechProbability = speechProbability
    }
}

/// Thread-safe state container for audio callback
private final class AudioRecordingState: Sendable {
    let sampleRate: Double = 16000

    private struct State {
        var isRecording = false
        var vadActive = false
        var lastSoundTime = Date()
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func setRecording(_ value: Bool) {
        lock.withLock { $0.isRecording = value }
    }

    func getRecording() -> Bool {
        lock.withLock { $0.isRecording }
    }

    func setVADActive(_ value: Bool) {
        lock.withLock { $0.vadActive = value }
    }

    func getVADActive() -> Bool {
        lock.withLock { $0.vadActive }
    }

    func updateLastSoundTime() {
        lock.withLock { $0.lastSoundTime = Date() }
    }

    func setLastSoundTime(_ value: Date) {
        lock.withLock { $0.lastSoundTime = value }
    }

    func getLastSoundTime() -> Date {
        lock.withLock { $0.lastSoundTime }
    }
}

/// Thread-safe queue for passing audio samples from callback to main actor
private final class AudioSampleQueue: @unchecked Sendable {
    private struct QueueState {
        var samples: [[Float]] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: QueueState())
    private let maxQueueSize = 100

    func enqueue(frames: [Float]) {
        lock.withLock { state in
            if state.samples.count >= maxQueueSize {
                state.samples.removeFirst()
            }
            state.samples.append(frames)
        }
    }

    func dequeueAll() -> [[Float]] {
        lock.withLockUnchecked { state in
            let result = state.samples
            state.samples.removeAll()
            return result
        }
    }
}

/// Helper for AVAudioConverter input block that ensures buffer is only supplied once.
/// Internal for testing.
///
/// Uses a class-based flag to avoid capturing a `var` in a `@Sendable` closure,
/// which is prohibited in Swift 6 strict concurrency mode.
func createOneShotInputBlock(buffer: AVAudioPCMBuffer) -> AVAudioConverterInputBlock {
    // Wraps both the one-shot flag and the non-Sendable AVAudioPCMBuffer
    // in a single @unchecked Sendable container. This is safe because the
    // converter callback is only invoked synchronously during convert().
    final class OneShotState: @unchecked Sendable {
        var provided = false
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
    let state = OneShotState(buffer)
    return { _, outStatus in
        if !state.provided {
            state.provided = true
            outStatus.pointee = .haveData
            return state.buffer
        } else {
            outStatus.pointee = .noDataNow
            return nil
        }
    }
}

/// Install audio tap outside MainActor context to avoid isolation assertions.
private func installAudioTap(
    on inputNode: AVAudioInputNode,
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat,
    converter: AVAudioConverter,
    recordingState: AudioRecordingState,
    sampleQueue: AudioSampleQueue,
    silenceThreshold: Float,
    targetSampleRate: Double
) {
    let inputSampleRate = inputFormat.sampleRate

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
        guard recordingState.getRecording() else { return }

        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * targetSampleRate / inputSampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            return
        }

        var error: NSError?
        let inputBlock = createOneShotInputBlock(buffer: buffer)
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if let channelData = convertedBuffer.floatChannelData?[0] {
            let frames = Int(convertedBuffer.frameLength)
            var rms: Float = 0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frames))

            if rms > silenceThreshold {
                recordingState.updateLastSoundTime()
            }

            let frameArray = Array(UnsafeBufferPointer(start: channelData, count: frames))
            sampleQueue.enqueue(frames: frameArray)
        }
    }
}

/// Records audio and streams chunks for transcription with VAD support
@MainActor
public final class StreamingRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: AudioBuffer?
    private var checkTimer: Timer?
    private var processingTimer: Timer?

    // Thread-safe state accessed from audio callback
    private let state = AudioRecordingState()

    // Queue for samples from audio callback
    private let sampleQueue = AudioSampleQueue()

    // VAD Components
    private var vadProcessor: VADProcessor?
    private var sessionController: SessionController?

    /// When this recording session started (for diagnostic logging)
    public private(set) var sessionStartDate: Date?

    /// Callback when a chunk is ready for transcription
    public var onChunkReady: ((AudioChunk) -> Void)?

    /// Callback when session should auto-end (VAD detected prolonged silence)
    public var onAutoEnd: (() -> Void)?

    private var sampleRate: Double { state.sampleRate }

    /// Flag to suppress final chunk emission on cancel
    private var isCancelled = false

    /// Throttle for periodic diagnostic heartbeat (every ~2s)
    private var lastHeartbeatLog: Date = .distantPast

    private let settings: any SettingsProviding

    public init(settings: any SettingsProviding = Settings.shared) {
        self.settings = settings
    }

    /// Update the transcript text used for thinking-pause detection.
    ///
    /// When the user pauses mid-sentence, `SessionController` checks whether the
    /// current transcript ends with an incomplete linguistic pattern (trailing
    /// conjunction, preposition, filler word, etc.). If so, it extends the
    /// silence threshold before auto-end fires.
    ///
    /// Call this from `RecordingController` whenever new transcription text arrives.
    /// The text should be the cumulative transcript for the current recording session.
    public func updateTranscript(_ text: String) async {
        await sessionController?.set(lastTranscript: text)
    }

    /// Cancel recording without emitting final chunk
    public func cancel() {
        isCancelled = true
        stop()
    }

    /// Start recording audio.
    /// Returns `true` if the audio engine started successfully, `false` on failure.
    /// On failure, all state is rolled back (engine, buffer, flags cleaned up).
    @discardableResult
    public func start() async -> Bool {
        sessionStartDate = Date()
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return false }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Logger.audio.error("Failed to create output audio format")
            audioEngine = nil
            return false
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            Logger.audio.error("Failed to create audio converter")
            audioEngine = nil
            return false
        }

        audioBuffer = AudioBuffer(sampleRate: sampleRate)
        state.setRecording(true)
        state.setLastSoundTime(Date())

        // Initialize VAD BEFORE starting audio capture to avoid race condition
        await initializeVAD()

        // Re-check recording state: stop() may have been called during the async
        // VAD initialization (e.g. on first run while Silero model loads).
        // Without this guard, we'd install orphan taps/timers after the user stopped.
        guard state.getRecording() else {
            Logger.audio.info("Recording cancelled during VAD initialization, aborting start")
            audioEngine = nil
            audioBuffer = nil
            return false
        }

        // Capture references for use in audio callback (NO self capture)
        let recordingState = self.state
        let sampleQueue = self.sampleQueue
        let silenceThreshold = Config.silenceThreshold
        let targetSampleRate = self.sampleRate

        // Install tap using nonisolated helper to avoid actor context in closure
        installAudioTap(
            on: inputNode,
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            converter: converter,
            recordingState: recordingState,
            sampleQueue: sampleQueue,
            silenceThreshold: silenceThreshold,
            targetSampleRate: targetSampleRate
        )

        do {
            try engine.start()
            let settings = self.settings
            let isFullRecording = settings.chunkDuration.isFullRecording

            if isFullRecording {
                Logger.audio.info("Recording started (full recording mode, max \(settings.maxChunkDuration)s)")
            } else {
                Logger.audio.info("Recording started (min \(settings.minChunkDuration)s, max \(settings.maxChunkDuration)s chunks)")
            }

            // Timer to process queued samples on main actor
            processingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.processQueuedSamples()
                }
            }

            // Timer for periodic chunk/auto-end checks
            checkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.periodicCheck()
                }
            }
            return true
        } catch {
            Logger.audio.error("Failed to start audio engine: \(error.localizedDescription)")
            // Rollback all state on failure
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            audioBuffer = nil
            state.setRecording(false)
            vadProcessor = nil
            sessionController = nil
            sessionStartDate = nil
            return false
        }
    }

    private func processQueuedSamples() async {
        guard state.getRecording() else { return }

        let batches = sampleQueue.dequeueAll()
        guard !batches.isEmpty else { return }

        Logger.audio.debug("Processing \(batches.count) queued sample batches")

        // ── Accumulate sub-batches before any actor work ───────────────────────────
        //
        // Merge all sub-batches into one contiguous array for efficient batch
        // processing. The `reserveCapacity` avoids Array growth reallocations.
        var accumulated: [Float] = []
        accumulated.reserveCapacity(batches.reduce(0) { $0 + $1.count })
        for batch in batches {
            accumulated.append(contentsOf: batch)
        }

        // Single actor hop into AudioBuffer
        await audioBuffer?.append(frames: accumulated)

        // ── VAD inference in model-sized chunks ───────────────────────────────────
        //
        // Silero's model processes at most 4096 samples (256ms at 16kHz) per call.
        // FluidAudio's `processChunk` truncates any input larger than 4096 samples
        // using `prefix(Self.chunkSize)`, discarding excess audio.
        //
        // Under normal conditions (50ms timer, ~1000 samples/tick), this is fine.
        // But if the main actor stalls (UI-heavy work, system load), the queue can
        // accumulate many batches before processing, exceeding 4096 samples.
        //
        // If we pass >4096 samples to VAD:
        //   - The model only sees the first 4096 samples
        //   - Probability is computed for those samples only
        //   - processedSamples advances by the FULL chunk size
        //   - Event timestamps become misaligned
        //   - Speech in samples 4097+ is invisible to VAD
        //
        // SOLUTION: Split accumulated samples into 4096-sample chunks and process
        // each chunk through VAD sequentially. This ensures every sample gets
        // evaluated while still amortizing actor hop overhead.
        guard state.getVADActive() else { return }

        let maxChunkSize = 4096
        var offset = 0
        while offset < accumulated.count {
            let end = min(offset + maxChunkSize, accumulated.count)
            let chunk = Array(accumulated[offset..<end])
            await processWithVAD(samples: chunk)
            offset = end
        }
    }

    private func initializeVAD() async {
        let settings = self.settings

        guard settings.vadEnabled && VADProcessor.isAvailable else {
            if !VADProcessor.isAvailable {
                Logger.audio.info("VAD not available on \(PlatformSupport.platformDescription). Using fallback mode.")
            } else {
                Logger.audio.info("VAD disabled in settings. Using fallback mode.")
            }
            state.setVADActive(false)
            return
        }

        do {
            let vadConfig = VADConfiguration(
                threshold: settings.vadThreshold,
                minSilenceAfterSpeech: Config.vadMinSilenceAfterSpeech,
                minSpeechDuration: Config.vadMinSpeechDuration,
                enabled: true,
                // Volume gate: suppress speechStart events that lack sufficient
                // audio loudness (prevents keyboard/fan noise from triggering speech).
                // Users can tune minVolumeForSpeech or disable the gate in Settings.
                volumeGateEnabled: settings.vadVolumeGateEnabled,
                minVolumeForSpeech: settings.vadMinVolumeForSpeech,
                // Smoothing factor and state-reset interval use hardcoded defaults
                // (0.2 and 5.0s respectively) — these are not user-configurable
                // because they are internal signal-processing parameters that
                // non-expert users should not need to touch.
                volumeSmoothingFactor: Config.vadVolumeSmoothingFactor,
                stateResetInterval: Config.vadStateResetInterval
            )

            let autoEndConfig = AutoEndConfiguration(
                enabled: settings.autoEndEnabled,
                silenceDuration: settings.autoEndSilenceDuration,
                minSessionDuration: Config.autoEndMinSessionDuration,
                requireSpeechFirst: true
            )

            vadProcessor = VADProcessor(config: vadConfig)
            try await vadProcessor?.initialize()

            sessionController = SessionController(
                vadConfig: vadConfig,
                autoEndConfig: autoEndConfig,
                maxChunkDuration: settings.maxChunkDuration
            )
            await sessionController?.startSession()

            state.setVADActive(true)
            Logger.audio.info("VAD enabled on \(PlatformSupport.platformDescription)")
            // swiftlint:disable:next line_length
            Logger.audio.warning("VAD CONFIG: vadThreshold=\(settings.vadThreshold, privacy: .public) minSilence=\(Config.vadMinSilenceAfterSpeech, privacy: .public) volumeGate=\(settings.vadVolumeGateEnabled, privacy: .public) minVol=\(settings.vadMinVolumeForSpeech, privacy: .public) stateReset=\(Config.vadStateResetInterval, privacy: .public)s autoEnd=\(settings.autoEndEnabled, privacy: .public) silenceDur=\(settings.autoEndSilenceDuration, privacy: .public) minSession=\(Config.autoEndMinSessionDuration, privacy: .public) maxChunk=\(settings.maxChunkDuration, privacy: .public) chunkDur=\(settings.chunkDuration.rawValue, privacy: .public) skipSilent=\(settings.skipSilentChunks, privacy: .public)")
        } catch {
            Logger.audio.warning("VAD initialization failed: \(error.localizedDescription). Using fallback mode.")
            vadProcessor = nil
            sessionController = nil
            state.setVADActive(false)
        }
    }

    private var vadProbAccumulator: Float = 0
    private var vadProbCount: Int = 0
    private var lastVADProbLog: Date = .distantPast

    private func processWithVAD(samples: [Float]) async {
        guard let vad = vadProcessor, let session = sessionController else { return }

        do {
            let result = try await vad.processChunk(samples)

            // Track VAD probability for periodic logging
            vadProbAccumulator += result.probability
            vadProbCount += 1
            let now = Date()
            if now.timeIntervalSince(lastVADProbLog) >= 1.0 {
                let avgProb = vadProbCount > 0 ? vadProbAccumulator / Float(vadProbCount) : 0
                Logger.audio.info("🔊 VAD prob (1s avg): \(String(format: "%.3f", avgProb), privacy: .public) (\(self.vadProbCount, privacy: .public) chunks, current=\(String(format: "%.3f", result.probability), privacy: .public), speaking=\(result.isSpeaking, privacy: .public))")
                vadProbAccumulator = 0
                vadProbCount = 0
                lastVADProbLog = now
            }

            if let event = result.event {
                await session.onSpeechEvent(event)

                // ── Early chunk emission on speechEnd ─────────────────────────────
                //
                // WHY: In batch mode, chunks are only emitted when buffer duration
                // exceeds maxChunkDuration (default 60s). But auto-end evaluates
                // every 0.5s with ~5s silence thresholds, and thinking-pause uses
                // `lastTranscript` to detect incomplete sentences.
                //
                // For a typical short dictation (e.g. 10s), auto-end fires at ~7s
                // (5s silence after 2s speech), but the chunk wouldn't emit until 60s.
                // Result: lastTranscript is always empty → thinking-pause never
                // engages → mid-thought utterances get cut off.
                //
                // SOLUTION: When speechEnd fires, emit the current buffer as a chunk
                // immediately. This triggers transcription within ~1-2s, well before
                // auto-end evaluates. The transcript then populates lastTranscript,
                // enabling thinking-pause to extend the silence threshold.
                //
                // Only emit on speechEnd (not speechStart) to avoid fragmenting
                // chunks mid-utterance. The isFullRecording guard prevents this from
                // changing behavior in "full recording" mode.
                if case .ended = event {
                    let isFullRecording = self.settings.chunkDuration.isFullRecording
                    if !isFullRecording, await session.hasSpoken {
                        let duration = await audioBuffer?.duration ?? 0
                        if duration >= self.settings.minChunkDuration {
                            Logger.audio.info("⚡ EARLY CHUNK on speechEnd: duration=\(String(format: "%.1f", duration), privacy: .public)s (feeding transcript for thinking-pause)")
                            let sent = await sendChunkIfReady(reason: "speechEnd: early emit for transcript")
                            if sent {
                                await session.chunkSent()
                            }
                        }
                    }
                }
            }
        } catch {
            Logger.audio.error("VAD processing error: \(error.localizedDescription)")
        }
    }

    private func periodicCheck() async {
        guard state.getRecording(), let buffer = audioBuffer else { return }

        let duration = await buffer.duration
        let isFullRecording = self.settings.chunkDuration.isFullRecording

        // Periodic diagnostic heartbeat (every ~2s) — traces VAD state between events
        if state.getVADActive(), let session = sessionController {
            let now = Date()
            if now.timeIntervalSince(lastHeartbeatLog) >= 2.0 {
                lastHeartbeatLog = now
                let summary = await session.diagnosticSummary
                let vadProb = await vadProcessor?.averageSpeechProbability ?? 0
                let smoothedVol = await vadProcessor?.currentSmoothedVolume ?? 0
                // smoothedVol shows the volume-gate signal in real time — useful for
                // tuning vadMinVolumeForSpeech: if legitimate speech is being
                // suppressed, check whether smoothedVol stays below 0.008 during speech.
                Logger.audio.debug("💓 HEARTBEAT: \(summary, privacy: .public) vadProb=\(String(format: "%.2f", vadProb), privacy: .public) smoothedVol=\(String(format: "%.4f", smoothedVol), privacy: .public)")
            }
        }

        if state.getVADActive(), let session = sessionController {
            let isSpeaking = await vadProcessor?.isSpeaking ?? false
            let silenceDur = await session.currentSilenceDuration
            let sessionDur = await session.currentSessionDuration
            let hasSpoken = await session.hasSpoken

            if !isFullRecording {
                let shouldChunk = await session.shouldSendChunk()
                if shouldChunk {
                    Logger.audio.warning("⚡ CHUNK SEND: duration=\(String(format: "%.1f", duration), privacy: .public)s, isSpeaking=\(isSpeaking, privacy: .public), silence=\(String(format: "%.1f", silenceDur ?? -1), privacy: .public)s")
                    let sent = await sendChunkIfReady(reason: "VAD: speech pause")
                    if sent {
                        await session.chunkSent()
                    }
                }
            }

            let shouldAutoEnd = await session.shouldAutoEndSession()
            if shouldAutoEnd {
                let dur = String(format: "%.1f", duration)
                let sess = String(format: "%.1f", sessionDur)
                let sil = String(format: "%.1f", silenceDur ?? -1)
                // swiftlint:disable:next line_length
                Logger.audio.error("AUTO-END TRIGGERED: duration=\(dur, privacy: .public)s sessionDur=\(sess, privacy: .public)s isSpeaking=\(isSpeaking, privacy: .public) silence=\(sil, privacy: .public)s hasSpoken=\(hasSpoken, privacy: .public)")
                onAutoEnd?()
                return
            }

            if duration >= self.settings.maxChunkDuration {
                let isSpeaking = await vadProcessor?.isSpeaking ?? false
                if !isSpeaking {
                    let sent = await sendChunkIfReady(reason: "max duration + silence")
                    if sent { await session.chunkSent() }
                } else if duration >= self.settings.maxChunkDuration * Config.forceSendChunkMultiplier {
                    // Hard upper limit: force-send even during continuous speech to prevent
                    // unbounded buffer accumulation. Without this, a user speaking non-stop
                    // for minutes would get all audio in one huge chunk that may timeout
                    // on the API or produce poor transcription quality.
                    Logger.audio.warning("⚠️ FORCE CHUNK: buffer=\(String(format: "%.1f", duration), privacy: .public)s exceeds \(String(format: "%.1f", self.settings.maxChunkDuration * Config.forceSendChunkMultiplier), privacy: .public)s hard limit (user still speaking)")
                    let sent = await sendChunkIfReady(reason: "forced: continuous speech exceeded \(String(format: "%.0f", Config.forceSendChunkMultiplier))× max duration")
                    if sent { await session.chunkSent() }
                }
            }
        } else {
            if duration >= self.settings.maxChunkDuration {
                await sendChunkIfReady(reason: "max duration (fallback)")
            } else if !isFullRecording &&
                      duration >= self.settings.minChunkDuration &&
                      Date().timeIntervalSince(state.getLastSoundTime()) >= Config.silenceDuration {
                await sendChunkIfReady(reason: "silence (fallback)")
            }
        }
    }

    @discardableResult
    private func sendChunkIfReady(reason: String) async -> Bool {
        guard let buffer = audioBuffer else { return false }
        // Capture all Settings values BEFORE any await suspension points
        // to prevent concurrent @MainActor tasks from changing them mid-execution.
        let minDuration = settings.minChunkDuration
        let skipSilentChunks = settings.skipSilentChunks
        let currentDuration = await buffer.duration

        guard currentDuration >= minDuration else {
            Logger.audio.debug("Chunk too short (\(String(format: "%.1f", currentDuration))s < \(minDuration)s, vadActive=\(self.state.getVADActive()))")
            return false
        }

        // ── Evaluate skip criteria before draining buffer ──────────────────────────
        // This keeps buffered audio intact when a chunk is skipped.
        let vadActive = state.getVADActive()
        let speechProbability: Float

        if vadActive, let vad = vadProcessor {
            speechProbability = await vad.averageSpeechProbability
        } else {
            // VAD inactive — no reliable way to judge speech. Never skip.
            speechProbability = 1.0
        }

        // Only skip based on VAD probability. No RMS/energy fallback.
        let skipThreshold = Config.minVADSpeechProbability

        // If speech was detected at any point in this session, always send
        // intermediate chunks. This mirrors the final-chunk protection in stop().
        // Without this, a chunk with mixed speech + silence (e.g. 8s speech + 7s pause)
        // can have an average probability below the threshold, causing the audio to be
        // silently discarded, dropping early chunks in long continuous speech sessions.
        let speechDetectedInSession: Bool
        if let session = sessionController {
            speechDetectedInSession = await session.hasSpoken
        } else {
            speechDetectedInSession = false
        }

        if skipSilentChunks && speechProbability < skipThreshold && !speechDetectedInSession {
            // No speech detected in session at all — treat as a discarded chunk.
            // We still drain so periodic checks can advance chunk timing instead of
            // retrying the same oversized buffer forever.
            let skippedSamples = await buffer.takeAll()
            let skippedDuration = Double(skippedSamples.count) / sampleRate

            if vadActive {
                await vadProcessor?.resetChunk()
            }
            Logger.audio.debug(
                "Skipping silent chunk (\(String(format: "%.0f", speechProbability * 100))% speech, threshold=\(String(format: "%.0f", skipThreshold * 100))%, duration=\(String(format: "%.1f", skippedDuration))s, vadActive=\(vadActive))"
            )
            return true
        }

        // ── Drain buffer and send ──────────────────────────────────────
        let samples = await buffer.takeAll()
        let duration = Double(samples.count) / sampleRate

        // Reset VAD chunk accumulator after draining (only when we commit to sending)
        if vadActive {
            await vadProcessor?.resetChunk()
        }

        let durationStr = String(format: "%.1f", duration)
        let speechPct = String(format: "%.0f", speechProbability * 100)
        Logger.audio.info("Chunk ready (\(reason)): \(durationStr)s, \(speechPct)% speech")

        let wavData = createWav(from: samples)
        let chunk = AudioChunk(wavData: wavData, durationSeconds: duration, speechProbability: speechProbability)

        onChunkReady?(chunk)
        state.updateLastSoundTime()
        return true
    }

    public func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        processingTimer?.invalidate()
        processingTimer = nil

        state.setRecording(false)

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        let hadVADActive = state.getVADActive()

        let wasCancelled = isCancelled
        isCancelled = false

        Task { [self] in
            defer { self.state.setVADActive(false) }
            guard let buffer = self.audioBuffer else { return }

            // Drain pending callback samples so short sessions don't lose trailing audio.
            let pendingSamples = self.sampleQueue.dequeueAll()
            if !pendingSamples.isEmpty {
                Logger.audio.debug("Flushing \(pendingSamples.count) pending sample batches on stop")
            }
            for sample in pendingSamples {
                await buffer.append(frames: sample)
                if hadVADActive {
                    await self.processWithVAD(samples: sample)
                }
            }

            let finalSamples = await buffer.takeAll()
            let duration = Double(finalSamples.count) / self.sampleRate

            guard !wasCancelled else {
                Logger.audio.info("Recording cancelled, discarding \(String(format: "%.1f", duration))s of audio")
                return
            }

            let minDurationMs = Double(Config.minRecordingDurationMs) / 1000.0
            let minDuration = self.settings.chunkDuration.isFullRecording ? minDurationMs : 1.0
            let skipSilentChunks = self.settings.skipSilentChunks

            let speechProbability: Float
            if hadVADActive, let vad = self.vadProcessor {
                speechProbability = await vad.averageSpeechProbability
            } else {
                // VAD inactive — no reliable way to judge speech. Always send.
                speechProbability = 1.0
            }
            await self.vadProcessor?.resetSession()

            // If speech was detected at ANY point in this session, always send
            // the final chunk. skipSilentChunks is for intermediate chunks that are
            // entirely silent, NOT for the final chunk which may contain real speech
            // diluted by trailing silence (e.g. 2s speech + 5s silence → avg prob < threshold).
            let speechDetectedInSession: Bool
            if let session = self.sessionController {
                speechDetectedInSession = await session.hasSpoken
            } else {
                speechDetectedInSession = false
            }

            // Only skip based on VAD probability. No RMS/energy fallback.
            let skipThreshold = Config.minVADSpeechProbability
            let hasEnoughSpeech = speechProbability >= skipThreshold
            let shouldSend = duration >= minDuration &&
                (!skipSilentChunks || hasEnoughSpeech || speechDetectedInSession)

            if shouldSend {
                Logger.audio.info("Final chunk: \(String(format: "%.1f", duration))s, speech=\(String(format: "%.0f", speechProbability * 100))%")
                let wavData = self.createWav(from: finalSamples)
                let chunk = AudioChunk(wavData: wavData, durationSeconds: duration, speechProbability: speechProbability)
                await MainActor.run {
                    self.onChunkReady?(chunk)
                }
            } else if duration < minDuration {
                Logger.audio.debug("Recording too short (\(String(format: "%.2f", duration))s < \(String(format: "%.2f", minDuration))s)")
            } else if !hasEnoughSpeech && skipSilentChunks {
                // Log when chunk is skipped due to low speech - helps diagnose VAD issues
                Logger.audio.warning("Final chunk SKIPPED: duration=\(String(format: "%.1f", duration))s, speech=\(String(format: "%.0f", speechProbability * 100))% < \(String(format: "%.0f", skipThreshold * 100))% threshold (vadActive=\(hadVADActive), skipSilentChunks=true)")
            }
            Logger.audio.info("Recording stopped")
        }
    }

    /// Encode PCM Float32 samples as a WAV file.
    ///
    /// ## Performance
    ///
    /// Previous implementation:
    ///   `samples.map { Int16(...) }` → intermediate `[Int16]` heap array  (~938 KB for 30s)
    ///   `int16.forEach { wav.append(withUnsafeBytes(of: $0.littleEndian) { Data($0) }) }`
    ///   → 480,000 individual `Data($0)` heap allocations per 30-second chunk
    ///
    /// This implementation:
    ///   1 `[Float]` scratch buffer (for in-place clip + scale)
    ///   1 `Data(count: totalBytes)` pre-allocation for the output
    ///   `vDSP_vclip` + `vDSP_vsmul` + `vDSP_vfix16`: vectorised SIMD clamp → scale → truncate
    ///   `withUnsafeMutableBytes` storeBytes for header fields — direct pointer writes
    ///
    /// Allocation budget: 2 heap objects (down from ~480K + 1 intermediate [Int16])
    ///
    /// ## Why vDSP_vclip + vDSP_vsmul + vDSP_vfix16 and not vDSP_vfixr16?
    ///
    /// `vDSP_vfixr16` converts float to Int16 by **rounding** without pre-scaling,
    /// which collapses the full [-1, 1] float range to just {-1, 0, 1} — completely wrong.
    /// The correct 3-step pipeline:
    ///   1. `vDSP_vclip`: clamp to [-1, 1]       — identical to `max(-1, min(1, x))`
    ///   2. `vDSP_vsmul`: multiply by 32767.0     — scale to Int16 range
    ///   3. `vDSP_vfix16`: truncate to Int16      — identical to Swift's `Int16(Float)`
    /// This produces deterministic Int16 PCM output aligned with Swift truncation semantics.
    private func createWav(from samples: [Float]) -> Data {
        guard !samples.isEmpty else { return Data() }

        let sampleCount = samples.count
        let n           = vDSP_Length(sampleCount)
        let dataBytes   = sampleCount * MemoryLayout<Int16>.stride   // 2 bytes per sample
        let totalBytes  = 44 + dataBytes                              // WAV header is exactly 44 bytes

        // Scratch buffer for in-place clip + scale (avoids mutating the immutable `samples` param)
        var scratch = [Float](unsafeUninitializedCapacity: sampleCount) { buf, count in
            samples.withUnsafeBufferPointer { src in
                buf.baseAddress!.initialize(from: src.baseAddress!, count: sampleCount)
            }
            count = sampleCount
        }

        // Step 1: clip to [-1, 1] (in-place)
        var low: Float  = -1.0
        var high: Float =  1.0
        vDSP_vclip(scratch, 1, &low, &high, &scratch, 1, n)

        // Step 2: scale by 32767 (in-place)
        var scale: Float = 32767.0
        vDSP_vsmul(scratch, 1, &scale, &scratch, 1, n)

        // Single pre-allocated output avoids per-sample allocation churn.
        var wav = Data(count: totalBytes)

        wav.withUnsafeMutableBytes { raw in
            let b = raw.baseAddress!

            // ── RIFF chunk descriptor ──────────────────────────────────────
            b.storeBytes(of: 0x46464952 as UInt32, as: UInt32.self)                        // "RIFF"
            (b + 4).storeBytes(of: UInt32(36 + dataBytes).littleEndian, as: UInt32.self)   // chunk size
            (b + 8).storeBytes(of: 0x45564157 as UInt32, as: UInt32.self)                  // "WAVE"

            // ── fmt  sub-chunk (16 bytes) ─────────────────────────────────
            (b + 12).storeBytes(of: 0x20746D66 as UInt32, as: UInt32.self)                 // "fmt "
            (b + 16).storeBytes(of: UInt32(16).littleEndian, as: UInt32.self)              // sub-chunk size
            (b + 20).storeBytes(of: UInt16(1).littleEndian,  as: UInt16.self)              // PCM = 1
            (b + 22).storeBytes(of: UInt16(1).littleEndian,  as: UInt16.self)              // mono
            let sr = UInt32(sampleRate)
            (b + 24).storeBytes(of: sr.littleEndian,           as: UInt32.self)            // sample rate
            (b + 28).storeBytes(of: (sr * 2).littleEndian,     as: UInt32.self)            // byte rate
            (b + 32).storeBytes(of: UInt16(2).littleEndian,    as: UInt16.self)            // block align
            (b + 34).storeBytes(of: UInt16(16).littleEndian,   as: UInt16.self)            // bits/sample

            // ── data sub-chunk header ─────────────────────────────────────
            (b + 36).storeBytes(of: 0x61746164 as UInt32, as: UInt32.self)                 // "data"
            (b + 40).storeBytes(of: UInt32(dataBytes).littleEndian, as: UInt32.self)       // data size

            // ── Step 3: truncate scaled floats to Int16 ───────────────────
            //
            // vDSP_vfix16 truncates (matches Swift's `Int16(Float)` truncation semantics),
            // producing deterministic output that matches Swift's truncation semantics.
            // The destination pointer is bound directly into the pre-allocated wav buffer,
            // writing all Int16 samples in a single SIMD pass — zero per-sample overhead.
            let dst = (b + 44).bindMemory(to: Int16.self, capacity: sampleCount)
            vDSP_vfix16(scratch, 1, dst, 1, n)
        }

        return wav
    }

    /// Start a mock recording session using provided audio data.
    /// Used for E2E testing in environments without microphone hardware.
    public func startMock(audioData: [Float]) async {
        sessionStartDate = Date()
        audioBuffer = AudioBuffer(sampleRate: sampleRate)
        state.setRecording(true)
        state.setLastSoundTime(Date())

        await initializeVAD()
        
        guard state.getRecording() else { return }
        Logger.audio.info("Starting MOCK recording with \(audioData.count) samples")
        
        // Start timers (same as real recording)
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.processQueuedSamples()
            }
        }
        
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.periodicCheck()
            }
        }
        
        // Feed samples in a background task
        Task {
            let chunkSize = Int(sampleRate * 0.05) // 50ms chunks
            var offset = 0
            
            while state.getRecording() && offset < audioData.count {
                let end = min(offset + chunkSize, audioData.count)
                let frames = Array(audioData[offset..<end])
                
                var rms: Float = 0
                vDSP_rmsqv(frames, 1, &rms, vDSP_Length(frames.count))
                // RMS drives non-VAD fallback silence detection (lastSoundTime).
                // VADProcessor's Silero probability is authoritative for speech.
                if rms > Config.silenceThreshold {
                    state.updateLastSoundTime()
                }

                sampleQueue.enqueue(frames: frames)
                
                offset = end
                try? await Task.sleep(for: .milliseconds(50))
            }
            
            if offset >= audioData.count {
                Logger.audio.info("MOCK recording finished feeding samples")
                // Keep running until stopped externally (by timeout or auto-end)
            }
        }
    }
}

#if DEBUG
// swiftlint:disable identifier_name
@MainActor
extension StreamingRecorder {
    func _testInjectAudioBuffer(_ buffer: AudioBuffer?) {
        audioBuffer = buffer
    }

    func _testInjectSessionController(_ controller: SessionController?) {
        sessionController = controller
    }

    func _testInjectVADProcessor(_ processor: VADProcessor?) {
        vadProcessor = processor
    }

    func _testSetVADActive(_ active: Bool) {
        state.setVADActive(active)
    }

    func _testSetIsRecording(_ recording: Bool) {
        state.setRecording(recording)
    }

    func _testInvokeSendChunkIfReady(reason: String) async {
        _ = await sendChunkIfReady(reason: reason)
    }

    func _testInvokePeriodicCheck() async {
        await periodicCheck()
    }

    func _testInvokeProcessQueuedSamples() async {
        await processQueuedSamples()
    }

    func _testAudioBufferDuration() async -> Double {
        guard let buffer = audioBuffer else { return 0 }
        return await buffer.duration
    }

    /// Enqueue a sample batch directly into the internal AudioSampleQueue.
    /// Used by tests to bypass the audio tap and inject controlled sample data.
    func _testEnqueueSamples(_ frames: [Float]) {
        sampleQueue.enqueue(frames: frames)
    }

    /// Expose createWav for correctness tests.
    func _testCreateWav(from samples: [Float]) -> Data {
        createWav(from: samples)
    }

    var _testHasProcessingTimer: Bool { processingTimer != nil }
    var _testHasCheckTimer: Bool { checkTimer != nil }
    var _testHasAudioEngine: Bool { audioEngine != nil }
    var _testHasAudioBuffer: Bool { audioBuffer != nil }
    var _testIsRecording: Bool { state.getRecording() }
}
// swiftlint:enable identifier_name
#endif
