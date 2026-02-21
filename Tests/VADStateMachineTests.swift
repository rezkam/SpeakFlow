import Foundation
import Testing
@testable import SpeakFlowCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - VAD State Machine Tests — Deterministic Mock-Based
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// These tests use `MockVADBackend` to inject scripted `VADFrame` sequences into
// `VADProcessor`, bypassing Silero/FluidAudio entirely. This is the Swift
// Uses `MockVADBackend` injection to feed scripted frames to
// the real gate/smoothing/state-reset logic, bypassing Silero.

//
// **Why deterministic tests over integration tests with Silero:**
//
// 1. SPEED: These tests complete in ~5ms total (vs ~200ms for Silero startup).
//    No CoreML model loading, no Apple Silicon requirement.
//
// 2. ISOLATION: Each test exercises ONE specific behavior (gate, smoothing, drift).
//    Integration tests with real Silero conflate model quality with logic quality —
//    if Silero happens to return low probability on keyboard noise, the test passes
//    but NOT because the gate is working.
//
// 3. REPRODUCIBILITY: The same frame sequence always produces the same result.
//    Real Silero output varies with model version, hardware, and accumulated state.
//
// 4. REGRESSION POWER: `VADScenario.longSessionDrift()` encodes the EXACT condition
//    that triggered the Task 1 bug (post-5min drift). We cannot reproduce that with
//    a 3-second synthetic audio clip fed to real Silero.
//
// **What these tests DO NOT test:**
// - Whether Silero correctly identifies speech in real audio (that's Silero's job)
// - Whether FluidAudio's STARTING/STOPPING hysteresis fires at the right time
//   (that's FluidAudio's job, tested by `VADIntegrationTests.swift`)
// - Whether the full StreamingRecorder pipeline works end-to-end (LiveE2E)
//
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// MARK: - Helpers

