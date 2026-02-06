import Foundation

/// Fixed application configuration constants
public enum Config {
    // MARK: - Audio Processing (Fixed)
    /// RMS threshold below which audio is considered silence
    public static let silenceThreshold: Float = 0.003
    /// Seconds of silence before triggering chunk send
    public static let silenceDuration: Double = 2.0
    /// Minimum ratio of speech frames to total frames
    public static let minSpeechRatio: Float = 0.03

    // MARK: - Audio Limits (Fixed)
    /// Sample rate for audio recording (Hz)
    public static let sampleRate: Double = 16000
    /// M4A (AAC) encoding bitrate - 32kbps is excellent for voice
    public static let audioBitrate: Int = 32000
    /// Minimum recording duration in milliseconds (matches Codex behavior)
    public static let minRecordingDurationMs: Int = 250
    /// Maximum audio file size in bytes (25MB API limit - covers ~100 min M4A at 32kbps)
    public static let maxAudioSizeBytes: Int = 25_000_000
    /// Maximum recording duration when chunking is disabled (1 hour, matches Codex)
    public static let maxFullRecordingDuration: Double = 3600.0

    // MARK: - API Settings (Fixed)
    /// Minimum seconds between API requests (rate limiting)
    public static let minTimeBetweenRequests: Double = 10.0
    /// Request timeout in seconds
    public static let timeout: Double = 30.0
    /// Maximum retry attempts for failed requests
    public static let maxRetries: Int = 2
    /// Base delay for exponential backoff (seconds)
    public static let retryBaseDelay: Double = 5.0

    // MARK: - Text Insertion Limits (Fixed)
    /// P3 Security: Maximum queued text insertions to prevent unbounded task chains
    /// If chunks arrive faster than text can be typed, older insertions are dropped
    public static let maxQueuedTextInsertions: Int = 10
}

// MARK: - Chunk Duration Options

public enum ChunkDuration: Double, CaseIterable {
    public static let allCases: [ChunkDuration] = [.seconds30, .seconds45, .minute1, .minute2, .minute5, .minute7, .fullRecording]
    case seconds30 = 30.0
    case seconds45 = 45.0
    case minute1 = 60.0
    case minute2 = 120.0
    case minute5 = 300.0
    case minute7 = 420.0
    case fullRecording = 3600.0  // 1 hour max (matches Codex behavior)

    public var displayName: String {
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
    public var isFullRecording: Bool {
        self == .fullRecording
    }

    /// Minimum chunk duration (shorter chunks get buffered)
    public var minDuration: Double {
        switch self {
        case .fullRecording:
            // For full recording mode, use a very short minimum (250ms like Codex)
            return 0.25
        default:
            // Min equals max - chunks are sent at the selected duration
            // (silence detection only skips silent chunks, doesn't trigger early sends)
            return rawValue
        }
    }
}

// MARK: - User Settings

/// User-configurable settings stored in UserDefaults
public final class Settings {
    public static let shared = Settings()

    private enum Keys {
        public static let chunkDuration = "settings.chunkDuration"
        public static let skipSilentChunks = "settings.skipSilentChunks"
    }

    private init() {}

    /// Maximum chunk duration before forced send
    public var chunkDuration: ChunkDuration {
        get {
            let rawValue = UserDefaults.standard.double(forKey: Keys.chunkDuration)
            return ChunkDuration(rawValue: rawValue) ?? .minute1
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.chunkDuration)
        }
    }

    /// Whether to skip chunks that are mostly silent
    public var skipSilentChunks: Bool {
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
    public var maxChunkDuration: Double {
        chunkDuration.rawValue
    }

    /// Minimum seconds of audio before sending to API
    public var minChunkDuration: Double {
        chunkDuration.minDuration
    }
}
