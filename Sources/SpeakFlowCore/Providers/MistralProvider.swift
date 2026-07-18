import Foundation
import OSLog

// MARK: - Mistral Provider

/// Mistral Voxtral Realtime streaming transcription provider.
/// Connects via WebSocket to Mistral's realtime transcription API and streams audio in real-time.
/// Uses the `voxtral-mini-transcribe-realtime-latest` model for low-latency live transcription.
///
/// Protocol (from mistralai/client-python SDK):
/// - WebSocket URL: `wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=...`
/// - Auth: `Authorization: Bearer <key>` header
/// - Audio: PCM s16le, 16kHz, mono — base64-encoded in JSON messages
/// - Segment-based: deltas accumulate, segments finalize with timing info
public final class MistralProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    public let id = ProviderId.mistral
    public let displayName = "Mistral"
    public let mode: ProviderMode = .streaming
    public var authRequirement: ProviderAuthRequirement { .apiKey(providerId: ProviderId.mistral) }

    public var isConfigured: Bool {
        hasAPIKey(id)
    }

    private let logger = Logger(subsystem: "SpeakFlow", category: "Mistral")
    private let settings: any MistralSettingsProviding
    private let providerSettings: any ProviderSettingsProviding
    private let hasAPIKey: @Sendable (String) -> Bool

    @MainActor
    public convenience init(
        settings: any MistralSettingsProviding = Settings.shared,
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
        settings: any MistralSettingsProviding = Settings.shared,
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
            language: settings.mistralLanguage,
            sampleRate: 16000,
            encoding: .linear16,
            interimResults: true,
            smartFormat: false,
            endpointingMs: 300,
            model: settings.mistralModel
        )
    }

    public func startSession(config: StreamingSessionConfig) async throws -> StreamingSession {
        let apiKey = await providerSettings.apiKey(for: id)
        guard let apiKey, !apiKey.isEmpty else {
            throw MistralError.missingApiKey
        }

        let session = MistralStreamingSession(apiKey: apiKey, config: config)
        try await session.connect()
        return session
    }
}

// MARK: - API Key Validation

extension MistralProvider: APIKeyValidatable {
    /// Validate a Mistral API key by calling the /v1/models endpoint (lightweight, no cost).
    /// Returns nil on success, or a user-facing error message on failure.
    private static let validationEndpoint: URL = {
        guard let url = URL(string: "https://api.mistral.ai/v1/models") else {
            preconditionFailure("Invalid Mistral validation URL constant")
        }
        return url
    }()

    public nonisolated func validateAPIKey(_ key: String) async -> String? {
        await Self.validateMistralAPIKey(key)
    }

