import Foundation

/// Application configuration constants
public enum Config {
    // MARK: - Audio Processing
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
    /// so we are 80%+ sure it's silent.
    public static let minVADSpeechProbability: Float = 0.20

    // MARK: - Pre-VAD Audio Filter
    /// Enables the lightweight noise gate before VAD and chunk buffering.
    /// Keeps the default behavior conservative: only near-silence is zeroed.
    public static let audioNoiseGateEnabled: Bool = true
    /// RMS threshold (0-1) for the pre-VAD noise gate.
    /// Frames below this value are replaced with silence.
    public static let audioNoiseGateRmsThreshold: Float = 0.002

    // MARK: - Audio Limits
    /// Sample rate for audio recording (Hz)
    public static let sampleRate: Double = 16000
    /// Minimum recording duration in milliseconds
    public static let minRecordingDurationMs: Int = 250
    /// Maximum audio file size in bytes (25MB - covers ~7 minutes at 16kHz mono 16-bit)
    public static let maxAudioSizeBytes: Int = 25_000_000
    /// Maximum recording duration when chunking is disabled (1 hour)
    public static let maxFullRecordingDuration: Double = 3600.0

    // MARK: - API Settings
    /// Minimum seconds between API requests (rate limiting)
    public static let minTimeBetweenRequests: Double = 10.0
    /// Hard wall-clock timeout per request attempt (seconds).
    ///
    /// Based on 303 real ChatGPT transcription sessions:
    ///   p50=2.6s  p90=5.5s  p95=7.1s  p99=9.2s  max(success)=25s
    ///
    /// 15s comfortably covers p99 while killing the ~38s server stalls
    /// (which never recover) early enough to fit 3 retries within a
    /// reasonable total wait. URLRequest.timeoutInterval is also set to
    /// this value but is unreliable for stalled HTTP responses — the task
    /// group timeout enforces it as a hard wall-clock deadline.
    public static let requestTimeout: Double = 15.0

    /// Total number of attempts (initial + retries).
    /// 3 attempts × 15s + 2 × 1s delay = 47s worst-case wall clock.
    public static let maxAttempts: Int = 3

    /// Flat delay between retry attempts (seconds).
    /// Kept flat (not exponential) because the failure mode is a server
    /// stall, not overload — retrying quickly gets a fresh connection.
    public static let retryDelay: Double = 1.0

    // --- legacy aliases kept for MistralBatchProvider timeout calculation ---
    public static let timeout: Double = requestTimeout
    public static let maxTimeout: Double = requestTimeout
    public static let baseTimeoutDataSize: Int = 480_000
    public static let maxRetries: Int = maxAttempts - 1
    public static let retryBaseDelay: Double = retryDelay

    // MARK: - Text Insertion Limits
    /// Maximum queued text insertions to prevent unbounded task chains.
    /// If chunks arrive faster than text can be typed, older insertions are dropped
    public static let maxQueuedTextInsertions: Int = 10

    // MARK: - Observability
    /// Master switch for structured observability event capture.
    public static let observabilityEnabled: Bool = true
    /// Default event verbosity for structured observability events.
    public static let observabilityVerbosity: ObservabilityVerbosity = .standard
    /// Include startup/session settings snapshots in observability events.
    public static let observabilityCaptureSettingsSnapshot: Bool = true
    /// Include one-time runtime/system context in observability events.
    public static let observabilityCaptureSystemContext: Bool = true
    /// Include raw transcript/keystroke payloads in observability events.
    /// Off by default due sensitivity and log volume.
    public static let observabilityCaptureTextPayloads: Bool = false
    /// Rotate structured observability logs before they grow without bound.
    public static let observabilityMaxLogBytes: UInt64 = 25 * 1024 * 1024
    /// Number of rotated observability log files to retain per profile.
    public static let observabilityMaxRotatedLogFiles: Int = 3
    /// Default lexical word floor before a non-speechFinal streaming final commits.
    /// Keeping this at 2 avoids one-word clause fragments being committed too early.
    public static let defaultStreamingMinimumFinalWordCount: Int = 2

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

