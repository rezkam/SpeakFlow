import Foundation
import OSLog

// MARK: - Deepgram Provider

/// Deepgram Nova-3 streaming transcription provider.
/// Connects via WebSocket and streams audio in real-time.
public final class DeepgramProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    public let id = ProviderId.deepgram
    public let displayName = "Deepgram"
    public let mode: ProviderMode = .streaming
    public var authRequirement: ProviderAuthRequirement { .apiKey(providerId: ProviderId.deepgram) }

    public var isConfigured: Bool {
        UnifiedAuthStorage.shared.apiKey(for: id) != nil
    }

    private let logger = Logger(subsystem: "SpeakFlow", category: "Deepgram")
    private let settings: any StreamingSettingsProviding
    private let providerSettings: any ProviderSettingsProviding

    @MainActor
    public init(
        settings: any StreamingSettingsProviding = Settings.shared,
        providerSettings: any ProviderSettingsProviding = ProviderSettings.shared
    ) {
        self.settings = settings
        self.providerSettings = providerSettings
    }

    @MainActor
    public func buildSessionConfig() -> StreamingSessionConfig {
        StreamingSessionConfig(
            language: settings.deepgramLanguage,
            interimResults: settings.deepgramInterimResults,
            smartFormat: settings.deepgramSmartFormat,
            endpointingMs: settings.deepgramEndpointingMs,
            model: settings.deepgramModel
        )
    }

    public func startSession(config: StreamingSessionConfig) async throws -> StreamingSession {
        let apiKey = await providerSettings.apiKey(for: id)
        guard let apiKey, !apiKey.isEmpty else {
            throw DeepgramError.missingApiKey
        }

        let session = DeepgramStreamingSession(apiKey: apiKey, config: config)
        try await session.connect()
        return session
    }
}

// MARK: - API Key Validation

extension DeepgramProvider: APIKeyValidatable {
    /// Validate a Deepgram API key by calling the /v1/projects endpoint (free, no cost).
    /// Returns nil on success, or a user-facing error message on failure.
    private static let validationEndpoint: URL = {
        guard let url = URL(string: "https://api.deepgram.com/v1/projects") else {
            preconditionFailure("Invalid Deepgram validation URL constant")
        }
        return url
    }()

    public nonisolated func validateAPIKey(_ key: String) async -> String? {
        let url = Self.validationEndpoint
        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Invalid response from Deepgram"
            }
            switch http.statusCode {
            case 200: return nil
            case 401, 403: return "Invalid API key (authentication failed)"
            default: return "Unexpected response (HTTP \(http.statusCode))"
            }
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Errors

public enum DeepgramError: Error, LocalizedError {
    case missingApiKey
    case connectionFailed(String)
    case invalidResponse(String)
    case webSocketError(Error)
    case sessionClosed

    public var errorDescription: String? {
        switch self {
        case .missingApiKey: return "Deepgram API key not configured"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .webSocketError(let err): return "WebSocket error: \(err.localizedDescription)"
        case .sessionClosed: return "Session is closed"
        }
    }
}

// MARK: - Streaming Session

/// A live WebSocket session to Deepgram's streaming API.
public actor DeepgramStreamingSession: StreamingSession {
    private let apiKey: String
    private let config: StreamingSessionConfig
    private let logger = Logger(subsystem: "SpeakFlow", category: "DeepgramSession")

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var eventContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private let _events: AsyncStream<TranscriptionEvent>
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?

    public nonisolated var events: AsyncStream<TranscriptionEvent> {
        _events
    }

    init(apiKey: String, config: StreamingSessionConfig) {
        self.apiKey = apiKey
        self.config = config

        // Create the event stream — _events is a let, safe for nonisolated access
        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        self._events = AsyncStream<TranscriptionEvent> { c in
            continuation = c
        }
        self.eventContinuation = continuation
    }

    func connect() async throws {
        let url = buildURL()
        logger.info("Connecting to Deepgram: \(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: request)

        self.urlSession = session
        self.webSocketTask = wsTask

        wsTask.resume()
        isConnected = true

        logger.info("WebSocket connected")

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func sendAudio(_ data: Data) async throws {
        guard isConnected, let ws = webSocketTask else {
            throw DeepgramError.sessionClosed
        }
        try await ws.send(.data(data))
    }

    public func finalize() async throws {
        guard isConnected, let ws = webSocketTask else {
            throw DeepgramError.sessionClosed
        }
        let msg = #"{"type":"Finalize"}"#
        try await ws.send(.string(msg))
        logger.debug("Sent Finalize")
    }

    public func close() async throws {
        guard isConnected else { return }
        isConnected = false

        if let ws = webSocketTask {
            let msg = #"{"type":"CloseStream"}"#
            try? await ws.send(.string(msg))
            ws.cancel(with: .normalClosure, reason: nil)
            logger.info("WebSocket closed")
        }

        receiveTask?.cancel()
        receiveTask = nil
        eventContinuation?.finish()
    }

    public func keepAlive() async throws {
        guard isConnected, let ws = webSocketTask else { return }
        let msg = #"{"type":"KeepAlive"}"#
        try await ws.send(.string(msg))
    }

    // MARK: - Private

    func buildURL() -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.deepgram.com"
        components.path = "/v1/listen"
        components.queryItems = [
            URLQueryItem(name: "model", value: config.model),
            URLQueryItem(name: "language", value: config.language),
            URLQueryItem(name: "encoding", value: config.encoding.rawValue),
            URLQueryItem(name: "sample_rate", value: String(config.sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: config.interimResults ? "true" : "false"),
            URLQueryItem(name: "smart_format", value: config.smartFormat ? "true" : "false"),
            URLQueryItem(name: "endpointing", value: String(config.endpointingMs)),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "vad_events", value: "true"),
            URLQueryItem(name: "utterance_end_ms", value: "1500"),
        ]
        guard let url = components.url else {
            preconditionFailure("Failed to construct Deepgram WebSocket URL from valid components")
        }
        return url
    }

    private func receiveLoop() async {
        guard let ws = webSocketTask else { return }

        while isConnected && !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    parseMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        parseMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if isConnected {
                    logger.error("WebSocket receive error: \(error.localizedDescription)")
                    eventContinuation?.yield(.error(DeepgramError.webSocketError(error)))
                    isConnected = false
                }
                break
            }
        }

        eventContinuation?.yield(.closed)
        eventContinuation?.finish()
    }

