import Foundation
import Testing
@testable import SpeakFlowCore


// MARK: - Platform Support Tests

struct PlatformSupportTests {
    @Test func testSupportsVAD() {
        #expect(PlatformSupport.supportsVAD == PlatformSupport.isAppleSilicon)
    }

    @Test func testDescription() {
        #expect(!PlatformSupport.platformDescription.isEmpty)
    }

    @Test func testVadUnavailableReason() {
        if PlatformSupport.isAppleSilicon {
            #expect(PlatformSupport.vadUnavailableReason == nil)
        } else {
            #expect(PlatformSupport.vadUnavailableReason != nil)
        }
    }
}

// MARK: - VAD Configuration Tests

struct VADConfigurationTests {
    @Test func testDefaults() {
        let c = VADConfiguration()
        #expect(c.threshold == 0.5)
        #expect(c.minSilenceAfterSpeech == 1.0)
        #expect(c.minSpeechDuration == 0.25)
        #expect(c.enabled == true)
    }

    @Test func testSensitive() {
        #expect(VADConfiguration.sensitive.threshold == 0.3)
    }

    @Test func testStrict() {
        #expect(VADConfiguration.strict.threshold == 0.7)
    }

    // ── Task 1 additions: volume gate + smoothing + state reset defaults ──

    /// Volume gate defaults: enabled=true, minVolume=0.008.
    ///
    /// Why 0.008? Empirically: keyboard noise RMS ≈ 0.002–0.005,
    /// quiet speech RMS ≈ 0.01–0.03. 0.008 sits exactly in the gap.
    @Test func testVolumeGateDefaults() {
        let c = VADConfiguration()
        #expect(c.volumeGateEnabled == true,
                "Volume gate must be enabled by default — prevents keyboard/fan noise from triggering speech")
        #expect(c.minVolumeForSpeech == 0.008,
                "Default 0.008 sits between keyboard noise (0.002–0.005) and quiet speech (0.01–0.03)")
    }

    /// Exponential smoothing defaults: factor=0.2 (tames transient spikes).
    @Test func testVolumeSmoothingDefault() {
        let c = VADConfiguration()
        #expect(c.volumeSmoothingFactor == 0.2,
                "Smoothing factor 0.2 tames transient volume spikes")
    }

    /// Periodic state reset interval: 5.0s (prevents LSTM drift in long sessions).
    @Test func testStateResetIntervalDefault() {
        let c = VADConfiguration()
        #expect(c.stateResetInterval == 5.0,
                "5.0s prevents Silero LSTM drift in long sessions")
    }

    /// Preset `.default` passes through to VADProcessor's init.
    @Test func testDefaultPresetHasNewFields() {
        let c = VADConfiguration.default
        #expect(c.volumeGateEnabled == true)
        #expect(c.minVolumeForSpeech == 0.008)
        #expect(c.volumeSmoothingFactor == 0.2)
        #expect(c.stateResetInterval == 5.0)
    }

    /// Volume gate can be disabled for environments where the user needs
    /// maximum sensitivity (e.g., very quiet dictation in a padded studio).
    @Test func testVolumeGateCanBeDisabled() {
        let c = VADConfiguration(
            threshold: 0.15,
            minSilenceAfterSpeech: 3.0,
            minSpeechDuration: 0.25,
            enabled: true,
            volumeGateEnabled: false,
            minVolumeForSpeech: 0.008,
            volumeSmoothingFactor: 0.2,
            stateResetInterval: 5.0
        )
        #expect(c.volumeGateEnabled == false)
    }
}

// MARK: - VAD Processor Tests

struct VADProcessorTests {
    @Test func testIsAvailable() {
        #expect(VADProcessor.isAvailable == PlatformSupport.supportsVAD)
    }

    @Test func testInitialState() async {
        let p = VADProcessor()
        #expect(await p.isSpeaking == false)
        #expect(await p.lastSpeechEndTime == nil)
        #expect(await p.lastSpeechStartTime == nil)
    }

    @Test func testResetSession() async {
        let p = VADProcessor()
        await p.resetSession()
        #expect(await p.isSpeaking == false)
        #expect(await p.averageSpeechProbability == 0)
    }

    @Test func testAverageSpeechProbability() async {
        let p = VADProcessor()
        // Before processing, should be 0
        #expect(await p.averageSpeechProbability == 0)
    }

