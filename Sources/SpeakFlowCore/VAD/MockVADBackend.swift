// Only compiled in DEBUG builds — never ships in production.
#if DEBUG

import Foundation

// MARK: - VADFrame

/// A single scripted VAD frame for deterministic testing.
///
/// Encodes what `VADProcessor.processChunk()` would receive from FluidAudio/Silero
/// for one 50ms audio window, without actually running the CoreML model.
///
/// **Why this exists:**
/// Silero is a stateful LSTM — its output depends on every frame it has ever seen.
/// It is impossible to reproduce "what Silero would output after 5 minutes of noisy
/// audio" in a unit test without actually running 5 minutes of audio through it.
///
/// Instead, we describe the scenario in terms of what Silero *would have* output,
/// then inject those values directly. Our gate/smoothing/state-reset logic then
/// runs on the injected values — so the tests cover OUR code, not Silero's model.
///
/// Uses the same pattern as the real `processChunk` path in ``VADProcessor``.
public struct VADFrame: Sendable {
    /// Silero's raw speech probability (0.0–1.0) for this frame.
    public let probability: Float
    /// Whether FluidAudio's internal STARTING/STOPPING state machine has
    /// decided this frame is "speaking" (probability held above threshold
    /// for `minSpeechDuration` seconds).
    public let isSpeaking: Bool
    /// Instantaneous RMS of the audio for this frame, in the same float32
    /// 0–1 scale used by `StreamingRecorder.installAudioTap()`.
    /// Injected into the exponential smoothing calculation.
    public let instantRMS: Float

    public init(probability: Float, isSpeaking: Bool, instantRMS: Float) {
        self.probability = probability
        self.isSpeaking = isSpeaking
        self.instantRMS = instantRMS
    }

    // MARK: - Semantic constructors

    /// Normal speech: high probability, speaking=true, speech-level RMS.
    ///
    /// Default RMS 0.05 ≈ moderate indoor dictation. Well above
    /// `Config.vadMinVolumeForSpeech` (0.008), so the volume gate passes.
    public static func speech(_ probability: Float = 0.9, rms: Float = 0.05) -> VADFrame {
        VADFrame(probability: probability, isSpeaking: true, instantRMS: rms)
    }

    /// Silence: near-zero probability, not speaking, mic-floor RMS.
    ///
    /// Default RMS 0.0005 ≈ muted mic. The volume gate would block this even
    /// if somehow the probability spiked.
    public static func silence(_ probability: Float = 0.02, rms: Float = 0.0005) -> VADFrame {
        VADFrame(probability: probability, isSpeaking: false, instantRMS: rms)
    }

    /// Long-session drift: probability just above threshold, but RMS is ambient noise.
    ///
    /// Models the condition that motivated Task 1 (state reset): after 5+ minutes of
    /// continuous LSTM operation, Silero's hidden state drifts so that ambient noise
    /// (fan, HVAC) starts producing probabilities just above our 0.15 threshold.
    ///
    /// Default probability 0.18: just above `Config.vadThreshold` (0.15).
    /// Default RMS 0.003: fan/HVAC noise level — below `minVolumeForSpeech` (0.008).
    ///
    /// With volume gate ON:  gate blocks → no speechStart (correct)
    /// With volume gate OFF: false speechStart fires (the pre-Task-1 bug)
    public static func drift(_ probability: Float = 0.18, rms: Float = 0.003) -> VADFrame {
        VADFrame(probability: probability, isSpeaking: false, instantRMS: rms)
    }

    /// Keyboard click transient: moderate probability, below volume gate.
    ///
    /// Models a mechanical keyboard keypress picked up by a MacBook mic.
    /// The 2kHz click resonance can resemble voiced fricatives spectrally,
    /// giving Silero a non-trivial confidence boost.
    ///
    /// Default probability 0.25: above threshold but not dramatically.
    /// Default RMS 0.003: keyboard noise level — below `minVolumeForSpeech` (0.008).
    ///
    /// With volume gate ON:  gate blocks → no speechStart (correct)
    /// With volume gate OFF: false speechStart fires
    public static func keyboardClick(_ probability: Float = 0.25, rms: Float = 0.003) -> VADFrame {
        VADFrame(probability: probability, isSpeaking: false, instantRMS: rms)
    }

    /// Loud transient (door slam, dropped object): very high RMS but short.
    ///
    /// Tests the smoothing behavior: even though instantRMS is high (0.08),
    /// one frame with smoothing factor 0.2 produces smoothedVolume ≈ 0.016.
    /// After that one frame, 4 more silent frames decay it back below the gate.
    ///
    /// This verifies that smoothing prevents single-frame transients from
    /// passing the volume gate.
    public static func loudTransient(_ probability: Float = 0.3, rms: Float = 0.08) -> VADFrame {
        VADFrame(probability: probability, isSpeaking: false, instantRMS: rms)
    }

    /// High-probability keyboard noise (for gate-disabled tests).
    ///
    /// When we want to verify that disabling the volume gate actually ALLOWS
    /// events through, we need frames that would definitely trigger speechStart
    /// if the gate is off. Uses very high probability (0.85) with still-low RMS.
    public static func highProbNoise(_ probability: Float = 0.85, rms: Float = 0.003) -> VADFrame {
        VADFrame(probability: probability, isSpeaking: true, instantRMS: rms)
    }
}

// MARK: - MockVADBackend

/// Scriptable VAD backend for deterministic testing of `VADProcessor`.
///
/// When injected via `VADProcessor._testInjectBackend()`, all calls to
/// `processChunk()` use scripted `VADFrame` values instead of running Silero.
///
/// **Design:**
/// - `actor` isolation: safe to call from async test code alongside `VADProcessor`
/// - Script runs sequentially; falls back to `.silence()` after exhaustion
/// - `callCount` lets tests verify all frames were consumed
///
/// **Pattern:** A list of scripted `VADFrame` values consumed in sequence, keeping
/// tests deterministic and independent of the real Silero model output.
///
/// ```swift
/// // Example: encode the long-session-drift bug as a test scenario
/// let backend = MockVADBackend(VADScenario.longSessionDrift())
/// await vad._testInjectBackend(backend)
/// // ... processChunk() will see the scripted drift frames, not Silero output
/// ```
public actor MockVADBackend {
    private var script: [VADFrame]
    private var index: Int = 0

    /// Total number of times `next()` was called (including exhaustion fallbacks).
    public private(set) var callCount: Int = 0

    // MARK: - Init

    /// Create a backend with an explicit sequence of frames.
    public init(_ frames: [VADFrame]) {
        self.script = frames
    }

    /// Create a backend that repeats the same frame N times.
    /// Useful for simple uniform scenarios ("60 silence frames").
    public init(repeating frame: VADFrame, count: Int) {
        self.script = Array(repeating: frame, count: count)
    }

    // MARK: - Interface

    /// Consume and return the next scripted frame.
    /// Falls back to `.silence()` once the script is exhausted.
    public func next() -> VADFrame {
        callCount += 1
        guard index < script.count else {
            return .silence()
        }
        defer { index += 1 }
        return script[index]
    }

    /// Reset to the beginning of the script (re-run the scenario).
    public func reset() {
        index = 0
        callCount = 0
    }

    /// Number of frames remaining in the script.
    public var framesRemaining: Int {
        max(0, script.count - index)
    }

    /// Whether the script has been fully consumed.
    public var isExhausted: Bool {
        index >= script.count
    }
}

#endif // DEBUG