    func parseMessage(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        do {
            let msg = try JSONDecoder().decode(DeepgramMessage.self, from: data)

            switch msg.type {
            case "Results":
                guard let channel = msg.channel,
                      let alt = channel.alternatives.first else { return }

                let words = alt.words?.map { w in
                    WordInfo(word: w.punctuatedWord ?? w.word, start: w.start, end: w.end, confidence: w.confidence)
                } ?? []

                let result = TranscriptionResult(
                    transcript: alt.transcript,
                    confidence: alt.confidence,
                    start: msg.start ?? 0,
                    duration: msg.duration ?? 0,
                    words: words,
                    isFinal: msg.isFinal ?? false,
                    speechFinal: msg.speechFinal ?? false
                )

                if msg.isFinal == true {
                    eventContinuation?.yield(.finalResult(result))
                    if !alt.transcript.isEmpty {
                        logger.info("FINAL: \(alt.transcript, privacy: .public)")
                    }
                } else {
                    eventContinuation?.yield(.interim(result))
                    if !alt.transcript.isEmpty {
                        logger.debug("interim: \(alt.transcript, privacy: .public)")
                    }
                }

            case "UtteranceEnd":
                let lastWordEnd = msg.lastWordEnd ?? 0
                eventContinuation?.yield(.utteranceEnd(lastWordEnd: lastWordEnd))
                logger.info("UtteranceEnd at \(String(format: "%.2f", lastWordEnd))s")

            case "SpeechStarted":
                let timestamp = msg.timestamp ?? 0
                eventContinuation?.yield(.speechStarted(timestamp: timestamp))
                logger.debug("SpeechStarted at \(String(format: "%.2f", timestamp))s")

            case "Metadata":
                let requestId = msg.requestId ?? "unknown"
                eventContinuation?.yield(.metadata(requestId: requestId))
                logger.info("Session metadata: requestId=\(requestId, privacy: .public)")

            default:
                logger.debug("Unknown message type: \(msg.type, privacy: .public)")
            }
        } catch {
            logger.error("Failed to parse message: \(error.localizedDescription)")
        }
    }
}

// MARK: - Deepgram JSON Models

private struct DeepgramMessage: Decodable {
    let type: String
    // Results fields
    let channel: DeepgramChannel?
    let isFinal: Bool?
    let speechFinal: Bool?
    let start: Double?
    let duration: Double?
    let fromFinalize: Bool?
    // Metadata fields
    let requestId: String?
    let transactionKey: String?
    // UtteranceEnd fields
    let lastWordEnd: Double?
    // SpeechStarted fields
    let timestamp: Double?

    enum CodingKeys: String, CodingKey {
        case type, channel, start, duration, timestamp
        case isFinal = "is_final"
        case speechFinal = "speech_final"
        case fromFinalize = "from_finalize"
        case requestId = "request_id"
        case transactionKey = "transaction_key"
        case lastWordEnd = "last_word_end"
    }
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]
}

private struct DeepgramAlternative: Decodable {
    let transcript: String
    let confidence: Double
    let words: [DeepgramWord]?
}

private struct DeepgramWord: Decodable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double
    let punctuatedWord: String?

    enum CodingKeys: String, CodingKey {
        case word, start, end, confidence
        case punctuatedWord = "punctuated_word"
    }
}
