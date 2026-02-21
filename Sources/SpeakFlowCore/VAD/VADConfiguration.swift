import Foundation

/// Configuration for the Voice Activity Detection processor.
///
/// All fields have defaults that work well for typical dictation on a MacBook
/// with moderate ambient noise. Power users can tune them via Settings UI or
/// by constructing a custom configuration programmatically.
public struct VADConfiguration: Sendable {

    // MARK: - Silero Probability Threshold

    /// Silero VAD probability (0–1) above which a frame is considered speech.
    ///
    /// Lowered from the Silero default of 0.85 to 0.15 because real microphone
    /// speech often registers 0.07–0.25 on the Silero scale, especially at
    /// normal dictation distances from a MacBook mic. 0.15 is sensitive enough
    /// to catch soft speech without being so high that genuine speech is missed.
    ///
    /// The negative threshold (speechEnd) is derived internally by FluidAudio as
    /// `threshold − 0.15`, clamped to 0.01 minimum. Do NOT set negativeThreshold
    /// directly — FluidAudio's VadSegmentationConfig interprets it as the positive
    /// threshold offset, which would raise the trigger inadvertently.
    public var threshold: Float

    // MARK: - Timing Parameters

    /// Minimum silence duration (seconds) required before a `speechEnd` event fires.
    ///
    /// Set to 3.0s to prevent false speechEnd events during natural between-sentence
    /// pauses. Real dictation commonly has 1–2s pauses between sentences while the
    /// speaker breathes or collects thoughts; setting this below 3s causes premature
    /// session auto-end, which is the #1 user complaint.
    ///
    /// Trade-off: a higher value means auto-end waits longer after the user stops
    /// speaking. The SessionController's `silenceDuration` adds on top of this.
    public var minSilenceAfterSpeech: TimeInterval

    /// Minimum speech duration (seconds) before a `speechStart` event fires.
    ///
    /// At 0.25s, a very brief noise burst (cough, click) that lasts under 250ms
    /// will NOT trigger speechStart even if Silero's probability spikes. This
    /// prevents false session activation from short transients.
    public var minSpeechDuration: TimeInterval

    /// Whether VAD processing is enabled at all.
    ///
    /// When false, `VADProcessor.processChunk()` is never called and the recorder
    /// falls back to pure time-based chunking (no silence detection).
    public var enabled: Bool

    // MARK: - Volume Gate (Problem 2 fix)

    /// When true, requires audio to exceed `minVolumeForSpeech` (smoothed RMS)
    /// before a `speechStart` event is allowed through.
    ///
    /// WHY THIS EXISTS — The Dual-Gate Problem:
    /// Silero analyzes spectral patterns, not loudness. A keyboard tap, fan surge,
    /// or cough can push Silero's probability above our low 0.15 threshold because
    /// it briefly resembles voiced fricatives in the frequency domain. Without a
    /// volume check, these become false `speechStart` events that:
    ///   1. Set `isUserSpeaking = true` in SessionController
    ///   2. Block auto-end (`guard !isUserSpeaking else { return false }`)
    ///   3. Send silent chunks to the transcription API (wasting cost)
    ///
    /// The volume gate adds a second, independent check: the audio must also be
    /// loud enough to plausibly be human speech. A keyboard tap at a desk has
    /// RMS ~0.002–0.005; quiet dictation has RMS ~0.01–0.03. A threshold of
    /// 0.008 sits cleanly between them.
    ///
    /// Dual-gate pattern: `speaking = confidence >= threshold AND volume >= min_volume`
    public var volumeGateEnabled: Bool

    /// Minimum smoothed RMS amplitude (float32 range 0–1) for a speechStart event
    /// to pass the volume gate. Ignored when `volumeGateEnabled` is false.
    ///
    /// Empirical reference ranges (MacBook Pro microphone at typical desk usage):
    ///   - Silence (mic open, no sound):  RMS ≈ 0.0001 – 0.0005
    ///   - Background fan / HVAC:         RMS ≈ 0.001  – 0.003
    ///   - Keyboard typing (1m away):     RMS ≈ 0.002  – 0.005
    ///   - Quiet speech (arm's length):   RMS ≈ 0.010  – 0.030
    ///   - Normal speech (0.5m):          RMS ≈ 0.020  – 0.060
    ///   - Loud speech / raised voice:    RMS ≈ 0.050  – 0.150
    ///
    /// 0.008 is chosen to sit between keyboard noise (~0.005) and quiet speech
    /// (~0.010), filtering out common non-vocal transients while still catching
    /// soft dictation in a quiet environment.
    ///
    /// Note: this is on our RMS float32 scale (0–1). Different from EBU R128 loudness
    /// scale used in some voice frameworks — the numeric value differs but the concept
    /// (loudness floor for speech) is identical.
    public var minVolumeForSpeech: Float

