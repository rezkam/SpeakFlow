import AVFoundation
import Accelerate
import OSLog

/// Records audio and streams chunks for transcription
final class StreamingRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: AudioBuffer?
    private var isRecording = false
    private var lastSoundTime: Date = Date()
    private var chunkTimer: Timer?
    private var silenceTimer: Timer?

    var onChunkReady: ((Data) -> Void)?
    private let sampleRate: Double = 16000

    func start() {
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
                    await self.audioBuffer?.append(frames: frameArray, hasSpeech: hasSpeech)
                }
            }
        }

        do {
            try engine.start()
            Logger.audio.info("Recording started (min \(Config.minChunkDuration)s, max \(Config.maxChunkDuration)s chunks)")

            // Check for max duration
            chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkMaxDuration()
            }

            // Check for silence
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkSilence()
            }
        } catch {
            Logger.audio.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func checkMaxDuration() {
        Task {
            guard let buffer = audioBuffer else { return }
            let duration = await buffer.duration
            if duration >= Config.maxChunkDuration {
                await sendChunkIfReady(reason: "max duration")
            }
        }
    }

    private func checkSilence() {
        guard isRecording else { return }

        Task {
            guard let buffer = audioBuffer else { return }
            let duration = await buffer.duration

            // Only send on silence if we have minimum duration
            if duration >= Config.minChunkDuration && Date().timeIntervalSince(lastSoundTime) >= Config.silenceDuration {
                await sendChunkIfReady(reason: "silence")
            }
        }
    }

    private func sendChunkIfReady(reason: String) async {
        guard let buffer = audioBuffer else { return }

        let result = await buffer.takeAll()
        let duration = Double(result.samples.count) / sampleRate

        guard duration >= Config.minChunkDuration else {
            Logger.audio.debug("Chunk too short (\(String(format: "%.1f", duration))s < \(Config.minChunkDuration)s)")
            return
        }

        if result.speechRatio < Config.minSpeechRatio {
            Logger.audio.debug("Skipping silent chunk (\(String(format: "%.0f", result.speechRatio * 100))% speech)")
            return
        }

        let durationStr = String(format: "%.1f", duration)
        let speechPct = String(format: "%.0f", result.speechRatio * 100)
        Logger.audio.info("Chunk ready (\(reason)): \(durationStr)s, \(speechPct)% speech")
        let wavData = createWav(from: result.samples)
        await MainActor.run {
            onChunkReady?(wavData)
        }
        lastSoundTime = Date()
    }

    func stop() {
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

        Task {
            guard let buffer = audioBuffer else { return }
            let result = await buffer.takeAll()
            let duration = Double(result.samples.count) / sampleRate

            // On stop, send whatever we have (if it has speech)
            if duration >= 1.0 && result.speechRatio >= Config.minSpeechRatio {
                Logger.audio.info("Final chunk: \(String(format: "%.1f", duration))s")
                let wavData = createWav(from: result.samples)
                await MainActor.run {
                    onChunkReady?(wavData)
                }
            }
            Logger.audio.info("Recording stopped")
        }
    }

    private func createWav(from samples: [Float]) -> Data {
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
