import Foundation
import OSLog

/// Actor for thread-safe audio buffer management
public actor AudioBuffer {
    private var samples: [Float] = []
    private var speechFrameCount: Int = 0
    private var totalFrameCount: Int = 0
    private let sampleRate: Double

    /// Maximum samples to prevent unbounded memory growth
    /// Based on max recording duration (1 hour) at 16kHz = 57,600,000 samples
    /// Using 60M as a round number with some headroom
    private let maxSamples: Int

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // Calculate max samples based on max full recording duration + 10% headroom
        self.maxSamples = Int(Config.maxFullRecordingDuration * sampleRate * 1.1)
    }

    public var duration: Double {
        Double(samples.count) / sampleRate
    }

    public var speechRatio: Float {
        totalFrameCount > 0 ? Float(speechFrameCount) / Float(totalFrameCount) : 0
    }

    /// Returns true if buffer is at capacity
    public var isAtCapacity: Bool {
        samples.count >= maxSamples
    }

    public func append(frames: [Float], hasSpeech: Bool) {
        // P0 Security: Prevent unbounded memory growth
        guard samples.count + frames.count <= maxSamples else {
            Logger.audio.warning("Audio buffer at capacity (\(self.maxSamples) samples), dropping frames")
            return
        }

        samples.append(contentsOf: frames)
        totalFrameCount += frames.count
        if hasSpeech { speechFrameCount += frames.count }
    }

    public func takeAll() -> (samples: [Float], speechRatio: Float) {
        let result = (samples: samples, speechRatio: speechRatio)
        samples = []
        speechFrameCount = 0
        totalFrameCount = 0
        return result
    }

    public func reset() {
        samples = []
        speechFrameCount = 0
        totalFrameCount = 0
    }
}