    /// Exponential smoothing factor applied to the per-frame RMS before the volume
    /// gate check. Range 0–1: lower = more smoothing, higher = more reactive.
    ///
    /// WHY THIS EXISTS — Transient Suppression:
    /// Raw RMS is instantaneous. A single loud pop, click, or door-slam can spike
    /// the RMS far above `minVolumeForSpeech` for one 50ms batch and trigger the
    /// volume gate even if nothing else would. Exponential smoothing ensures the
    /// current frame contributes only `factor × 100%` to the running estimate.
    ///
    /// With factor 0.2:
    ///   - A single loud clap moves smoothedVolume by only 20% of the spike.
    ///   - The spike decays back to baseline within ~4–5 frames (~200–250ms).
    ///   - Sustained speech (continuous loudness) converges to the true level
    ///     after ~10–15 frames (~500–750ms).
    ///
    public var volumeSmoothingFactor: Float

    // MARK: - Silero State Reset (Problem 1 fix)

    /// How often (seconds) to reset the Silero RNN hidden state during recording.
    ///
    /// WHY THIS EXISTS — Model Drift in Long Sessions:
    /// Silero VAD is a recurrent neural network (LSTM/GRU). Its hidden state
    /// (`h` and `c` matrices) accumulates context from every audio frame processed.
    /// In short sessions (< 2 min) this is beneficial: context helps the model
    /// distinguish speech from environmental noise.
    ///
    /// In long sessions (5+ min), the accumulated state causes **probability drift**:
    /// the model's internal representation shifts toward whatever sounds dominate
    /// the session. If the user is in a noisy office, Silero gradually raises its
    /// baseline probability for ambient noise, eventually treating fan noise as
    /// speech. This manifests as false `speechStart` events late in long sessions,
    /// blocking auto-end.
    ///
    /// Resetting the hidden state periodically:
    ///   - Prevents probability drift (the primary goal)
    ///   - Costs only ~100–200ms of context loss per reset (Silero needs 3–5 frames
    ///     to re-establish context, at ~32ms per frame)
    ///   - Is safe because FluidAudio's VadSegmentationConfig manages the actual
    ///     speech/silence event state machine via `minSpeechDuration` /
    ///     `minSilenceDuration`; the Silero hidden state only affects raw probability
    ///
    /// Default: 5 seconds — empirically tuned to balance drift prevention vs context loss.
    public var stateResetInterval: TimeInterval

    // MARK: - Init

    public init(
        threshold: Float = 0.5,
        minSilenceAfterSpeech: TimeInterval = 1.0,
        minSpeechDuration: TimeInterval = 0.25,
        enabled: Bool = true,
        volumeGateEnabled: Bool = true,
        minVolumeForSpeech: Float = 0.008,
        volumeSmoothingFactor: Float = 0.2,
        stateResetInterval: TimeInterval = 5.0
    ) {
        self.threshold = threshold
        self.minSilenceAfterSpeech = minSilenceAfterSpeech
        self.minSpeechDuration = minSpeechDuration
        self.enabled = enabled
        self.volumeGateEnabled = volumeGateEnabled
        self.minVolumeForSpeech = minVolumeForSpeech
        self.volumeSmoothingFactor = volumeSmoothingFactor
        self.stateResetInterval = stateResetInterval
    }

    // MARK: - Presets

    /// Default configuration — balanced for typical quiet-to-moderate desktop use.
    public static let `default` = VADConfiguration()

    /// Sensitive configuration for users with soft voices or distant microphones.
    /// Lower probability threshold catches quieter speech; other settings unchanged.
    public static let sensitive = VADConfiguration(threshold: 0.3)

    /// Strict configuration for noisy environments.
    /// Higher probability threshold reduces false positives from ambient noise.
    public static let strict = VADConfiguration(threshold: 0.7)
}
