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

    public init() {}

    @MainActor
    public func buildSessionConfig() -> StreamingSessionConfig {
        StreamingSessionConfig(
            language: Settings.shared.deepgramLanguage,
            interimResults: Settings.shared.deepgramInterimResults,
            smartFormat: Settings.shared.deepgramSmartFormat,
            endpointingMs: Settings.shared.deepgramEndpointingMs,
            model: Settings.shared.deepgramModel
        )
    }

    public func startSession(config: StreamingSessionConfig) async throws -> StreamingSession {
        let apiKey = await ProviderSettings.shared.apiKey(for: id)
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
    public nonisolated func validateAPIKey(_ key: String) async -> String? {
        let url = URL(string: "https://api.deepgram.com/v1/projects")!
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

    private func buildURL() -> URL {
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
        return components.url!
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

    private func parseMessage(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        do {
            let msg = try JSONDecoder().decode(DeepgramMessage.self, from: data)

            switch msg.type {
            case "Results":
                guard let channel = msg.channel,
                      let alt = channel.alternatives.first else { return }

                let words = alt.words?.map { w in
                    WordInfo(word: w.punctuated_word ?? w.word, start: w.start, end: w.end, confidence: w.confidence)
                } ?? []

                let result = TranscriptionResult(
                    transcript: alt.transcript,
                    confidence: alt.confidence,
                    start: msg.start ?? 0,
                    duration: msg.duration ?? 0,
                    words: words,
                    isFinal: msg.is_final ?? false,
                    speechFinal: msg.speech_final ?? false
                )

                if msg.is_final == true {
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
                let lastWordEnd = msg.last_word_end ?? 0
                eventContinuation?.yield(.utteranceEnd(lastWordEnd: lastWordEnd))
                logger.info("UtteranceEnd at \(String(format: "%.2f", lastWordEnd))s")

            case "SpeechStarted":
                let timestamp = msg.timestamp ?? 0
                eventContinuation?.yield(.speechStarted(timestamp: timestamp))
                logger.debug("SpeechStarted at \(String(format: "%.2f", timestamp))s")

            case "Metadata":
                let requestId = msg.request_id ?? "unknown"
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
    let is_final: Bool?
    let speech_final: Bool?
    let start: Double?
    let duration: Double?
    let from_finalize: Bool?
    // Metadata fields
    let request_id: String?
    let transaction_key: String?
    // UtteranceEnd fields
    let last_word_end: Double?
    // SpeechStarted fields
    let timestamp: Double?
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
    let punctuated_word: String?
}