/// Run all frames in a scenario through a VADProcessor with mock backend.
/// Returns (speechStarts, speechEnds, allResults).
@discardableResult
private func runScenario(
    _ frames: [VADFrame],
    config: VADConfiguration = .default
) async throws -> (starts: Int, ends: Int, results: [VADResult]) {
    let backend = MockVADBackend(frames)
    let vad = VADProcessor(config: config)
    await vad._testInjectBackend(backend)

    var starts = 0
    var ends = 0
    var results: [VADResult] = []

    for _ in frames {
        let r = try await vad.processChunk([Float](repeating: 0, count: 800))
        results.append(r)
        if let event = r.event {
            switch event {
            case .started: starts += 1
            case .ended:   ends += 1
            }
        }
    }

    return (starts, ends, results)
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Suite 1: Basic Event Firing
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("VAD State Machine — Basic Events")
struct VADBasicEventTests {

    /// Normal speech: must produce exactly one speechStart and one speechEnd.
    ///
    /// VADScenario.normalSpeech(): 40 silence + 60 speech + 40 silence = 7s.
    /// The mock provides isSpeaking=true during speech frames, so the gate
    /// (if volume passes) forwards the event.
    @Test func testNormalSpeechProducesStartAndEndEvents() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008  // speech frames have RMS=0.05 → passes gate
        )
        let (starts, ends, _) = try await runScenario(VADScenario.normalSpeech(), config: config)

        #expect(starts == 1, "Normal speech must produce exactly 1 speechStart (got \(starts))")
        #expect(ends == 1,   "Normal speech must produce exactly 1 speechEnd (got \(ends))")
    }

    /// Multiple speech bursts must produce one event pair per burst.
    @Test func testMultipleSpeechBurstsProduceMultipleEventPairs() async throws {
        let config = VADConfiguration(volumeGateEnabled: true, minVolumeForSpeech: 0.008)
        let (starts, ends, _) = try await runScenario(
            VADScenario.multipleSpeechBursts(), config: config)

        #expect(starts >= 2, "Multiple bursts must produce ≥2 speechStart events (got \(starts))")
        #expect(ends >= 2,   "Multiple bursts must produce ≥2 speechEnd events (got \(ends))")
    }

    /// Pure silence must produce zero speech events.
    @Test func testPureSilenceProducesNoEvents() async throws {
        let (starts, ends, _) = try await runScenario(VADScenario.puresilence(seconds: 5.0))

        #expect(starts == 0, "Silence must not produce speechStart events (got \(starts))")
        #expect(ends == 0,   "Silence must not produce speechEnd events (got \(ends))")
    }

    /// SpeechEnd must NOT fire before speechStart.
    /// Verifies that the state machine starts in the non-speaking state.
    @Test func testSpeechEndNeverFiresBeforeSpeechStart() async throws {
        let frames = VADScenario.normalSpeech()
        let backend = MockVADBackend(frames)
        let vad = VADProcessor(config: .default)
        await vad._testInjectBackend(backend)

        var firstEvent: SpeechEvent?
        for _ in frames {
            let r = try await vad.processChunk([Float](repeating: 0, count: 800))
            if let event = r.event, firstEvent == nil {
                firstEvent = event
            }
        }

        guard let first = firstEvent else {
            Issue.record("Expected at least one speech event")
            return
        }
        if case .ended = first {
            Issue.record("First event must be speechStart, not speechEnd")
        }
    }

    /// After a speechEnd, isSpeaking must return to false.
    @Test func testIsSpeakingReturnsFalseAfterEnd() async throws {
        let frames = VADScenario.normalSpeech()
        let backend = MockVADBackend(frames)
        let vad = VADProcessor(config: .default)
        await vad._testInjectBackend(backend)

        var lastResult: VADResult?
        for _ in frames {
            lastResult = try await vad.processChunk([Float](repeating: 0, count: 800))
        }

        // After the scenario ends (silence frames), must be not speaking
        #expect(await vad.isSpeaking == false,
                "After speech ends and silence follows, isSpeaking must be false")
        // The last result should also reflect non-speaking
        #expect(lastResult?.isSpeaking == false,
                "Last result in silence must have isSpeaking=false")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Suite 2: Volume Gate
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("VAD State Machine — Volume Gate")
struct VADVolumeGateTests {

