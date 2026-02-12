import Foundation

// MARK: - Provider IDs

/// Canonical provider identifiers used across the app.
/// New providers should add their ID here to avoid scattered string literals.
public enum ProviderId {
    public static let chatGPT = "gpt"
    public static let deepgram = "deepgram"
}

// MARK: - Provider Mode & Auth

/// Whether a provider operates in batch or streaming mode.
public enum ProviderMode: String, Sendable, Hashable {
    case batch
    case streaming
}

/// How a provider authenticates — used by UI to show the right setup flow.
public enum ProviderAuthRequirement: Sendable {
    case oauth
    case apiKey(providerId: String)
    case none
}

// MARK: - Provider Protocol

/// A transcription provider that can convert audio to text.
///
/// Each provider is self-describing: it carries its own metadata (mode, auth requirement,
/// configuration status) so the app layer doesn't need hardcoded switch statements.
/// Conform to `BatchTranscriptionProvider` or `StreamingTranscriptionProvider` for the
/// actual transcription capability.
public protocol TranscriptionProvider: Sendable {
    /// Unique identifier for this provider (use constants from `ProviderId`)
    var id: String { get }

    /// Human-readable name
    var displayName: String { get }

    /// Whether this provider operates in batch or streaming mode.
    var mode: ProviderMode { get }

    /// Whether the provider is ready to use (credentials configured).
    var isConfigured: Bool { get }

    /// How this provider authenticates (OAuth, API key, etc.)
    var authRequirement: ProviderAuthRequirement { get }
}

extension TranscriptionProvider {
    /// Display name with mode label for UI (e.g. "ChatGPT — Batch").
    public var providerDisplayName: String {
        let modeLabel = mode == .streaming ? "Streaming" : "Batch"
        return "\(displayName) — \(modeLabel)"
    }
}

// MARK: - API Key Validation

/// Providers that authenticate via API key can conform to validate keys before saving.
/// Returns nil on success, or a user-facing error message on failure.
public protocol APIKeyValidatable: Sendable {
    func validateAPIKey(_ key: String) async -> String?
}

// MARK: - Batch Provider

/// A provider that transcribes a complete audio file and returns text.
/// Audio is recorded locally, then sent as a single request after recording stops.
public protocol BatchTranscriptionProvider: TranscriptionProvider {
    /// Transcribe a complete audio buffer and return the resulting text.
    func transcribe(audio: Data) async throws -> String
}

// MARK: - Streaming Provider

/// A provider that supports real-time audio streaming with live transcription.
/// Audio is sent continuously and transcription results arrive as the user speaks.
public protocol StreamingTranscriptionProvider: TranscriptionProvider {
    /// Start a streaming session. Returns a session object for sending audio and receiving results.
    func startSession(config: StreamingSessionConfig) async throws -> StreamingSession

    /// Build session configuration from the provider's stored settings.
    /// Default implementation returns `StreamingSessionConfig.default`.
    @MainActor func buildSessionConfig() -> StreamingSessionConfig
}

extension StreamingTranscriptionProvider {
    @MainActor public func buildSessionConfig() -> StreamingSessionConfig { .default }
}

// MARK: - Session Config

/// Configuration for a streaming transcription session.
public struct StreamingSessionConfig: Sendable {
    public var language: String
    public var sampleRate: Int
    public var encoding: AudioEncoding
    public var interimResults: Bool
    public var smartFormat: Bool
    public var endpointingMs: Int
    public var model: String

    public init(
        language: String = "en-US",
        sampleRate: Int = 16000,
        encoding: AudioEncoding = .linear16,
        interimResults: Bool = true,
        smartFormat: Bool = true,
        endpointingMs: Int = 300,
        model: String = "nova-3"
    ) {
        self.language = language
        self.sampleRate = sampleRate
        self.encoding = encoding
        self.interimResults = interimResults
        self.smartFormat = smartFormat
        self.endpointingMs = endpointingMs
        self.model = model
    }

    public static let `default` = StreamingSessionConfig()
}

public enum AudioEncoding: String, Sendable {
    case linear16
    case linear32
    case flac
    case opus
    case mulaw
    case alaw
}

