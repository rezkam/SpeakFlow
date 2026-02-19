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
        UnifiedAuthStorage.shared.apiKey(for: id) != nil
    }

    private let logger = Logger(subsystem: "SpeakFlow", category: "Mistral")
    private let settings: any MistralSettingsProviding
    private let providerSettings: any ProviderSettingsProviding

    @MainActor
    public init(
        settings: any MistralSettingsProviding = Settings.shared,
        providerSettings: any ProviderSettingsProviding = ProviderSettings.shared
    ) {
        self.settings = settings
        self.providerSettings = providerSettings
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
    case invalidResponse(String)
    case webSocketError(Error)
    case sessionClosed
    case serverError(String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey: return "Mistral API key not configured"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
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

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var eventContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private let _events: AsyncStream<TranscriptionEvent>
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?
    private var sawTranscriptionDone = false

    /// Accumulates `transcription.text.delta` fragments between segment boundaries.
    /// Reset when a `transcription.segment` or `transcription.done` arrives.
    private var pendingDeltaText = ""

    public nonisolated var events: AsyncStream<TranscriptionEvent> {
        _events
    }

    init(apiKey: String, config: StreamingSessionConfig) {
        self.apiKey = apiKey
        self.config = config

        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        self._events = AsyncStream<TranscriptionEvent> { c in
            continuation = c
        }
        self.eventContinuation = continuation
    }

    func connect() async throws {
        let url = buildURL()
        logger.info("Connecting to Mistral Realtime: \(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: request)

        self.urlSession = session
        self.webSocketTask = wsTask

        wsTask.resume()
        isConnected = true

        // Wait for session.created handshake (matches Python SDK's _recv_handshake)
        let serverFormat = try await waitForSessionCreated()

        logger.info("Mistral WebSocket connected — session created")

        // Only send session.update if the server's default format differs from ours.
        // The Python SDK only calls update_session() when audio_format is explicitly passed.
        // The server default is pcm_s16le@16kHz — same as our pipeline — so typically no update needed.
        if serverFormat.encoding != "pcm_s16le" || serverFormat.sampleRate != config.sampleRate {
            try await sendSessionUpdate()
            logger.info("Sent session.update (format mismatch)")
        }

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
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
        guard let ws = webSocketTask else {
            throw MistralError.connectionFailed("No WebSocket task")
        }

        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                throw MistralError.connectionFailed("WebSocket handshake failed: \(error.localizedDescription)")
            }

            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d):
                guard let s = String(data: d, encoding: .utf8) else { continue }
                text = s
            @unknown default: continue
            }

            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "session.created" {
                let sessionObj = json["session"] as? [String: Any]
                let requestId = sessionObj?["request_id"] as? String ?? "mistral-session"
                eventContinuation?.yield(.metadata(requestId: requestId))

                // Extract the server's default audio format
                let audioFormat = sessionObj?["audio_format"] as? [String: Any]
                let encoding = audioFormat?["encoding"] as? String ?? "pcm_s16le"
                let sampleRate = audioFormat?["sample_rate"] as? Int ?? 16000

                return ServerAudioFormat(encoding: encoding, sampleRate: sampleRate)
            } else if type == "error" {
                let (msg, code) = extractError(json)
                throw MistralError.serverError(msg, code: code)
            }
        }

        throw MistralError.connectionFailed("Timeout waiting for session.created")
    }

    /// Send `session.update` with our desired audio format (pcm_s16le @ 16kHz).
    /// This mirrors the Python SDK's `connection.update_session(audio_format)`.
    private func sendSessionUpdate() async throws {
        guard isConnected, let ws = webSocketTask else {
            throw MistralError.sessionClosed
        }
        let msg = """
        {"type":"session.update","session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":\(config.sampleRate)}}}
        """
        try await ws.send(.string(msg))
        logger.debug("Sent session.update with pcm_s16le @ \(self.config.sampleRate)Hz")
    }

    public func sendAudio(_ data: Data) async throws {
        guard isConnected, let ws = webSocketTask else {
            throw MistralError.sessionClosed
        }

        // Mistral expects base64-encoded PCM audio in a JSON message
        // (matches Python SDK's RealtimeConnection.send_audio)
        let base64Audio = data.base64EncodedString()
        let msg = #"{"type":"input_audio.append","audio":""# + base64Audio + #""}"#
        try await ws.send(.string(msg))
    }

    public func finalize() async throws {
        guard isConnected, let ws = webSocketTask else {
            throw MistralError.sessionClosed
        }
        // Signal end of audio stream (matches Python SDK's connection.end_audio)
        let msg = #"{"type":"input_audio.end"}"#
        try await ws.send(.string(msg))
        logger.debug("Sent input_audio.end")
    }

    public func close() async throws {
        guard isConnected else { return }
        isConnected = false

        // Flush any remaining delta text as a final result
        if !pendingDeltaText.isEmpty {
            let result = TranscriptionResult(
                transcript: pendingDeltaText,
                isFinal: true,
                speechFinal: true
            )
            eventContinuation?.yield(.finalResult(result))
            pendingDeltaText = ""
        }

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        logger.info("WebSocket closed")

        receiveTask?.cancel()
        receiveTask = nil
        eventContinuation?.finish()
    }

    public func keepAlive() async throws {
        // Mistral's realtime API doesn't have an explicit keep-alive message.
        // The connection stays open as long as audio is being streamed.
        guard isConnected else { return }
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
                    // Distinguish a normal server-initiated close from a genuine network error.
                    // Mistral's protocol closes the WebSocket after `transcription.done` — this
                    // is expected and must not be reported as an error (which would kill recording).
                    if isNormalClose(error) {
                        let nsError = error as NSError
                        if sawTranscriptionDone {
                            logger.info("WebSocket closed by server after transcription.done (expected) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
                        } else {
                            logger.info("WebSocket closed by server before transcription.done domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
                        }
                    } else {
                        let nsError = error as NSError
                        logger.error("WebSocket receive error: \(error.localizedDescription) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
                        eventContinuation?.yield(.error(MistralError.webSocketError(error)))
                    }
                    isConnected = false
                }
                break
            }
        }

        eventContinuation?.yield(.closed)
        eventContinuation?.finish()
    }

    /// Returns true when the WebSocket close is a clean, server-initiated closure that
    /// should be treated as a normal end-of-session, not a network error.
    ///
    /// URLSessionWebSocketTask surfaces a server close frame as a URLError. We match on:
    /// - `.networkConnectionLost` — most common form of a remote close on Darwin
    /// - `.cancelled`            — fired when the task is cancelled (our own close())
    /// The underlying close *code* is not directly accessible from URLError, so we
    /// rely on error domain and code to filter out the non-fatal cases.
    private nonisolated func isNormalClose(_ error: Error) -> Bool {
        // Task cancellation (our own close() called cancel on the WS task)
        if error is CancellationError { return true }

        let nsError = error as NSError
        // URLError domain
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNetworkConnectionLost,  // remote close frame
                 NSURLErrorCancelled:              // task cancelled
                return true
            default:
                return false
            }
        }
        // POSIXError — sometimes surfaced on macOS for socket-level close
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ECONNRESET) {
            return true
        }
        return false
    }

    /// Parse a server message according to the Mistral realtime protocol.
    /// Message types are defined in `_MESSAGE_MODELS` in the Python SDK's `connection.py`.
    func parseMessage(_ json: String) {
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
            eventContinuation?.yield(.interim(result))
            logger.debug("delta: \(text, privacy: .public) → accumulated: \(self.pendingDeltaText, privacy: .public)")

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
                eventContinuation?.yield(.finalResult(result))
                logger.info("SEGMENT [\(String(format: "%.1f", start))–\(String(format: "%.1f", start + duration))s]: \(segmentText, privacy: .public)")
            }

            // Reset delta accumulator for next segment
            pendingDeltaText = ""

            // Signal utterance boundary so LiveStreamingController can track silence
            eventContinuation?.yield(.utteranceEnd(lastWordEnd: start + duration))

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
            sawTranscriptionDone = true
            // Flush any remaining delta text
            if !pendingDeltaText.isEmpty {
                let result = TranscriptionResult(
                    transcript: pendingDeltaText,
                    isFinal: true,
                    speechFinal: true
                )
                eventContinuation?.yield(.finalResult(result))
                pendingDeltaText = ""
            }
            logger.info("Transcription done")

        // --- session.created ---
        // May arrive again after handshake (already handled in waitForSessionCreated).
        case "session.created":
            if let session = obj["session"] as? [String: Any],
               let requestId = session["request_id"] as? String {
                eventContinuation?.yield(.metadata(requestId: requestId))
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
            eventContinuation?.yield(.error(MistralError.serverError(msg, code: code)))

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

#if DEBUG
    /// Test seam: mark the session as connected without a real WebSocket,
    /// so close() will execute its flush path.
    func _testSetConnected(_ connected: Bool) {
        isConnected = connected
    }

    /// Test seam: expose isNormalClose for unit testing the error classification logic.
    nonisolated func _testIsNormalClose(_ error: Error) -> Bool {
        isNormalClose(error)
    }
#endif
}
