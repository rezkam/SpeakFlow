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
                audioFilePath: audioFilePath
            )
        }
    }

    static func main() async {
        let config = Configuration.load()

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  SpeakFlow Live E2E")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // CRITICAL: Configure settings for E2E testing
        // LiveE2E runs as separate bundle with fresh UserDefaults
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        
        if config.testNoiseRejection {
             // For noise rejection, we WANT to skip silent chunks to verify VAD is working
             settings.skipSilentChunks = true
             print("Noise Rejection Mode: skipSilentChunks=true")
        } else {
             // For normal transcription tests, disable skipSilentChunks to ensure chunks are sent
             settings.skipSilentChunks = false
        }
        
        // Apply chunk duration override if present, otherwise default to unlimited
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
        print("VAD CONFIG DUMP (stdout): vadThreshold=\(settings.vadThreshold), minSilenceAfterSpeech=\(Config.vadMinSilenceAfterSpeech), autoEndEnabled=\(settings.autoEndEnabled), autoEndSilenceDuration=\(settings.autoEndSilenceDuration), autoEndMinSession=\(Config.autoEndMinSessionDuration), maxChunkDuration=\(settings.maxChunkDuration), chunkDuration=\(settings.chunkDuration.rawValue), skipSilentChunks=\(settings.skipSilentChunks)")

        guard OpenAICodexAuth.isLoggedIn else {
            fail("Not logged in. Open SpeakFlow and complete ChatGPT login first.")
        }

        let micAuthorized = await ensureMicrophoneAccess()
        guard micAuthorized else {
            fail("Microphone access is required. Grant access for the current process and retry.")
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
                let seq = await bridge.nextSequence()
                Transcription.shared.transcribe(seq: seq, chunk: chunk)
            }
        }

        if config.testAutoEnd {
            print("Testing AUTO-END feature (will wait for auto-end to trigger)")
            print("Auto-end should trigger ~5s after speech ends")
        } else {
            print("Recording for \(String(format: "%.1f", config.recordSeconds))s.")
        }
        if let expectedPhrase = config.expectedPhrase {
            print("Expected phrase hint: \"\(expectedPhrase)\"")
        }
        if let autoSpeakText = config.autoSpeakText {
            print("Auto-speak enabled: \"\(autoSpeakText)\"")
            if let autoSpeakTextPart2 = config.autoSpeakTextPart2 {
                print("Auto-speak part 2 after \(String(format: "%.1f", config.autoSpeakGapSeconds))s gap: \"\(autoSpeakTextPart2)\"")
            }
            if let autoSpeakRate = config.autoSpeakRate {
                print("Auto-speak rate: \(autoSpeakRate) words/min")
            }
        } else {
            print("Speak clearly after the countdown.")
        }
        if let min = config.expectedAutoEndMinSeconds, let max = config.expectedAutoEndMaxSeconds {
            print("Expected auto-end window: \(String(format: "%.1f", min))s - \(String(format: "%.1f", max))s")
        }

        for seconds in stride(from: 3, through: 1, by: -1) {
            print("Starting in \(seconds)...")
            try? await Task.sleep(for: .seconds(1))
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
        
        if config.testAutoEnd {
            // Wait for auto-end or timeout
            let autoEndDeadline = Date().addingTimeInterval(config.timeoutSeconds)
            while !autoEndTriggered && Date() < autoEndDeadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            
            if autoEndTriggered {
                print("✅ Auto-end worked! Recording stopped automatically.")
                if let elapsed = autoEndElapsedSeconds,
                   let min = config.expectedAutoEndMinSeconds,
                   let max = config.expectedAutoEndMaxSeconds {
                    if elapsed < min || elapsed > max {
                        recorder.stop()
                        fail("Auto-end timing out of range: elapsed=\(String(format: "%.1f", elapsed))s, expected \(String(format: "%.1f", min))s-\(String(format: "%.1f", max))s")
                    }
                    print("✅ Auto-end timing within expected window")
                }
                recorder.stop()  // Clean up
            } else {
                recorder.stop()
                fail("Auto-end did NOT trigger within \(config.timeoutSeconds)s timeout")
            }
        } else {
            // Normal mode: manual stop after fixed time
            try? await Task.sleep(for: .seconds(config.recordSeconds))
            recorder.stop()
        }

        let deadline = Date().addingTimeInterval(config.timeoutSeconds)
        while Date() < deadline {
            let pending = await bridge.getPendingCount()
            if chunksSubmitted > 0 && pending == 0 {
                break
            }
            // In noise rejection mode, we expect 0 chunks, so we might just wait the full timeout?
            // Actually, if we stopped recording, we just wait for pending to drain.
            // If chunksSubmitted is 0, pending is 0, loop breaks immediately?
            // No, if chunksSubmitted == 0, the first condition `chunksSubmitted > 0` fails, so we loop until timeout?
            // We should break if pending == 0 regardless of chunksSubmitted, but only after some grace period?
            // Actually, `getPendingCount` checks the queue. If nothing was ever added, it's 0.
            if pending == 0 {
                 break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let pendingAfterWait = await bridge.getPendingCount()
        
        if config.testNoiseRejection {
            if chunksSubmitted > 0 {
                fail("Noise rejection failed: \(chunksSubmitted) chunks were sent to API.")
            } else {
                print("✅ Noise rejection passed: 0 chunks sent.")
                print("Status: PASS")
                return // Exit successfully
            }
        }

        if chunksSubmitted == 0 {
            fail("No chunks were produced. Ensure microphone input has audible speech.")
        }
        if pendingAfterWait > 0 {
            Transcription.shared.cancelAll()
            fail("Timed out waiting for transcription completion (\(pendingAfterWait) pending).")
        }

        let transcript = transcriptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            fail("Transcription result is empty.")
        }

        if let expected = config.expectedPhrase, !looselyMatches(expected: expected, actual: transcript) {
            fail("""
            Transcript did not match expected phrase.
            expected: \(expected)
            actual:   \(transcript)
            """)
        }

        print("Transcript: \(transcript)")
        print("Status: PASS")
    }

    private static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func startAutoSpeakSequence(firstText: String, secondText: String?, gapSeconds: Double, rate: Int?) {
        _ = startAutoSpeak(text: firstText, rate: rate)

        guard let secondText, !secondText.isEmpty else { return }

        Task { @MainActor in
            if gapSeconds > 0 {
                try? await Task.sleep(for: .seconds(gapSeconds))
            }
            _ = startAutoSpeak(text: secondText, rate: rate)
        }
    }

    @discardableResult
    private static func startAutoSpeak(text: String, rate: Int?) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")

        if let rate {
            process.arguments = ["-r", "\(rate)", text]
        } else {
            process.arguments = [text]
        }

        do {
            try process.run()
            return process
        } catch {
            fputs("WARNING: failed to start auto-speak: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    @discardableResult
    private static func startAudioPlayback(filePath: String) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [filePath]

        do {
            try process.run()
            return process
        } catch {
            fputs("WARNING: failed to start audio playback: \(error.localizedDescription)\n", stderr)
            return nil
        }
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
