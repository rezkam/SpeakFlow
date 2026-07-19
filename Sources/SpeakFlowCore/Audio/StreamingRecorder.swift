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
    private var audioFilter: (any AudioFilter)?
    private var idleNudgeController: IdleNudgeController?
    private var turnClassifier: TurnClassifier?

    /// When this recording session started (for diagnostic logging)
    public private(set) var sessionStartDate: Date?

    /// Callback when a chunk is ready for transcription
    public var onChunkReady: ((AudioChunk) -> Void)?

    /// Callback when session should auto-end (VAD detected prolonged silence)
    public var onAutoEnd: (() -> Void)?

    private var sampleRate: Double { state.sampleRate }

    /// Flag to suppress final chunk emission on cancel
    private var isCancelled = false

    /// In-flight async stop pipeline task (drain queue, emit final chunk, teardown).
    /// Exposed via `waitForStopCompletion()` so callers can await final flush completion.
    private var stopTask: Task<Void, Never>?

    /// Throttle for periodic diagnostic heartbeat (every ~2s)
    private var lastHeartbeatLog: Date = .distantPast

    private let settings: any SettingsProviding

    public init(settings: any SettingsProviding = Settings.shared) {
        self.settings = settings
    }

    private static func isTestRuntime() -> Bool {
        Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })
    }

    private static func shouldIsolateTestAudioCapture() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let isolate = env["SPEAKFLOW_ISOLATE_TEST_AUDIO"] ?? "1"
        let allowAudioEngine = env["SPEAKFLOW_ALLOW_TEST_AUDIO_ENGINE"] == "1"
        return isTestRuntime() && isolate != "0" && !allowAudioEngine
    }

    private func observabilityEvent(
        _ name: String,
        level: ObservabilityEventLevel = .debug,
        metadata: @autoclosure () -> [String: String] = [:]
    ) {
        guard settings.observabilityEnabled,
              settings.observabilityVerbosity.includes(level) else { return }
        let payload = metadata()
        Task {
            await ObservabilityStore.shared.record(
                component: "StreamingRecorder",
                name: name,
                level: level,
                metadata: payload
            )
        }
    }

    private func startTimers() {
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

    /// Wait for an in-flight stop pipeline to finish draining/enqueuing final audio.
    ///
    /// Used by `RecordingController` batch finalization to avoid racing completion
    /// before the recorder has had a chance to enqueue its final chunk.
    public func waitForStopCompletion() async {
        await stopTask?.value
    }

    /// Start recording audio.
    /// Returns `true` if the audio engine started successfully, `false` on failure.
    /// On failure, all state is rolled back (engine, buffer, flags cleaned up).
    @discardableResult
    public func start() async -> Bool {
        sessionStartDate = Date()
        observabilityEvent(
            "start_requested",
            metadata: [
                "skipSilentChunks": settings.skipSilentChunks ? "true" : "false",
                "chunkDuration": String(settings.chunkDuration.rawValue)
            ]
        )

        audioBuffer = AudioBuffer(sampleRate: sampleRate)
        state.setRecording(true)
        state.setLastSoundTime(Date())
        setupIdleNudgeController()
        setupTurnClassifier()
        audioFilter = settings.audioNoiseGateEnabled
            ? NoiseGateFilter(rmsThreshold: settings.audioNoiseGateRmsThreshold)
            : nil
        await audioFilter?.start(sampleRate: sampleRate)

        // Initialize VAD BEFORE starting audio capture to avoid race condition
        await initializeVAD()

        // Re-check recording state: stop() may have been called during the async
        // VAD initialization (e.g. on first run while Silero model loads).
        // Without this guard, we'd install orphan taps/timers after the user stopped.
        guard state.getRecording() else {
            Logger.audio.info("Recording cancelled during VAD initialization, aborting start")
            await audioFilter?.stop()
            audioFilter = nil
            idleNudgeController?.stopMonitoring()
            idleNudgeController = nil
            turnClassifier = nil
            audioEngine = nil
            audioBuffer = nil
            return false
        }

        if Self.shouldIsolateTestAudioCapture() {
            Logger.audio.info("Test runtime detected — starting recorder without audio engine")
            observabilityEvent(
                "start_succeeded_test_isolated",
                level: .warning,
                metadata: ["reason": "test_runtime_audio_isolation"]
            )
            startTimers()
            return true
        }

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
            observabilityEvent("start_failed_output_format", level: .error)
            audioEngine = nil
            return false
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            Logger.audio.error("Failed to create audio converter")
            observabilityEvent("start_failed_converter", level: .error)
            audioEngine = nil
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
            observabilityEvent(
                "start_succeeded",
                metadata: [
                    "isFullRecording": isFullRecording ? "true" : "false",
                    "maxChunkDuration": String(settings.maxChunkDuration)
                ]
            )
            startTimers()
            return true
        } catch {
            Logger.audio.error("Failed to start audio engine: \(error.localizedDescription)")
            observabilityEvent(
                "start_failed_audio_engine",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            // Rollback all state on failure
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            audioBuffer = nil
            state.setRecording(false)
            await audioFilter?.stop()
            audioFilter = nil
            idleNudgeController?.stopMonitoring()
            idleNudgeController = nil
            turnClassifier = nil
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

        // Optional pre-VAD filter stage (noise gate).
        // VAD and chunk buffering must observe the same filtered signal.
        let filteredSamples = audioFilter?.filter(accumulated) ?? accumulated

        // Single actor hop into AudioBuffer
        await audioBuffer?.append(frames: filteredSamples)

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
        while offset < filteredSamples.count {
            let end = min(offset + maxChunkSize, filteredSamples.count)
            let chunk = Array(filteredSamples[offset..<end])
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
                volumeSmoothingFactor: settings.vadVolumeSmoothingFactor,
                stateResetInterval: settings.vadStateResetInterval
            )

            let autoEndConfig = AutoEndConfiguration(
                enabled: settings.autoEndEnabled,
                silenceDuration: settings.autoEndSilenceDuration,
                minSessionDuration: settings.autoEndMinSessionDuration,
                requireSpeechFirst: settings.autoEndRequireSpeechFirst,
                noSpeechTimeout: settings.autoEndNoSpeechTimeout,
                maxContinuousSpeechDuration: settings.autoEndMaxContinuousSpeechDuration,
                thinkingPauseEnabled: settings.thinkingPauseEnabled,
                thinkingPauseExtensionSeconds: settings.thinkingPauseExtensionSeconds,
                turnClassifierEnabled: settings.turnClassifierEnabled,
                turnClassifierMinimumSilence: settings.turnClassifierMinimumSilence,
                turnClassifierIncompleteExtensionSeconds: settings.turnClassifierIncompleteExtensionSeconds,
                turnClassifierThreshold: settings.turnClassifierThreshold
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
            Logger.audio.warning("VAD CONFIG: vadThreshold=\(settings.vadThreshold, privacy: .public) minSilence=\(Config.vadMinSilenceAfterSpeech, privacy: .public) volumeGate=\(settings.vadVolumeGateEnabled, privacy: .public) minVol=\(settings.vadMinVolumeForSpeech, privacy: .public) smoothing=\(settings.vadVolumeSmoothingFactor, privacy: .public) stateReset=\(settings.vadStateResetInterval, privacy: .public)s autoEnd=\(settings.autoEndEnabled, privacy: .public) silenceDur=\(settings.autoEndSilenceDuration, privacy: .public) minSession=\(settings.autoEndMinSessionDuration, privacy: .public) maxChunk=\(settings.maxChunkDuration, privacy: .public) chunkDur=\(settings.chunkDuration.rawValue, privacy: .public) skipSilent=\(settings.skipSilentChunks, privacy: .public)")
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

            if isPotentialSpeechLikeFrame(result) {
                await session.onPotentialSpeechActivity()
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
                        // Gated on the dedicated early-emit floor, NOT settings.minChunkDuration
                        // (== the full chunk length, e.g. 60s for .minute1). Short dictations
                        // — exactly what this path targets — would never reach that floor.
                        if duration >= Config.earlyEmitMinDuration {
                            Logger.audio.info("⚡ EARLY CHUNK on speechEnd: duration=\(String(format: "%.1f", duration), privacy: .public)s (feeding transcript for thinking-pause)")
                            let sent = await sendChunkIfReady(
                                reason: "speechEnd: early emit for transcript",
                                minimumDuration: Config.earlyEmitMinDuration
                            )
                            if sent {
                                await session.chunkSent()
                            }
                        }
                    }
                } else if case .started = event {
                    idleNudgeController?.stopMonitoring()
                }
            }
        } catch {
            Logger.audio.error("VAD processing error: \(error.localizedDescription)")
        }
    }

    /// Returns true when a VAD frame looks speech-like even if `.speechStart`
    /// has not been emitted yet.
    ///
    /// This acts as a safety guard against premature auto-end when speechStart is
    /// delayed/suppressed by conservative gating in noisy or very quiet conditions.
    private func isPotentialSpeechLikeFrame(_ result: VADResult) -> Bool {
        let probabilityFloor = max(settings.vadThreshold * 0.85, 0.08)
        let volumeFloor: Float
        if settings.vadVolumeGateEnabled {
            volumeFloor = max(settings.vadMinVolumeForSpeech * 0.6, Config.silenceThreshold * 1.5)
        } else {
            volumeFloor = Config.silenceThreshold * 1.5
        }
        return result.probability >= probabilityFloor && result.smoothedVolume >= volumeFloor
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
            await maybeEvaluateTurnCompletion(session: session)
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
                if let idleNudgeController {
                    idleNudgeController.startMonitoring(afterDelay: settings.idleNudgeInitialDelay)
                    return
                }
                let dur = String(format: "%.1f", duration)
                let sess = String(format: "%.1f", sessionDur)
                let sil = String(format: "%.1f", silenceDur ?? -1)
                // swiftlint:disable:next line_length
                Logger.audio.error("AUTO-END TRIGGERED: duration=\(dur, privacy: .public)s sessionDur=\(sess, privacy: .public)s isSpeaking=\(isSpeaking, privacy: .public) silence=\(sil, privacy: .public)s hasSpoken=\(hasSpoken, privacy: .public)")
                onAutoEnd?()
                return
            } else {
                idleNudgeController?.stopMonitoring()
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

    /// Drain the buffer and emit a chunk if it meets the minimum-duration floor.
    ///
    /// - Parameter minimumDuration: Overrides the floor a chunk must meet before
    ///   being sent. `nil` (the default, used by all normal chunking callers) falls
    ///   back to `settings.minChunkDuration` (the configured chunk length). Pass
    ///   `Config.earlyEmitMinDuration` for the speechEnd early-emit path, which
    ///   intentionally uses a much lower floor — see that constant's doc comment.
    @discardableResult
    private func sendChunkIfReady(reason: String, minimumDuration: Double? = nil) async -> Bool {
        guard let buffer = audioBuffer else { return false }
        // Capture all Settings values BEFORE any await suspension points
        // to prevent concurrent @MainActor tasks from changing them mid-execution.
        let minDuration = minimumDuration ?? settings.minChunkDuration
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
        observabilityEvent("stop_requested")
        checkTimer?.invalidate()
        checkTimer = nil
        processingTimer?.invalidate()
        processingTimer = nil

        state.setRecording(false)
        idleNudgeController?.stopMonitoring()
        turnClassifier = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        let hadVADActive = state.getVADActive()
        let filter = audioFilter
        audioFilter = nil

        let wasCancelled = isCancelled
        isCancelled = false

        let stopTask = Task { [self] in
            await filter?.stop()
            idleNudgeController = nil
            turnClassifier = nil
            defer { self.state.setVADActive(false) }
            guard let buffer = self.audioBuffer else { return }

            // Drain pending callback samples so short sessions don't lose trailing audio.
            let pendingSamples = self.sampleQueue.dequeueAll()
            if !pendingSamples.isEmpty {
                Logger.audio.debug("Flushing \(pendingSamples.count) pending sample batches on stop")
                self.observabilityEvent(
                    "stop_flush_pending_samples",
                    metadata: ["pendingBatches": String(pendingSamples.count)]
                )
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
                self.observabilityEvent(
                    "stop_cancelled_discard",
                    level: .warning,
                    metadata: ["durationSeconds": String(format: "%.3f", duration)]
                )
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
                self.observabilityEvent(
                    "stop_final_chunk_sent",
                    metadata: [
                        "durationSeconds": String(format: "%.3f", duration),
                        "speechProbability": String(format: "%.3f", speechProbability),
                        "bytes": String(wavData.count)
                    ]
                )
                let chunk = AudioChunk(wavData: wavData, durationSeconds: duration, speechProbability: speechProbability)
                await MainActor.run {
                    self.onChunkReady?(chunk)
                }
            } else if duration < minDuration {
                Logger.audio.debug("Recording too short (\(String(format: "%.2f", duration))s < \(String(format: "%.2f", minDuration))s)")
                self.observabilityEvent(
                    "stop_final_chunk_skipped_too_short",
                    level: .warning,
                    metadata: [
                        "durationSeconds": String(format: "%.3f", duration),
                        "minDuration": String(format: "%.3f", minDuration)
                    ]
                )
            } else if !hasEnoughSpeech && skipSilentChunks {
                // Log when chunk is skipped due to low speech - helps diagnose VAD issues
                Logger.audio.warning("Final chunk SKIPPED: duration=\(String(format: "%.1f", duration))s, speech=\(String(format: "%.0f", speechProbability * 100))% < \(String(format: "%.0f", skipThreshold * 100))% threshold (vadActive=\(hadVADActive), skipSilentChunks=true)")
                self.observabilityEvent(
                    "stop_final_chunk_skipped_low_speech",
                    level: .warning,
                    metadata: [
                        "durationSeconds": String(format: "%.3f", duration),
                        "speechProbability": String(format: "%.3f", speechProbability),
                        "skipThreshold": String(format: "%.3f", skipThreshold)
                    ]
                )
            }
            Logger.audio.info("Recording stopped")
            self.observabilityEvent("stop_completed")
        }
        self.stopTask = stopTask
    }

    /// Encode PCM Float32 samples as a WAV file.
    ///
    /// Delegates to shared ``WavEncoder`` so WAV generation remains reusable and
    /// independently testable across components.
    private func createWav(from samples: [Float]) -> Data {
        WavEncoder.encode(samples: samples, sampleRate: sampleRate)
    }

    /// Start a mock recording session using provided audio data.
    /// Used for E2E testing in environments without microphone hardware.
    public func startMock(audioData: [Float]) async {
        sessionStartDate = Date()
        audioBuffer = AudioBuffer(sampleRate: sampleRate)
        state.setRecording(true)
        state.setLastSoundTime(Date())
        setupIdleNudgeController()
        setupTurnClassifier()
        audioFilter = Config.audioNoiseGateEnabled
            ? NoiseGateFilter(rmsThreshold: Config.audioNoiseGateRmsThreshold)
            : nil
        await audioFilter?.start(sampleRate: sampleRate)

        await initializeVAD()
        
        guard state.getRecording() else {
            await audioFilter?.stop()
            audioFilter = nil
            idleNudgeController?.stopMonitoring()
            idleNudgeController = nil
            turnClassifier = nil
            return
        }
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

    @discardableResult
    func _testInvokeSendChunkIfReady(reason: String, minimumDuration: Double? = nil) async -> Bool {
        await sendChunkIfReady(reason: reason, minimumDuration: minimumDuration)
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

    var _testHasIdleNudgeController: Bool { idleNudgeController != nil }

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

@MainActor
private extension StreamingRecorder {
    func setupIdleNudgeController() {
        guard settings.idleNudgeEnabled else {
            idleNudgeController = nil
            return
        }
        let controller = IdleNudgeController(
            nudgeInterval: settings.idleNudgeInterval,
            maxNudges: settings.idleNudgeMaxCount
        )
        controller.onNudge = {
            Logger.audio.info("Idle nudge: user is silent, waiting before auto-end")
        }
        controller.onFinalWarning = {
            Logger.audio.info("Idle final warning before auto-end")
        }
        controller.onExpired = { [weak self] in
            self?.onAutoEnd?()
        }
        idleNudgeController = controller
    }

    func setupTurnClassifier() {
        guard settings.turnClassifierEnabled else {
            turnClassifier = nil
            return
        }
        let classifier = TurnClassifier()
        turnClassifier = classifier
        Task {
            await classifier.loadModelIfAvailable()
        }
    }

    func maybeEvaluateTurnCompletion(session: SessionController) async {
        guard let turnClassifier else { return }
        guard await session.shouldEvaluateTurnCompletion() else { return }

        let transcript = await session.lastTranscript
        let recentAudio = await audioBuffer?.peekLast(seconds: 8.0) ?? []
        let probability = await turnClassifier.classify(
            transcript: transcript,
            recentAudio: recentAudio,
            sampleRate: sampleRate
        )
        await session.setTurnCompletionProbability(probability)
        await session.markTurnCompletionEvaluated()
        Logger.audio.debug("Turn classifier probability=\(String(format: "%.2f", probability), privacy: .public)")
    }
}
