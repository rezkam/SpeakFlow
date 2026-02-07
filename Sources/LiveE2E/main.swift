import AVFoundation
import Foundation
import SpeakFlowCore

@MainActor
@main
struct SpeakFlowLiveE2E {
    private struct Configuration {
        let recordSeconds: Double
        let timeoutSeconds: Double
        let expectedPhrase: String?
        let autoSpeakText: String?
        let autoSpeakTextPart2: String?
        let autoSpeakGapSeconds: Double
        let autoSpeakRate: Int?
        let expectedAutoEndMinSeconds: Double?
        let expectedAutoEndMaxSeconds: Double?
        let testAutoEnd: Bool  // Test auto-end feature instead of manual stop
        let chunkDurationOverride: Double?
        let testNoiseRejection: Bool // Expect NO chunks/transcription
        let audioFilePath: String? // Path to audio file to play (instead of 'say')
        let useMockInput: Bool

        static func load() -> Configuration {
            let env = ProcessInfo.processInfo.environment
            let recordSeconds = Double(env["SPEAKFLOW_E2E_RECORD_SECONDS"] ?? "") ?? 6.0
            let timeoutSeconds = Double(env["SPEAKFLOW_E2E_TIMEOUT_SECONDS"] ?? "") ?? 35.0
            let expectedPhrase = env["SPEAKFLOW_E2E_EXPECT_PHRASE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let autoSpeakText = env["SPEAKFLOW_E2E_AUTO_SPEAK_TEXT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let autoSpeakTextPart2 = env["SPEAKFLOW_E2E_AUTO_SPEAK_TEXT_PART2"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let autoSpeakGapSeconds = Double(env["SPEAKFLOW_E2E_AUTO_SPEAK_GAP_SECONDS"] ?? "") ?? 0
            let autoSpeakRate = Int(env["SPEAKFLOW_E2E_AUTO_SPEAK_RATE"] ?? "")
            let expectedAutoEndMinSeconds = Double(env["SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS"] ?? "")
            let expectedAutoEndMaxSeconds = Double(env["SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS"] ?? "")
            let testAutoEnd = env["SPEAKFLOW_E2E_TEST_AUTO_END"] == "true" || env["SPEAKFLOW_E2E_TEST_AUTO_END"] == "1"
            let chunkDurationRaw = Double(env["SPEAKFLOW_E2E_CHUNK_DURATION"] ?? "")
            let testNoiseRejection = env["SPEAKFLOW_E2E_TEST_NOISE_REJECTION"] == "true" || env["SPEAKFLOW_E2E_TEST_NOISE_REJECTION"] == "1"
            let audioFilePath = env["SPEAKFLOW_E2E_AUDIO_FILE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let useMockInput = env["SPEAKFLOW_E2E_USE_MOCK_INPUT"] == "true" || env["SPEAKFLOW_E2E_USE_MOCK_INPUT"] == "1"
            
            return Configuration(
                recordSeconds: max(1.0, recordSeconds),
                timeoutSeconds: max(5.0, timeoutSeconds),
                expectedPhrase: expectedPhrase?.isEmpty == true ? nil : expectedPhrase,
                autoSpeakText: autoSpeakText?.isEmpty == true ? nil : autoSpeakText,
                autoSpeakTextPart2: autoSpeakTextPart2?.isEmpty == true ? nil : autoSpeakTextPart2,
                autoSpeakGapSeconds: max(0, autoSpeakGapSeconds),
                autoSpeakRate: autoSpeakRate,
                expectedAutoEndMinSeconds: expectedAutoEndMinSeconds,
                expectedAutoEndMaxSeconds: expectedAutoEndMaxSeconds,
                testAutoEnd: testAutoEnd,
                chunkDurationOverride: chunkDurationRaw,
                testNoiseRejection: testNoiseRejection,
                audioFilePath: audioFilePath,
                useMockInput: useMockInput
            )
        }
    }

    static func main() async {
        let config = Configuration.load()

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  SpeakFlow Live E2E")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        
        if config.testNoiseRejection {
             settings.skipSilentChunks = true
             print("Noise Rejection Mode: skipSilentChunks=true")
        } else {
             settings.skipSilentChunks = false
        }
        
        if let override = config.chunkDurationOverride, let duration = ChunkDuration(rawValue: override) {
            settings.chunkDuration = duration
        } else {
            settings.chunkDuration = .unlimited
        }
        
        defer {
            settings.skipSilentChunks = originalSkipSilent
            settings.chunkDuration = originalChunkDuration
        }
        
        print("Settings: skipSilentChunks=\(settings.skipSilentChunks), chunkDuration=\(settings.chunkDuration.displayName)")
        print("VAD CONFIG DUMP: vadThreshold=\(settings.vadThreshold), skipSilentChunks=\(settings.skipSilentChunks)")

        guard OpenAICodexAuth.isLoggedIn else {
            fail("Not logged in. Open SpeakFlow and complete ChatGPT login first.")
        }

        if !config.useMockInput {
            let micAuthorized = await ensureMicrophoneAccess()
            guard micAuthorized else {
                fail("Microphone access is required. Grant access for the current process and retry.")
            }
        }

        let bridge = Transcription.shared.queueBridge
        await bridge.reset()

        var chunksSubmitted = 0
        var transcriptParts: [String] = []

        bridge.onTextReady = { text in
            transcriptParts.append(text)
            print("partial: \(text)")
        }

        let recorder = StreamingRecorder()
        recorder.onChunkReady = { chunk in
            chunksSubmitted += 1
            let duration = String(format: "%.2f", chunk.durationSeconds)
            let speech = String(format: "%.0f", chunk.speechProbability * 100)
            print("chunk #\(chunksSubmitted): \(duration)s (\(speech)% speech)")
            Task { @MainActor in
                let ticket = await bridge.nextSequence()
                Transcription.shared.transcribe(ticket: ticket, chunk: chunk)
            }
        }

        if config.testAutoEnd {
            print("Testing AUTO-END feature")
        } else {
            print("Recording for \(String(format: "%.1f", config.recordSeconds))s.")
        }

        // Track if auto-end was triggered
        var autoEndTriggered = false
        var autoEndElapsedSeconds: Double?
        let autoEndTime = Date()
        
        recorder.onAutoEnd = {
            autoEndTriggered = true
            let elapsed = Date().timeIntervalSince(autoEndTime)
            autoEndElapsedSeconds = elapsed
            print("🔔 AUTO-END triggered after \(String(format: "%.1f", elapsed))s")
        }

        if config.useMockInput {
            var audioData: [Float] = []
            if let path = config.audioFilePath {
                if let loaded = loadAudioFile(path: path) {
                    audioData = loaded
                    print("Loaded audio file: \(path) (\(audioData.count) samples)")
                } else {
                    fail("Failed to load audio file at \(path)")
                }
            } else {
                print("Using synthesized sine wave audio")
                let sampleRate = 16000.0
                let duration = config.recordSeconds
                // Simple sine wave
                let sampleCount = Int(sampleRate * duration)
                audioData = (0..<sampleCount).map { i -> Float in
                     let time = Double(i) / sampleRate
                     let angle = 2.0 * .pi * 440.0 * time
                     return Float(sin(angle)) * 0.5
                }
            }
            await recorder.startMock(audioData: audioData)
        } else {
            await recorder.start()
            if let autoSpeakText = config.autoSpeakText {
                startAutoSpeakSequence(
                    firstText: autoSpeakText,
                    secondText: config.autoSpeakTextPart2,
                    gapSeconds: config.autoSpeakGapSeconds,
                    rate: config.autoSpeakRate
                )
            } else if let audioPath = config.audioFilePath {
                 print("Playing audio file: \(audioPath)")
                 startAudioPlayback(filePath: audioPath)
            }
        }
        
        if config.testAutoEnd {
            // Wait for auto-end or timeout
            let autoEndDeadline = Date().addingTimeInterval(config.timeoutSeconds)
            while !autoEndTriggered && Date() < autoEndDeadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            
            if autoEndTriggered {
                print("✅ Auto-end worked!")
                recorder.stop()
            } else {
                recorder.stop()
                fail("Auto-end did NOT trigger within \(config.timeoutSeconds)s timeout")
            }
        } else {
            // Normal mode: manual stop after fixed time
            // If using mock input, the input runs out or we wait recordSeconds
            try? await Task.sleep(for: .seconds(config.recordSeconds))
            recorder.stop()
        }

        let deadline = Date().addingTimeInterval(config.timeoutSeconds)
        while Date() < deadline {
            let pending = await bridge.getPendingCount()
            if chunksSubmitted > 0 && pending == 0 {
                break
            }
            if pending == 0 && chunksSubmitted == 0 {
                // If we haven't submitted anything yet, keep waiting
            }
             if pending == 0 && chunksSubmitted > 0 { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let pendingAfterWait = await bridge.getPendingCount()
        
        if config.testNoiseRejection {
            if chunksSubmitted > 0 {
                fail("Noise rejection failed: \(chunksSubmitted) chunks were sent to API.")
            } else {
                print("✅ Noise rejection passed: 0 chunks sent.")
                return 
            }
        }

        if chunksSubmitted == 0 {
            fail("No chunks were produced. Ensure input has audible speech.")
        }
        if pendingAfterWait > 0 {
            Transcription.shared.cancelAll()
            fail("Timed out waiting for transcription completion (\(pendingAfterWait) pending).")
        }

        let transcript = transcriptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        print("Transcript: \(transcript)")
        print("Status: PASS")
    }

    private static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private static func startAutoSpeakSequence(firstText: String, secondText: String?, gapSeconds: Double, rate: Int?) {
        _ = startAutoSpeak(text: firstText, rate: rate)
        guard let secondText, !secondText.isEmpty else { return }
        Task { @MainActor in
            if gapSeconds > 0 { try? await Task.sleep(for: .seconds(gapSeconds)) }
            _ = startAutoSpeak(text: secondText, rate: rate)
        }
    }

    @discardableResult
    private static func startAutoSpeak(text: String, rate: Int?) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        if let rate { process.arguments = ["-r", "\(rate)", text] }
        else { process.arguments = [text] }
        try? process.run()
        return process
    }

    @discardableResult
    private static func startAudioPlayback(filePath: String) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [filePath]
        try? process.run()
        return process
    }
    
    private static func loadAudioFile(path: String) -> [Float]? {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return nil
        }
        try? file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private static func looselyMatches(expected: String, actual: String) -> Bool {
        let expectedWords = normalizedWords(expected)
        let actualWords = normalizedWords(actual)
        guard !expectedWords.isEmpty else { return true }
        let overlapCount = expectedWords.intersection(actualWords).count
        let requiredOverlap = max(1, expectedWords.count / 2)
        return overlapCount >= requiredOverlap
    }

    private static func normalizedWords(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let components = lowered.split { !$0.isLetter && !$0.isNumber }
        return Set(components.map(String.init))
    }

    private static func fail(_ message: String) -> Never {
        fputs("ERROR: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
