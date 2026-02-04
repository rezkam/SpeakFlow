import Foundation

/// Fixed application configuration constants
enum Config {
    // MARK: - Audio Processing (Fixed)
    /// RMS threshold below which audio is considered silence
    static let silenceThreshold: Float = 0.003
    /// Seconds of silence before triggering chunk send
    static let silenceDuration: Double = 2.0
    /// Minimum ratio of speech frames to total frames
    static let minSpeechRatio: Float = 0.03

    // MARK: - Audio Limits (Fixed)
    /// Sample rate for audio recording (Hz)
    static let sampleRate: Double = 16000
    /// Minimum recording duration in milliseconds (matches Codex behavior)
    static let minRecordingDurationMs: Int = 250
    /// Maximum audio file size in bytes (25MB - covers ~7 minutes at 16kHz mono 16-bit)
    static let maxAudioSizeBytes: Int = 25_000_000
    /// Maximum recording duration when chunking is disabled (1 hour, matches Codex)
    static let maxFullRecordingDuration: Double = 3600.0

    // MARK: - API Settings (Fixed)
    /// Minimum seconds between API requests (rate limiting)
    static let minTimeBetweenRequests: Double = 10.0
    /// Request timeout in seconds
    static let timeout: Double = 30.0
    /// Maximum retry attempts for failed requests
    static let maxRetries: Int = 2
    /// Base delay for exponential backoff (seconds)
    static let retryBaseDelay: Double = 5.0
}

// MARK: - Chunk Duration Options

enum ChunkDuration: Double, CaseIterable {
    case seconds30 = 30.0
    case seconds45 = 45.0
    case minute1 = 60.0
    case minute2 = 120.0
    case minute5 = 300.0
    case minute7 = 420.0
    case fullRecording = 3600.0  // 1 hour max (matches Codex behavior)

    var displayName: String {
        switch self {
        case .seconds30: return "30 seconds"
        case .seconds45: return "45 seconds"
        case .minute1: return "1 minute"
        case .minute2: return "2 minutes"
        case .minute5: return "5 minutes"
        case .minute7: return "7 minutes"
        case .fullRecording: return "Full Recording (no chunking)"
        }
    }

    /// Whether this mode effectively disables chunking
    var isFullRecording: Bool {
        self == .fullRecording
    }

    /// Minimum chunk duration (shorter chunks get buffered)
    var minDuration: Double {
        switch self {
        case .fullRecording:
            // For full recording mode, use a very short minimum (250ms like Codex)
            return 0.25
        default:
            // Min is roughly 1/6 of max, with a floor of 5 seconds
            return max(5.0, rawValue / 6.0)
        }
    }
}

// MARK: - User Settings

/// User-configurable settings stored in UserDefaults
final class Settings {
    static let shared = Settings()

    private enum Keys {
        static let chunkDuration = "settings.chunkDuration"
        static let skipSilentChunks = "settings.skipSilentChunks"
    }

    private init() {}

    /// Maximum chunk duration before forced send
    var chunkDuration: ChunkDuration {
        get {
            let rawValue = UserDefaults.standard.double(forKey: Keys.chunkDuration)
            return ChunkDuration(rawValue: rawValue) ?? .minute1
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.chunkDuration)
        }
    }

    /// Whether to skip chunks that are mostly silent
    var skipSilentChunks: Bool {
        get {
            // Default to true if not set
            if UserDefaults.standard.object(forKey: Keys.skipSilentChunks) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.skipSilentChunks)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.skipSilentChunks)
        }
    }

    // MARK: - Computed Properties for Audio Processing

    /// Maximum seconds before forced chunk send
    var maxChunkDuration: Double {
        chunkDuration.rawValue
    }

    /// Minimum seconds of audio before sending to API
    var minChunkDuration: Double {
        chunkDuration.minDuration
    }
}
