import Foundation

/// Fixed application configuration constants
public enum Config {
    // MARK: - Audio Processing (Fixed)
    /// RMS threshold below which audio is considered silence
    public static let silenceThreshold: Float = 0.003
    /// Seconds of silence before triggering chunk send
    public static let silenceDuration: Double = 2.0
    /// Minimum ratio of speech frames to total frames (energy-based, used when VAD is inactive)
    public static let minSpeechRatio: Float = 0.03
    /// Minimum VAD probability to consider a chunk as containing real speech.
    /// When VAD is active, this replaces minSpeechRatio for skip decisions.
    /// Filters broadband noise (white noise ~0.26) while passing real speech (typically >0.5).
    public static let minVADSpeechProbability: Float = 0.30

    // MARK: - Audio Limits (Fixed)
    /// Sample rate for audio recording (Hz)
    public static let sampleRate: Double = 16000
    /// Minimum recording duration in milliseconds (matches Codex behavior)
    public static let minRecordingDurationMs: Int = 250
    /// Maximum audio file size in bytes (25MB - covers ~7 minutes at 16kHz mono 16-bit)
    public static let maxAudioSizeBytes: Int = 25_000_000
    /// Maximum recording duration when chunking is disabled (1 hour, matches Codex)
    public static let maxFullRecordingDuration: Double = 3600.0

    // MARK: - API Settings (Fixed)
    /// Minimum seconds between API requests (rate limiting)
    public static let minTimeBetweenRequests: Double = 10.0
    /// Base request timeout in seconds for small audio files (≤ baseTimeoutDataSize).
    /// 10s is comfortable for typical 15s chunks (~480KB WAV) — OpenAI usually
    /// responds in 2–5s, but cold starts and network hiccups can push to 8s.
    public static let timeout: Double = 10.0
    /// Maximum request timeout in seconds, used for the largest allowed files.
    public static let maxTimeout: Double = 30.0
    /// Data size (bytes) at or below which the base timeout applies.
    /// ~480KB ≈ 15 seconds of 16kHz mono 16-bit PCM WAV.
    public static let baseTimeoutDataSize: Int = 480_000
    /// Maximum retry attempts for failed requests
    public static let maxRetries: Int = 3
    /// Base delay for exponential backoff (seconds)
    public static let retryBaseDelay: Double = 1.5

    // MARK: - Text Insertion Limits (Fixed)
    /// P3 Security: Maximum queued text insertions to prevent unbounded task chains
    /// If chunks arrive faster than text can be typed, older insertions are dropped
    public static let maxQueuedTextInsertions: Int = 10

    // MARK: - VAD Settings
    public static let vadThreshold: Float = 0.3
    public static let vadMinSilenceAfterSpeech: Double = 1.0
    public static let vadMinSpeechDuration: Double = 0.25
    public static let autoEndSilenceDuration: Double = 5.0
    public static let autoEndMinSessionDuration: Double = 2.0
    
    // MARK: - Chunk Safety Limits
    /// Hard multiplier for force-sending chunks during continuous speech.
    /// When buffer duration exceeds maxChunkDuration × this multiplier,
    /// the chunk is sent regardless of speaking state. Prevents unbounded
    /// buffer accumulation that leads to API timeouts and lost transcriptions.
    public static let forceSendChunkMultiplier: Double = 2.0

    // minChunkDurationForPauseSend removed — chunks now respect user's
    // configured ChunkDuration, not a hardcoded 5s minimum. See shouldSendChunk().
}

// MARK: - Chunk Duration Options

public enum ChunkDuration: Double, CaseIterable, Sendable {
    public static let allCases: [ChunkDuration] = [.seconds15, .seconds30, .seconds45, .minute1, .minute2, .minute5, .minute10, .minute15, .unlimited]
    case seconds15 = 15.0
    case seconds30 = 30.0
    case seconds45 = 45.0
    case minute1 = 60.0
    case minute2 = 120.0
    case minute5 = 300.0
    case minute10 = 600.0
    case minute15 = 900.0
    case unlimited = 3600.0  // 1 hour max (matches Codex behavior)

