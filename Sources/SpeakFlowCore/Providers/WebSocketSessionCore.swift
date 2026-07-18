import Foundation
import OSLog
import os

/// Transport-level failures shared by all WebSocket transcription providers.
enum WebSocketConnectionError: Error, LocalizedError, Sendable {
    case handshakeRejected(statusCode: Int)
    case handshakeTimedOut
    case connectionFailed(String)
    case connectionAlreadyInProgress
    case alreadyConnected
    case messageTimedOut

    var errorDescription: String? {
        switch self {
        case .handshakeRejected(let statusCode):
            return "WebSocket handshake rejected (HTTP \(statusCode))"
        case .handshakeTimedOut:
            return "WebSocket handshake timed out"
        case .connectionFailed(let message):
            return "WebSocket connection failed: \(message)"
        case .connectionAlreadyInProgress:
            return "WebSocket connection is already in progress"
        case .alreadyConnected:
            return "WebSocket is already connected"
        case .messageTimedOut:
            return "Timed out waiting for a WebSocket message"
        }
    }
}

/// Sendable wrapper around URLSession's WebSocket and session lifecycle.
/// Tests can supply the same behavior with closures, without opening a socket.
struct WebSocketConnection: Sendable {
    let send: @Sendable (URLSessionWebSocketTask.Message) async throws -> Void
    let receive: @Sendable () async throws -> URLSessionWebSocketTask.Message
    let cancel: @Sendable (URLSessionWebSocketTask.CloseCode, Data?) async -> Void
    let invalidate: @Sendable () async -> Void

    init(
        send: @escaping @Sendable (URLSessionWebSocketTask.Message) async throws -> Void,
        receive: @escaping @Sendable () async throws -> URLSessionWebSocketTask.Message,
        cancel: @escaping @Sendable (URLSessionWebSocketTask.CloseCode, Data?) async -> Void,
        invalidate: @escaping @Sendable () async -> Void
    ) {
        self.send = send
        self.receive = receive
        self.cancel = cancel
        self.invalidate = invalidate
    }

    init(urlSession: URLSession, webSocketTask: URLSessionWebSocketTask) {
        self.init(
            send: { message in try await webSocketTask.send(message) },
            receive: { try await webSocketTask.receive() },
            cancel: { code, reason in webSocketTask.cancel(with: code, reason: reason) },
            invalidate: { urlSession.invalidateAndCancel() }
        )
    }
}

typealias WebSocketConnectionFactory = @Sendable (
    _ request: URLRequest,
    _ timeout: TimeInterval
) async throws -> WebSocketConnection

/// Races one receive against timeout and caller cancellation without waiting for the
/// losing receive operation. This matters because URLSession WebSocket receives do not
/// guarantee prompt cooperative cancellation. The caller can therefore close the socket
/// after timeout, which releases any receive still suspended in URLSession.
private final class WebSocketMessageWaiter: @unchecked Sendable {
    private typealias Message = URLSessionWebSocketTask.Message

    private struct State {
        var result: Result<Message, Error>?
        var continuation: CheckedContinuation<Message, Error>?
        var receiveTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private let connection: WebSocketConnection
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(connection: WebSocketConnection) {
        self.connection = connection
    }

    func wait(timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message {
        guard timeout > 0 else {
            throw WebSocketConnectionError.messageTimedOut
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completedResult = state.withLock { state -> Result<Message, Error>? in
                    if let result = state.result {
                        return result
                    }
                    precondition(state.continuation == nil, "WebSocket message waiter already used")
                    state.continuation = continuation
                    return nil
                }

                if let completedResult {
                    continuation.resume(with: completedResult)
                    return
                }

                let receiveTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let message = try await connection.receive()
                        complete(with: .success(message))
                    } catch {
                        complete(with: .failure(error))
                    }
                }
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    self?.complete(with: .failure(WebSocketConnectionError.messageTimedOut))
                }
                install(receiveTask: receiveTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            self.complete(with: .failure(CancellationError()))
        }
    }

    private func install(
        receiveTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        let alreadyCompleted = state.withLock { state in
            guard state.result == nil else { return true }
            state.receiveTask = receiveTask
            state.timeoutTask = timeoutTask
            return false
        }
        if alreadyCompleted {
            receiveTask.cancel()
            timeoutTask.cancel()
        }
    }

