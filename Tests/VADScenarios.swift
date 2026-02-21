import Foundation
@testable import SpeakFlowCore

// MARK: - VAD Test Scenarios
//
// Named scenario datasets for deterministic VADProcessor testing.
//
// Each scenario is a sequence of `VADFrame` values that encode a specific
// real-world condition. They are consumed by `MockVADBackend` and injected
// into `VADProcessor.processChunk()` instead of running Silero.
//
// **WHY NAMED SCENARIOS (not ad-hoc arrays in each test):**
// When a test fails, the scenario name tells you EXACTLY what real-world
// situation broke:
//   - `longSessionDrift` failing → state-reset logic broken
//   - `keyboardTyping` failing → volume gate broken
//   - `singleTransientSpike` failing → smoothing broken
//   - `normalSpeech` failing → basic VAD event logic broken
//
// All frame counts assume 50ms/frame (the `StreamingRecorder` processing interval).
//
// **Reference:**
// The mock backend injection pattern allows encoding exact scenarios —
// scenarios are expressed as arrays of `VADFrame` passed to `MockVADBackend`.
// We extend this with per-frame RMS values to also test the volume gate.
//
// ─────────────────────────────────────────────────────────────────────────────

// swiftlint:disable identifier_name
enum VADScenario {

    // MARK: - Basic Scenarios

    /// 2s quiet → 3s speech → 2s quiet.
    ///
    /// The simplest possible speech event sequence. Tests that:
    /// - `speechStart` fires when speaking begins
    /// - `speechEnd` fires when speaking ends
    /// - No spurious events during silence
    ///
    /// Frame counts: 40 silence + 60 speech + 40 silence = 140 frames = 7s.
    static func normalSpeech() -> [VADFrame] {
        Array(repeating: .silence(), count: 40) +
        Array(repeating: .speech(), count: 60) +
        Array(repeating: .silence(), count: 40)
    }

    /// Multiple speech bursts separated by short pauses.
    ///
    /// Tests that the STARTING/STOPPING state machine correctly handles
    /// multiple speech events in one session.
    ///
    /// Pattern: speak 2s, pause 1s, speak 2s, pause 1s, speak 2s.
    /// Expected: 3× (speechStart + speechEnd) pairs.
    static func multipleSpeechBursts() -> [VADFrame] {
        Array(repeating: .speech(), count: 40) +
        Array(repeating: .silence(), count: 20) +
        Array(repeating: .speech(), count: 40) +
        Array(repeating: .silence(), count: 20) +
        Array(repeating: .speech(), count: 40)
    }

    /// Pure silence — no speech at all.
    ///
    /// Tests the common idle state: mic is live but user is not speaking.
    /// Expected: zero speech events throughout.
    static func puresilence(seconds: Double = 10.0) -> [VADFrame] {
        let frameCount = Int(seconds / 0.05)
        return Array(repeating: .silence(), count: frameCount)
    }

    // MARK: - Feature 1: State Reset (Long Session Drift)

    /// **Long-session probability drift scenario.**
    ///
    /// After 5+ minutes of continuous Silero LSTM operation, the hidden state
    /// accumulates environmental noise context. The model starts assigning
    /// probability ≈ 0.18 to ambient sounds (fan, HVAC) that it initially
    /// treated as silence.
    ///
    /// This scenario encodes that drift as scripted frames:
    /// - 5990 frames (≈5 min) of clean silence (prob=0.02)
    /// - 10 frames of "drift" (prob=0.18, just above threshold=0.15, rms=0.003)
    ///
    /// **Expected behavior with periodic state reset enabled:**
    ///   The periodic state reset (every 5s) clears the LSTM context, so the
    ///   probability never drifts. With the mock backend, the state reset only
    ///   matters for our OWN state machine — the drift frames still arrive, but
    ///   the volume gate (rms=0.003 < minVol=0.008) blocks them.
    ///
    ///   *Note:* In the mock backend, `stateResetInterval` affects the periodic
    ///   `lastStreamStateRefresh` update but does NOT retroactively prevent the
    ///   injected drift probabilities from arriving. The volume gate is what
    ///   actually blocks them in this test. The state-reset prevents drift from
    ///   even happening in production by resetting the real LSTM.
    ///
    /// **Expected behavior WITHOUT volume gate:**
    ///   Drift frames have prob=0.18 and isSpeaking=false (FluidAudio's hysteresis
    ///   hasn't committed to SPEAKING yet). So this scenario tests the gate stopping
    ///   the STARTING state before it commits.
    static func longSessionDrift() -> [VADFrame] {
        Array(repeating: .silence(), count: 5990) +
        Array(repeating: .drift(), count: 10)
    }

    /// Shorter version of longSessionDrift for faster tests (30s instead of 5min).
    ///
    /// Uses 5 drift frames after 600 silence frames. Same gate/smoothing logic,
    /// much faster to execute.
    static func shortSessionDrift() -> [VADFrame] {
        Array(repeating: .silence(), count: 600) +
        Array(repeating: .drift(), count: 5)
    }

