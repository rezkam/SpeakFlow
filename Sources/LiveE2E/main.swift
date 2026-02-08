import AVFoundation
import Foundation
import SpeakFlowCore

// MARK: - Test Scenario Definition

/// A speech segment followed by optional silence.
struct TextSegment {
    let text: String
    /// Seconds of silence to insert AFTER this segment's audio.
    let silenceAfterSeconds: Double
}

struct TestScenario {
    let name: String
    /// Audio is built by concatenating segments (with silence gaps between).
    let segments: [TextSegment]
    let chunkDuration: ChunkDuration
    let expectedMinChunks: Int
    let expectedMaxChunks: Int
    /// Extra seconds after all audio is fed before stopping (lets VAD/timers fire).
    let trailingSeconds: Double
    /// Speech rate for macOS `say` (nil = default ~175 wpm).
    let rate: Int?
    let validateTranscript: Bool

    /// Combined text from all segments for transcript matching.
    var fullText: String { segments.map(\.text).joined(separator: " ") }
}

// MARK: - Audio Fixture Generation

@MainActor
struct AudioFixture {
    let durationSeconds: Double
    let samples: [Float]
}

/// Generate a multi-segment fixture: speech from `say`, resampled to 16 kHz mono,
/// with silence gaps between segments.
@MainActor
func generateFixture(segments: [TextSegment], rate: Int?,
                     fixturesDir: URL, index: Int) -> AudioFixture? {
    let targetRate: Double = 16000
    var allSamples: [Float] = []

    for (segIdx, segment) in segments.enumerated() {
        let aiffPath = fixturesDir.appendingPathComponent("fix\(index)_s\(segIdx).aiff").path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args = ["-o", aiffPath]
        if let rate { args += ["-r", "\(rate)"] }
        args.append(segment.text)
        proc.arguments = args

        do { try proc.run(); proc.waitUntilExit() }
        catch {
            print("    ✗ say failed for segment \(segIdx) (\"\(segment.text.prefix(40))…\"): \(error)")
            return nil
        }
        guard proc.terminationStatus == 0 else {
            print("    ✗ say exited with status \(proc.terminationStatus) for segment \(segIdx) (\"\(segment.text.prefix(40))…\"), output path: \(aiffPath)")
            return nil
        }

        guard FileManager.default.fileExists(atPath: aiffPath) else {
            print("    ✗ say produced no output file at \(aiffPath)")
            return nil
        }

        guard let samples = resampleToMono16k(path: aiffPath) else {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: aiffPath)[.size] as? Int) ?? 0
            print("    ✗ resample to 16kHz mono failed for segment \(segIdx), source file: \(aiffPath) (\(fileSize) bytes)")
            return nil
        }

        let segDur = String(format: "%.1f", Double(samples.count) / targetRate)
        if segment.silenceAfterSeconds > 0 {
            print("    seg[\(segIdx)]: \(segDur)s speech + \(String(format: "%.1f", segment.silenceAfterSeconds))s silence")
        } else {
            print("    seg[\(segIdx)]: \(segDur)s speech")
        }

        allSamples.append(contentsOf: samples)
        if segment.silenceAfterSeconds > 0 {
            allSamples.append(contentsOf: [Float](repeating: 0,
                count: Int(targetRate * segment.silenceAfterSeconds)))
        }
    }

    let duration = Double(allSamples.count) / targetRate
    return AudioFixture(durationSeconds: duration, samples: allSamples)
}

/// Load an audio file and resample to 16 kHz mono Float32.
private func resampleToMono16k(path: String) -> [Float]? {
    let url = URL(fileURLWithPath: path)
    guard let file = try? AVAudioFile(forReading: url) else { return nil }

    let srcRate = file.processingFormat.sampleRate
    let srcFrames = AVAudioFrameCount(file.length)
    guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: srcRate, channels: 1, interleaved: false),
          let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: srcFrames)
    else { return nil }
    do { try file.read(into: srcBuf) } catch { return nil }

    let targetRate: Double = 16000
    let outFrames = AVAudioFrameCount(Double(srcFrames) * targetRate / srcRate)
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: targetRate, channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: srcFmt, to: outFmt),
          let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outFrames)
    else { return nil }

    final class OneShot: @unchecked Sendable {
        var done = false; let buf: AVAudioPCMBuffer
        init(_ b: AVAudioPCMBuffer) { buf = b }
    }
    let state = OneShot(srcBuf)
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
        if !state.done { state.done = true; status.pointee = .haveData; return state.buf }
        status.pointee = .endOfStream; return nil
    }

    guard let d = outBuf.floatChannelData?[0] else { return nil }
    return Array(UnsafeBufferPointer(start: d, count: Int(outBuf.frameLength)))
}

