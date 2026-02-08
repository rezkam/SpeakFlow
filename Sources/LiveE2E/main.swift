import AVFoundation
import Foundation
import SpeakFlowCore

// MARK: - Test Scenario Definition

/// Type of background noise to fill "silence" gaps.
enum NoiseType: String, CaseIterable {
    case digital       // Pure zeros (unrealistic, easy for VAD)
    case whiteNoise    // AC / fan hiss
    case pinkNoise     // Natural room tone
    case brownNoise    // Low rumble (traffic, HVAC)
    case officeAmbient // Pink noise + 120 Hz hum
    case breathing     // Periodic low-amplitude bursts (simulates breathing)
}

/// A speech segment followed by optional silence.
struct TextSegment {
    let text: String
    /// Seconds of silence to insert AFTER this segment's audio.
    let silenceAfterSeconds: Double
    /// What fills the silence gap. Default is `.digital` (pure zeros) for backward compat.
    let noiseType: NoiseType

    init(text: String, silenceAfterSeconds: Double, noiseType: NoiseType = .digital) {
        self.text = text
        self.silenceAfterSeconds = silenceAfterSeconds
        self.noiseType = noiseType
    }
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
    /// If non-nil, validates auto-end behavior:
    /// - `true`: auto-end MUST fire during the scenario (session ends by itself)
    /// - `false`: auto-end must NOT fire (session stays alive until manual stop)
    let expectAutoEnd: Bool?

    /// Combined text from all segments for transcript matching.
    var fullText: String { segments.map(\.text).joined(separator: " ") }

    init(name: String, segments: [TextSegment], chunkDuration: ChunkDuration,
         expectedMinChunks: Int, expectedMaxChunks: Int,
         trailingSeconds: Double, rate: Int?, validateTranscript: Bool,
         expectAutoEnd: Bool? = nil) {
        self.name = name
        self.segments = segments
        self.chunkDuration = chunkDuration
        self.expectedMinChunks = expectedMinChunks
        self.expectedMaxChunks = expectedMaxChunks
        self.trailingSeconds = trailingSeconds
        self.rate = rate
        self.validateTranscript = validateTranscript
        self.expectAutoEnd = expectAutoEnd
    }
}

// MARK: - Noise Generation

/// Generate noise samples at 16 kHz to fill "silence" gaps in test audio.
/// These simulate real-world ambient sound that a microphone picks up.
func generateNoiseSamples(type: NoiseType, count: Int) -> [Float] {
    switch type {
    case .digital:
        return [Float](repeating: 0, count: count)

    case .whiteNoise:
        // Low-level white noise (AC hiss, ~0.005–0.01 RMS)
        return (0..<count).map { _ in Float.random(in: -0.015...0.015) }

    case .pinkNoise:
        // Pink noise via simple 1/f approximation (Voss-McCartney)
        // More energy in low frequencies — sounds like room tone
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        let amplitude: Float = 0.02
        return (0..<count).map { _ in
            let white = Float.random(in: -1...1)
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            return (b0 + b1 + b2 + white * 0.5362) * amplitude * 0.15
        }

    case .brownNoise:
        // Brown noise (random walk) — low-frequency rumble like distant traffic
        var last: Float = 0
        let amplitude: Float = 0.03
        return (0..<count).map { _ in
            last = last * 0.998 + Float.random(in: -0.01...0.01)
            return last * amplitude * 5.0
        }

    case .officeAmbient:
        // Pink noise + 120 Hz electrical hum (office environment)
        let pink = generateNoiseSamples(type: .pinkNoise, count: count)
        let sampleRate: Float = 16000
        let humFreq: Float = 120
        let humAmplitude: Float = 0.003
        return pink.enumerated().map { (i, p) in
            let hum = sin(2.0 * .pi * humFreq * Float(i) / sampleRate) * humAmplitude
            return p + hum
        }

    case .breathing:
        // Periodic amplitude bursts every ~3-4 seconds (simulates breathing)
        // Base is low pink noise with periodic louder bursts
        let base = generateNoiseSamples(type: .pinkNoise, count: count)
        let sampleRate: Float = 16000
        let breathCycle: Float = 3.5  // seconds per breath
        let breathDuration: Float = 0.8 // how long each breath lasts
        return base.enumerated().map { (i, b) in
            let t = Float(i) / sampleRate
            let cyclePos = t.truncatingRemainder(dividingBy: breathCycle)
            // During "breath" portion, boost amplitude 3-5x
            if cyclePos < breathDuration {
                let envelope = sin(.pi * cyclePos / breathDuration) // smooth rise/fall
                return b * (1.0 + envelope * 4.0)
            }
            return b
        }
    }
}