// MARK: - Streaming Session

/// An active streaming transcription session.
/// Send audio data and receive transcription events.
public protocol StreamingSession: Sendable {
    /// Send raw audio bytes to the transcription engine.
    func sendAudio(_ data: Data) async throws

    /// Signal that the current utterance is complete (flush pending audio).
    func finalize() async throws

    /// End the session and close the connection.
    func close() async throws

    /// Send a keep-alive to prevent timeout.
    func keepAlive() async throws

    /// Stream of transcription events from the server.
    var events: AsyncStream<TranscriptionEvent> { get }
}

// MARK: - Events

/// Events received from a streaming transcription provider.
public enum TranscriptionEvent: Sendable {
    /// Interim (partial) transcription — will be replaced by subsequent updates.
    case interim(TranscriptionResult)

    /// Final transcription for a segment — will not change.
    case finalResult(TranscriptionResult)

    /// The user has stopped speaking (utterance boundary detected by the provider).
    case utteranceEnd(lastWordEnd: Double)

    /// The user has started speaking.
    case speechStarted(timestamp: Double)

    /// Session metadata received.
    case metadata(requestId: String)

    /// An error occurred.
    case error(Error)

    /// The connection was closed.
    case closed
}

/// A transcription result with text and timing info.
public struct TranscriptionResult: Sendable {
    public let transcript: String
    public let confidence: Double
    public let start: Double
    public let duration: Double
    public let words: [WordInfo]
    public let isFinal: Bool
    public let speechFinal: Bool

    public init(
        transcript: String,
        confidence: Double = 0,
        start: Double = 0,
        duration: Double = 0,
        words: [WordInfo] = [],
        isFinal: Bool = false,
        speechFinal: Bool = false
    ) {
        self.transcript = transcript
        self.confidence = confidence
        self.start = start
        self.duration = duration
        self.words = words
        self.isFinal = isFinal
        self.speechFinal = speechFinal
    }
}

/// Word-level timing information.
public struct WordInfo: Sendable {
    public let word: String
    public let start: Double
    public let end: Double
    public let confidence: Double

    public init(word: String, start: Double, end: Double, confidence: Double) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

// MARK: - Provider Settings

/// Stores API keys and settings for transcription providers.
/// Keys are stored in the unified `~/.speakflow/auth.json` via `UnifiedAuthStorage`.
/// Environment variables (e.g. DEEPGRAM_API_KEY) are checked as fallback for CI/testing.
@MainActor
public final class ProviderSettings {
    public static let shared = ProviderSettings()

    private let storage = UnifiedAuthStorage.shared

    private enum Keys {
        static let activeProvider = "provider.active"
    }

    private init() {}

    // MARK: - Active Provider

    /// The currently active provider ID.
    public var activeProviderId: String {
        get { UserDefaults.standard.string(forKey: Keys.activeProvider) ?? ProviderId.chatGPT }
        set { UserDefaults.standard.set(newValue, forKey: Keys.activeProvider) }
    }

    // MARK: - API Key Storage (delegated to UnifiedAuthStorage)

    /// Get the API key for a provider.
    /// Checks unified auth storage first, then falls back to environment variable for CI/testing.
    public func apiKey(for providerId: String) -> String? {
        // 1. Unified file storage (primary — set by the user via settings)
        if let key = storage.apiKey(for: providerId), !key.isEmpty {
            return key
        }

        // 2. Environment variable fallback (for CI/testing only)
        let envName = "\(providerId.uppercased())_API_KEY"
        if let envKey = ProcessInfo.processInfo.environment[envName], !envKey.isEmpty {
            return envKey
        }

        return nil
    }

    /// Save the API key for a provider to unified auth storage.
    public func setApiKey(_ apiKey: String?, for providerId: String) {
        storage.setApiKey(apiKey, for: providerId)
    }

    /// Check if a provider has an API key configured (file or env).
    public func hasApiKey(for providerId: String) -> Bool {
        apiKey(for: providerId) != nil
    }

    /// Remove the stored API key for a provider.
    public func removeApiKey(for providerId: String) {
        storage.removeApiKey(for: providerId)
    }

}