// MARK: - Test Runner

@MainActor
struct SpeakFlowLiveE2E {

    // ── Scenarios ────────────────────────────────────────────────────

    static let scenarios: [TestScenario] = [

        // 1) Short utterance — single chunk
        TestScenario(
            name: "Short speech → single chunk (unlimited)",
            segments: [TextSegment(text: "Hello world, this is a quick test.", silenceAfterSeconds: 0)],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: true
        ),

        // 2) Medium speech — fits inside 15 s chunk
        TestScenario(
            name: "Medium speech → single chunk (15s)",
            segments: [TextSegment(
                text: "The quick brown fox jumps over the lazy dog. "
                    + "This sentence tests whether a medium length phrase is captured correctly.",
                silenceAfterSeconds: 0
            )],
            chunkDuration: .seconds15,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: true
        ),

        // 3) Two-part speech with silence gap → VAD splits into 2 chunks
        //    Part 1 exceeds 15 s so the buffer reaches chunk size before the gap.
        TestScenario(
            name: "Two-part speech with pause → 2 chunks (15s)",
            segments: [
                TextSegment(
                    text: "This is the first part of a longer recording session. "
                        + "It needs to be long enough to fill an entire fifteen second chunk buffer. "
                        + "The voice activity detection system should recognise the silence gap that follows. "
                        + "Once the gap is detected and the buffer exceeds the chunk duration, "
                        + "the system must automatically send this chunk to the transcription service.",
                    silenceAfterSeconds: 3.0
                ),
                TextSegment(
                    text: "Now this is the second part spoken after a clear pause. "
                        + "It should arrive as a completely separate chunk in the transcription queue.",
                    silenceAfterSeconds: 0
                ),
            ],
            chunkDuration: .seconds15,
            expectedMinChunks: 2, expectedMaxChunks: 3,
            trailingSeconds: 5, rate: 170, validateTranscript: true
        ),

        // 4) Same two-part audio with 30 s chunks → fits in one chunk
        TestScenario(
            name: "Two-part speech → single chunk (30s chunks, audio fits)",
            segments: [
                TextSegment(
                    text: "This is the first part of a longer recording session. "
                        + "It needs to be long enough to fill an entire fifteen second chunk buffer. "
                        + "The voice activity detection system should recognise the silence gap that follows. "
                        + "Once the gap is detected and the buffer exceeds the chunk duration, "
                        + "the system must automatically send this chunk to the transcription service.",
                    silenceAfterSeconds: 3.0
                ),
                TextSegment(
                    text: "Now this is the second part spoken after a clear pause. "
                        + "It should arrive as a completely separate chunk in the transcription queue.",
                    silenceAfterSeconds: 0
                ),
            ],
            chunkDuration: .seconds30,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 5, rate: 170, validateTranscript: true
        ),

        // 5) Short phrase — baseline transcription check
        TestScenario(
            name: "Short phrase → unlimited (baseline)",
            segments: [TextSegment(
                text: "The rain in Spain stays mainly in the plain.",
                silenceAfterSeconds: 0
            )],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: true
        ),
    ]

    // ── Entry point ──────────────────────────────────────────────────

    static func main() async {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  SpeakFlow Live E2E — Multi-Scenario Suite")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        guard OpenAICodexAuth.isLoggedIn else {
            fail("Not logged in. Open SpeakFlow and complete ChatGPT login first.")
        }

