import Foundation

/// Application configuration constants
enum Config {
    // MARK: - Audio Chunking
    /// Minimum seconds of audio before sending to API
    static let minChunkDuration: Double = 5.0
    /// Maximum seconds before forced send
    static let maxChunkDuration: Double = 60.0
    /// RMS threshold below which audio is considered silence
    static let silenceThreshold: Float = 0.003
    /// Seconds of silence before triggering chunk send
    static let silenceDuration: Double = 2.0
    /// Minimum ratio of speech frames to total frames
    static let minSpeechRatio: Float = 0.03

    // MARK: - API Settings
    /// Minimum seconds between API requests (rate limiting)
    static let minTimeBetweenRequests: Double = 10.0
    /// Request timeout in seconds
    static let timeout: Double = 30.0
    /// Maximum retry attempts for failed requests
    static let maxRetries: Int = 2
    /// Base delay for exponential backoff (seconds)
    static let retryBaseDelay: Double = 5.0
}