    // MARK: - Idle Nudge (pre auto-end)
    /// When enabled, auto-end is preceded by progressive nudges.
    public static let idleNudgeEnabled: Bool = false
    /// Delay before the first nudge once auto-end condition is reached.
    public static let idleNudgeInitialDelay: Double = 0.0
    /// Interval between nudges.
    public static let idleNudgeInterval: Double = 3.0
    /// Number of nudges before expiration callback fires.
    public static let idleNudgeMaxCount: Int = 2

    // MARK: - Turn completion classifier (SmartTurn-style)
    /// Master switch for classifier-assisted auto-end gating.
    public static let turnClassifierEnabled: Bool = false
    /// Minimum silence after speech end before evaluating turn completion.
    public static let turnClassifierMinimumSilence: Double = 1.5
    /// Extra silence allowance when the classifier predicts an incomplete turn.
    public static let turnClassifierIncompleteExtensionSeconds: Double = 3.0
    /// Completion probability threshold.
    public static let turnClassifierThreshold: Float = 0.5

    // MARK: - VAD Volume Gate (filters non-vocal speech starts)

    /// Whether the volume gate is enabled by default.
    ///
    /// When true, a `speechStart` event from Silero is only forwarded if the
    /// audio's smoothed RMS also exceeds `vadMinVolumeForSpeech`. This prevents
    /// keyboard clicks, fan surges, and other non-vocal transients from blocking
    /// auto-end or sending silent chunks to the transcription API.
    ///
    /// Can be disabled per user if they use a very quiet microphone or experience
    /// legitimate speech being suppressed. See Settings.vadVolumeGateEnabled.
    public static let vadVolumeGateEnabled: Bool = true

    /// Minimum smoothed RMS amplitude (float32 range 0–1) for a speechStart
    /// event to pass the volume gate.
    ///
    /// Empirical reference ranges (MacBook Pro mic at typical desk usage):
    ///   - Silence (open mic, no sound):  RMS ≈ 0.0001 – 0.0005
    ///   - Background fan / HVAC:         RMS ≈ 0.001  – 0.003
    ///   - Keyboard typing (1m away):     RMS ≈ 0.002  – 0.005
    ///   - Quiet speech (arm's length):   RMS ≈ 0.010  – 0.030
    ///   - Normal speech (0.5m):          RMS ≈ 0.020  – 0.060
    ///
    /// 0.008 sits between keyboard noise (~0.005) and quiet speech (~0.010).
    public static let vadMinVolumeForSpeech: Float = 0.008

    /// Exponential smoothing factor applied to per-frame RMS before the volume gate.
    ///
    /// With factor 0.2, the current frame contributes 20% to the running estimate.
    /// A single-frame spike decays to near-zero within 5–6 frames (~300ms at 50ms
    /// frame stride). Only sustained loudness (speech) moves the value above the
    /// threshold.
    public static let vadVolumeSmoothingFactor: Float = 0.2

    // MARK: - VAD State Reset (controls probability drift in long sessions)

    /// How often (seconds) the Silero RNN hidden state is reset during recording.
    ///
    /// Silero is an LSTM/GRU-based model whose hidden state accumulates context
    /// from every frame. In sessions longer than ~5 minutes, this can cause
    /// probability drift — the model adjusts to environmental noise and starts
    /// classifying it as speech. Resetting every 5 seconds prevents this drift
    /// with minimal context loss (~100–200ms per reset).
    public static let vadStateResetInterval: Double = 5.0
    
    // MARK: - Chunk Safety Limits
    /// Hard multiplier for force-sending chunks during continuous speech.
    /// When buffer duration exceeds maxChunkDuration × this multiplier,
    /// the chunk is sent regardless of speaking state. Prevents unbounded
    /// buffer accumulation that leads to API timeouts and lost transcriptions.
    public static let forceSendChunkMultiplier: Double = 2.0

    // Chunking uses the configured ChunkDuration. See shouldSendChunk().
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

