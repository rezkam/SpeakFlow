import AVFoundation
import Accelerate
import OSLog

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
private final class AudioRecordingState: @unchecked Sendable {
    private var isRecording = false
    private var vadActive = false
    private var lastSoundTime: Date = Date()
    let sampleRate: Double = 16000

    // Lock for thread-safe access
    private let lock = NSLock()

    func setRecording(_ value: Bool) {
        lock.lock()
        isRecording = value
        lock.unlock()
    }

    func getRecording() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRecording
    }

    func setVADActive(_ value: Bool) {
        lock.lock()
        vadActive = value
        lock.unlock()
    }

    func getVADActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return vadActive
    }

    func updateLastSoundTime() {
        lock.lock()
        lastSoundTime = Date()
        lock.unlock()
    }

    func setLastSoundTime(_ value: Date) {
        lock.lock()
        lastSoundTime = value
        lock.unlock()
    }

    func getLastSoundTime() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return lastSoundTime
    }
}

/// Thread-safe queue for passing audio samples from callback to main actor
private final class AudioSampleQueue: @unchecked Sendable {
    private var samples: [(frames: [Float], hasSpeech: Bool)] = []
    private let lock = NSLock()
    private let maxQueueSize = 100

    func enqueue(frames: [Float], hasSpeech: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if samples.count >= maxQueueSize {
            samples.removeFirst()
        }
        samples.append((frames: frames, hasSpeech: hasSpeech))
    }

    func dequeueAll() -> [(frames: [Float], hasSpeech: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll()
        return result
    }
}

/// Helper for AVAudioConverter input block that ensures buffer is only supplied once.
/// Internal for testing.
///
/// Uses a class-based flag to avoid capturing a `var` in a `@Sendable` closure,
/// which is prohibited in Swift 6.2 strict concurrency mode.
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

            let hasSpeech = rms > silenceThreshold
            if hasSpeech {
                recordingState.updateLastSoundTime()
            }

            let frameArray = Array(UnsafeBufferPointer(start: channelData, count: frames))
            sampleQueue.enqueue(frames: frameArray, hasSpeech: hasSpeech)
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

    public init() {}

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
            let settings = Settings.shared
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

        let samples = sampleQueue.dequeueAll()
        guard !samples.isEmpty else { return }

        Logger.audio.debug("Processing \(samples.count) queued sample batches")
        