    @Test func testHasSignificantSpeech() async {
        let p = VADProcessor()
        // Before processing, should have no significant speech
        #expect(await p.hasSignificantSpeech() == false)
    }

    @Test func testCurrentSilenceDuration() async {
        let p = VADProcessor()
        // When not speaking and no last speech end, should be nil
        #expect(await p.currentSilenceDuration == nil)
    }

    // ── Task 1 additions: volume smoothing state helpers ──

    /// New test helper `_testSetSmoothedVolume` must correctly set internal state
    /// so integration tests can pre-seed the smoothed volume without needing
    /// to run many audio frames to warm it up.
    @Test func testSmoothedVolumeTestHelper() async {
        let p = VADProcessor(config: .default)
        // Initial smoothed volume must be 0
        let initial = await p._testSmoothedVolume
        #expect(initial == 0, "Smoothed volume must start at 0 (silence before any audio)")

        // Seed a known value via test helper
        await p._testSetSmoothedVolume(0.025)
        let seeded = await p._testSmoothedVolume
        #expect(seeded == 0.025, "_testSetSmoothedVolume must set the internal smoothedVolume directly")
    }

    /// The `_testLastStreamStateRefresh` helper exposes the refresh timestamp
    /// for integration tests that want to verify the reset fires at the right time.
    @Test func testLastStreamStateRefreshHelper() async {
        let p = VADProcessor(config: .default)
        let refresh = await p._testLastStreamStateRefresh
        // Should be close to now (initialized in init)
        let diff = abs(refresh.timeIntervalSinceNow)
        #expect(diff < 1.0, "lastStreamStateRefresh should be initialized to ~now (diff=\(diff)s)")
    }

    /// VADProcessor with `volumeGateEnabled=false` should expose the same initial
    /// state as default (the gate only matters during processChunk).
    @Test func testInitialStateWithGateDisabled() async {
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
        let p = VADProcessor(config: config)
        #expect(await p.isSpeaking == false)
        #expect(await p._testSmoothedVolume == 0, "Smoothed volume starts at 0 regardless of gate setting")
    }

    /// `resetSession()` must also reset the smoothed volume to 0.
    ///
    /// WHY: At the start of a new recording session, the smoothed volume
    /// carries no meaning from the previous session. If the user dictated
    /// loudly, smoothedVolume might be 0.08. Starting fresh with a reset
    /// means the volume gate won't immediately open just because the last
    /// session was loud.
    @Test func testResetSessionClearsSmoothedVolume() async {
        let p = VADProcessor(config: .default)
        await p._testSetSmoothedVolume(0.05)
        #expect(await p._testSmoothedVolume == 0.05, "Sanity: value was set")

        await p.resetSession()
        #expect(await p._testSmoothedVolume == 0,
                "resetSession() must clear smoothedVolume to 0 — old session's loudness shouldn't carry over")
    }


}

// MARK: - Settings VAD Tests
//
// Test that `Settings.shared` exposes the new volume gate fields.
// Settings.init() is private so we use `Settings.shared` directly with
// save/restore pattern (same pattern as AudioPipelineTests.swift).
//
// These tests run serially to avoid races on shared state.

@Suite("Settings — VAD volume gate fields", .serialized)
@MainActor
struct SettingsVADTests {