    /// **Core Task 1 regression: keyboard clicks must NOT trigger speech.**
    ///
    /// VADScenario.keyboardTyping(): 40 silence + 20 keyboard clicks + 40 silence.
    /// Keyboard frames: prob=0.25, isSpeaking=false, rms=0.003.
    /// Gate threshold: minVolumeForSpeech=0.008.
    /// Smoothed RMS after 20 clicks: ≈0.003 (still below 0.008).
    ///
    /// This test encodes the exact bug that Task 1 was designed to fix:
    /// keyboard typing used to produce false speechStart events because the
    /// volume check was missing.
    @Test func testVolumeGateBlocksKeyboardClicks() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008
        )
        let (starts, _, _) = try await runScenario(VADScenario.keyboardTyping(), config: config)

        #expect(starts == 0,
                "Volume gate must block ALL keyboard clicks — got \(starts) false speechStart events")
    }

    /// Gate disabled must allow high-probability events through.
    ///
    /// This is the ONLY way to verify that `volumeGateEnabled=false` actually
    /// disables the gate (not silently broken). Uses `keyboardNoiseGateDisabled`
    /// which has prob=0.85 and isSpeaking=true — clearly above threshold.
    @Test func testDisabledGateAllowsHighProbEvents() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: false     // gate disabled!
        )
        let (starts, _, _) = try await runScenario(
            VADScenario.keyboardNoiseGateDisabled(), config: config)

        #expect(starts > 0,
                "With gate disabled, high-prob isSpeaking=true frames must produce speechStart events (got 0)")
    }

    /// With gate enabled AND high-prob keyboard noise, events must still be blocked.
    ///
    /// Contrast with the disabled-gate test: gate=ON, high prob, LOW rms → blocked.
    @Test func testEnabledGateBlocksHighProbLowVolumeNoise() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008    // rms=0.003 < 0.008 → blocked
        )
        // highProbNoise: prob=0.85, isSpeaking=true, rms=0.003
        let frames = Array(repeating: VADFrame.highProbNoise(), count: 30)
        let (starts, _, _) = try await runScenario(frames, config: config)

        #expect(starts == 0,
                "Even prob=0.85 must be blocked when smoothedVolume < minVolumeForSpeech (got \(starts))")
    }

    /// Real speech after keyboard typing must still produce speechStart.
    ///
    /// Verifies the gate doesn't permanently block speech once keyboard noise
    /// has been seen. The gate decision is per-frame, not session-level.
    @Test func testSpeechAfterKeyboardStillFiresEvents() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2
        )
        let (starts, ends, _) = try await runScenario(
            VADScenario.keyboardThenSpeech(), config: config)

        #expect(starts >= 1, "Real speech after keyboard noise must produce speechStart (got \(starts))")
        #expect(ends >= 1,   "Real speech after keyboard noise must produce speechEnd (got \(ends))")
    }

    /// Sustained quiet speech (RMS=0.015) must converge above the gate threshold.
    ///
    /// With smoothing factor=0.2, after 50 frames of RMS=0.015, smoothedVolume
    /// converges to 0.015 — well above minVolumeForSpeech=0.008. The gate opens.
    @Test func testSustainedQuietSpeechPassesGate() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2
        )
        let (starts, _, _) = try await runScenario(
            VADScenario.sustainedQuietSpeech(), config: config)

        #expect(starts >= 1, "Quiet speech (RMS=0.015 > gate=0.008) must produce speechStart after warmup")
    }

    /// SpeechEnd must NOT be suppressed by the volume gate.
    ///
    /// This is a critical correctness property: if we gated speechEnd, a session
    /// could get stuck in `isSpeaking=true` forever if volume drops.
    @Test func testVolumeGateDoesNotSuppressSpeechEnd() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.5     // absurdly high — would block most speech
        )
        // Scenario: user was speaking (isSpeaking=true from mock) then stops
        // Even though minVolumeForSpeech=0.5, the silence/end frames should still
        // allow the session to transition back to not-speaking.
        let frames =
            Array(repeating: VADFrame.speech(rms: 0.9), count: 20) +  // pass gate (rms=0.9 > 0.5)
            Array(repeating: VADFrame.silence(), count: 40)            // end, rms≈0

        let backend = MockVADBackend(frames)
        let vad = VADProcessor(config: config)
        await vad._testInjectBackend(backend)

        var hadSpeechStart = false
        for _ in frames {
            let r = try await vad.processChunk([Float](repeating: 0, count: 800))
            if let event = r.event, case .started = event { hadSpeechStart = true }
        }

        // After speech frames + silence, must NOT be speaking
        #expect(await vad.isSpeaking == false,
                "After speech ends, isSpeaking must be false — speechEnd cannot be gated")

        // If speechStart fired (speech rms=0.9 > 0.5 threshold), then speechEnd must also fire
        if hadSpeechStart {
            let (_, ends, _) = try await runScenario(frames, config: config)
            #expect(ends >= 1, "If speechStart fired, speechEnd must also fire")
        }
    }

    /// Noisy dictation: keyboard between sentences must produce events only during speech.
    @Test func testNoisyDictationProducesCorrectEventCount() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2
        )
        let (starts, ends, _) = try await runScenario(VADScenario.noisyDictation(), config: config)

        #expect(starts >= 2, "Noisy dictation (2 speech segments) must have ≥2 speechStart events")
        #expect(ends >= 2,   "Noisy dictation (2 speech segments) must have ≥2 speechEnd events")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Suite 3: Exponential Smoothing
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("VAD State Machine — Volume Smoothing")
struct VADVolumeSmoothingTests {

