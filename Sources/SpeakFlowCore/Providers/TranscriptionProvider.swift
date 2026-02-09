import Foundation

// MARK: - Provider Protocol

/// A transcription provider that can convert audio to text.
/// Implementations may be batch (send file, get text) or streaming (send audio stream, get live text).
public protocol TranscriptionProvider: Sendable {
    /// Unique identifier for this provider (e.g. "deepgram", "gpt")
    var id: String { get }

    /// Human-readable name
    var displayName: String { get }

    /// Whether this provider supports real-time streaming
    var supportsStreaming: Bool { get }
}

// MARK: - Streaming Provider

/// A provider that supports real-time audio streaming with live transcription.
/// Audio is sent continuously and transcription results arrive as the user speaks.
public protocol StreamingTranscriptionProvider: TranscriptionProvider {
    /// Start a streaming session. Returns a session object for sending audio and receiving results.
    func startSession(config: StreamingSessionConfig) async throws -> StreamingSession
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
/// Keys are stored in `~/.speakflow/<provider>.json` with restricted permissions (600),
/// matching the OpenAI credential storage pattern.
/// Environment variables (e.g. DEEPGRAM_API_KEY) are checked as fallback for CI/testing.
@MainActor
public final class ProviderSettings {
    public static let shared = ProviderSettings()

    private enum Keys {
        static let activeProvider = "provider.active"
    }

    private init() {}

    // MARK: - Active Provider

    /// The currently active provider ID ("gpt" or "deepgram").
    public var activeProviderId: String {
        get { UserDefaults.standard.string(forKey: Keys.activeProvider) ?? "gpt" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.activeProvider) }
    }

    // MARK: - API Key Storage (file-based, like OpenAI credentials)

    private static var speakflowDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".speakflow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func keyFileURL(for providerId: String) -> URL {
        speakflowDir.appendingPathComponent("\(providerId).json")
    }

    /// Get the API key for a provider.
    /// Checks file storage first, then falls back to environment variable for CI/testing.
    public func apiKey(for providerId: String) -> String? {
        // 1. File storage (primary — set by the user via menu)
        if let key = loadKeyFromFile(providerId: providerId), !key.isEmpty {
            return key
        }

        // 2. Environment variable fallback (for CI/testing only)
        let envName = envVarName(for: providerId)
        if let envKey = ProcessInfo.processInfo.environment[envName], !envKey.isEmpty {
            return envKey
        }

        return nil
    }

    /// Save the API key for a provider to `~/.speakflow/<provider>.json`.
    public func setApiKey(_ apiKey: String?, for providerId: String) {
        let fileURL = Self.keyFileURL(for: providerId)

        if let apiKey, !apiKey.isEmpty {
            let payload: [String: String] = ["api_key": apiKey]
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
                )
            }
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Check if a provider has an API key configured (file or env).
    public func hasApiKey(for providerId: String) -> Bool {
        apiKey(for: providerId) != nil
    }

    /// Remove the stored API key for a provider.
    public func removeApiKey(for providerId: String) {
        let fileURL = Self.keyFileURL(for: providerId)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Validation

    /// Validate a Deepgram API key by calling the /v1/projects endpoint (free, no cost).
    /// Returns nil on success, or an error message on failure.
    public nonisolated func validateDeepgramKey(_ apiKey: String) async -> String? {
        let url = URL(string: "https://api.deepgram.com/v1/projects")!
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Invalid response from Deepgram"
            }
            switch http.statusCode {
            case 200: return nil  // Valid key
            case 401, 403: return "Invalid API key (authentication failed)"
            default: return "Unexpected response (HTTP \(http.statusCode))"
            }
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func loadKeyFromFile(providerId: String) -> String? {
        let fileURL = Self.keyFileURL(for: providerId)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict["api_key"]
    }

    private func envVarName(for providerId: String) -> String {
        "\(providerId.uppercased())_API_KEY"
    }
}