    /// Default value for vadVolumeGateEnabled must come from Config constant.
    ///
    /// The constant in Config is the authoritative default — Settings reads it
    /// via `if defaults.object(forKey:) == nil { return Config.vadVolumeGateEnabled }`
    @Test func testVolumeGateEnabledConstantMatchesConfig() {
        #expect(Config.vadVolumeGateEnabled == true,
                "Config.vadVolumeGateEnabled must be true (the safe default that enables the gate)")
    }

    /// Default value for vadMinVolumeForSpeech must match empirically derived constant.
    @Test func testMinVolumeForSpeechConstantMatchesConfig() {
        #expect(Config.vadMinVolumeForSpeech == 0.008,
                "Config.vadMinVolumeForSpeech must be 0.008 (between keyboard noise and quiet speech)")
    }

    /// Mutating vadVolumeGateEnabled on Settings.shared must be immediately readable.
    @Test func testVolumeGateEnabledMutation() {
        let saved = Settings.shared.vadVolumeGateEnabled
        defer { Settings.shared.vadVolumeGateEnabled = saved }

        Settings.shared.vadVolumeGateEnabled = false
        #expect(Settings.shared.vadVolumeGateEnabled == false,
                "Mutation must be immediately readable on Settings.shared")

        Settings.shared.vadVolumeGateEnabled = true
        #expect(Settings.shared.vadVolumeGateEnabled == true,
                "Mutation back to true must also be immediately readable")
    }

    /// Mutating vadMinVolumeForSpeech must be immediately readable.
    @Test func testMinVolumeForSpeechMutation() {
        let saved = Settings.shared.vadMinVolumeForSpeech
        defer { Settings.shared.vadMinVolumeForSpeech = saved }

        Settings.shared.vadMinVolumeForSpeech = 0.025
        #expect(Settings.shared.vadMinVolumeForSpeech == 0.025,
                "Mutation must be immediately readable on Settings.shared")
    }

    /// vadMinVolumeForSpeech must clamp negative values to a small positive number
    /// to prevent division-by-zero or nonsensical gate behavior.
    @Test func testMinVolumeForSpeechClampsNegative() {
        let saved = Settings.shared.vadMinVolumeForSpeech
        defer { Settings.shared.vadMinVolumeForSpeech = saved }

        Settings.shared.vadMinVolumeForSpeech = -1.0
        // Should be clamped to at least 0.0001 (see Config.swift setter)
        #expect(Settings.shared.vadMinVolumeForSpeech > 0,
                "Negative min volume must be clamped to a positive value")
    }

    /// vadMinVolumeForSpeech must clamp values above 0.1 (the RMS range for speech
    /// maxes out around 0.1 on MacBook mic — values above this would block all speech).
    @Test func testMinVolumeForSpeechClampsAboveMax() {
        let saved = Settings.shared.vadMinVolumeForSpeech
        defer { Settings.shared.vadMinVolumeForSpeech = saved }

        Settings.shared.vadMinVolumeForSpeech = 0.5  // absurdly high — would block all speech
        #expect(Settings.shared.vadMinVolumeForSpeech <= 0.1,
                "Min volume above 0.1 must be clamped (would block all speech if unclamped)")
    }
}

// MARK: - Config VAD Tests

struct ConfigVADTests {
    @Test func testConstants() {
        #expect(Config.vadThreshold == 0.15)
        #expect(Config.vadMinSilenceAfterSpeech == 3.0)
        #expect(Config.vadMinSpeechDuration == 0.25)
        #expect(Config.autoEndSilenceDuration == 5.0)
        #expect(Config.autoEndMinSessionDuration == 2.0)
    }

    // ── Task 1 additions: new volume gate + smoothing + state reset constants ──

    /// Verify all Task 1 constants exist with correct values.
    ///
    /// Changing these changes VAD behavior for all users. Any change here
    /// must be accompanied by empirical testing on noisy audio samples.
    @Test func testVolumeGateConfigConstants() {
        // Volume gate — default on
        #expect(Config.vadVolumeGateEnabled == true,
                "Volume gate must default to enabled — this is the safe default")

        // Min volume — sits between keyboard noise and quiet speech
        // keyboard RMS: 0.002–0.005 | quiet speech RMS: 0.01–0.03 | chosen: 0.008
        #expect(Config.vadMinVolumeForSpeech == 0.008,
                "0.008 is the empirically derived gap between keyboard noise and quiet speech")

        // Smoothing factor — prevents transient spikes from passing the volume gate
        #expect(Config.vadVolumeSmoothingFactor == Float(0.2),
                "0.2 ensures transients decay within 5-6 frames (~300ms)")

        // State reset interval — prevents LSTM probability drift in long sessions
        #expect(Config.vadStateResetInterval == 5.0,
                "5.0s balances drift prevention vs context loss")
    }
}

// MARK: - Exponential Smoothing Tests
//
// Tests for the `expSmoothing(_:_:_:)` free function in SpeechEvent.swift.
//
// Standard exponential smoothing (EMA) formula:
//   def exp_smoothing(value, prev_value, factor):
//       return prev_value + factor * (value - prev_value)
//
// It is used by VADProcessor to smooth instantaneous RMS values so that
// single-frame transients (keyboard clicks, door slams) do not pass the
// volume gate.
//

//
// Test strategy: verify the mathematical properties that make smoothing useful:
// 1. A single spike contributes only `factor` fraction to the smoothed value
// 2. The smoothed value converges to a steady input after many frames
// 3. After a transient, smoothed value decays exponentially back to baseline

