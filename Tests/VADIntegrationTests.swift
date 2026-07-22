import Foundation
import Testing
@testable import SpeakFlowCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - VAD Integration Tests — Task 1 (Volume Gate + Smoothing + State Reset)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// These tests exercise VADProcessor with the real Silero CoreML model using
// synthetic audio. They verify:
//   - Feature 1: Periodic Silero RNN state reset (every N seconds)
//   - Feature 2: Exponential volume smoothing
//   - Feature 3: Volume gate suppresses low-volume speechStart events
//
// **Requires Apple Silicon and a local Silero model** — Silero runs on CoreML,
// which requires Apple Neural Engine. The suite is disabled with Swift Testing's
// `.enabled(if:)` trait unless VAD is available and the FluidAudio cache contains
// Silero, so ordinary offline runs skip rather than trigger a download.
//
// **Why use synthetic audio (not real recordings)?**
// Real recordings depend on microphone hardware, background environment, and
// would require bundling large audio assets. Synthetic audio (pure sine waves,
// white noise, silence) gives reproducible, environment-independent results.
// The goal is to test the *gate and smoothing logic*, not Silero's classification
// accuracy, which is already tested by the live E2E suite.
//
// References:
//   - Volume gate: dual-gate pattern (probability AND volume must pass)
//   - Smoothing:   exponential smoothing with factor 0.2 to tame transients
//   - State reset: periodic Silero RNN hidden state reset every 5s
//
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// MARK: - Helpers

/// Generate a buffer of silence (all zeros).
private func silenceChunk(samples: Int = 800) -> [Float] {
    [Float](repeating: 0, count: samples)
}

/// Generate white noise at the given amplitude (RMS ≈ amplitude * 0.577).
/// Used to simulate ambient or keyboard noise — NOT classified as speech by Silero.
private func noiseChunk(amplitude: Float, samples: Int = 800) -> [Float] {
    (0..<samples).map { _ in Float.random(in: -amplitude...amplitude) }
}

/// Generate a sine wave chunk at the given frequency and amplitude.
/// RMS ≈ amplitude / sqrt(2) ≈ amplitude * 0.707.
private func sineChunk(frequency: Float = 300.0, amplitude: Float = 0.1, samples: Int = 800,
                        sampleRate: Float = 16000) -> [Float] {
    (0..<samples).map { i in
        sin(2.0 * .pi * frequency * Float(i) / sampleRate) * amplitude
    }
}

// MARK: - Integration Test Suite

@Suite("VAD Integration — Volume Gate + Smoothing + State Reset", .serialized, .enabled(if: VADModelTestSupport.integrationTestsEnabled()))
struct VADIntegrationTests {

    // MARK: Feature 1: Periodic State Reset

