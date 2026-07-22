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
        hasAPIKey(id)
    }

    private let logger = Logger(subsystem: "SpeakFlow", category: "Deepgram")
    private let settings: any StreamingSettingsProviding
    private let providerSettings: any ProviderSettingsProviding
    private let hasAPIKey: @Sendable (String) -> Bool

    @MainActor
    public convenience init(
        settings: any StreamingSettingsProviding = Settings.shared,
        providerSettings: any ProviderSettingsProviding = ProviderSettings.shared
    ) {
        self.init(
            settings: settings,
            providerSettings: providerSettings,
            hasAPIKey: { ProviderAPIKeys.hasAPIKey(for: $0) }
        )
    }

    @MainActor
    init(
        settings: any StreamingSettingsProviding = Settings.shared,
        providerSettings: any ProviderSettingsProviding = ProviderSettings.shared,
        hasAPIKey: @escaping @Sendable (String) -> Bool
    ) {
        self.settings = settings
        self.providerSettings = providerSettings
        self.hasAPIKey = hasAPIKey
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
    case handshakeRejected(statusCode: Int)
    case handshakeTimedOut
    case invalidResponse(String)
    case webSocketError(Error)
    case sessionClosed

    public var errorDescription: String? {
        switch self {
        case .missingApiKey: return "Deepgram API key not configured"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .handshakeRejected(let statusCode):
            return "Deepgram WebSocket handshake rejected (HTTP \(statusCode))"
        case .handshakeTimedOut:
            return "Deepgram WebSocket handshake timed out"
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
    private let logger: any ProviderLogging

    private let core: WebSocketSessionCore
    private var messageSequence: UInt64 = 0
    private let handshakeTimeout: TimeInterval

    public nonisolated var events: AsyncStream<TranscriptionEvent> {
        core.events
    }

    init(
        apiKey: String,
        config: StreamingSessionConfig,
        handshakeTimeout: TimeInterval = 10,
        connectionFactory: @escaping WebSocketConnectionFactory = { request, timeout in
            try await WebSocketConnector.connect(request: request, timeout: timeout)
        },
        logger: any ProviderLogging = OSLogProviderLogger(category: "DeepgramSession")
    ) {
        self.apiKey = apiKey
        self.config = config
        self.handshakeTimeout = handshakeTimeout
        self.logger = logger
        self.core = WebSocketSessionCore(
            component: "DeepgramSession",
            connectionFactory: connectionFactory,
            receiveErrorMapper: { DeepgramError.webSocketError($0) }
        )
    }

    public func setObservabilitySessionId(_ sessionId: UUID?) async {
        await core.setObservabilitySessionId(sessionId)
    }

    func connect() async throws {
        let url = buildURL()
        logger.log("Connecting to Deepgram: \(url.absoluteString)", level: .info, visibility: .public)

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        var openedTransport = false
        do {
            try await core.connect(request: request, timeout: handshakeTimeout)
            openedTransport = true
            try await core.startReceiving { [weak self] text in
                await self?.parseMessage(text)
            }
            logger.log("WebSocket handshake completed", level: .info, visibility: .public)
        } catch {
            if openedTransport {
                await core.close(code: .goingAway)
            }
            throw Self.connectionError(from: error)
        }
    }

    public func sendAudio(_ data: Data) async throws {
        try await core.send(.data(data), disconnectedError: DeepgramError.sessionClosed)
    }

    public func finalize() async throws {
        let msg = #"{"type":"Finalize"}"#
        try await core.send(.string(msg), disconnectedError: DeepgramError.sessionClosed)
        logger.log("Sent Finalize", level: .debug, visibility: .public)
    }

    public func close() async throws {
        if await core.isConnected {
            let msg = #"{"type":"CloseStream"}"#
            try? await core.send(.string(msg), disconnectedError: DeepgramError.sessionClosed)
        }
        await core.close()
        logger.log("WebSocket closed", level: .info, visibility: .public)
    }

    public func keepAlive() async throws {
        guard await core.isConnected else { return }
        let msg = #"{"type":"KeepAlive"}"#
        try await core.send(.string(msg), disconnectedError: DeepgramError.sessionClosed)
    }

    // MARK: - Private

    private func observabilityEvent(
        _ name: String,
        level: ObservabilityEventLevel = .debug,
        metadata: @autoclosure () -> [String: String] = [:]
    ) {
        let payload = metadata()
        Task {
            await core.recordObservabilityEvent(name, level: level, metadata: payload)
        }
    }

    private func nextMessageSequence() -> UInt64 {
        messageSequence &+= 1
        return messageSequence
    }

    private func metadataForTranscript(_ text: String) -> [String: String] {
        [
            "transcriptChars": String(text.count),
            "transcriptWords": String(text.split(whereSeparator: \.isWhitespace).count),
            "transcriptFingerprint": ObservabilityFingerprint.sha256(text)
        ]
    }

    private static func extractMessageType(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        return type
    }

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

    func parseMessage(_ json: String) async {
        guard let data = json.data(using: .utf8) else { return }
        let observedSequence = nextMessageSequence()
        let hintedType = Self.extractMessageType(from: data) ?? "unknown"

        do {
            let msg = try JSONDecoder().decode(DeepgramMessage.self, from: data)

            switch msg.type {
            case "Results":
                guard let channel = msg.channel?.alternatives,
                      let alt = channel.first else { return }
                observabilityEvent(
                    "provider_message",
                    metadata: [
                        "providerMessageSequence": String(observedSequence),
                        "messageType": msg.type,
                        "isFinal": msg.isFinal == true ? "true" : "false",
                        "speechFinal": msg.speechFinal == true ? "true" : "false"
                    ].merging(metadataForTranscript(alt.transcript), uniquingKeysWith: { _, new in new })
                )

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
                    await core.yield(.finalResult(result))
                    if !alt.transcript.isEmpty {
                        logger.log("FINAL: \(alt.transcript)", level: .info, visibility: .privateHash)
                    }
                } else {
                    await core.yield(.interim(result))
                    if !alt.transcript.isEmpty {
                        logger.log("interim: \(alt.transcript)", level: .debug, visibility: .privateHash)
                    }
                }

            case "UtteranceEnd":
                observabilityEvent(
                    "provider_message",
                    metadata: [
                        "providerMessageSequence": String(observedSequence),
                        "messageType": msg.type,
                        "lastWordEnd": String(format: "%.3f", msg.lastWordEnd ?? 0)
                    ]
                )
                let lastWordEnd = msg.lastWordEnd ?? 0
                await core.yield(.utteranceEnd(lastWordEnd: lastWordEnd))
                logger.log("UtteranceEnd at \(String(format: "%.2f", lastWordEnd))s", level: .info, visibility: .public)

            case "SpeechStarted":
                observabilityEvent(
                    "provider_message",
                    metadata: [
                        "providerMessageSequence": String(observedSequence),
                        "messageType": msg.type,
                        "timestamp": String(format: "%.3f", msg.timestamp ?? 0)
                    ]
                )
                let timestamp = msg.timestamp ?? 0
                await core.yield(.speechStarted(timestamp: timestamp))
                logger.log("SpeechStarted at \(String(format: "%.2f", timestamp))s", level: .debug, visibility: .public)

            case "Metadata":
                observabilityEvent(
                    "provider_message",
                    metadata: [
                        "providerMessageSequence": String(observedSequence),
                        "messageType": msg.type,
                        "requestId": msg.requestId ?? "unknown"
                    ]
                )
                let requestId = msg.requestId ?? "unknown"
                await core.yield(.metadata(requestId: requestId))
                logger.log("Session metadata: requestId=\(requestId)", level: .info, visibility: .public)

            default:
                observabilityEvent(
                    "provider_message",
                    metadata: [
                        "providerMessageSequence": String(observedSequence),
                        "messageType": msg.type
                    ]
                )
                logger.log("Unknown message type: \(msg.type)", level: .debug, visibility: .public)
            }
        } catch {
            let metadata: [String: String] = [
                "providerMessageSequence": String(observedSequence),
                "messageType": hintedType,
                "payloadChars": String(json.count),
                "payloadFingerprint": ObservabilityFingerprint.sha256(json),
                "error": error.localizedDescription
            ]
            observabilityEvent("provider_message_parse_failed", level: .error, metadata: metadata)
            logger.log("Failed to parse message: \(error.localizedDescription)", level: .error, visibility: .public)
        }
    }

    private static func connectionError(from error: Error) -> Error {
        if error is CancellationError || error is DeepgramError {
            return error
        }
        guard let connectionError = error as? WebSocketConnectionError else {
            return DeepgramError.connectionFailed(error.localizedDescription)
        }

        switch connectionError {
        case .handshakeRejected(let statusCode):
            return DeepgramError.handshakeRejected(statusCode: statusCode)
        case .handshakeTimedOut, .messageTimedOut:
            return DeepgramError.handshakeTimedOut
        case .connectionFailed(let message):
            return DeepgramError.connectionFailed(message)
        case .connectionAlreadyInProgress:
            return DeepgramError.connectionFailed("Connection already in progress")
        case .alreadyConnected:
            return DeepgramError.connectionFailed("Session is already connected")
        }
    }

#if DEBUG
    // swiftlint:disable identifier_name
    func _testSetConnected(_ connected: Bool) async {
        await core._testSetConnected(connected)
    }

    func _testSetURLSession(_ session: URLSession?) async {
        await core._testSetURLSession(session)
    }

    func _testDidInvalidateURLSession() async -> Bool {
        await core._testDidInvalidateConnection()
    }

    func _testIsConnected() async -> Bool {
        await core.isConnected
    }

    func _testFinishReceiveLoop(after error: Error) async {
        await core._testFinishReceiveLoop(after: error)
    }

    func _testObservabilitySessionId() async -> UUID? {
        await core._testObservabilitySessionId()
    }
    // swiftlint:enable identifier_name
#endif
}

// MARK: - Deepgram JSON Models

private struct DeepgramMessage: Decodable {
    let type: String
    // Results fields
    let channel: DeepgramChannelPayload?
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

private enum DeepgramChannelPayload: Decodable {
    case alternatives(DeepgramChannel)
    case indexes([Int])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let channel = try? container.decode(DeepgramChannel.self) {
            self = .alternatives(channel)
            return
        }
        if let indexes = try? container.decode([Int].self) {
            self = .indexes(indexes)
            return
        }
        throw DecodingError.typeMismatch(
            DeepgramChannelPayload.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected channel object or channel index array"
            )
        )
    }

    var alternatives: [DeepgramAlternative]? {
        guard case .alternatives(let channel) = self else { return nil }
        return channel.alternatives
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
