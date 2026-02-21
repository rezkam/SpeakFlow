import Foundation

// MARK: - Speech Events

public enum SpeechEvent: Sendable {
    case started(at: Double)
    case ended(at: Double)
}

// MARK: - VAD Result

/// The output of a single `VADProcessor.processChunk()` call.
///
/// In addition to the raw Silero probability and speaking state, the result
/// now carries `smoothedVolume` so callers (heartbeat logging, future metrics)
/// can observe the volume signal that was used in the gate decision — without
/// having to re-compute it.
public struct VADResult: Sendable {
    /// Raw Silero VAD probability for this chunk (0–1).
    /// This is the unfiltered output; the volume gate may have suppressed the
    /// resulting event even when probability is high.
    public let probability: Float

    /// Whether the VADProcessor currently considers the user to be speaking.
    /// Updated only when speech events pass all gates (probability + volume).
    public let isSpeaking: Bool

    /// The speech lifecycle event that fired this chunk, if any.
    ///
    /// `nil` means no transition occurred (mid-speech or sustained silence).
    /// `.started` means the probability + volume gates both passed and the
    ///   minSpeechDuration was exceeded.
    /// `.ended` means silence exceeded minSilenceAfterSpeech (volume gate is
    ///   NOT applied to speechEnd — dropping volume is itself the end signal).
    public let event: SpeechEvent?

    /// Wall-clock time the VAD model inference took, in milliseconds.
    /// Useful for diagnosing latency on slower machines or model variants.
    public let processingTimeMs: Double

    /// Exponentially-smoothed RMS amplitude of the audio chunk (float32, 0–1).
    ///
    /// This is the volume value that was compared against
    /// `VADConfiguration.minVolumeForSpeech` in the volume gate. Carrying it
    /// in the result lets callers (heartbeat logs, session metrics) surface the
    /// value without re-computing it.
    ///
    /// A value near 0 means the audio was silent or very quiet.
    /// Values of 0.008–0.030 correspond to typical quiet-to-normal dictation.
    /// Values above 0.050 correspond to loud speech or shouting.
    public let smoothedVolume: Float

    public init(
        probability: Float,
        isSpeaking: Bool,
        event: SpeechEvent?,
        processingTimeMs: Double,
        smoothedVolume: Float = 0
    ) {
        self.probability = probability
        self.isSpeaking = isSpeaking
        self.event = event
        self.processingTimeMs = processingTimeMs
        self.smoothedVolume = smoothedVolume
    }
}

// MARK: - VAD Errors

public enum VADError: Error, Sendable {
    case notInitialized
    case unsupportedPlatform(String)
    case processingFailed(String)
}

// MARK: - Exponential Smoothing Utility

/// Apply one step of exponential smoothing to a time-series value.
///
/// Formula: `result = prev + factor × (value − prev)`
///
/// With `factor = 0.2`:
///   - The current frame contributes 20% to the smoothed estimate.
///   - A single-frame spike of amplitude A decays to 0.2A after 1 frame,
///     0.16A after 2, 0.128A after 3 — effectively gone within 5–6 frames (~300ms).
///   - A sustained constant input converges to within 1% of the true value
///     after ~21 frames (~1 second at 50ms frame stride).
///
/// - Parameters:
///   - value:     The new (instantaneous) measurement.
///   - prevValue: The previous smoothed estimate.
///   - factor:    Smoothing factor in range (0, 1]. Higher = more reactive,
///                lower = more damping. Default 0.2.
/// - Returns: The updated smoothed estimate.
public func expSmoothing(_ value: Float, _ prevValue: Float, _ factor: Float) -> Float {
    prevValue + factor * (value - prevValue)
}