    // MARK: - Feature 2: Exponential Smoothing

    /// **Single loud transient that must NOT pass the volume gate.**
    ///
    /// One frame of instantRMS=0.08 (door slam, dropped object) surrounded by silence.
    ///
    /// With smoothing factor 0.2:
    ///   - Before spike: smoothedVolume ≈ 0.0001
    ///   - Spike frame:  smoothedVolume = 0.0001 + 0.2*(0.08-0.0001) ≈ 0.016
    ///   - Frame+1:      smoothedVolume = 0.016 + 0.2*(0.0001-0.016) ≈ 0.0128
    ///   - Frame+2:      ≈ 0.0102
    ///   - Frame+3:      ≈ 0.0082
    ///   - Frame+4:      ≈ 0.0066 (< minVol=0.008 → gate would close again)
    ///
    /// But wait — only one frame has isSpeaking=false from FluidAudio, so the event
    /// never fires regardless. The important thing is that the SMOOTHED volume after
    /// the spike is ≈0.016, which IS above the gate threshold (0.008). This means:
    ///
    /// ⚠️ A single spike of RMS 0.08 WILL temporarily open the gate for ~3 frames.
    ///
    /// The real protection is that FluidAudio requires `minSpeechDuration` (0.25s = 5 frames)
    /// before committing to SPEAKING. So the gate + duration threshold together prevent
    /// the single transient from producing a speechStart.
    ///
    /// **What this test actually verifies:**
    /// After the spike, smoothedVolume decays below the threshold within 4 frames.
    /// And the single isSpeaking=false spike cannot produce a speech event anyway.
    static func singleTransientSpike() -> [VADFrame] {
        Array(repeating: .silence(), count: 20) +
        [VADFrame.loudTransient()] +
        Array(repeating: .silence(), count: 20)
    }

    /// **Sustained transient series that STILL should not produce speechStart.**
    ///
    /// 5 consecutive high-RMS frames (0.08 each). After smoothing:
    ///   frame 1: 0.016, frame 2: 0.029, frame 3: 0.039, frame 4: 0.047, frame 5: 0.054
    ///
    /// All frames have isSpeaking=false and probability=0.3 (just above threshold=0.15).
    /// The volume gate should OPEN at frame 1 (smoothed > 0.008), but FluidAudio's
    /// hysteresis (isSpeaking=false) prevents speechStart from firing.
    ///
    /// This scenario tests that our gate correctly reflects smoothedVolume while
    /// FluidAudio's state machine provides the final event-firing decision.
    static func sustainedTransientBurst() -> [VADFrame] {
        Array(repeating: .silence(), count: 10) +
        Array(repeating: .loudTransient(), count: 5) +
        Array(repeating: .silence(), count: 10)
    }

    /// Smoothing convergence: sustained quiet speech warms up the volume estimate.
    ///
    /// 50 frames of speech with RMS=0.015. After smoothing factor=0.2 for 50 frames,
    /// smoothedVolume should converge to ≈0.015 (within 1% of true value).
    ///
    /// This verifies that the gate correctly OPENS for sustained real speech.
    static func sustainedQuietSpeech() -> [VADFrame] {
        let speechFrame = VADFrame(probability: 0.9, isSpeaking: true, instantRMS: 0.015)
        return Array(repeating: speechFrame, count: 50)
    }

    // MARK: - Feature 3: Volume Gate

    /// **20 keyboard clicks surrounded by silence.**
    ///
    /// Each keystroke: prob=0.25, isSpeaking=false, rms=0.003.
    /// Smoothed RMS after each click: converges to ≈0.003 * (1 - 0.8^n).
    /// After 20 frames: smoothedVolume ≈ 0.003 (still below minVol=0.008).
    ///
    /// **Expected:** Zero speechStart events (gate blocks all clicks).
    static func keyboardTyping() -> [VADFrame] {
        Array(repeating: .silence(), count: 40) +
        Array(repeating: .keyboardClick(), count: 20) +
        Array(repeating: .silence(), count: 40)
    }

    /// Keyboard typing followed by real speech.
    ///
    /// Tests the most common real-world pattern: user types for a moment
    /// then starts dictating. The volume gate must:
    /// 1. Block keyboard clicks (phase 1)
    /// 2. Let real speech through once volume warms up (phase 2)
    ///
    /// Expected: Zero events during keyboard phase, speechStart during speech phase.
    static func keyboardThenSpeech() -> [VADFrame] {
        Array(repeating: .keyboardClick(), count: 20) +        // keyboard: no events
        Array(repeating: .silence(), count: 5) +               // brief pause
        Array(repeating: .speech(rms: 0.05), count: 60) +     // real speech: events fire
        Array(repeating: .silence(), count: 20)
    }