    /// Whether this mode effectively disables chunking
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
        public static let vadVolumeGateEnabled = "settings.vad.volumeGateEnabled"
        public static let vadMinVolumeForSpeech = "settings.vad.minVolumeForSpeech"
        public static let vadVolumeSmoothingFactor = "settings.vad.volumeSmoothingFactor"
        public static let vadStateResetInterval = "settings.vad.stateResetInterval"
        public static let autoEndEnabled = "settings.autoEndEnabled"
        public static let autoEndSilenceDuration = "settings.autoEndSilenceDuration"
        public static let autoEndMinSessionDuration = "settings.autoEndMinSessionDuration"
        public static let autoEndRequireSpeechFirst = "settings.autoEndRequireSpeechFirst"
        public static let autoEndNoSpeechTimeout = "settings.autoEndNoSpeechTimeout"
        public static let autoEndMaxContinuousSpeechDuration = "settings.autoEndMaxContinuousSpeechDuration"
        public static let thinkingPauseEnabled = "settings.autoEnd.thinkingPauseEnabled"
        public static let thinkingPauseExtensionSeconds = "settings.autoEnd.thinkingPauseExtensionSeconds"
        public static let turnClassifierEnabled = "settings.autoEnd.turnClassifierEnabled"
        public static let turnClassifierMinimumSilence = "settings.autoEnd.turnClassifierMinimumSilence"
        public static let turnClassifierIncompleteExtensionSeconds = "settings.autoEnd.turnClassifierIncompleteExtensionSeconds"
        public static let turnClassifierThreshold = "settings.autoEnd.turnClassifierThreshold"
        public static let idleNudgeEnabled = "settings.autoEnd.idleNudgeEnabled"
        public static let idleNudgeInitialDelay = "settings.autoEnd.idleNudgeInitialDelay"
        public static let idleNudgeInterval = "settings.autoEnd.idleNudgeInterval"
        public static let idleNudgeMaxCount = "settings.autoEnd.idleNudgeMaxCount"
        public static let audioNoiseGateEnabled = "settings.audio.noiseGateEnabled"
        public static let audioNoiseGateRmsThreshold = "settings.audio.noiseGateRmsThreshold"
        public static let streamingAutoEndEnabled = "settings.streaming.autoEndEnabled"
        public static let streamingKeepAliveEnabled = "settings.streaming.keepAliveEnabled"
        public static let streamingKeepAliveInterval = "settings.streaming.keepAliveInterval"
        public static let streamingReconnectEnabled = "settings.streaming.reconnectEnabled"
        public static let streamingMinimumFinalWordCount = "settings.streaming.minimumFinalWordCount"
        public static let streamingTrailingFinalTimeout = "settings.streaming.trailingFinalTimeout"
        public static let batchFinalizationTimeoutBase = "settings.batch.finalizationTimeoutBase"
        public static let batchFinalizationTimeoutPerChunkSecond = "settings.batch.finalizationTimeoutPerChunkSecond"
        public static let batchFinalizationMaxTimeout = "settings.batch.finalizationMaxTimeout"
        public static let minSpeechRatio = "settings.minSpeechRatio"
        public static let focusWaitTimeout = "settings.focusWaitTimeout"
        public static let hotkeyRestartsRecording = "settings.hotkeyRestartsRecording"
        public static let observabilityEnabled = "settings.observability.enabled"
        public static let observabilityVerbosity = "settings.observability.verbosity"
        public static let observabilityCaptureSettingsSnapshot = "settings.observability.captureSettingsSnapshot"
        public static let observabilityCaptureSystemContext = "settings.observability.captureSystemContext"
        public static let observabilityCaptureTextPayloads = "settings.observability.captureTextPayloads"
    }

    private let defaults: UserDefaults

    private init() {
        let isTestRun = Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })
        if isTestRun {
            let suiteName = "nu.rez.speakflow.tests.\(ProcessInfo.processInfo.processIdentifier)"
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
                return value > 0 ? value : Config.vadThreshold
            }
            return Config.vadThreshold
        }
        set {
            defaults.set(newValue, forKey: Keys.vadThreshold)
        }
    }

    // MARK: - VAD Volume Gate Settings

    /// Whether the volume gate is enabled.
    ///
    /// When enabled, a `speechStart` event from Silero is only forwarded when
    /// the audio's smoothed RMS also exceeds `vadMinVolumeForSpeech`. This
    /// prevents keyboard clicks, fan surges, and other non-vocal transients
    /// from triggering false speech detection.
    ///
    /// Disable if you use a very quiet microphone and legitimate speech is
    /// being suppressed. Default: true.
    public var vadVolumeGateEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.vadVolumeGateEnabled) == nil {
                return Config.vadVolumeGateEnabled
            }
            return defaults.bool(forKey: Keys.vadVolumeGateEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.vadVolumeGateEnabled)
        }
    }

    /// Minimum smoothed RMS amplitude (0–1) for a speechStart to pass the volume gate.
    ///
    /// Lower this if soft speech is being suppressed (e.g. quiet environment,
    /// distant microphone). Raise it if non-vocal noises keep triggering speech.
    ///
    /// Empirical ranges (MacBook Pro mic):
    ///   - Keyboard noise: ~0.002–0.005
    ///   - Quiet speech:   ~0.010–0.030
    /// Default 0.008 sits between them. Range: 0.001–0.050 is sensible.
    public var vadMinVolumeForSpeech: Float {
        get {
            if defaults.object(forKey: Keys.vadMinVolumeForSpeech) != nil {
                let value = defaults.float(forKey: Keys.vadMinVolumeForSpeech)
                return value > 0 ? value : Config.vadMinVolumeForSpeech
            }
            return Config.vadMinVolumeForSpeech
        }
        set {
            // Clamp to a sane range to prevent accidentally zeroing out the gate
            defaults.set(max(0.0001, min(0.1, newValue)), forKey: Keys.vadMinVolumeForSpeech)
        }
    }

    /// Exponential smoothing factor for the VAD volume gate (0...1).
    public var vadVolumeSmoothingFactor: Float {
        get {
            if defaults.object(forKey: Keys.vadVolumeSmoothingFactor) != nil {
                return defaults.float(forKey: Keys.vadVolumeSmoothingFactor)
            }
            return Config.vadVolumeSmoothingFactor
        }
        set {
            defaults.set(max(0.0, min(1.0, newValue)), forKey: Keys.vadVolumeSmoothingFactor)
        }
    }

    /// Seconds between periodic Silero hidden-state resets.
    public var vadStateResetInterval: Double {
        get {
            let value = defaults.double(forKey: Keys.vadStateResetInterval)
            return value > 0 ? value : Config.vadStateResetInterval
        }
        set {
            defaults.set(max(0.1, min(120.0, newValue)), forKey: Keys.vadStateResetInterval)
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

    /// Minimum session duration before auto-end is considered.
    public var autoEndMinSessionDuration: Double {
        get {
            let value = defaults.double(forKey: Keys.autoEndMinSessionDuration)
            return value > 0 ? value : Config.autoEndMinSessionDuration
        }
        set {
            defaults.set(max(0.0, min(30.0, newValue)), forKey: Keys.autoEndMinSessionDuration)
        }
    }

    /// Block auto-end until at least one speechStart has occurred.
    public var autoEndRequireSpeechFirst: Bool {
        get {
            if defaults.object(forKey: Keys.autoEndRequireSpeechFirst) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.autoEndRequireSpeechFirst)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoEndRequireSpeechFirst)
        }
    }

    /// End session after this many seconds if no speech is detected at all. 0 disables.
    public var autoEndNoSpeechTimeout: Double {
        get {
            guard defaults.object(forKey: Keys.autoEndNoSpeechTimeout) != nil else {
                return 10.0
            }
            return max(0.0, min(120.0, defaults.double(forKey: Keys.autoEndNoSpeechTimeout)))
        }
        set {
            defaults.set(max(0.0, min(120.0, newValue)), forKey: Keys.autoEndNoSpeechTimeout)
        }
    }

    /// Safety force-clear threshold for stuck speaking state. 0 disables.
    public var autoEndMaxContinuousSpeechDuration: Double {
        get {
            guard defaults.object(forKey: Keys.autoEndMaxContinuousSpeechDuration) != nil else {
                return 180.0
            }
            return max(0.0, min(1800.0, defaults.double(forKey: Keys.autoEndMaxContinuousSpeechDuration)))
        }
        set {
            defaults.set(max(0.0, min(1800.0, newValue)), forKey: Keys.autoEndMaxContinuousSpeechDuration)
        }
    }

    /// Thinking pause detection toggle.
    public var thinkingPauseEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.thinkingPauseEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.thinkingPauseEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.thinkingPauseEnabled)
        }
    }

    /// Extra silence allowance when thinking-pause is detected.
    public var thinkingPauseExtensionSeconds: Double {
        get {
            let value = defaults.double(forKey: Keys.thinkingPauseExtensionSeconds)
            return value > 0 ? value : 5.0
        }
        set {
            defaults.set(max(0.0, min(30.0, newValue)), forKey: Keys.thinkingPauseExtensionSeconds)
        }
    }

    /// SmartTurn-style classifier toggle.
    public var turnClassifierEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.turnClassifierEnabled) == nil {
                return Config.turnClassifierEnabled
            }
            return defaults.bool(forKey: Keys.turnClassifierEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.turnClassifierEnabled)
        }
    }

    /// Minimum post-speech silence before turn completion classifier runs.
    public var turnClassifierMinimumSilence: Double {
        get {
            let value = defaults.double(forKey: Keys.turnClassifierMinimumSilence)
            return value > 0 ? value : Config.turnClassifierMinimumSilence
        }
        set {
            defaults.set(max(0.2, min(15.0, newValue)), forKey: Keys.turnClassifierMinimumSilence)
        }
    }

    /// Additional silence allowance when classifier predicts incomplete turn.
    public var turnClassifierIncompleteExtensionSeconds: Double {
        get {
            let value = defaults.double(forKey: Keys.turnClassifierIncompleteExtensionSeconds)
            return value > 0 ? value : Config.turnClassifierIncompleteExtensionSeconds
        }
        set {
            defaults.set(max(0.0, min(30.0, newValue)), forKey: Keys.turnClassifierIncompleteExtensionSeconds)
        }
    }

    /// Completion threshold in [0,1].
    public var turnClassifierThreshold: Float {
        get {
            if defaults.object(forKey: Keys.turnClassifierThreshold) != nil {
                return defaults.float(forKey: Keys.turnClassifierThreshold)
            }
            return Config.turnClassifierThreshold
        }
        set {
            defaults.set(max(0.0, min(1.0, newValue)), forKey: Keys.turnClassifierThreshold)
        }
    }

    /// Enable idle nudge sequence before auto-end expiration.
    public var idleNudgeEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.idleNudgeEnabled) == nil {
                return Config.idleNudgeEnabled
            }
            return defaults.bool(forKey: Keys.idleNudgeEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.idleNudgeEnabled)
        }
    }

    /// Delay before first idle nudge (seconds).
    public var idleNudgeInitialDelay: Double {
        get {
            let value = defaults.double(forKey: Keys.idleNudgeInitialDelay)
            return value >= 0 ? value : Config.idleNudgeInitialDelay
        }
        set {
            defaults.set(max(0.0, min(30.0, newValue)), forKey: Keys.idleNudgeInitialDelay)
        }
    }

    /// Interval between idle nudges (seconds).
    public var idleNudgeInterval: Double {
        get {
            let value = defaults.double(forKey: Keys.idleNudgeInterval)
            return value > 0 ? value : Config.idleNudgeInterval
        }
        set {
            defaults.set(max(0.5, min(30.0, newValue)), forKey: Keys.idleNudgeInterval)
        }
    }

    /// Maximum number of nudges before expiration.
    public var idleNudgeMaxCount: Int {
        get {
            let value = defaults.integer(forKey: Keys.idleNudgeMaxCount)
            return value > 0 ? value : Config.idleNudgeMaxCount
        }
        set {
            defaults.set(max(1, min(10, newValue)), forKey: Keys.idleNudgeMaxCount)
        }
    }

    /// Enable lightweight pre-VAD noise gate.
    public var audioNoiseGateEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.audioNoiseGateEnabled) == nil {
                return Config.audioNoiseGateEnabled
            }
            return defaults.bool(forKey: Keys.audioNoiseGateEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.audioNoiseGateEnabled)
        }
    }

    /// RMS threshold for pre-VAD noise gate.
    public var audioNoiseGateRmsThreshold: Float {
        get {
            if defaults.object(forKey: Keys.audioNoiseGateRmsThreshold) != nil {
                return defaults.float(forKey: Keys.audioNoiseGateRmsThreshold)
            }
            return Config.audioNoiseGateRmsThreshold
        }
        set {
            defaults.set(max(0.0, min(0.05, newValue)), forKey: Keys.audioNoiseGateRmsThreshold)
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

    // MARK: - Observability

    /// Master switch for observability event capture.
    public var observabilityEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.observabilityEnabled) == nil {
                return Config.observabilityEnabled
            }
            return defaults.bool(forKey: Keys.observabilityEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.observabilityEnabled)
        }
    }

    /// Verbosity level for observability events.
    public var observabilityVerbosity: ObservabilityVerbosity {
        get {
            guard let raw = defaults.string(forKey: Keys.observabilityVerbosity),
                  let value = ObservabilityVerbosity(rawValue: raw) else {
                return Config.observabilityVerbosity
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.observabilityVerbosity)
        }
    }

    /// Capture structured settings snapshots in observability logs.
    public var observabilityCaptureSettingsSnapshot: Bool {
        get {
            if defaults.object(forKey: Keys.observabilityCaptureSettingsSnapshot) == nil {
                return Config.observabilityCaptureSettingsSnapshot
            }
            return defaults.bool(forKey: Keys.observabilityCaptureSettingsSnapshot)
        }
        set {
            defaults.set(newValue, forKey: Keys.observabilityCaptureSettingsSnapshot)
        }
    }

    /// Capture one-time runtime/system context in observability logs.
    public var observabilityCaptureSystemContext: Bool {
        get {
            if defaults.object(forKey: Keys.observabilityCaptureSystemContext) == nil {
                return Config.observabilityCaptureSystemContext
            }
            return defaults.bool(forKey: Keys.observabilityCaptureSystemContext)
        }
        set {
            defaults.set(newValue, forKey: Keys.observabilityCaptureSystemContext)
        }
    }

    /// Include raw transcript/keystroke payloads in observability events.
    public var observabilityCaptureTextPayloads: Bool {
        get {
            if defaults.object(forKey: Keys.observabilityCaptureTextPayloads) == nil {
                return Config.observabilityCaptureTextPayloads
            }
            return defaults.bool(forKey: Keys.observabilityCaptureTextPayloads)
        }
        set {
            defaults.set(newValue, forKey: Keys.observabilityCaptureTextPayloads)
        }
    }

    // MARK: - Streaming Auto-End

    /// Whether auto-end is enabled for streaming mode.
    public var streamingAutoEndEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.streamingAutoEndEnabled) == nil {
                // Enabled by default now that realtime auto-end behavior is stable.
                return true
            }
            return defaults.bool(forKey: Keys.streamingAutoEndEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.streamingAutoEndEnabled)
        }
    }

    /// Whether live streaming keepAlive pings are sent periodically.
    public var streamingKeepAliveEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.streamingKeepAliveEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.streamingKeepAliveEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.streamingKeepAliveEnabled)
        }
    }

    /// Interval between keepAlive pings (seconds).
    public var streamingKeepAliveInterval: Double {
        get {
            let value = defaults.double(forKey: Keys.streamingKeepAliveInterval)
            return value > 0 ? value : 8.0
        }
        set {
            defaults.set(max(1.0, min(30.0, newValue)), forKey: Keys.streamingKeepAliveInterval)
        }
    }

    /// Whether one automatic reconnect attempt is made after unexpected close.
    public var streamingReconnectEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.streamingReconnectEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.streamingReconnectEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.streamingReconnectEnabled)
        }
    }

    /// Minimum lexical words for non-speechFinal commits in streaming mode.
    public var streamingMinimumFinalWordCount: Int {
        get {
            let value = defaults.integer(forKey: Keys.streamingMinimumFinalWordCount)
            return value > 0 ? value : Config.defaultStreamingMinimumFinalWordCount
        }
        set {
            defaults.set(max(1, min(5, newValue)), forKey: Keys.streamingMinimumFinalWordCount)
        }
    }

    /// Maximum seconds to wait for server trailing finals after stop-finalize in
    /// streaming mode. Stop may finish earlier once trailing events go quiet.
    /// Must be ≥ 0.1 s and ≤ 30 s.
    public var streamingTrailingFinalTimeout: Double {
        get {
            let value = defaults.double(forKey: Keys.streamingTrailingFinalTimeout)
            return value > 0 ? value : 2.0
        }
        set {
            defaults.set(max(0.1, min(30.0, newValue)), forKey: Keys.streamingTrailingFinalTimeout)
        }
    }

    /// Minimum wait floor for batch finalization (seconds). Must be ≥ 1 s.
    public var batchFinalizationTimeoutBase: Double {
        get {
            let value = defaults.double(forKey: Keys.batchFinalizationTimeoutBase)
            return value > 0 ? value : 10.0
        }
        set {
            defaults.set(max(1.0, newValue), forKey: Keys.batchFinalizationTimeoutBase)
        }
    }

    /// Extra wait seconds per second of max chunk audio for batch finalization. Must be ≥ 0.
    ///
    /// The getter uses `object(forKey:)` to distinguish "never written" (→ return default 2.0)
    /// from "user explicitly set to 0" (→ return 0.0).  Using `double(forKey:) >= 0` would
    /// always return 0.0 on fresh installs because `UserDefaults.double` returns 0.0 when
    /// the key is absent, making `0.0 >= 0` evaluate to `true` and masking the default.
    public var batchFinalizationTimeoutPerChunkSecond: Double {
        get {
            guard defaults.object(forKey: Keys.batchFinalizationTimeoutPerChunkSecond) != nil else {
                return 2.0  // spec default: 2.0 s per second of chunk audio
            }
            return max(0.0, defaults.double(forKey: Keys.batchFinalizationTimeoutPerChunkSecond))
        }
        set {
            defaults.set(max(0.0, newValue), forKey: Keys.batchFinalizationTimeoutPerChunkSecond)
        }
    }

    /// Hard ceiling for batch finalization wait regardless of chunk size (seconds). Must be ≥ 10 s.
    public var batchFinalizationMaxTimeout: Double {
        get {
            let value = defaults.double(forKey: Keys.batchFinalizationMaxTimeout)
            return value > 0 ? value : 120.0
        }
        set {
            defaults.set(max(10.0, newValue), forKey: Keys.batchFinalizationMaxTimeout)
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

    // MARK: - Mistral Voxtral Realtime Settings

    private enum MistralKeys {
        static let model = "settings.mistral.model"
        static let batchModel = "settings.mistral.batchModel"
        static let language = "settings.mistral.language"
        static let temperature = "settings.mistral.temperature"
        static let diarize = "settings.mistral.diarize"
        static let contextBias = "settings.mistral.contextBias"
    }

    /// Mistral Voxtral realtime transcription model
    public var mistralModel: String {
        get {
            let stored = defaults.string(forKey: MistralKeys.model)
            // Migrate from -latest to -2602 if needed (latest alias not universally available)
            if stored == "voxtral-mini-transcribe-realtime-latest" {
                defaults.set("voxtral-mini-transcribe-realtime-2602", forKey: MistralKeys.model)
                return "voxtral-mini-transcribe-realtime-2602"
            }
            return stored ?? "voxtral-mini-transcribe-realtime-2602"
        }
        set { defaults.set(newValue, forKey: MistralKeys.model) }
    }

    /// Mistral Voxtral batch transcription model
    public var mistralBatchModel: String {
        get { defaults.string(forKey: MistralKeys.batchModel) ?? "voxtral-mini-latest" }
        set { defaults.set(newValue, forKey: MistralKeys.batchModel) }
    }

    /// Mistral Voxtral transcription language
    public var mistralLanguage: String {
        get { defaults.string(forKey: MistralKeys.language) ?? "en" }
        set { defaults.set(newValue, forKey: MistralKeys.language) }
    }

    /// Mistral transcription temperature (0.0 = deterministic, higher = more creative)
    public var mistralTemperature: Float {
        get {
            if defaults.object(forKey: MistralKeys.temperature) != nil {
                return defaults.float(forKey: MistralKeys.temperature)
            }
            return 0.0
        }
        set { defaults.set(newValue, forKey: MistralKeys.temperature) }
    }

    /// Whether to enable speaker diarization (batch mode only, not compatible with realtime)
    public var mistralDiarize: Bool {
        get {
            if defaults.object(forKey: MistralKeys.diarize) == nil { return false }
            return defaults.bool(forKey: MistralKeys.diarize)
        }
        set { defaults.set(newValue, forKey: MistralKeys.diarize) }
    }

    /// Context bias string (batch only): comma-separated terms to guide recognition.
    /// Up to 100 words/phrases per API spec. Empty = disabled.
    public var mistralContextBias: String {
        get { defaults.string(forKey: MistralKeys.contextBias) ?? "" }
        set { defaults.set(newValue, forKey: MistralKeys.contextBias) }
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
