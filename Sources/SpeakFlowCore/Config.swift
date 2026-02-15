import Foundation

/// Fixed application configuration constants
public enum Config {
    // MARK: - Audio Processing (Fixed)
    /// RMS threshold below which audio is considered silence
    public static let silenceThreshold: Float = 0.003
    /// Seconds of silence before triggering chunk send
    public static let silenceDuration: Double = 2.0
    /// Minimum ratio of speech frames to total frames (energy-based, used when VAD is inactive)
    public static let minSpeechRatio: Float = 0.01
    /// Minimum VAD probability to consider a chunk as containing real speech.
    /// When VAD is active, this replaces minSpeechRatio for skip decisions.
    /// Only skip a chunk if we are ≥80% confident it is pure silence.
    /// VAD probability < 0.20 means the model sees <20% chance of speech,
    /// so we are 80%+ sure it's silent. Previously 0.30 (only 70% confident).
    public static let minVADSpeechProbability: Float = 0.20

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
    /// Positive threshold for Silero VAD: probability ≥ this triggers speechStart.
    /// Lowered from 0.30 to 0.15 because real mic speech often registers 0.07-0.25
    /// (Silero's default is 0.85 — our value is already very sensitive).
    /// The negative threshold (speechEnd) is derived as threshold - 0.15 offset,
    /// clamped to 0.01 minimum by FluidAudio.
    public static let vadThreshold: Float = 0.15
    /// Minimum duration of below-negative-threshold probability before a speechEnd
    /// event fires. Increased from 1.0s to 3.0s to prevent false speechEnd events
    /// during natural sentence pauses (user's speech regularly dips below threshold
    /// for 1-2s between sentences).
    public static let vadMinSilenceAfterSpeech: Double = 3.0
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
    public static let allCases: [ChunkDuration] = [.seconds15, .seconds30, .seconds45, .minute1, .minute2, .minute5, .minute10]
    case seconds15 = 15.0
    case seconds30 = 30.0
    case seconds45 = 45.0
    case minute1 = 60.0
    case minute2 = 120.0
    case minute5 = 300.0
    case minute10 = 600.0

    public var displayName: String {
        switch self {
        case .seconds15: return "15 seconds"
        case .seconds30: return "30 seconds"
        case .seconds45: return "45 seconds"
        case .minute1: return "1 minute"
        case .minute2: return "2 minutes"
        case .minute5: return "5 minutes"
        case .minute10: return "10 minutes"
        }
    }

    /// Whether this mode effectively disables chunking (no longer possible — max is 10 min)
    public var isFullRecording: Bool {
        false
    }

    /// Minimum chunk duration (shorter chunks get buffered)
    public var minDuration: Double {
        rawValue
    }
}

// MARK: - User Settings