    /// Shared validation implementation used by both MistralProvider and MistralBatchProvider.
    /// Validates a Mistral API key by calling the /v1/models endpoint.
    static func validateMistralAPIKey(_ key: String) async -> String? {
        let url = Self.validationEndpoint
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Invalid response from Mistral"
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

public enum MistralError: Error, LocalizedError {
    case missingApiKey
    case connectionFailed(String)
    case handshakeRejected(statusCode: Int)
    case handshakeTimedOut
    case invalidResponse(String)
    case webSocketError(Error)
    case sessionClosed
    case serverError(String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey: return "Mistral API key not configured"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .handshakeRejected(let statusCode):
            return "Mistral WebSocket handshake rejected (HTTP \(statusCode))"
        case .handshakeTimedOut:
            return "Mistral WebSocket handshake timed out"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .webSocketError(let err): return "WebSocket error: \(err.localizedDescription)"
        case .sessionClosed: return "Session is closed"
        case .serverError(let msg, let code): return "Server error (\(code)): \(msg)"
        }
    }
}

// MARK: - Streaming Session

/// A live WebSocket session to Mistral's realtime transcription API.
///
/// Implements the protocol defined in `mistralai/client-python/src/mistralai/extra/realtime/`:
///
/// **Client → Server messages:**
/// - `{"type": "input_audio.append", "audio": "<base64 PCM s16le>"}` — send audio chunk
/// - `{"type": "input_audio.end"}` — signal end of audio stream
/// - `{"type": "session.update", "session": {"audio_format": {"encoding": "...", "sample_rate": N}}}` — update audio format
///
/// **Server → Client messages:**
/// - `{"type": "session.created", "session": {"request_id": "...", "model": "...", "audio_format": {...}}}` — handshake
/// - `{"type": "transcription.text.delta", "text": "..."}` — incremental text fragment
/// - `{"type": "transcription.segment", "text": "...", "start": N, "end": N}` — finalized segment with timing
/// - `{"type": "transcription.language", "audio_language": "..."}` — detected language
/// - `{"type": "transcription.done", "text": "...", "model": "...", "usage": {...}}` — session complete
/// - `{"type": "error", "error": {"message": "...", "code": N}}` — server error
public actor MistralStreamingSession: StreamingSession {
    private let apiKey: String
    private let config: StreamingSessionConfig
    private let logger = Logger(subsystem: "SpeakFlow", category: "MistralSession")

    private let core: WebSocketSessionCore
    private let handshakeTimeout: TimeInterval

    /// Accumulates `transcription.text.delta` fragments between segment boundaries.
    /// Reset when a `transcription.segment` or `transcription.done` arrives.
    private var pendingDeltaText = ""

    public nonisolated var events: AsyncStream<TranscriptionEvent> {
        core.events
    }

    init(
        apiKey: String,
        config: StreamingSessionConfig,
        handshakeTimeout: TimeInterval = 10,
        connectionFactory: @escaping WebSocketConnectionFactory = { request, timeout in
            try await WebSocketConnector.connect(request: request, timeout: timeout)
        }
    ) {
        self.apiKey = apiKey
        self.config = config
        self.handshakeTimeout = handshakeTimeout
        self.core = WebSocketSessionCore(
            component: "MistralSession",
            connectionFactory: connectionFactory,
            receiveErrorMapper: { MistralError.webSocketError($0) }
        )
    }

    public func setObservabilitySessionId(_ sessionId: UUID?) async {
        await core.setObservabilitySessionId(sessionId)
    }

    func connect() async throws {
        let url = buildURL()
        logger.info("Connecting to Mistral Realtime: \(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var openedTransport = false
        do {
            try await core.connect(request: request, timeout: handshakeTimeout)
            openedTransport = true

            // Wait for session.created handshake (matches Python SDK's _recv_handshake).
            let serverFormat = try await waitForSessionCreated()
            logger.info("Mistral WebSocket connected — session created")

            // Only send session.update if the server's default format differs from ours.
            if serverFormat.encoding != "pcm_s16le" || serverFormat.sampleRate != config.sampleRate {
                try await sendSessionUpdate()
                logger.info("Sent session.update (format mismatch)")
            }

            try await core.startReceiving { [weak self] text in
                await self?.parseMessage(text)
            }
        } catch {
            if openedTransport {
                await core.close(code: .goingAway)
            }
            throw Self.connectionError(from: error)
        }
    }

    /// Server audio format returned in session.created.
    struct ServerAudioFormat {
        var encoding: String
        var sampleRate: Int
    }

    /// Wait for the server to send `session.created` confirming the connection.
    /// Mirrors `_recv_handshake` in the Python SDK — reads until session.created or error.
    /// Returns the server's default audio format so we can decide whether to send session.update.
    private func waitForSessionCreated() async throws -> ServerAudioFormat {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(handshakeTimeout)

        while clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            let message = try await core.receiveHandshakeMessage(
                timeout: Self.timeInterval(from: remaining)
            )

            let text: String
            switch message {
            case .string(let string):
                text = string
            case .data(let data):
                guard let string = String(data: data, encoding: .utf8) else { continue }
                text = string
            @unknown default:
                continue
            }

            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "session.created" {
                let sessionObject = json["session"] as? [String: Any]
                let requestId = sessionObject?["request_id"] as? String ?? "mistral-session"
                await core.yield(.metadata(requestId: requestId))

                let audioFormat = sessionObject?["audio_format"] as? [String: Any]
                let encoding = audioFormat?["encoding"] as? String ?? "pcm_s16le"
                let sampleRate = audioFormat?["sample_rate"] as? Int ?? 16000
                return ServerAudioFormat(encoding: encoding, sampleRate: sampleRate)
            }

            if type == "error" {
                let (message, code) = extractError(json)
                throw MistralError.serverError(message, code: code)
            }
        }

        throw MistralError.handshakeTimedOut
    }

    /// Send `session.update` with our desired audio format (pcm_s16le @ 16kHz).
    /// This mirrors the Python SDK's `connection.update_session(audio_format)`.
    private func sendSessionUpdate() async throws {
        let msg = """
        {"type":"session.update","session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":\(config.sampleRate)}}}
        """
        try await core.send(.string(msg), disconnectedError: MistralError.sessionClosed)
        logger.debug("Sent session.update with pcm_s16le @ \(self.config.sampleRate)Hz")
    }

    public func sendAudio(_ data: Data) async throws {
        // Mistral expects base64-encoded PCM audio in a JSON message.
        let base64Audio = data.base64EncodedString()
        let msg = #"{"type":"input_audio.append","audio":""# + base64Audio + #""}"#
        try await core.send(.string(msg), disconnectedError: MistralError.sessionClosed)
    }

    public func finalize() async throws {
        let msg = #"{"type":"input_audio.end"}"#
        try await core.send(.string(msg), disconnectedError: MistralError.sessionClosed)
        logger.debug("Sent input_audio.end")
    }

    public func close() async throws {
        // Flush any remaining delta text as a final result.
        if !pendingDeltaText.isEmpty {
            let result = TranscriptionResult(
                transcript: pendingDeltaText,
                isFinal: true,
                speechFinal: true
            )
            await core.yield(.finalResult(result))
            pendingDeltaText = ""
        }

        await core.close()
        logger.info("WebSocket closed")
    }

    public func keepAlive() async throws {
        // Mistral's realtime API does not have an explicit keep-alive message.
    }

    // MARK: - Private

    func buildURL() -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.mistral.ai"
        components.path = "/v1/audio/transcriptions/realtime"
        components.queryItems = [
            URLQueryItem(name: "model", value: config.model),
        ]
        guard let url = components.url else {
            preconditionFailure("Failed to construct Mistral WebSocket URL from valid components")
        }
        return url
    }