    /// Smoothed volume must start at 0 and increase towards the true RMS
    /// on sustained loud input.
    @Test func testSmoothedVolumeConvergesOnSustainedSpeech() async throws {
        let config = VADConfiguration(volumeGateEnabled: false, volumeSmoothingFactor: 0.2)
        let backend = MockVADBackend(repeating: .speech(rms: 0.08), count: 60)
        let vad = VADProcessor(config: config)
        await vad._testInjectBackend(backend)

        for _ in 0..<60 {
            _ = try await vad.processChunk([Float](repeating: 0, count: 800))
        }

        // After 60 frames of RMS=0.08, smoothedVolume should be ≥ 0.07
        let smoothed = await vad.currentSmoothedVolume
        #expect(smoothed > 0.07,
                "After 60 frames of RMS=0.08, smoothedVolume should converge (got \(smoothed))")
    }

    /// After a single transient spike, smoothedVolume must decay quickly.
    ///
    /// Spike frame: instantRMS=0.08 → smoothedVolume ≈ 0.016 (20% of spike)
    /// After 5 more silence frames: smoothed decays to ≈ 0.016 * 0.8^5 ≈ 0.005
    @Test func testSmoothedVolumeDecaysAfterTransientSpike() async throws {
        let config = VADConfiguration(volumeGateEnabled: false, volumeSmoothingFactor: 0.2)
        let frames = VADScenario.singleTransientSpike()

        let backend = MockVADBackend(frames)
        let vad = VADProcessor(config: config)
        await vad._testInjectBackend(backend)

        var peakSmoothed: Float = 0
        var finalSmoothed: Float = 0
        for (i, _) in frames.enumerated() {
            let r = try await vad.processChunk([Float](repeating: 0, count: 800))
            // Peak is right after the spike (frame index 20)
            if i == 21 { peakSmoothed = r.smoothedVolume }
            finalSmoothed = r.smoothedVolume
        }

        // Peak after spike should be ~0.016 (20% of 0.08)
        #expect(peakSmoothed > 0.010,
                "Spike of RMS=0.08 must produce smoothed peak > 0.010 (got \(peakSmoothed))")
        #expect(peakSmoothed < 0.025,
                "Spike peak must not exceed 0.025 — smoothing must dampen it (got \(peakSmoothed))")

        // Final value after 20 more silence frames should be near 0
        #expect(finalSmoothed < 0.002,
                "Smoothed volume must decay near 0 after spike + 20 silence frames (got \(finalSmoothed))")
    }

    /// VADResult.smoothedVolume must match actor's currentSmoothedVolume at every frame.
    @Test func testResultSmoothedVolumeMatchesActorState() async throws {
        let config = VADConfiguration(volumeSmoothingFactor: 0.2)
        let frames = VADScenario.normalSpeech()
        let backend = MockVADBackend(frames)
        let vad = VADProcessor(config: config)
        await vad._testInjectBackend(backend)

        for _ in frames {
            let result = try await vad.processChunk([Float](repeating: 0, count: 800))
            // currentSmoothedVolume is actor-isolated — use _testSmoothedVolume (sync)
            // to avoid re-entering the actor in the same turn
            let actorVolume = await vad._testSmoothedVolume

            #expect(abs(result.smoothedVolume - actorVolume) < 0.0001,
                    "VADResult.smoothedVolume and actor smoothedVolume must be identical")
        }
    }

    /// Smoothing factor 0.0 means no change — volume is frozen at initial value (0).
    @Test func testSmoothingFactorZeroMeansNoChange() async throws {
        let config = VADConfiguration(volumeGateEnabled: false, volumeSmoothingFactor: 0.0)
        let frames = Array(repeating: VADFrame.speech(rms: 0.5), count: 20)
        let backend = MockVADBackend(frames)
        let vad = VADProcessor(config: config)
        await vad._testInjectBackend(backend)

        for _ in frames {
            _ = try await vad.processChunk([Float](repeating: 0, count: 800))
        }

        let smoothed = await vad._testSmoothedVolume
        #expect(smoothed == 0,
                "Factor=0.0: volume frozen at 0 (got \(smoothed))")
    }

    /// Smoothing factor 1.0 means instant convergence to current RMS.
    @Test func testSmoothingFactorOneIsInstant() async throws {
        let config = VADConfiguration(volumeGateEnabled: false, volumeSmoothingFactor: 1.0)
        let oneFrame = [VADFrame.speech(rms: 0.07)]
        let backend = MockVADBackend(oneFrame)
        let vad = VADProcessor(config: config)
        await vad._testInjectBackend(backend)

        let result = try await vad.processChunk([Float](repeating: 0, count: 800))

        #expect(abs(result.smoothedVolume - 0.07) < 0.0001,
                "Factor=1.0 means instant tracking — smoothedVolume must equal RMS immediately")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Suite 4: Long Session Drift (State Reset)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// IMPORTANT NOTE on mock testing of state reset:
