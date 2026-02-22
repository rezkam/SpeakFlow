import Foundation

/// Pluggable pre-VAD audio filter.
///
/// Filters run before samples are appended to ``AudioBuffer`` and before VAD
/// processing. This keeps VAD decisions and outgoing chunks aligned to the same
/// cleaned signal.
public protocol AudioFilter: Sendable {
    func start(sampleRate: Double) async
    func stop() async
    func filter(_ samples: [Float]) -> [Float]
}

/// Lightweight RMS noise gate.
///
/// Frames with RMS below `rmsThreshold` are zeroed out. This suppresses steady
/// ambient noise and low-energy keyboard/fan bleed before VAD inference.
public struct NoiseGateFilter: AudioFilter, Sendable {
    public let rmsThreshold: Float

    public init(rmsThreshold: Float) {
        self.rmsThreshold = max(0, rmsThreshold)
    }

    public func start(sampleRate: Double) async {}
    public func stop() async {}

    public func filter(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumSq / Float(samples.count))
        guard rms < rmsThreshold else { return samples }
        return [Float](repeating: 0, count: samples.count)
    }
}
