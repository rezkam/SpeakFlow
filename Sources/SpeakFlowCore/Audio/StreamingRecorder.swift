import AVFoundation
import Accelerate
import OSLog

/// Audio chunk with metadata
public struct AudioChunk {
    public let audioData: Data
    public let durationSeconds: Double
    public let mimeType: String

    public init(audioData: Data, durationSeconds: Double, mimeType: String = "audio/mp4") {
        self.audioData = audioData
        self.durationSeconds = durationSeconds
        self.mimeType = mimeType
    }
}

/// Records audio and streams chunks for transcription
public final class StreamingRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: AudioBuffer?
    private var isRecording = false
    private var lastSoundTime: Date = Date()
    private var chunkTimer: Timer?
    private var silenceTimer: Timer?

    /// Callback when a chunk is ready for transcription
    public var onChunkReady: ((AudioChunk) -> Void)?
    private let sampleRate: Double = 16000

    /// Flag to suppress final chunk emission on cancel
    private var isCancelled = false

    public init() {}

    /// Cancel recording without emitting final chunk
    /// P2 Security: Prevents unwanted API calls and text insertion after user cancels
    public func cancel() {
        isCancelled = true
        stop()
    }

    public func start() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Logger.audio.error("Failed to create output audio format")
            return
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return }

        audioBuffer = AudioBuffer(sampleRate: sampleRate)
        isRecording = true
        lastSoundTime = Date()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let channelData = convertedBuffer.floatChannelData?[0] {
                let frames = Int(convertedBuffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frames))

                let hasSpeech = rms > Config.silenceThreshold
                if hasSpeech { self.lastSoundTime = Date() }

                let frameArray = Array(UnsafeBufferPointer(start: channelData, count: frames))
                Task {
                    // P1 Security: Double-check recording state inside Task
                    // The tap callback may fire after stop() is called
                    guard self.isRecording else { return }
                    await self.audioBuffer?.append(frames: frameArray, hasSpeech: hasSpeech)
                }
            }
        }

        do {
            try engine.start()
            let settings = Settings.shared
            let isFullRecording = settings.chunkDuration.isFullRecording

            if isFullRecording {
                Logger.audio.info("Recording started (full recording mode, max \(settings.maxChunkDuration)s)")
            } else {
                Logger.audio.info("Recording started (min \(settings.minChunkDuration)s, max \(settings.maxChunkDuration)s chunks)")
            }

            // Check for max duration (always enabled)
            chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkMaxDuration()
            }

            // Check for silence - only in chunking mode, not full recording
            if !isFullRecording {
                silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.checkSilence()
                }
            }
        } catch {
            Logger.audio.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func checkMaxDuration() {
        // P1 Security: Check recording state before spawning async work
        guard isRecording else { return }

        Task {
            // Double-check state inside Task in case stop() was called
            guard self.isRecording, let buffer = audioBuffer else { return }
            let duration = await buffer.duration
            if duration >= Settings.shared.maxChunkDuration {
                await sendChunkIfReady(reason: "max duration")
            }
        }
    }

    private func checkSilence() {
        guard isRecording else { return }

        Task {
            // P1 Security: Double-check state inside Task in case stop() was called
            guard self.isRecording, let buffer = audioBuffer else { return }
            let duration = await buffer.duration

            // Only send on silence if we have minimum duration
            if duration >= Settings.shared.minChunkDuration &&
               Date().timeIntervalSince(lastSoundTime) >= Config.silenceDuration {
                await sendChunkIfReady(reason: "silence")
            }
        }
    }

    private func sendChunkIfReady(reason: String) async {
        guard let buffer = audioBuffer else { return }

        let result = await buffer.takeAll()
        let duration = Double(result.samples.count) / sampleRate

        guard duration >= Settings.shared.minChunkDuration else {
            Logger.audio.debug("Chunk too short (\(String(format: "%.1f", duration))s < \(Settings.shared.minChunkDuration)s)")
            return
        }

        // Check if we should skip silent chunks (configurable)
        if Settings.shared.skipSilentChunks && result.speechRatio < Config.minSpeechRatio {
            Logger.audio.debug("Skipping silent chunk (\(String(format: "%.0f", result.speechRatio * 100))% speech)")
            return
        }

        let durationStr = String(format: "%.1f", duration)
        let speechPct = String(format: "%.0f", result.speechRatio * 100)
        Logger.audio.info("Chunk ready (\(reason)): \(durationStr)s, \(speechPct)% speech")

        let audioData = await createM4A(from: result.samples)
        let chunk = AudioChunk(audioData: audioData, durationSeconds: duration)

        await MainActor.run {
            onChunkReady?(chunk)
        }
        lastSoundTime = Date()
    }

    public func stop() {
        // Invalidate timers FIRST to prevent callbacks seeing stale state
        chunkTimer?.invalidate()
        chunkTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Then update state flag
        isRecording = false

        // Stop audio engine
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // P2 Security: Skip final chunk processing if cancelled to prevent unwanted API calls
        let wasCancelled = isCancelled
        isCancelled = false  // Reset for next recording

        Task {
            guard let buffer = audioBuffer else { return }
            let result = await buffer.takeAll()
            let duration = Double(result.samples.count) / sampleRate

            // Skip emission if recording was cancelled
            guard !wasCancelled else {
                Logger.audio.info("Recording cancelled, discarding \(String(format: "%.1f", duration))s of audio")
                return
            }

            // Minimum duration: 250ms for full recording mode, 1s otherwise
            let minDurationMs = Double(Config.minRecordingDurationMs) / 1000.0
            let minDuration = Settings.shared.chunkDuration.isFullRecording ? minDurationMs : 1.0

            // On stop, send whatever we have (if it has speech or skip is disabled)
            let hasEnoughSpeech = result.speechRatio >= Config.minSpeechRatio
            let shouldSend = duration >= minDuration && (!Settings.shared.skipSilentChunks || hasEnoughSpeech)

            if shouldSend {
                Logger.audio.info("Final chunk: \(String(format: "%.1f", duration))s")
                let audioData = await self.createM4A(from: result.samples)
                let chunk = AudioChunk(audioData: audioData, durationSeconds: duration)
                await MainActor.run {
                    onChunkReady?(chunk)
                }
            } else if duration < minDuration {
                Logger.audio.debug("Recording too short (\(String(format: "%.2f", duration))s < \(String(format: "%.2f", minDuration))s)")
            }
            Logger.audio.info("Recording stopped")
        }
    }

    /// Encode samples to M4A (AAC) format - smaller files, ~5x compression vs WAV
    private func createM4A(from samples: [Float]) async -> Data {
        // Don't create empty files
        guard !samples.isEmpty else { return Data() }

        // Create temporary file for AVAudioFile output
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            // AAC encoding settings - 32kbps is excellent for voice
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: Config.audioBitrate
            ]

            let outputFile = try AVAudioFile(forWriting: tempURL, settings: settings)

            // Create PCM buffer from samples
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                Logger.audio.error("Failed to create audio format for M4A encoding")
                return createWavFallback(from: samples)
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                Logger.audio.error("Failed to create PCM buffer for M4A encoding")
                return createWavFallback(from: samples)
            }

            // Copy samples to buffer
            if let channelData = buffer.floatChannelData?[0] {
                for (index, sample) in samples.enumerated() {
                    channelData[index] = sample
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
            }

            // Write to file (this performs AAC encoding)
            try outputFile.write(from: buffer)

            // Read encoded data
            let m4aData = try Data(contentsOf: tempURL)
            let compression = Double(samples.count * 4) / Double(m4aData.count)
            Logger.audio.debug("M4A encoded: \(m4aData.count) bytes (\(String(format: "%.1f", compression))x compression)")

            return m4aData

        } catch {
            Logger.audio.error("M4A encoding failed: \(error.localizedDescription), falling back to WAV")
            return createWavFallback(from: samples)
        }
    }

    /// Fallback to WAV if M4A encoding fails
    private func createWavFallback(from samples: [Float]) -> Data {
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
}