    /// Parse a server message according to the Mistral realtime protocol.
    /// Message types are defined in `_MESSAGE_MODELS` in the Python SDK's `connection.py`.
    func parseMessage(_ json: String) async {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {

        // --- transcription.text.delta ---
        // Incremental text fragment. Accumulate in pendingDeltaText and emit as interim.
        // Python model: TranscriptionStreamTextDelta { text: str }
        case "transcription.text.delta":
            guard let text = obj["text"] as? String, !text.isEmpty else { return }

            pendingDeltaText += text

            let result = TranscriptionResult(
                transcript: pendingDeltaText,
                isFinal: false,
                speechFinal: false
            )
            await core.yield(.interim(result))
            logger.debug(
                "delta: \(text, privacy: .private(mask: .hash)) → accumulated: \(self.pendingDeltaText, privacy: .private(mask: .hash))"
            )

        // --- transcription.segment ---
        // Completed segment with timing. This is the "final" result for the segment.
        // Python model: TranscriptionStreamSegmentDelta { text: str, start: float, end: float, speaker_id: str? }
        case "transcription.segment":
            let segmentText: String
            if let text = obj["text"] as? String, !text.isEmpty {
                segmentText = text
            } else {
                segmentText = pendingDeltaText
            }

            let start = obj["start"] as? Double ?? 0
            let duration = (obj["end"] as? Double ?? 0) - start

            if !segmentText.isEmpty {
                let result = TranscriptionResult(
                    transcript: segmentText,
                    start: start,
                    duration: duration,
                    isFinal: true,
                    speechFinal: true
                )
                await core.yield(.finalResult(result))
                logger.info(
                    "SEGMENT [\(String(format: "%.1f", start))–\(String(format: "%.1f", start + duration))s]: \(segmentText, privacy: .private(mask: .hash))"
                )
            }

            // Reset delta accumulator for next segment
            pendingDeltaText = ""

            // Signal utterance boundary so LiveStreamingController can track silence
            await core.yield(.utteranceEnd(lastWordEnd: start + duration))

        // --- transcription.language ---
        // Detected language. Informational.
        // Python model: TranscriptionStreamLanguage { audio_language: str }
        case "transcription.language":
            if let language = obj["audio_language"] as? String {
                logger.info("Detected language: \(language, privacy: .public)")
            }

        // --- transcription.done ---
        // Session complete. Contains full text, model, usage stats.
        // Python model: TranscriptionStreamDone { model: str, text: str, usage: UsageInfo, language: str? }
        case "transcription.done":
            // Flush any remaining delta text
            if !pendingDeltaText.isEmpty {
                let result = TranscriptionResult(
                    transcript: pendingDeltaText,
                    isFinal: true,
                    speechFinal: true
                )
                await core.yield(.finalResult(result))
                pendingDeltaText = ""
            }
            logger.info("Transcription done")

        // --- session.created ---
        // May arrive again after handshake (already handled in waitForSessionCreated).
        case "session.created":
            if let session = obj["session"] as? [String: Any],
               let requestId = session["request_id"] as? String {
                await core.yield(.metadata(requestId: requestId))
            }
            logger.info("Session created event received")

        // --- session.updated ---
        // Confirmation of session.update. Informational.
        case "session.updated":
            logger.info("Session updated confirmed")

        // --- error ---
        // Server error. Python model: RealtimeTranscriptionError { error: { message: str|dict, code: int } }
        case "error":
            let (msg, code) = extractError(obj)
            logger.error("Server error (\(code)): \(msg, privacy: .public)")
            await core.yield(.error(MistralError.serverError(msg, code: code)))

        default:
            logger.debug("Unknown message type: \(type, privacy: .public)")
        }
    }