        for sample in samples {
            await audioBuffer?.append(frames: sample.frames, hasSpeech: sample.hasSpeech)

            if state.getVADActive() {
                await processWithVAD(samples: sample.frames)
            }
        }
    }

    private func initializeVAD() async {
        let settings = Settings.shared

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
                enabled: true
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
            Logger.audio.warning("VAD CONFIG DUMP: vadThreshold=\(settings.vadThreshold, privacy: .public), minSilenceAfterSpeech=\(Config.vadMinSilenceAfterSpeech, privacy: .public), autoEndEnabled=\(settings.autoEndEnabled, privacy: .public), autoEndSilenceDuration=\(settings.autoEndSilenceDuration, privacy: .public), autoEndMinSession=\(Config.autoEndMinSessionDuration, privacy: .public), maxChunkDuration=\(settings.maxChunkDuration, privacy: .public), chunkDuration=\(settings.chunkDuration.rawValue, privacy: .public), skipSilentChunks=\(settings.skipSilentChunks, privacy: .public)")
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
            }
        } catch {
            Logger.audio.error("VAD processing error: \(error.localizedDescription)")
        }
    }

    private func periodicCheck() async {
        guard state.getRecording(), let buffer = audioBuffer else { return }

        let settings = Settings.shared
        let duration = await buffer.duration
        let isFullRecording = settings.chunkDuration.isFullRecording

        // Periodic diagnostic heartbeat (every ~2s) — traces VAD state between events
        if state.getVADActive(), let session = sessionController {
            let now = Date()
            if now.timeIntervalSince(lastHeartbeatLog) >= 2.0 {
                lastHeartbeatLog = now
                let summary = await session.diagnosticSummary
                let vadProb = await vadProcessor?.averageSpeechProbability ?? 0
                Logger.audio.debug("💓 HEARTBEAT: \(summary, privacy: .public) vadProb=\(String(format: "%.2f", vadProb), privacy: .public)")
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
                Logger.audio.error("🛑 AUTO-END TRIGGERED: duration=\(String(format: "%.1f", duration), privacy: .public)s, sessionDur=\(String(format: "%.1f", sessionDur), privacy: .public)s, isSpeaking=\(isSpeaking, privacy: .public), silence=\(String(format: "%.1f", silenceDur ?? -1), privacy: .public)s, hasSpoken=\(hasSpoken, privacy: .public)")
                onAutoEnd?()
                return
            }

            if duration >= settings.maxChunkDuration {
                let isSpeaking = await vadProcessor?.isSpeaking ?? false
                if !isSpeaking {
                    let sent = await sendChunkIfReady(reason: "max duration + silence")
                    if sent { await session.chunkSent() }
                } else if duration >= settings.maxChunkDuration * Config.forceSendChunkMultiplier {
                    // Hard upper limit: force-send even during continuous speech to prevent
                    // unbounded buffer accumulation. Without this, a user speaking non-stop
                    // for minutes would get all audio in one huge chunk that may timeout
                    // on the API or produce poor transcription quality.
                    Logger.audio.warning("⚠️ FORCE CHUNK: buffer=\(String(format: "%.1f", duration), privacy: .public)s exceeds \(String(format: "%.1f", settings.maxChunkDuration * Config.forceSendChunkMultiplier), privacy: .public)s hard limit (user still speaking)")
                    let sent = await sendChunkIfReady(reason: "forced: continuous speech exceeded \(String(format: "%.0f", Config.forceSendChunkMultiplier))× max duration")
                    if sent { await session.chunkSent() }
                }
            }
        } else {
            if duration >= settings.maxChunkDuration {
                await sendChunkIfReady(reason: "max duration (fallback)")
            } else if !isFullRecording &&
                      duration >= settings.minChunkDuration &&
                      Date().timeIntervalSince(state.getLastSoundTime()) >= Config.silenceDuration {
                await sendChunkIfReady(reason: "silence (fallback)")
            }
        }
    }

    @discardableResult
    private func sendChunkIfReady(reason: String) async -> Bool {
        guard let buffer = audioBuffer else { return false }
        // Use the user's configured chunk duration as the minimum.
        // This prevents sending short chunks on every speech pause,
        // which wastes API calls. VAD extends past the chunk duration
        // until a natural pause, but never sends BEFORE it.
        let minDuration = Settings.shared.minChunkDuration
        let currentDuration = await buffer.duration

        guard currentDuration >= minDuration else {
            Logger.audio.debug("Chunk too short (\(String(format: "%.1f", currentDuration))s < \(minDuration)s, vadActive=\(self.state.getVADActive()))")
            return false
        }

        // ── Skip check BEFORE draining buffer ──────────────────────────
        // Previously, the buffer was drained (via takeAll) before the skip
        // decision, permanently losing audio when a chunk was skipped. Now
        // we evaluate the speech probability first so that skipped chunks
        // leave the buffer intact for the next check cycle.
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
        // silently discarded — the "first chunk lost on long speech" bug.
        let speechDetectedInSession: Bool
        if let session = sessionController {
            speechDetectedInSession = await session.hasSpoken
        } else {
            speechDetectedInSession = false
        }

        if Settings.shared.skipSilentChunks && speechProbability < skipThreshold && !speechDetectedInSession {
            // No speech detected in session at all — safe to skip this truly silent chunk.
            // Buffer is NOT drained, so audio is preserved for the next check cycle.
            // Reset VAD chunk accumulator even on skip — prevents stale samples from
            // accumulating across consecutive skipped chunks, which would bloat memory
            // and skew future speech probability calculations.
            if vadActive {
                await vadProcessor?.resetChunk()
            }
            Logger.audio.debug("Skipping silent chunk (\(String(format: "%.0f", speechProbability * 100))% speech, threshold=\(String(format: "%.0f", skipThreshold * 100))%, vadActive=\(vadActive))")
            return false
        }

        // ── Drain buffer and send ──────────────────────────────────────
        let result = await buffer.takeAll()
        let duration = Double(result.samples.count) / sampleRate

        // Reset VAD chunk accumulator after draining (only when we commit to sending)
        if vadActive {
            await vadProcessor?.resetChunk()
        }

        let durationStr = String(format: "%.1f", duration)
        let speechPct = String(format: "%.0f", speechProbability * 100)
        Logger.audio.info("Chunk ready (\(reason)): \(durationStr)s, \(speechPct)% speech")

        let wavData = createWav(from: result.samples)
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
                await buffer.append(frames: sample.frames, hasSpeech: sample.hasSpeech)
                if hadVADActive {
                    await self.processWithVAD(samples: sample.frames)
                }
            }

            let result = await buffer.takeAll()
            let duration = Double(result.samples.count) / self.sampleRate

            guard !wasCancelled else {
                Logger.audio.info("Recording cancelled, discarding \(String(format: "%.1f", duration))s of audio")
                return
            }

            let minDurationMs = Double(Config.minRecordingDurationMs) / 1000.0
            let minDuration = Settings.shared.chunkDuration.isFullRecording ? minDurationMs : 1.0

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
                (!Settings.shared.skipSilentChunks || hasEnoughSpeech || speechDetectedInSession)

            if shouldSend {
                Logger.audio.info("Final chunk: \(String(format: "%.1f", duration))s, speech=\(String(format: "%.0f", speechProbability * 100))%")
                let wavData = self.createWav(from: result.samples)
                let chunk = AudioChunk(wavData: wavData, durationSeconds: duration, speechProbability: speechProbability)
                await MainActor.run {
                    self.onChunkReady?(chunk)
                }
            } else if duration < minDuration {
                Logger.audio.debug("Recording too short (\(String(format: "%.2f", duration))s < \(String(format: "%.2f", minDuration))s)")
            } else if !hasEnoughSpeech && Settings.shared.skipSilentChunks {
                // Log when chunk is skipped due to low speech - helps diagnose VAD issues
                Logger.audio.warning("Final chunk SKIPPED: duration=\(String(format: "%.1f", duration))s, speech=\(String(format: "%.0f", speechProbability * 100))% < \(String(format: "%.0f", skipThreshold * 100))% threshold (vadActive=\(hadVADActive), skipSilentChunks=true)")
            }
            Logger.audio.info("Recording stopped")
        }
    }

    private func createWav(from samples: [Float]) -> Data {
        guard !samples.isEmpty else { return Data() }

        let int16 = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        var wav = Data()
        let sr = UInt32(sampleRate)
        let sz = UInt32(int16.count * 2)
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(withUnsafeBytes(of: (36 + sz).littleEndian) { Data($0) })
        wav.append(contentsOf: "WAVEfmt ".utf8)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: sr.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: (sr * 2).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        wav.append(contentsOf: "data".utf8)
        wav.append(withUnsafeBytes(of: sz.littleEndian) { Data($0) })
        int16.forEach { wav.append(withUnsafeBytes(of: $0.littleEndian) { Data($0) }) }
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
                let hasSpeech = rms > Config.silenceThreshold
                
                if hasSpeech {
                    state.updateLastSoundTime()
                }
                
                sampleQueue.enqueue(frames: frames, hasSpeech: hasSpeech)
                
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
        await sendChunkIfReady(reason: reason)
    }

    func _testInvokePeriodicCheck() async {
        await periodicCheck()
    }

    func _testAudioBufferDuration() async -> Double {
        guard let buffer = audioBuffer else { return 0 }
        return await buffer.duration
    }

    var _testHasProcessingTimer: Bool { processingTimer != nil }
    var _testHasCheckTimer: Bool { checkTimer != nil }
    var _testHasAudioEngine: Bool { audioEngine != nil }
    var _testHasAudioBuffer: Bool { audioBuffer != nil }
    var _testIsRecording: Bool { state.getRecording() }
}
#endif