        // ── Generate fixtures ────────────────────────────────────────
        let fixturesDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpeakFlowE2E_\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixturesDir) }

        print("\n📦 Generating audio fixtures…")
        var fixtures: [AudioFixture] = []
        for (i, s) in scenarios.enumerated() {
            print("  [\(i+1)/\(scenarios.count)] \(s.name)")
            guard let f = generateFixture(segments: s.segments, rate: s.rate,
                                          fixturesDir: fixturesDir, index: i) else {
                fail("Fixture generation failed for: \(s.name)")
            }
            print("    → total: \(String(format: "%.1f", f.durationSeconds))s")
            fixtures.append(f)
        }

        // ── Run scenarios ────────────────────────────────────────────
        var passed = 0, failed = 0

        for (i, scenario) in scenarios.enumerated() {
            let fixture = fixtures[i]
            print("\n┌─────────────────────────────────────────────")
            print("│ [\(i+1)/\(scenarios.count)] \(scenario.name)")
            print("│ Audio: \(String(format: "%.1f", fixture.durationSeconds))s  Chunk: \(scenario.chunkDuration.displayName)")
            print("└─────────────────────────────────────────────")

            let r = await runScenario(scenario: scenario, fixture: fixture)
            if r.success { print("  ✅ PASS"); passed += 1 }
            else { print("  ❌ FAIL: \(r.error ?? "unknown")"); failed += 1 }
        }

        // ── Summary ──────────────────────────────────────────────────
        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  Results: \(passed) passed, \(failed) failed")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        if failed > 0 { Foundation.exit(1) }
    }

    // MARK: - Scenario Execution

    struct ScenarioResult {
        let success: Bool; let error: String?
        static func pass() -> ScenarioResult { .init(success: true, error: nil) }
        static func fail(_ m: String) -> ScenarioResult { .init(success: false, error: m) }
    }

    static func runScenario(scenario: TestScenario, fixture: AudioFixture) async -> ScenarioResult {
        // Configure settings
        let settings = Settings.shared
        let savedChunk = settings.chunkDuration
        let savedSkip  = settings.skipSilentChunks
        settings.chunkDuration = scenario.chunkDuration
        settings.skipSilentChunks = false
        defer {
            settings.chunkDuration = savedChunk
            settings.skipSilentChunks = savedSkip
        }

        let bridge = Transcription.shared.queueBridge
        await bridge.reset()

        var chunksSubmitted = 0
        var transcriptParts: [String] = []

        bridge.onTextReady = { text in
            transcriptParts.append(text)
            let preview = text.count > 80 ? String(text.prefix(77)) + "…" : text
            print("    📝 chunk transcript: \(preview)")
        }

        let recorder = StreamingRecorder()
        recorder.onChunkReady = { chunk in
            chunksSubmitted += 1
            let dur = String(format: "%.1f", chunk.durationSeconds)
            let sp  = String(format: "%.0f", chunk.speechProbability * 100)
            print("    🎤 chunk #\(chunksSubmitted): \(dur)s (\(sp)% speech)")
            Task { @MainActor in
                let ticket = await bridge.nextSequence()
                Transcription.shared.transcribe(ticket: ticket, chunk: chunk)
            }
        }

        // Feed pre-recorded audio via mock input (no mic/speaker needed)
        await recorder.startMock(audioData: fixture.samples)

        let totalWait = fixture.durationSeconds + scenario.trailingSeconds
        print("    ⏱ Feeding \(String(format: "%.1f", fixture.durationSeconds))s + \(String(format: "%.0f", scenario.trailingSeconds))s trailing…")
        try? await Task.sleep(nanoseconds: UInt64(totalWait * 1_000_000_000))
        recorder.stop()

        // Grace period for stop()'s async final-chunk Task to fire
        try? await Task.sleep(for: .seconds(2))

        // Drain transcription responses (up to 30 s)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let pending = await bridge.getPendingCount()
            if chunksSubmitted > 0 && pending == 0 { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let pending = await bridge.getPendingCount()
        if pending > 0 {
            Transcription.shared.cancelAll()
            return .fail("Timed out: \(pending) transcription(s) still pending")
        }

        // ── Validate chunk count ─────────────────────────────────────
        print("    📊 Chunks: \(chunksSubmitted) (expected \(scenario.expectedMinChunks)–\(scenario.expectedMaxChunks))")
        if chunksSubmitted < scenario.expectedMinChunks {
            return .fail("Too few chunks: \(chunksSubmitted) < min \(scenario.expectedMinChunks)")
        }
        if chunksSubmitted > scenario.expectedMaxChunks {
            return .fail("Too many chunks: \(chunksSubmitted) > max \(scenario.expectedMaxChunks)")
        }

        // ── Validate transcript ──────────────────────────────────────
        let transcript = transcriptParts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = transcript.count > 120 ? String(transcript.prefix(117)) + "…" : transcript
        print("    📄 Transcript: \(preview)")

        if transcript.isEmpty {
            return .fail("Empty transcript — audio sent but nothing returned")
        }
        if scenario.validateTranscript && !looselyMatches(expected: scenario.fullText, actual: transcript) {
            return .fail("Transcript mismatch.\n      Expected: \(scenario.fullText.prefix(80))…\n      Got: \(transcript.prefix(80))…")
        }

        return .pass()
    }

    // MARK: - Helpers

    /// Loose match: at least 1/3 of expected words must appear in actual.
    static func looselyMatches(expected: String, actual: String) -> Bool {
        let exp = normalized(expected), act = normalized(actual)
        guard !exp.isEmpty else { return true }
        return exp.intersection(act).count >= max(1, exp.count / 3)
    }

    private static func normalized(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    static func fail(_ message: String) -> Never {
        fputs("ERROR: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

// Entry point
await SpeakFlowLiveE2E.main()