/// User-configurable settings stored in UserDefaults.
///
/// In test runs, uses an isolated UserDefaults suite to avoid polluting the
/// user's actual settings. Detection mirrors the `Statistics` pattern.
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
        public static let focusWaitTimeout = "settings.focusWaitTimeout"
        public static let hotkeyRestartsRecording = "settings.hotkeyRestartsRecording"
    }

    private let defaults: UserDefaults

    private init() {
        let isTestRun = Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })
        if isTestRun {
            let suiteName = "app.monodo.speakflow.tests.\(ProcessInfo.processInfo.processIdentifier)"
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            defaults = .standard
        }
    }

    /// Maximum chunk duration before forced send
    public var chunkDuration: ChunkDuration {
        get {
            let rawValue = defaults.double(forKey: Keys.chunkDuration)
            return ChunkDuration(rawValue: rawValue) ?? .minute1
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.chunkDuration)
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
            if defaults.object(forKey: Keys.skipSilentChunks) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.skipSilentChunks)
        }
        set {
            defaults.set(newValue, forKey: Keys.skipSilentChunks)
        }
    }

    // MARK: - VAD Settings

    /// Whether Voice Activity Detection is enabled
    public var vadEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.vadEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.vadEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.vadEnabled)
        }
    }

    /// VAD threshold (0.0-1.0)
    public var vadThreshold: Float {
        get {
            // Only use stored value if the key actually exists (user explicitly changed it)
            if defaults.object(forKey: Keys.vadThreshold) != nil {
                let value = defaults.float(forKey: Keys.vadThreshold)
                // Migrate: if user had old defaults (0.5 or 0.3), use new default (0.15)
                if value == 0.5 || value == 0.3 {
                    defaults.removeObject(forKey: Keys.vadThreshold)
                    return Config.vadThreshold
                }
                return value > 0 ? value : Config.vadThreshold
            }
            return Config.vadThreshold
        }
        set {
            defaults.set(newValue, forKey: Keys.vadThreshold)
        }
    }

    // MARK: - Auto-End Settings

    /// Whether auto-end session is enabled
    public var autoEndEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.autoEndEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.autoEndEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoEndEnabled)
        }
    }

    /// Silence duration before auto-ending session
    /// Clamped to minimum 3.0s to prevent accidental premature auto-end from stale UserDefaults
    public var autoEndSilenceDuration: Double {
        get {
            let value = defaults.double(forKey: Keys.autoEndSilenceDuration)
            if value > 0 {
                return max(value, 3.0)  // Safety clamp: never less than 3 seconds
            }
            return Config.autoEndSilenceDuration
        }
        set {
            defaults.set(max(newValue, 3.0), forKey: Keys.autoEndSilenceDuration)
        }
    }

    /// Minimum speech ratio to consider a chunk as containing speech (0.0-1.0)
    /// Chunks below this threshold are considered silent when skipSilentChunks=true
    /// Default: 0.03 (3%) - lower values catch quieter speech but may include noise
    public var minSpeechRatio: Float {
        get {
            let value = defaults.float(forKey: Keys.minSpeechRatio)
            return value > 0 ? value : Config.minSpeechRatio
        }
        set {
            defaults.set(newValue, forKey: Keys.minSpeechRatio)
        }
    }

    // MARK: - Behavior Settings

    /// Maximum seconds to wait for the user to return to the target app.
    /// After this timeout, pending text operations are discarded.
    /// Setter clamps to minimum 10s; getter trusts the stored value.
    public var focusWaitTimeout: Double {
        get {
            let value = defaults.double(forKey: Keys.focusWaitTimeout)
            return value > 0 ? value : 60.0
        }
        set { defaults.set(max(newValue, 10.0), forKey: Keys.focusWaitTimeout) }
    }

    /// When enabled, pressing the hotkey during processing cancels current
    /// transcription and starts a new recording immediately.
    public var hotkeyRestartsRecording: Bool {
        get {
            if defaults.object(forKey: Keys.hotkeyRestartsRecording) == nil { return true }
            return defaults.bool(forKey: Keys.hotkeyRestartsRecording)
        }
        set { defaults.set(newValue, forKey: Keys.hotkeyRestartsRecording) }
    }

    // MARK: - Streaming Auto-End

    /// Whether auto-end is enabled for streaming mode (disabled by default)
    public var streamingAutoEndEnabled: Bool {
        get {
            if defaults.object(forKey: "settings.streaming.autoEndEnabled") == nil {
                return false
            }
            return defaults.bool(forKey: "settings.streaming.autoEndEnabled")
        }
        set {
            defaults.set(newValue, forKey: "settings.streaming.autoEndEnabled")
        }
    }

    // MARK: - Deepgram Streaming Settings

    private enum DeepgramKeys {
        static let interimResults = "settings.deepgram.interimResults"
        static let smartFormat = "settings.deepgram.smartFormat"
        static let endpointingMs = "settings.deepgram.endpointingMs"
        static let model = "settings.deepgram.model"
        static let language = "settings.deepgram.language"
    }

    /// Show partial transcription results as you speak
    public var deepgramInterimResults: Bool {
        get {
            if defaults.object(forKey: DeepgramKeys.interimResults) == nil {
                return true
            }
            return defaults.bool(forKey: DeepgramKeys.interimResults)
        }
        set { defaults.set(newValue, forKey: DeepgramKeys.interimResults) }
    }

    /// Automatic punctuation and capitalization
    public var deepgramSmartFormat: Bool {
        get {
            if defaults.object(forKey: DeepgramKeys.smartFormat) == nil {
                return true
            }
            return defaults.bool(forKey: DeepgramKeys.smartFormat)
        }
        set { defaults.set(newValue, forKey: DeepgramKeys.smartFormat) }
    }

    /// Endpointing threshold in milliseconds (how quickly utterance boundaries are detected)
    public var deepgramEndpointingMs: Int {
        get {
            let val = defaults.integer(forKey: DeepgramKeys.endpointingMs)
            return val > 0 ? val : 300
        }
        set { defaults.set(max(newValue, 100), forKey: DeepgramKeys.endpointingMs) }
    }

    /// Deepgram transcription model
    public var deepgramModel: String {
        get { defaults.string(forKey: DeepgramKeys.model) ?? "nova-3" }
        set { defaults.set(newValue, forKey: DeepgramKeys.model) }
    }

    /// Deepgram transcription language
    public var deepgramLanguage: String {
        get { defaults.string(forKey: DeepgramKeys.language) ?? "en-US" }
        set { defaults.set(newValue, forKey: DeepgramKeys.language) }
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

extension Settings: SettingsProviding {}