    /// **Gate-disabled version of keyboard typing.**
    ///
    /// Same keyboard frames, but volume gate is OFF. Uses `highProbNoise` (prob=0.85,
    /// isSpeaking=true) to verify the gate being disabled actually changes behavior.
    ///
    /// **Expected:** At least one speechStart fires (gate is off, high prob passes).
    /// Used by tests that verify `volumeGateEnabled=false` doesn't silently no-op.
    static func keyboardNoiseGateDisabled() -> [VADFrame] {
        Array(repeating: .silence(), count: 10) +
        Array(repeating: .highProbNoise(), count: 20) +        // prob=0.85, isSpeaking=true
        Array(repeating: .silence(), count: 10)
    }

    /// **Fan/HVAC ambient noise — persistent low-level noise.**
    ///
    /// Models office/home background noise: continuous low-probability, low-RMS.
    /// Without volume gate: might accumulate into false speech over time.
    /// With volume gate: blocked (rms=0.002 < minVol=0.008).
    ///
    /// Expected: Zero speech events throughout.
    static func ambientNoise(seconds: Double = 30.0) -> [VADFrame] {
        let fanFrame = VADFrame(probability: 0.05, isSpeaking: false, instantRMS: 0.002)
        return Array(repeating: fanFrame, count: Int(seconds / 0.05))
    }

    // MARK: - Compound / Real-world Scenarios

    /// **Full dictation session with typical patterns.**
    ///
    /// Simulates a realistic dictation session:
    /// 1. Quiet warmup (mic opens, user not yet speaking)
    /// 2. First sentence spoken
    /// 3. Natural thinking pause (2s silence)
    /// 4. Second sentence spoken
    /// 5. Longer pause (4s silence — would trigger auto-end at 5s)
    /// 6. Third sentence spoken
    /// 7. Session ends
    ///
    /// Expected: 3 speechStart + 3 speechEnd events.
    static func typicalDictationSession() -> [VADFrame] {
        Array(repeating: .silence(), count: 20) +              // warmup (1s)
        Array(repeating: .speech(), count: 60) +               // sentence 1 (3s)
        Array(repeating: .silence(), count: 40) +              // thinking pause (2s)
        Array(repeating: .speech(), count: 40) +               // sentence 2 (2s)
        Array(repeating: .silence(), count: 80) +              // long pause (4s)
        Array(repeating: .speech(), count: 40) +               // sentence 3 (2s)
        Array(repeating: .silence(), count: 20)                // end (1s)
    }

    /// **Noisy dictation: keyboard clicks interspersed with speech.**
    ///
    /// User types between spoken sentences. Tests that:
    /// - Keyboard clicks between sentences don't restart speech
    /// - Real speech is still detected despite surrounding noise
    ///
    /// Expected: 2× (speechStart + speechEnd), keyboard frames produce no events.
    static func noisyDictation() -> [VADFrame] {
        Array(repeating: .speech(), count: 40) +               // sentence 1
        Array(repeating: .keyboardClick(), count: 10) +        // typing
        Array(repeating: .silence(), count: 10) +              // pause
        Array(repeating: .keyboardClick(), count: 8) +         // more typing
        Array(repeating: .speech(), count: 40) +               // sentence 2
        Array(repeating: .silence(), count: 20)                // end
    }

    /// **Volume gate boundary: probe exactly at minVolumeForSpeech.**
    ///
    /// Uses warmup frames with RMS = 1.2× `Config.vadMinVolumeForSpeech` to ensure
    /// smoothedVolume converges ABOVE the threshold. Then speech frames at the same RMS.
    ///
    /// Gate condition: `smoothedVolume < minVolumeForSpeech`
    /// After warmup at 1.2× threshold, smoothedVolume ≈ 1.2× threshold > threshold → gate OPENS.
    ///
    /// Expected: speechStart fires.
    static func volumeAtGateThreshold() -> [VADFrame] {
        // Use 1.2× to guarantee convergence above threshold despite floating point
        let aboveThreshold = Config.vadMinVolumeForSpeech * 1.2
        let warmupFrame = VADFrame(probability: 0.02, isSpeaking: false,
                                  instantRMS: aboveThreshold)
        let speechFrame = VADFrame(probability: 0.9, isSpeaking: true,
                                   instantRMS: aboveThreshold)
        return Array(repeating: warmupFrame, count: 100) +  // 5s warmup → converges above threshold
               Array(repeating: speechFrame, count: 20)     // speech at same level
    }

    /// **Volume just below gate threshold — must be blocked.**
    ///
    /// Sustained RMS at 80% of minVolumeForSpeech. After convergence,
    /// smoothedVolume ≈ 0.008 * 0.80 = 0.0064 < 0.008 → gate stays closed.
    static func volumeJustBelowGateThreshold() -> [VADFrame] {
        let belowThreshold = Config.vadMinVolumeForSpeech * 0.80
        let speechFrame = VADFrame(probability: 0.9, isSpeaking: true, instantRMS: belowThreshold)
        return Array(repeating: speechFrame, count: 100)  // sustained — converges to 0.0064
    }
}
// swiftlint:enable identifier_name