    private func complete(with result: Result<Message, Error>) {
        let pending = state.withLock { state -> (
            CheckedContinuation<Message, Error>?,
            Task<Void, Never>?,
            Task<Void, Never>?
        )? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            let receiveTask = state.receiveTask
            let timeoutTask = state.timeoutTask
            state.continuation = nil
            state.receiveTask = nil
            state.timeoutTask = nil
            return (continuation, receiveTask, timeoutTask)
        }

        pending?.1?.cancel()
        pending?.2?.cancel()
        pending?.0?.resume(with: result)
    }
}

/// Shared WebSocket lifecycle for streaming transcription sessions.
///
/// Provider actors retain protocol-specific request construction, handshakes, message
/// parsing, and outbound message formats. This core owns transport connection state,
/// receive-loop routing, event-stream lifetime, close classification, and transport
/// observability so reliability behavior cannot diverge by provider.
actor WebSocketSessionCore {
    private enum Phase {
        case disconnected
        case connecting
        case connected
    }

    private let component: String
    private let logger: Logger
    private let connectionFactory: WebSocketConnectionFactory
    private let receiveErrorMapper: @Sendable (Error) -> Error
    private let eventContinuation: AsyncStream<TranscriptionEvent>.Continuation
    nonisolated let events: AsyncStream<TranscriptionEvent>

    private var phase: Phase = .disconnected
    private var connection: WebSocketConnection?
    private var receiveTask: Task<Void, Never>?
    private var observabilitySessionId: UUID?
    private var messageSequence: UInt64 = 0
    private var eventStreamFinished = false
#if DEBUG
    private var testDidInvalidateConnection = false
#endif

    init(
        component: String,
        connectionFactory: @escaping WebSocketConnectionFactory = { request, timeout in
            try await WebSocketConnector.connect(request: request, timeout: timeout)
        },
        receiveErrorMapper: @escaping @Sendable (Error) -> Error
    ) {
        self.component = component
        self.logger = Logger(subsystem: "SpeakFlow", category: component)
        self.connectionFactory = connectionFactory
        self.receiveErrorMapper = receiveErrorMapper

        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        self.events = AsyncStream<TranscriptionEvent> { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    func setObservabilitySessionId(_ sessionId: UUID?) {
        observabilitySessionId = sessionId
    }

    func connect(request: URLRequest, timeout: TimeInterval) async throws {
        switch phase {
        case .connecting:
            throw WebSocketConnectionError.connectionAlreadyInProgress
        case .connected:
            throw WebSocketConnectionError.alreadyConnected
        case .disconnected:
            break
        }

        guard connection == nil else {
            throw WebSocketConnectionError.alreadyConnected
        }

        phase = .connecting
        do {
            let openedConnection = try await connectionFactory(request, timeout)

            guard !Task.isCancelled else {
                await openedConnection.cancel(.goingAway, nil)
                await openedConnection.invalidate()
                phase = .disconnected
                throw CancellationError()
            }

            guard case .connecting = phase else {
                await openedConnection.cancel(.goingAway, nil)
                await openedConnection.invalidate()
                throw CancellationError()
            }

            connection = openedConnection
            phase = .connected
            logger.info("WebSocket transport connected")
            recordObservabilityEvent("websocket_connected")
        } catch {
            if case .connecting = phase {
                phase = .disconnected
            }
            throw error
        }
    }

    /// Receive one protocol-handshake message before the normal receive loop starts.
    func receiveHandshakeMessage(timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message {
        guard case .connected = phase, let connection else {
            throw WebSocketConnectionError.connectionFailed("No connected WebSocket")
        }
        guard receiveTask == nil else {
            throw WebSocketConnectionError.connectionFailed("Receive loop already started")
        }
        guard timeout > 0 else {
            throw WebSocketConnectionError.messageTimedOut
        }

        return try await Self.receive(connection: connection, timeout: timeout)
    }

    func startReceiving(
        onMessage: @escaping @Sendable (_ text: String) async -> Void
    ) throws {
        guard case .connected = phase, let connection else {
            throw WebSocketConnectionError.connectionFailed("No connected WebSocket")
        }
        guard receiveTask == nil else {
            throw WebSocketConnectionError.connectionFailed("Receive loop already started")
        }

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await connection.receive()
                    guard !Task.isCancelled else { return }
                    guard let text = Self.text(from: message) else { continue }
                    await self?.recordIncomingMessage(text)
                    await onMessage(text)
                } catch {
                    await self?.finishReceiveLoop(after: error)
                    return
                }
            }
        }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        disconnectedError: Error
    ) async throws {
        guard case .connected = phase, let connection else {
            throw disconnectedError
        }
        try await connection.send(message)
    }

    func yield(_ event: TranscriptionEvent) {
        guard !eventStreamFinished else { return }
        eventContinuation.yield(event)
    }

    func close(
        code: URLSessionWebSocketTask.CloseCode = .normalClosure,
        reason: Data? = nil
    ) async {
        phase = .disconnected
        receiveTask?.cancel()
        receiveTask = nil

        let closingConnection = connection
        connection = nil
        if let closingConnection {
            await closingConnection.cancel(code, reason)
            await closingConnection.invalidate()
#if DEBUG
            testDidInvalidateConnection = true
#endif
        }

        finishEventStream()
        logger.info("WebSocket transport closed")
        recordObservabilityEvent("websocket_closed")
    }

    func recordObservabilityEvent(
        _ name: String,
        level: ObservabilityEventLevel = .debug,
        metadata: [String: String] = [:]
    ) {
        let component = self.component
        let sessionId = observabilitySessionId
        Task {
            await ObservabilityStore.shared.record(
                component: component,
                name: name,
                level: level,
                sessionId: sessionId,
                metadata: metadata
            )
        }
    }

    private static func text(from message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    private static func receive(
        connection: WebSocketConnection,
        timeout: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await WebSocketMessageWaiter(connection: connection).wait(timeout: timeout)
    }

    private func recordIncomingMessage(_ text: String) {
        messageSequence &+= 1
        recordObservabilityEvent(
            "websocket_message_received",
            metadata: [
                "messageSequence": String(messageSequence),
                "payloadChars": String(text.count),
                "payloadFingerprint": ObservabilityFingerprint.sha256(text)
            ]
        )
    }

    private func finishReceiveLoop(after error: Error?) async {
        guard case .connected = phase else {
            finishEventStream()
            return
        }

        phase = .disconnected
        if let error {
            let nsError = error as NSError
            if WebSocketReceiveErrorClassifier.shouldRouteAsClosed(error) {
                logger.info(
                    "WebSocket connection ended domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
                )
                recordObservabilityEvent(
                    "websocket_connection_ended",
                    metadata: ["domain": nsError.domain, "code": String(nsError.code)]
                )
            } else {
                logger.error(
                    "WebSocket receive error: \(error.localizedDescription) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
                )
                eventContinuation.yield(.error(receiveErrorMapper(error)))
                recordObservabilityEvent(
                    "websocket_receive_failed",
                    level: .error,
                    metadata: [
                        "domain": nsError.domain,
                        "code": String(nsError.code),
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        eventContinuation.yield(.closed)
        finishEventStream()
    }

    private func finishEventStream() {
        guard !eventStreamFinished else { return }
        eventStreamFinished = true
        eventContinuation.finish()
    }

#if DEBUG
    // swiftlint:disable identifier_name
    func _testSetConnected(_ connected: Bool) {
        phase = connected ? .connected : .disconnected
    }

    func _testSetURLSession(_ session: URLSession?) {
        guard let session,
              let url = URL(string: "wss://127.0.0.1/test") else {
            connection = nil
            return
        }
        let task = session.webSocketTask(with: url)
        connection = WebSocketConnection(urlSession: session, webSocketTask: task)
    }

    func _testDidInvalidateConnection() -> Bool {
        testDidInvalidateConnection
    }

    func _testFinishReceiveLoop(after error: Error) async {
        phase = .connected
        await finishReceiveLoop(after: error)
    }

    func _testObservabilitySessionId() -> UUID? {
        observabilitySessionId
    }
    // swiftlint:enable identifier_name
#endif
}