    /// Extract error message and code from a Mistral error JSON object.
    /// Handles both string and dict message formats per the SDK model.
    private func extractError(_ json: [String: Any]) -> (message: String, code: Int) {
        let code: Int
        let message: String

        guard let error = json["error"] as? [String: Any] else {
            return ("Unknown error", 0)
        }

        code = error["code"] as? Int ?? 0

        if let msg = error["message"] as? String {
            message = msg
        } else if let msgDict = error["message"] as? [String: Any],
                  let detail = msgDict["detail"] as? String {
            message = detail
        } else {
            message = "Unknown error"
        }

        return (message, code)
    }

    private static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func connectionError(from error: Error) -> Error {
        if error is CancellationError || error is MistralError {
            return error
        }
        guard let connectionError = error as? WebSocketConnectionError else {
            return MistralError.connectionFailed(error.localizedDescription)
        }

        switch connectionError {
        case .handshakeRejected(let statusCode):
            return MistralError.handshakeRejected(statusCode: statusCode)
        case .handshakeTimedOut, .messageTimedOut:
            return MistralError.handshakeTimedOut
        case .connectionFailed(let message):
            return MistralError.connectionFailed(message)
        case .connectionAlreadyInProgress:
            return MistralError.connectionFailed("Connection already in progress")
        case .alreadyConnected:
            return MistralError.connectionFailed("Session is already connected")
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

    nonisolated func _testIsNormalClose(_ error: Error) -> Bool {
        WebSocketReceiveErrorClassifier.shouldRouteAsClosed(error)
    }
    // swiftlint:enable identifier_name
#endif
}