@Suite("Exponential Smoothing — expSmoothing() math")
struct ExpSmoothingTests {

    /// Starting from zero, a single spike of 1.0 with factor=0.2 should
    /// produce 0.2. The spike contributes only 20% of the change.
    ///
    /// formula: prev + factor * (value - prev) = 0 + 0.2 * (1.0 - 0) = 0.2
    @Test func testSingleSpikeDampening() {
        let result = expSmoothing(1.0, 0.0, 0.2)
        #expect(result == 0.2, "Single spike of 1.0 from 0 should yield 0.2 with factor=0.2")
    }

    /// The formula is symmetric: going down from 1.0 by a step of 1.0
    /// (to 0.0) with factor=0.2 should land at 0.8.
    @Test func testSingleDropDampening() {
        let result = expSmoothing(0.0, 1.0, 0.2)
        #expect(result == 0.8, "Step down from 1.0 to 0.0 with factor=0.2 should yield 0.8")
    }

    /// After many frames of constant input (0.5), the smoothed value should
    /// converge to within 0.1% of the true value.
    ///
    /// Formula: smoothed converges to input because at steady state,
    /// `smoothed = smoothed + factor * (0.5 - smoothed)` → smoothed = 0.5.
    @Test func testConvergenceToSteadyState() {
        var smoothed: Float = 0
        for _ in 0..<100 {
            smoothed = expSmoothing(0.5, smoothed, 0.2)
        }
        #expect(abs(smoothed - 0.5) < 0.001,
                "After 100 frames of 0.5 input, should converge to 0.5 (got \(smoothed))")
    }

    /// After one spike, returning to zero input should decay exponentially.
    /// After 4 frames the spike should be well below 0.15 (half of initial 0.2).
    ///
    /// Frame-by-frame:
    ///   spike →  frame 0: 0.0 + 0.2*(1.0-0.0) = 0.2000
    ///   decay →  frame 1: 0.2 + 0.2*(0.0-0.2) = 0.1600
    ///            frame 2: 0.16 + 0.2*(0.0-0.16) = 0.1280
    ///            frame 3: 0.128 + 0.2*(0.0-0.128) = 0.1024
    @Test func testTransientDecay() {
        var smoothed = expSmoothing(1.0, 0.0, 0.2) // spike to 0.2
        smoothed = expSmoothing(0.0, smoothed, 0.2) // 0.16
        smoothed = expSmoothing(0.0, smoothed, 0.2) // 0.128
        smoothed = expSmoothing(0.0, smoothed, 0.2) // 0.1024
        #expect(smoothed < 0.11,
                "After spike + 3 silent frames, smoothed should be below 0.11 (got \(smoothed))")
    }

    /// With factor=1.0, smoothing is instantaneous: output = current value.
    /// This is the maximum tracking speed.
    @Test func testFactorOneIsInstantaneous() {
        let result = expSmoothing(0.7, 0.0, 1.0)
        #expect(result == 0.7, "Factor=1.0 means no smoothing — output equals input instantly")
    }

    /// With factor=0.0, smoothing is frozen: output = previous value.
    /// This is the maximum damping — new values are completely ignored.
    @Test func testFactorZeroIsFrozen() {
        let result = expSmoothing(0.7, 0.3, 0.0)
        #expect(result == 0.3, "Factor=0.0 means infinite lag — output always equals previous value")
    }

    /// Both inputs and output must remain in [0, infinity) for non-negative audio amplitudes.
    @Test func testNonNegativeInputProducesNonNegativeOutput() {
        let result = expSmoothing(0.5, 0.1, 0.2)
        #expect(result >= 0, "Audio RMS is always non-negative — output should be too")
    }

    /// Test with values in the realistic VAD range: RMS 0–0.1.
    /// At minVolumeForSpeech=0.008, verify a single frame can't push through.
    @Test func testRealisticAudioRange() {
        // A single loud transient of RMS 0.02 from zero (simulates a click)
        // with smoothing factor 0.2 → should be 0.004 — below minVolumeForSpeech=0.008
        let smoothed = expSmoothing(0.02, 0.0, 0.2)
        #expect(smoothed < Config.vadMinVolumeForSpeech,
                "A single-frame click transient should NOT push smoothed volume above the gate threshold")
    }

    /// Sustained speech (constant input above minVolumeForSpeech) must
    /// converge above the threshold so legitimate speech is not blocked.
    @Test func testSustainedSpeechPassesGate() {
        // Quiet speech: constant RMS of 0.015 (just above minVolumeForSpeech=0.008)
        var smoothed: Float = 0
        for _ in 0..<50 { // ~2.5 seconds at 50ms/frame
            smoothed = expSmoothing(0.015, smoothed, 0.2)
        }
        #expect(smoothed > Config.vadMinVolumeForSpeech,
                "Sustained quiet speech (RMS=0.015) must converge above gate threshold after warmup")
    }
}