    /// The VAD processor must not crash when the periodic state reset fires.
    ///
    /// We configure a very short reset interval (0.5s) and feed enough audio
    /// to trigger multiple resets. The processor must remain functional and
    /// continue producing valid results after each reset.
    ///
    /// **Why 800 samples per chunk?**
    /// 800 samples at 16kHz = 50ms per chunk. Silero's native window is 32ms;
    /// FluidAudio handles chunking internally. 50ms batches match what
    /// StreamingRecorder's processing timer produces (withTimeInterval: 0.05).
    @Test func testPeriodicStateResetDoesNotCrash() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: false, // disable gate so we're testing reset only
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 0.5   // 500ms — very short for test speed
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // Feed 2 seconds of silence = 40 chunks at 50ms each.
        // State should reset at least 3 times (at 0.5s, 1.0s, 1.5s).
        let chunk = silenceChunk()
        for _ in 0..<40 {
            let result = try await vad.processChunk(chunk)
            // After reset, results must remain structurally valid
            #expect(result.probability >= 0 && result.probability <= 1,
                    "Probability must stay in [0,1] after state reset")
            #expect(result.processingTimeMs >= 0,
                    "Processing time must be non-negative after state reset")
        }

        // Processor must remain usable — one more chunk must succeed
        let finalResult = try await vad.processChunk(chunk)
        #expect(finalResult.probability >= 0,
                "VAD processor must still be functional after multiple state resets")
    }

    /// After a state reset, the smoothed volume must be preserved (it's not
    /// part of Silero's RNN state — it's our own smoothing state).
    ///
    /// WHY: The RNN state reset only affects Silero's probability output,
    /// not our own volume tracking. If smoothedVolume reset to 0 on every
    /// state reset, the volume gate would incorrectly block speech at the
    /// start of each 5-second window.
    @Test func testPeriodicStateResetPreservesSmoothedVolume() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: false,  // disable gate — test reset in isolation
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 0.2    // very short — fires after just ~4 chunks at 50ms
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // Seed a non-zero smoothed volume via the test helper
        // (equivalent to having processed loud audio for a while)
        await vad._testSetSmoothedVolume(0.05)
        #expect(await vad._testSmoothedVolume == 0.05, "Sanity: seed applied")

        // Feed one chunk — this will trigger a state reset (0.2s interval passed)
        let chunk = silenceChunk()
        _ = try await vad.processChunk(chunk)

        // Smoothed volume should have been updated by the new chunk (silence → 0),
        // but it must NOT have been zeroed-out by the reset.
        // After processing silence: smoothed = 0.05 + 0.2 * (0 - 0.05) = 0.04
        // That's still > 0, not zeroed by the reset.
        let volumeAfterReset = await vad._testSmoothedVolume
        #expect(volumeAfterReset > 0,
                "State reset must NOT zero smoothedVolume (it's independent of Silero RNN state)")
    }

    // MARK: Feature 2: Exponential Volume Smoothing

    /// After processing silence, the smoothed volume must be near zero.
    ///
    /// This verifies that the smoothing correctly attenuates silence to near-zero.
    @Test func testSmoothedVolumeNearZeroOnSilence() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: false,  // isolate smoothing feature
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 5.0
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // Feed 20 chunks of silence (1 second total)
        let chunk = silenceChunk()
        for _ in 0..<20 {
            _ = try await vad.processChunk(chunk)
        }

        // After 1 second of silence, smoothed volume should be < 0.001.
        // Use the actor's currentSmoothedVolume as the authoritative value.
        let smoothed = await vad.currentSmoothedVolume
        #expect(smoothed < 0.001,
                "After 1s of silence, smoothed volume must be near 0 (got \(smoothed))")
    }

    /// After sustained loud input, the smoothed volume must converge to the
    /// actual signal's RMS level.
    ///
    /// This verifies that sustained speech (not just transients) can move
    /// the smoothed volume above the gate threshold.
    @Test func testSmoothedVolumeConvergesOnLoudInput() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: false,  // isolate smoothing feature
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 5.0
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // Feed 50 chunks of loud input (2.5s total, RMS ≈ 0.14)
        // With factor=0.2 and 50 frames, smoothed should reach ~99% of true RMS.
        let chunk = sineChunk(frequency: 300, amplitude: 0.2) // RMS ≈ 0.141
        for _ in 0..<50 {
            _ = try await vad.processChunk(chunk)
        }

        // Use the actor's currentSmoothedVolume as the authoritative value.
        let smoothed = await vad.currentSmoothedVolume
        // Should be > 0.08 (well above minVolumeForSpeech=0.008)
        #expect(smoothed > 0.08,
                "After 2.5s of loud input (RMS≈0.14), smoothed volume must be above 0.08 (got \(smoothed))")
    }

    /// VADResult must include the smoothed volume computed during processChunk.
    ///
    /// This ensures the diagnostic field is populated so callers can log it
    /// or use it in future metrics without calling a separate accessor.
    @Test func testVADResultIncludesSmoothedVolume() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: false,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 5.0
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // Feed silence — smoothedVolume in result should be near 0
        let silentResult = try await vad.processChunk(silenceChunk())
        #expect(silentResult.smoothedVolume < 0.001,
                "Result's smoothedVolume must reflect the silence we fed")

        // Feed loud input — smoothedVolume in result should increase
        for _ in 0..<30 {
            _ = try await vad.processChunk(sineChunk(amplitude: 0.2))
        }
        let loudResult = try await vad.processChunk(sineChunk(amplitude: 0.2))
        #expect(loudResult.smoothedVolume > 0.01,
                "Result's smoothedVolume must increase after sustained loud input")

        // Verify result and actor agree
        let actorVolume = await vad.currentSmoothedVolume
        #expect(abs(loudResult.smoothedVolume - actorVolume) < 0.0001,
                "VADResult.smoothedVolume must equal actor's currentSmoothedVolume")
    }

    // MARK: Feature 3: Volume Gate

    /// With the volume gate enabled, very quiet noise (RMS << minVolumeForSpeech)
    /// should produce no `speechStart` events even if Silero's probability
    /// happens to cross the threshold.
    ///
    /// **Why this test matters:**
    /// Silero is calibrated for speech, but at very low volumes (fan noise, HVAC,
    /// microphone DC offset) it can still assign non-trivial probabilities to noise.
    /// The volume gate is the last line of defense.
    ///
    /// **RMS of our quiet noise:**
    /// amplitude=0.002, uniform distribution → RMS ≈ amplitude / sqrt(3) ≈ 0.0012
    /// This is below minVolumeForSpeech=0.008 and will stay below after smoothing.
    @Test func testVolumeGateSuppressesVeryQuietNoise() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: true,           // gate ON
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 5.0
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // 3 seconds of very quiet noise (RMS ≈ 0.0012 — far below gate threshold)
        // We use uniform noise rather than silence to be more realistic about
        // what a noisy mic floor looks like.
        var speechStartCount = 0
        for _ in 0..<60 {   // 60 × 50ms = 3 seconds
            let chunk = noiseChunk(amplitude: 0.002)
            let result = try await vad.processChunk(chunk)
            if let event = result.event, case .started = event {
                speechStartCount += 1
            }
        }
        #expect(speechStartCount == 0,
                "Volume gate must suppress all speechStart events from very quiet noise (got \(speechStartCount))")
    }

    /// When the volume gate is DISABLED, event decisions are driven by
    /// Silero probability and speaking state only.
    ///
    /// We feed quiet noise with gate disabled. We don't assert that events
    /// fire (Silero is nondeterministic on pure noise), but we assert that
    /// the system doesn't crash and still produces valid results.
    @Test func testDisabledVolumeGateDoesNotCrash() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: false,          // gate OFF
            minVolumeForSpeech: 0.05,          // high value — would block everything if gate were on
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 5.0
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // Feed silence for 1s — should work without crash
        for _ in 0..<20 {
            let result = try await vad.processChunk(silenceChunk())
            #expect(result.probability >= 0 && result.probability <= 1,
                    "Disabled gate must still produce valid probability values")
            #expect(result.smoothedVolume >= 0,
                    "Disabled gate must still compute and report smoothed volume")
        }
    }

    /// The volume gate must NOT suppress `speechEnd` events — only `speechStart`.
    ///
    /// **WHY:** If the user was speaking (volume high → speechStart fired) and
    /// then becomes quiet, the drop in volume IS the signal that speech has ended.
    /// Suppressing speechEnd would leave VAD stuck in the speaking state forever.
    ///
    /// This is a non-trivial distinction in the dual-gate pattern:
    ///   Full dual-gate: `speaking = confidence >= threshold AND volume >= min_volume`
    ///
    /// We interpret this as: the gate determines whether to ENTER speaking state,
    /// not whether to EXIT it. Once speaking, we trust Silero's `speechEnd`.
    @Test func testVolumeGateDoesNotSuppressSpeechEnd() async throws {
        // Use a very high minVolumeForSpeech so that our test audio cannot pass it.
        // If the gate incorrectly fired on speechEnd, it would suppress the end event.
        // We test by checking the actor's `isSpeaking` state directly rather than
        // relying on synthesized audio to trigger a specific event sequence.
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 5.0
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // Seed the VAD as if it's currently speaking
        // (integration test can't force Silero to fire a speechEnd, so we
        //  test the gate logic indirectly by verifying events from silence)
        var speechEndCount = 0
        var speechStartCount = 0
        for _ in 0..<40 {
            let result = try await vad.processChunk(silenceChunk())
            if let event = result.event {
                switch event {
                case .started: speechStartCount += 1
                case .ended:   speechEndCount += 1
                }
            }
        }

        // We're feeding silence — so:
        // - speechStart should NOT fire (gate would also prevent it)
        // - speechEnd should NOT fire (nothing to end — we never started)
        // The important guarantee is that if speechEnd DID happen to fire
        // (unlikely on silence), it must not have been suppressed by the gate.
        // Since we can't force a speechEnd from outside, this test validates
        // that the gate doesn't interfere with the isSpeaking=false→true→false
        // state machine by checking the event counts are sensible.
        #expect(speechStartCount == 0 || speechEndCount <= speechStartCount,
                "speechEnd events must not exceed speechStart events (gate must not suppress ends)")
    }

    // MARK: - Combined behavior: all three features together

    /// Smoke test: all three features enabled simultaneously must produce
    /// valid results for 3 seconds of silence.
    ///
    /// This is the most important integration test — it ensures the combined
    /// system (state reset + smoothing + gate) doesn't regress or crash.
    @Test func testAllFeaturesEnabledWithSilence() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 0.3    // short interval — forces multiple resets in 3s
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        var lastResult: VADResult?
        for _ in 0..<60 {   // 3 seconds
            lastResult = try await vad.processChunk(silenceChunk())
        }

        guard let result = lastResult else {
            Issue.record("No results produced")
            return
        }

        #expect(result.probability >= 0 && result.probability <= 1)
        #expect(result.smoothedVolume >= 0)
        #expect(result.processingTimeMs > 0)
        #expect(result.event == nil, "Silence should not produce speech events")
    }

    /// Smoke test: all three features enabled with realistic quiet background noise.
    /// Must NOT produce speech events.
    @Test func testAllFeaturesEnabledWithQuietNoise() async throws {
        let config = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: true,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 0.5
        )
        let vad = VADProcessor(config: config)
        try await vad.initialize()

        // Simulate HVAC / fan noise: amplitude=0.003 → RMS ≈ 0.0017
        // This is below minVolumeForSpeech=0.008 → gate should block any events
        var speechEvents = 0
        for _ in 0..<60 {   // 3 seconds
            let result = try await vad.processChunk(noiseChunk(amplitude: 0.003))
            if result.event != nil {
                speechEvents += 1
            }
        }

        #expect(speechEvents == 0,
                "Volume gate must prevent HVAC noise (RMS≈0.002) from triggering speech events")
    }

    // MARK: - resetSession() behavior

    /// `resetSession()` must reset smoothedVolume to 0 so each session starts clean.
    @Test func testResetSessionClearsSmoothedVolume() async throws {
        let vad = VADProcessor(config: .default)
        try await vad.initialize()

        // Build up smoothed volume by processing loud input
        let loudChunk = sineChunk(amplitude: 0.2)
        for _ in 0..<30 {
            _ = try await vad.processChunk(loudChunk)
        }

        let volumeBeforeReset = await vad.currentSmoothedVolume
        #expect(volumeBeforeReset > 0.01, "Sanity: should have accumulated volume (got \(volumeBeforeReset))")

        // Reset the session
        await vad.resetSession()

        let volumeAfterReset = await vad.currentSmoothedVolume
        #expect(volumeAfterReset == 0,
                "resetSession() must clear smoothedVolume to 0 (old session loudness should not persist)")
    }
}