//
// In the REAL Silero path, `stateResetInterval` prevents LSTM drift by calling
// `manager.makeStreamState()` periodically. With the mock backend, there is no
// LSTM — the mock injects probabilities directly. So the state reset doesn't
// "fix" the drift frames in mock mode.
//
// Instead, the volume gate (Feature 3) handles the drift frames: they have
// rms=0.003 < minVolumeForSpeech=0.008, so the gate blocks them.
//
// These tests verify that drift-level probability + low volume → no speech events.
// That's the COMBINED protection: state reset (real Silero) + volume gate (both).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("VAD State Machine — Long Session Drift Protection")
struct VADLongSessionDriftTests {

    /// **The Task 1 regression: post-5min drift frames must not produce speech events.**
    ///
    /// VADScenario.longSessionDrift():
    ///   5990 silence frames (prob=0.02, rms=0.0005) +
    ///   10 drift frames (prob=0.18, isSpeaking=false, rms=0.003)
    ///
    /// The drift frames have prob above threshold (0.18 > 0.15) but:
    ///   1. isSpeaking=false (FluidAudio hasn't committed to SPEAKING)
    ///   2. rms=0.003 < minVolumeForSpeech=0.008 → volume gate blocks
    ///
    /// Expected: Zero speech events despite 5990+10 frames.
    ///
    /// This test runs quickly (~30ms) because the mock backend never loads Silero.
    @Test func testLongSessionDriftFramesProduceNoEvents() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            stateResetInterval: 5.0
        )
        let (starts, ends, _) = try await runScenario(
            VADScenario.longSessionDrift(), config: config)

        #expect(starts == 0,
                "Drift frames (prob=0.18, rms=0.003) must not produce speechStart events (got \(starts))")
        #expect(ends == 0,
                "No speech start means no speech end either (got \(ends))")
    }

    /// Shorter version of the drift test (30s equivalent). Same logic, faster.
    @Test func testShortSessionDriftFramesProduceNoEvents() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008
        )
        let (starts, _, _) = try await runScenario(VADScenario.shortSessionDrift(), config: config)

        #expect(starts == 0,
                "Short session drift (prob=0.18, rms=0.003) must not produce speechStart (got \(starts))")
    }

    /// Without the volume gate, drift frames WOULD produce false speech events.
    ///
    /// This is the "what went wrong before Task 1" test. With gate OFF and
    /// high-prob drift frames (isSpeaking=true in this scenario), events fire.
    ///
    /// This test DOCUMENTS the pre-fix behavior to make the regression visible.
    @Test func testWithoutVolumeGateDriftFramesProduceEvents() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: false  // gate disabled → old behavior
        )
        // Use frames that would drift above threshold AND commit to isSpeaking=true
        // (the real LSTM would commit after minSpeechDuration; here we script it directly)
        let driftFrames = Array(repeating: VADFrame(
            probability: 0.18,
            isSpeaking: true,   // committed — would happen after sustained drift
            instantRMS: 0.003
        ), count: 20)

        let (starts, _, _) = try await runScenario(driftFrames, config: config)

        #expect(starts > 0,
                "Without volume gate, drift frames with isSpeaking=true fire events (pre-Task-1 bug, got \(starts))")
    }

    /// Ambient noise over 30s must produce zero events with the gate enabled.
    @Test func testAmbientNoiseProducesNoEvents() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008
        )
        let (starts, _, _) = try await runScenario(
            VADScenario.ambientNoise(seconds: 30.0), config: config)

        #expect(starts == 0,
                "30s of ambient noise (rms=0.002) must produce zero speech events (got \(starts))")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Suite 5: Volume Gate Boundary Conditions
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("VAD State Machine — Gate Boundary Conditions")
struct VADGateBoundaryTests {

