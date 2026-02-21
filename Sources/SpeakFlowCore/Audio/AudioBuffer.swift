import Foundation
import OSLog

/// Thread-safe, append-only audio sample buffer for a single recording session.
///
/// Samples are appended from the audio tap callback (via `StreamingRecorder`) and
/// drained atomically by `takeAll()` when a chunk is ready to send to the
/// transcription API.
///
/// The buffer intentionally stores raw samples only.
/// Speech confidence decisions are computed in `VADProcessor` and consumed by
/// `StreamingRecorder`; this actor is responsible only for reliable append/drain
/// behavior with bounded memory usage.
public actor AudioBuffer {
    private var samples: [Float] = []
    private let sampleRate: Double

    /// Maximum samples to prevent unbounded memory growth.
    /// Based on max recording duration (1 hour) at 16kHz = 57,600,000 samples.
    /// Using 10% headroom beyond the nominal max for safety.
    private let maxSamples: Int

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.maxSamples = Int(Config.maxFullRecordingDuration * sampleRate * 1.1)
    }

    // MARK: - Properties

    /// Current duration of buffered audio in seconds.
    public var duration: Double {
        Double(samples.count) / sampleRate
    }

    /// Returns true if the buffer is at its hard capacity limit.
    /// When true, further `append()` calls are no-ops (samples are dropped).
    public var isAtCapacity: Bool {
        samples.count >= maxSamples
    }

    // MARK: - Write

    /// Append audio frames to the buffer.
    ///
    /// - Parameter frames: Float32 PCM samples at the buffer's sample rate.
    public func append(frames: [Float]) {
        guard samples.count + frames.count <= maxSamples else {
            Logger.audio.warning("Audio buffer at capacity (\(self.maxSamples) samples), dropping frames")
            return
        }
        samples.append(contentsOf: frames)
    }

    // MARK: - Read / Drain

    /// Atomically drain all buffered samples and return them.
    ///
    /// After this call the buffer is empty. The caller owns the returned array.
    /// If the API call fails, the audio cannot be retried — it is gone. (A future
    /// improvement could add `takeAllWithOverlap` to keep recent audio for retry.)
    public func takeAll() -> [Float] {
        let result = samples
        samples = []
        return result
    }

    /// Reset the buffer without returning samples (used on cancel/abort).
    public func reset() {
        samples = []
    }
}