// MARK: - Speech Event Tests

struct SpeechEventTests {
    @Test func testStartedEvent() {
        let event = SpeechEvent.started(at: 1.5)
        if case .started(let time) = event {
            #expect(time == 1.5)
        } else {
            Issue.record("Expected .started event")
        }
    }

    @Test func testEndedEvent() {
        let event = SpeechEvent.ended(at: 3.0)
        if case .ended(let time) = event {
            #expect(time == 3.0)
        } else {
            Issue.record("Expected .ended event")
        }
    }
}

// MARK: - VAD Result Tests

struct VADResultTests {
    @Test func testInit() {
        let result = VADResult(probability: 0.8, isSpeaking: true, event: .started(at: 1.0), processingTimeMs: 0.5)
        #expect(result.probability == 0.8)
        #expect(result.isSpeaking == true)
        #expect(result.processingTimeMs == 0.5)
    }

    @Test func testNilEvent() {
        let result = VADResult(probability: 0.3, isSpeaking: false, event: nil, processingTimeMs: 0.3)
        #expect(result.event == nil)
    }

    // ── Task 1 additions: smoothedVolume field in VADResult ──

    /// VADResult must carry the smoothed volume used by the gate decision.
    ///
    /// This allows downstream consumers (logging, future metrics) to see
    /// what volume value was used to suppress or allow the speech event.
    @Test func testVADResultCarriesSmoothedVolume() {
        let result = VADResult(
            probability: 0.8,
            isSpeaking: true,
            event: .started(at: 1.0),
            processingTimeMs: 0.5,
            smoothedVolume: 0.015
        )
        #expect(result.smoothedVolume == 0.015,
                "smoothedVolume must be stored and retrievable for logging/metrics")
    }

    /// smoothedVolume defaults to 0 to avoid breaking callers that don't
    /// know about this field yet (e.g., test helpers seeding VADResults).
    @Test func testVADResultSmoothedVolumeDefaultsToZero() {
        let result = VADResult(probability: 0.3, isSpeaking: false, event: nil, processingTimeMs: 0.3)
        #expect(result.smoothedVolume == 0,
                "Default smoothedVolume=0 ensures backward compatibility with existing test helpers")
    }

    /// VADResult should reflect a gated (suppressed) event — the volume field
    /// lets us distinguish "gate open, no event" from "gate closed, event suppressed".
    @Test func testVADResultWithGatedEvent() {
        // When volume gate suppresses a speechStart, the event becomes nil
        // but smoothedVolume still records what was observed.
        let result = VADResult(
            probability: 0.85,          // Silero says speech
            isSpeaking: false,          // gate blocked it
            event: nil,                 // event suppressed by volume gate
            processingTimeMs: 0.4,
            smoothedVolume: 0.003       // below minVolumeForSpeech=0.008
        )
        #expect(result.event == nil, "Gate-suppressed event must be nil in the result")
        #expect(result.smoothedVolume == 0.003, "Suppressed volume must still be recorded for diagnostics")
        #expect(result.probability == 0.85, "Raw Silero probability is preserved even when gate fires")
    }
}

// MARK: - VAD Error Tests

struct VADErrorTests {
    @Test func testNotInitialized() {
        let error = VADError.notInitialized
        if case .notInitialized = error {
            // Pass
        } else {
            Issue.record("Expected .notInitialized")
        }
    }

    @Test func testUnsupportedPlatform() {
        let error = VADError.unsupportedPlatform("Intel Mac")
        if case .unsupportedPlatform(let reason) = error {
            #expect(reason == "Intel Mac")
        } else {
            Issue.record("Expected .unsupportedPlatform")
        }
    }

    @Test func testProcessingFailed() {
        let error = VADError.processingFailed("Model error")
        if case .processingFailed(let msg) = error {
            #expect(msg == "Model error")
        } else {
            Issue.record("Expected .processingFailed")
        }
    }
}