    /// At exactly the gate threshold, speech must NOT be suppressed.
    ///
    /// Gate condition: `smoothedVolume < minVolumeForSpeech`
    /// So at exactly minVolumeForSpeech (equal, not less than), gate OPENS.
    @Test func testVolumeExactlyAtThresholdOpensGate() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2
        )
        // Warm up smoothedVolume to exactly the threshold, then emit speech
        let (starts, _, _) = try await runScenario(
            VADScenario.volumeAtGateThreshold(), config: config)

        #expect(starts >= 1,
                "Speech at exactly the gate threshold (smoothed == 0.008) must produce speechStart")
    }

    /// Just below the gate threshold — speech must be suppressed.
    @Test func testVolumeJustBelowThresholdBlocksSpeech() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2
        )
        // sustainedQuietSpeech uses RMS just below threshold — converges below gate
        let frames = VADScenario.volumeJustBelowGateThreshold()
        let (starts, _, _) = try await runScenario(frames, config: config)

        #expect(starts == 0,
                "Speech with smoothed volume just below threshold must be blocked by gate")
    }

    /// Gate with minVolumeForSpeech=0.0 must let everything through.
    ///
    /// Setting the threshold to zero makes the gate effectively disabled
    /// (every RMS ≥ 0.0).
    @Test func testZeroThresholdAlwaysOpenGate() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.0     // zero threshold — always open
        )
        // Even keyboard noise (rms=0.003) should pass when threshold=0
        let frames = Array(repeating: VADFrame(
            probability: 0.9, isSpeaking: true, instantRMS: 0.001), count: 20)
        let (starts, _, _) = try await runScenario(frames, config: config)

        #expect(starts >= 1,
                "With minVolumeForSpeech=0.0, even very quiet speech must pass gate")
    }

    /// resetSession() must zero smoothedVolume so old session volume doesn't
    /// "pre-open" the gate for the new session.
    @Test func testResetSessionClearsSmoothedVolumeForGate() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2
        )
        let vad = VADProcessor(config: config)
        let loudFrames = MockVADBackend(repeating: .speech(rms: 0.1), count: 50)
        await vad._testInjectBackend(loudFrames)

        // Session 1: build up high smoothedVolume
        for _ in 0..<50 {
            _ = try await vad.processChunk([Float](repeating: 0, count: 800))
        }
        let volumeAfterSession1 = await vad.currentSmoothedVolume
        #expect(volumeAfterSession1 > 0.05, "Sanity: session 1 built up volume")

        // Reset session
        await vad.resetSession()

        let volumeAfterReset = await vad.currentSmoothedVolume
        #expect(volumeAfterReset == 0,
                "resetSession() must clear smoothedVolume to 0 (got \(volumeAfterReset))")

        // Session 2: quiet keyboard noise — must be blocked (not inheriting session 1 volume)
        let quietFrames = MockVADBackend(repeating: .keyboardClick(), count: 10)
        await vad._testInjectBackend(quietFrames)
        var starts = 0
        for _ in 0..<10 {
            let r = try await vad.processChunk([Float](repeating: 0, count: 800))
            if let e = r.event, case .started = e { starts += 1 }
        }
        #expect(starts == 0,
                "After reset, keyboard noise must be blocked (not inheriting session 1's high volume)")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Suite 6: Mock Backend Mechanics
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("VAD State Machine — MockVADBackend Mechanics")
struct MockVADBackendMechanicsTests {