    public var displayName: String {
        switch self {
        case .seconds15: return "15 seconds"
        case .seconds30: return "30 seconds"
        case .seconds45: return "45 seconds"
        case .minute1: return "1 minute"
        case .minute2: return "2 minutes"
        case .minute5: return "5 minutes"
        case .minute10: return "10 minutes"
        case .minute15: return "15 minutes"
        case .unlimited: return "Unlimited (no chunking)"
        }
    }

    /// Whether this mode effectively disables chunking
    public var isFullRecording: Bool {
        self == .unlimited
    }

    /// Minimum chunk duration (shorter chunks get buffered)
    public var minDuration: Double {
        switch self {
        case .unlimited:
            // For unlimited mode, use a very short minimum (250ms like Codex)
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
@MainActor
public final class Settings {
    public static let shared = Settings()

    private enum Keys {
        public static let chunkDuration = "settings.chunkDuration"
        public static let skipSilentChunks = "settings.skipSilentChunks"
        public static let vadEnabled = "settings.vadEnabled"
        public static let vadThreshold = "settings.vadThreshold"
        public static let autoEndEnabled = "settings.autoEndEnabled"
        public static let autoEndSilenceDuration = "settings.autoEndSilenceDuration"
        public static let minSpeechRatio = "settings.minSpeechRatio"
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
    /// Default: true — saves API costs by not sending chunks with no speech.
    /// The final chunk on session end is always sent if speech was detected,
    /// regardless of this setting (so trailing silence can't cause speech loss).
    public var skipSilentChunks: Bool {
        get {
            // Default to true — skip purely-silent chunks to save API costs.
            // Final chunks are protected: if speech occurred in the session,
            // stop() always sends regardless of this flag.
            if UserDefaults.standard.object(forKey: Keys.skipSilentChunks) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.skipSilentChunks)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.skipSilentChunks)
        }
    }

    // MARK: - VAD Settings

    /// Whether Voice Activity Detection is enabled
    public var vadEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.vadEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.vadEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.vadEnabled)
        }
    }

    /// VAD threshold (0.0-1.0)
    public var vadThreshold: Float {
        get {
            // Only use stored value if the key actually exists (user explicitly changed it)
            if UserDefaults.standard.object(forKey: Keys.vadThreshold) != nil {
                let value = UserDefaults.standard.float(forKey: Keys.vadThreshold)
                // Migrate: if user had old default of 0.5, use new default of 0.3
                if value == 0.5 {
                    UserDefaults.standard.removeObject(forKey: Keys.vadThreshold)
                    return Config.vadThreshold
                }
                return value > 0 ? value : Config.vadThreshold
            }
            return Config.vadThreshold
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.vadThreshold)
        }
    }

    // MARK: - Auto-End Settings

    /// Whether auto-end session is enabled
    public var autoEndEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.autoEndEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.autoEndEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.autoEndEnabled)
        }
    }

    /// Silence duration before auto-ending session
    /// Clamped to minimum 3.0s to prevent accidental premature auto-end from stale UserDefaults
    public var autoEndSilenceDuration: Double {
        get {
            let value = UserDefaults.standard.double(forKey: Keys.autoEndSilenceDuration)
            if value > 0 {
                return max(value, 3.0)  // Safety clamp: never less than 3 seconds
            }
            return Config.autoEndSilenceDuration
        }
        set {
            UserDefaults.standard.set(max(newValue, 3.0), forKey: Keys.autoEndSilenceDuration)
        }
    }

    /// Minimum speech ratio to consider a chunk as containing speech (0.0-1.0)
    /// Chunks below this threshold are considered silent when skipSilentChunks=true
    /// Default: 0.03 (3%) - lower values catch quieter speech but may include noise
    public var minSpeechRatio: Float {
        get {
            let value = UserDefaults.standard.float(forKey: Keys.minSpeechRatio)
            return value > 0 ? value : Config.minSpeechRatio
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.minSpeechRatio)
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