// MARK: - Audio Fixture Generation

@MainActor
struct AudioFixture {
    let durationSeconds: Double
    let samples: [Float]
}

/// Generate a multi-segment fixture: speech from `say`, resampled to 16 kHz mono,
/// with noise-filled gaps between segments.
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
        let noiseLabel = segment.noiseType == .digital ? "silence" : "\(segment.noiseType.rawValue)"
        if segment.silenceAfterSeconds > 0 {
            print("    seg[\(segIdx)]: \(segDur)s speech + \(String(format: "%.1f", segment.silenceAfterSeconds))s \(noiseLabel)")
        } else {
            print("    seg[\(segIdx)]: \(segDur)s speech")
        }

        allSamples.append(contentsOf: samples)
        if segment.silenceAfterSeconds > 0 {
            let gapSamples = Int(targetRate * segment.silenceAfterSeconds)
            let noise = generateNoiseSamples(type: segment.noiseType, count: gapSamples)
            allSamples.append(contentsOf: noise)
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

        // ── Silence Boundary Tests ──────────────────────────────────
        // These verify the core auto-end invariant: the turn should ONLY
        // end after 5.0s of silence (plus ~1s VAD detection delay).
        // Short thinking pauses must NEVER kill the session.

        // 6) 1s thinking pause — must NOT auto-end
        TestScenario(
            name: "Silence 1s pause → must NOT auto-end",
            segments: [
                TextSegment(
                    text: "I need to think about this for a moment.",
                    silenceAfterSeconds: 1.0
                ),
                TextSegment(
                    text: "Okay I have decided the answer is forty two.",
                    silenceAfterSeconds: 0
                ),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: true,
            expectAutoEnd: false
        ),

        // 7) 2s thinking pause — must NOT auto-end
        TestScenario(
            name: "Silence 2s pause → must NOT auto-end",
            segments: [
                TextSegment(
                    text: "Let me think about this carefully before I respond.",
                    silenceAfterSeconds: 2.0
                ),
                TextSegment(
                    text: "Right so the answer to that question is definitely yes.",
                    silenceAfterSeconds: 0
                ),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: true,
            expectAutoEnd: false
        ),

        // 8) 3s thinking pause — must NOT auto-end
        TestScenario(
            name: "Silence 3s pause → must NOT auto-end",
            segments: [
                TextSegment(
                    text: "This is a really tough question that requires some thought.",
                    silenceAfterSeconds: 3.0
                ),
                TextSegment(
                    text: "After careful consideration I believe the correct approach is to start over.",
                    silenceAfterSeconds: 0
                ),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: true,
            expectAutoEnd: false
        ),

        // 9) 4s thinking pause — must NOT auto-end
        //    This is near the threshold but still safely below.
        //    VAD detects speech-end after ~1s → auto-end timer has ~3s → well under 5s.
        TestScenario(
            name: "Silence 4s pause → must NOT auto-end",
            segments: [
                TextSegment(
                    text: "I am going to take a long pause now to gather my thoughts.",
                    silenceAfterSeconds: 4.0
                ),
                TextSegment(
                    text: "And now I am back with a fully formed response to share with you.",
                    silenceAfterSeconds: 0
                ),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: true,
            expectAutoEnd: false
        ),

        // 10) 8s silence at end — MUST auto-end
        //     VAD detects speech-end after ~1s → auto-end timer gets ~7s → exceeds 5s.
        //     Using 8s (not 5s) because total pipeline delay is ~6s (1s VAD + 5s timer).
        TestScenario(
            name: "Silence 8s → MUST auto-end",
            segments: [
                TextSegment(
                    text: "I am done speaking now and will remain silent.",
                    silenceAfterSeconds: 8.0
                ),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 5, rate: nil, validateTranscript: false,
            expectAutoEnd: true
        ),

        // 11) 12s silence at end — MUST auto-end (generous margin)
        TestScenario(
            name: "Silence 12s → MUST auto-end (margin)",
            segments: [
                TextSegment(
                    text: "This sentence is followed by a very long silence.",
                    silenceAfterSeconds: 12.0
                ),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 5, rate: nil, validateTranscript: false,
            expectAutoEnd: true
        ),

        // 12) Multiple short pauses — none should trigger auto-end
        //     Simulates natural conversation with multiple thinking gaps.
        TestScenario(
            name: "Multiple 2s pauses → must NOT auto-end",
            segments: [
                TextSegment(
                    text: "First point is that we need better testing.",
                    silenceAfterSeconds: 2.0
                ),
                TextSegment(
                    text: "Second point is that silence detection must be reliable.",
                    silenceAfterSeconds: 2.0
                ),
                TextSegment(
                    text: "Third and final point is that short pauses are normal.",
                    silenceAfterSeconds: 0
                ),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: true,
            expectAutoEnd: false
        ),

        // ── Noisy Silence Tests ─────────────────────────────────────
        // Real microphones never record true silence. These test that
        // ambient noise during pauses does NOT confuse the VAD into
        // firing premature speech-end → auto-end.

        // 13–17) 2s pause with each noise type — must NOT auto-end
        //        2s is the duration the user reports as problematic.
        TestScenario(
            name: "2s pause + white noise → must NOT auto-end",
            segments: [
                TextSegment(text: "Testing with white noise in the background during my pause.",
                            silenceAfterSeconds: 2.0, noiseType: .whiteNoise),
                TextSegment(text: "And now I continue speaking after the noisy pause.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        TestScenario(
            name: "2s pause + pink noise → must NOT auto-end",
            segments: [
                TextSegment(text: "Testing with pink noise simulating natural room tone.",
                            silenceAfterSeconds: 2.0, noiseType: .pinkNoise),
                TextSegment(text: "Back to speaking after the room tone pause.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        TestScenario(
            name: "2s pause + brown noise → must NOT auto-end",
            segments: [
                TextSegment(text: "Testing with brown noise like distant traffic rumble.",
                            silenceAfterSeconds: 2.0, noiseType: .brownNoise),
                TextSegment(text: "Resuming speech after the low frequency noise pause.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        TestScenario(
            name: "2s pause + office ambient → must NOT auto-end",
            segments: [
                TextSegment(text: "Testing with office ambient noise and electrical hum.",
                            silenceAfterSeconds: 2.0, noiseType: .officeAmbient),
                TextSegment(text: "Continuing to speak after the office noise pause.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        TestScenario(
            name: "2s pause + breathing → must NOT auto-end",
            segments: [
                TextSegment(text: "Testing with breathing sounds during the thinking pause.",
                            silenceAfterSeconds: 2.0, noiseType: .breathing),
                TextSegment(text: "Now speaking again after the breathing pause.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        // 18–20) 1s pause with noisiest types — the exact bug scenario
        TestScenario(
            name: "1s pause + pink noise → must NOT auto-end",
            segments: [
                TextSegment(text: "Very short pause with room tone noise.",
                            silenceAfterSeconds: 1.0, noiseType: .pinkNoise),
                TextSegment(text: "Immediately continuing after the brief pause.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        TestScenario(
            name: "1s pause + breathing → must NOT auto-end",
            segments: [
                TextSegment(text: "Quick breath pause with breathing noise.",
                            silenceAfterSeconds: 1.0, noiseType: .breathing),
                TextSegment(text: "Right back to talking after the breath.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        TestScenario(
            name: "1s pause + office ambient → must NOT auto-end",
            segments: [
                TextSegment(text: "Brief office noise pause while thinking.",
                            silenceAfterSeconds: 1.0, noiseType: .officeAmbient),
                TextSegment(text: "Okay I have my answer now.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        // 21–23) 3s pause with noise — near the danger zone
        TestScenario(
            name: "3s pause + breathing → must NOT auto-end",
            segments: [
                TextSegment(text: "Taking a longer breather to collect my thoughts.",
                            silenceAfterSeconds: 3.0, noiseType: .breathing),
                TextSegment(text: "Alright I have figured out what I want to say.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        TestScenario(
            name: "3s pause + office ambient → must NOT auto-end",
            segments: [
                TextSegment(text: "Long pause in a noisy office environment.",
                            silenceAfterSeconds: 3.0, noiseType: .officeAmbient),
                TextSegment(text: "Back with my complete thought after the pause.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        TestScenario(
            name: "3s pause + brown noise → must NOT auto-end",
            segments: [
                TextSegment(text: "Pausing with traffic rumble in the background.",
                            silenceAfterSeconds: 3.0, noiseType: .brownNoise),
                TextSegment(text: "Continuing my thought after the noisy pause.",
                            silenceAfterSeconds: 0),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 3, rate: nil, validateTranscript: false,
            expectAutoEnd: false
        ),

        // 24–25) Auto-end SHOULD fire with noise (not just digital silence)
        TestScenario(
            name: "8s pink noise → MUST auto-end",
            segments: [
                TextSegment(text: "Done speaking now with room tone in background.",
                            silenceAfterSeconds: 8.0, noiseType: .pinkNoise),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 5, rate: nil, validateTranscript: false,
            expectAutoEnd: true
        ),

        TestScenario(
            name: "8s office ambient → MUST auto-end",
            segments: [
                TextSegment(text: "Finished talking in a noisy office.",
                            silenceAfterSeconds: 8.0, noiseType: .officeAmbient),
            ],
            chunkDuration: .unlimited,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 5, rate: nil, validateTranscript: false,
            expectAutoEnd: true
        ),
    ]

    /// Scenarios that only test auto-end / VAD timing (no transcription API needed).
    static var silenceOnlyScenarios: [TestScenario] {
        scenarios.filter { $0.expectAutoEnd != nil }
    }

    /// Scenarios that require the transcription API (need login).
    static var transcriptionScenarios: [TestScenario] {
        scenarios.filter { $0.expectAutoEnd == nil }
    }

    // ── Entry point ──────────────────────────────────────────────────

    static func main() async {
        let args = CommandLine.arguments
        let silenceOnly = args.contains("--silence-only")
        let isLoggedIn = OpenAICodexAuth.isLoggedIn

        let activeScenarios: [TestScenario]
        if silenceOnly {
            activeScenarios = silenceOnlyScenarios
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("  SpeakFlow E2E — Silence / Auto-End Suite")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        } else if isLoggedIn {
            activeScenarios = scenarios
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("  SpeakFlow Live E2E — Full Suite")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        } else {
            // Not logged in — run silence-only scenarios automatically,
            // skip transcription ones (they need the API).
            activeScenarios = silenceOnlyScenarios
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("  SpeakFlow E2E — Silence / Auto-End Suite")
            print("  (not logged in — skipping transcription tests)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }

        guard !activeScenarios.isEmpty else {
            fail("No scenarios to run. Login for transcription tests or use --silence-only.")
        }

        // ── Generate fixtures ────────────────────────────────────────
        let fixturesDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpeakFlowE2E_\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixturesDir) }

        print("\n📦 Generating audio fixtures…")
        var fixtures: [AudioFixture] = []
        for (i, s) in activeScenarios.enumerated() {
            print("  [\(i+1)/\(activeScenarios.count)] \(s.name)")
            guard let f = generateFixture(segments: s.segments, rate: s.rate,
                                          fixturesDir: fixturesDir, index: i) else {
                fail("Fixture generation failed for: \(s.name)")
            }
            print("    → total: \(String(format: "%.1f", f.durationSeconds))s")
            fixtures.append(f)
        }

        // ── Run scenarios ────────────────────────────────────────────
        var passed = 0, failed = 0

        for (i, scenario) in activeScenarios.enumerated() {
            let fixture = fixtures[i]
            print("\n┌─────────────────────────────────────────────")
            print("│ [\(i+1)/\(activeScenarios.count)] \(scenario.name)")
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

        // Only use transcription API if logged in AND scenario needs it
        let needsTranscription = scenario.validateTranscript && OpenAICodexAuth.isLoggedIn

        let bridge = Transcription.shared.queueBridge
        if needsTranscription { await bridge.reset() }

        var chunksSubmitted = 0
        var transcriptParts: [String] = []

        // ── Auto-end tracking ────────────────────────────────────────
        var autoEndFired = false
        var autoEndTime: Date?

        if needsTranscription {
            bridge.onTextReady = { text in
                transcriptParts.append(text)
                let preview = text.count > 80 ? String(text.prefix(77)) + "…" : text
                print("    📝 chunk transcript: \(preview)")
            }
        }

        let recorder = StreamingRecorder()
        recorder.onChunkReady = { chunk in
            chunksSubmitted += 1
            let dur = String(format: "%.1f", chunk.durationSeconds)
            let sp  = String(format: "%.0f", chunk.speechProbability * 100)
            print("    🎤 chunk #\(chunksSubmitted): \(dur)s (\(sp)% speech)")
            if needsTranscription {
                Task { @MainActor in
                    let ticket = await bridge.nextSequence()
                    Transcription.shared.transcribe(ticket: ticket, chunk: chunk)
                }
            }
        }

        let recordingStartTime = Date()
        recorder.onAutoEnd = {
            autoEndFired = true
            autoEndTime = Date()
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(recordingStartTime))
            print("    🛑 AUTO-END fired at \(elapsed)s into recording")
            recorder.stop()
        }

        // Feed pre-recorded audio via mock input (no mic/speaker needed)
        await recorder.startMock(audioData: fixture.samples)

        if scenario.expectAutoEnd == true {
            // ── Wait for auto-end to fire ────────────────────────────
            // Give enough time: audio duration + generous margin for VAD + auto-end timer
            let maxWait = fixture.durationSeconds + 15.0
            print("    ⏱ Waiting up to \(String(format: "%.0f", maxWait))s for auto-end…")
            let deadline = Date().addingTimeInterval(maxWait)
            while !autoEndFired && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }

            if !autoEndFired {
                recorder.stop()
                return .fail("Auto-end did NOT fire within \(String(format: "%.0f", maxWait))s — expected it to trigger")
            }
            let elapsed = autoEndTime!.timeIntervalSince(recordingStartTime)
            print("    ✓ Auto-end fired at \(String(format: "%.1f", elapsed))s")
        } else {
            // ── Normal flow: feed audio + trailing wait, then stop ───
            let totalWait = fixture.durationSeconds + scenario.trailingSeconds
            print("    ⏱ Feeding \(String(format: "%.1f", fixture.durationSeconds))s + \(String(format: "%.0f", scenario.trailingSeconds))s trailing…")
            try? await Task.sleep(nanoseconds: UInt64(totalWait * 1_000_000_000))
            recorder.stop()

            // ── Validate auto-end did NOT fire (if expected) ─────────
            if scenario.expectAutoEnd == false && autoEndFired {
                let elapsed = autoEndTime.map { String(format: "%.1f", $0.timeIntervalSince(recordingStartTime)) } ?? "?"
                return .fail("Auto-end FIRED at \(elapsed)s — should NOT have triggered (silence was too short)")
            }
        }

        // Grace period for stop()'s async final-chunk Task to fire
        try? await Task.sleep(for: .seconds(2))

        if needsTranscription {
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
        if needsTranscription {
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
        }

        // ── Auto-end summary ─────────────────────────────────────────
        if let expected = scenario.expectAutoEnd {
            let status = autoEndFired ? "fired" : "did NOT fire"
            let symbol = (autoEndFired == expected) ? "✓" : "✗"
            print("    \(symbol) Auto-end: \(status) (expected: \(expected ? "fire" : "not fire"))")
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
