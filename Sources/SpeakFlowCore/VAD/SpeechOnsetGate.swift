import Foundation

/// Holds a raw speech onset until speech has been sustained for the configured
/// minimum duration.
///
/// FluidAudio's streaming state machine emits speechStart on the first frame
/// at or above the threshold and does not apply `minSpeechDuration`, so a brief
/// transient that passes the volume gate would otherwise count as speech. The
/// confirmed start keeps the onset time; audio is buffered independently, so
/// onset audio is never lost.
struct SpeechOnsetGate {
    enum Outcome: Equatable {
        case pending
        case confirmed(onset: Double)
        /// Probability fell below the threshold before the minimum was reached.
        case rejected
    }

    private var onset: Double?
    private var sustained: TimeInterval = 0

    var isPending: Bool { onset != nil }

    /// Starts tracking an onset. Returns the onset time when the first frame
    /// alone already meets the minimum.
    mutating func begin(at onset: Double, frameSeconds: TimeInterval, minimum: TimeInterval) -> Double? {
        guard frameSeconds < minimum else {
            reset()
            return onset
        }
        self.onset = onset
        sustained = frameSeconds
        return nil
    }

    /// Accounts one more frame of a pending onset.
    mutating func observe(aboveThreshold: Bool, frameSeconds: TimeInterval, minimum: TimeInterval) -> Outcome {
        guard let onset else { return .rejected }
        guard aboveThreshold else {
            reset()
            return .rejected
        }
        sustained += frameSeconds
        // Frame durations are summed in floating point; allow for rounding.
        guard sustained + 1e-9 >= minimum else { return .pending }
        reset()
        return .confirmed(onset: onset)
    }

    mutating func reset() {
        onset = nil
        sustained = 0
    }
}