    /// Mock backend must consume frames in order.
    @Test func testFramesConsumedInOrder() async throws {
        let frames: [VADFrame] = [
            .silence(0.01), .silence(0.05), .speech(0.9), .silence(0.02)
        ]
        let backend = MockVADBackend(frames)

        // Consume sequentially
        #expect(await backend.callCount == 0)

        let f0 = await backend.next()
        #expect(f0.probability == 0.01)
        #expect(await backend.callCount == 1)

        let f1 = await backend.next()
        #expect(f1.probability == 0.05)

        let f2 = await backend.next()
        #expect(f2.probability == 0.9)
        #expect(f2.isSpeaking == true)

        let f3 = await backend.next()
        #expect(f3.probability == 0.02)

        // Exhausted — falls back to silence
        let f4 = await backend.next()
        #expect(f4.probability == 0.02,
                "Exhausted backend must return default silence probability")
        #expect(await backend.callCount == 5)
    }

    /// Backend `reset()` must restart from the beginning.
    @Test func testResetRestartFromBeginning() async throws {
        let frames: [VADFrame] = [.speech(0.9), .silence(0.02)]
        let backend = MockVADBackend(frames)

        // Consume both
        _ = await backend.next()
        _ = await backend.next()
        #expect(await backend.isExhausted)

        // Reset
        await backend.reset()
        #expect(await backend.callCount == 0)
        #expect(await backend.framesRemaining == 2)

        // First frame again
        let f = await backend.next()
        #expect(f.probability == 0.9, "After reset, first frame must be re-consumed")
    }

    /// `framesRemaining` must decrease as frames are consumed.
    @Test func testFramesRemainingDecreases() async throws {
        let backend = MockVADBackend(repeating: .silence(), count: 5)

        #expect(await backend.framesRemaining == 5)
        _ = await backend.next()
        #expect(await backend.framesRemaining == 4)
        _ = await backend.next()
        _ = await backend.next()
        #expect(await backend.framesRemaining == 2)
    }

    /// `isExhausted` must be true after all frames consumed.
    @Test func testIsExhaustedAfterAllFramesConsumed() async throws {
        let backend = MockVADBackend(repeating: .silence(), count: 3)
        #expect(await backend.isExhausted == false)

        for _ in 0..<3 { _ = await backend.next() }
        #expect(await backend.isExhausted == true)
    }

    /// processChunk() must skip Silero when mock backend is injected,
    /// even WITHOUT calling initialize() first. This is the key benefit:
    /// no CoreML loading needed in tests.
    @Test func testProcessChunkWorksWithoutInitialize() async throws {
        let backend = MockVADBackend(repeating: .silence(), count: 5)
        let vad = VADProcessor(config: .default)
        await vad._testInjectBackend(backend)

        // Must NOT throw (would throw VADError.notInitialized without the mock)
        let result = try await vad.processChunk([Float](repeating: 0, count: 800))

        #expect(result.probability >= 0,
                "processChunk with mock backend must succeed without initialize()")
        #expect(result.processingTimeMs == 0,
                "Mock backend must report 0ms processing time (no real inference)")
    }

    /// Removing the mock backend restores the real Silero path.
    /// (Only verifiable by checking that notInitialized is thrown without the model.)
    @Test func testRemovingMockRestoresSileroPaths() async throws {
        let backend = MockVADBackend(repeating: .silence(), count: 1)
        let vad = VADProcessor(config: .default)

        // Inject mock — works without initialize()
        await vad._testInjectBackend(backend)
        _ = try await vad.processChunk([Float](repeating: 0, count: 800))

        // Remove mock — now real Silero path is used
        await vad._testInjectBackend(nil)

        // Without initialize(), must throw notInitialized
        do {
            _ = try await vad.processChunk([Float](repeating: 0, count: 800))
            Issue.record("Should have thrown VADError.notInitialized after removing mock")
        } catch VADError.notInitialized {
            // Expected — the real path requires initialization
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}
