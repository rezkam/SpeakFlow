import Foundation
import Testing
@testable import SpeakFlowCore

enum WebSocketProviderContractCase: String, CaseIterable, Sendable, CustomStringConvertible {
    case deepgram
    case mistral

    var description: String { rawValue }

    func makeSession(
        handshakeTimeout: TimeInterval = 1,
        connectionFactory: @escaping WebSocketConnectionFactory = { request, timeout in
            try await WebSocketConnector.connect(request: request, timeout: timeout)
        }
    ) -> any StreamingSession {
        switch self {
        case .deepgram:
            return DeepgramStreamingSession(
                apiKey: "contract-key",
                config: .default,
                handshakeTimeout: handshakeTimeout,
                connectionFactory: connectionFactory
            )
        case .mistral:
            return MistralStreamingSession(
                apiKey: "contract-key",
                config: .default,
                handshakeTimeout: handshakeTimeout,
                connectionFactory: connectionFactory
            )
        }
    }

    func connect(_ session: any StreamingSession) async throws {
        switch self {
        case .deepgram:
            guard let session = session as? DeepgramStreamingSession else {
                throw ContractTestError.wrongSessionType
            }
            try await session.connect()
        case .mistral:
            guard let session = session as? MistralStreamingSession else {
                throw ContractTestError.wrongSessionType
            }
            try await session.connect()
        }
    }

    func finishReceiveLoop(
        _ session: any StreamingSession,
        after error: Error
    ) async throws {
        switch self {
        case .deepgram:
            guard let session = session as? DeepgramStreamingSession else {
                throw ContractTestError.wrongSessionType
            }
            await session._testFinishReceiveLoop(after: error)
        case .mistral:
            guard let session = session as? MistralStreamingSession else {
                throw ContractTestError.wrongSessionType
            }
            await session._testFinishReceiveLoop(after: error)
        }
    }

    func isConnected(_ session: any StreamingSession) async throws -> Bool {
        switch self {
        case .deepgram:
            guard let session = session as? DeepgramStreamingSession else {
                throw ContractTestError.wrongSessionType
            }
            return await session._testIsConnected()
        case .mistral:
            guard let session = session as? MistralStreamingSession else {
                throw ContractTestError.wrongSessionType
            }
            return await session._testIsConnected()
        }
    }

    func observabilitySessionId(_ session: any StreamingSession) async throws -> UUID? {
        switch self {
        case .deepgram:
            guard let session = session as? DeepgramStreamingSession else {
                throw ContractTestError.wrongSessionType
            }
            return await session._testObservabilitySessionId()
        case .mistral:
            guard let session = session as? MistralStreamingSession else {
                throw ContractTestError.wrongSessionType
            }
            return await session._testObservabilitySessionId()
        }
    }

    func successfulConnection() async -> WebSocketConnection {
        let handshakeMessages: [URLSessionWebSocketTask.Message]
        switch self {
        case .deepgram:
            handshakeMessages = []
        case .mistral:
            handshakeMessages = [
                .string(
                    #"{"type":"session.created","session":{"request_id":"contract-session","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#
                )
            ]
        }
        return await ContractWebSocketTransport(messages: handshakeMessages).connection()
    }
}

private enum ContractTestError: Error {
    case wrongSessionType
}

private actor ContractWebSocketTransport {
    private var messages: [URLSessionWebSocketTask.Message]
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private(set) var cancelled = false
    private(set) var invalidated = false

    init(messages: [URLSessionWebSocketTask.Message]) {
        self.messages = messages
    }

    func connection() -> WebSocketConnection {
        WebSocketConnection(
            send: { message in
                await self.record(message)
            },
            receive: {
                try await self.receive()
            },
            cancel: { _, _ in
                await self.cancel()
            },
            invalidate: {
                await self.invalidate()
            }
        )
    }

    private func record(_ message: URLSessionWebSocketTask.Message) {
        sentMessages.append(message)
    }

    private func receive() async throws -> URLSessionWebSocketTask.Message {
        if !messages.isEmpty {
            return messages.removeFirst()
        }
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }

    private func cancel() {
        cancelled = true
    }

    private func invalidate() {
        invalidated = true
    }
}

private final class ConnectionFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private let delay: Duration
    private let connection: WebSocketConnection

    init(delay: Duration, connection: WebSocketConnection) {
        self.delay = delay
        self.connection = connection
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func open() async throws -> WebSocketConnection {
        lock.withLock { attempts += 1 }
        try await Task.sleep(for: delay)
        return connection
    }
}

@Suite("Streaming provider WebSocket contract")
struct WebSocketSessionContractTests {
    @Test(arguments: WebSocketProviderContractCase.allCases)
    func rejectedUpgradeMakesConnectThrow(provider: WebSocketProviderContractCase) async throws {
        let session = provider.makeSession { _, _ in
            throw WebSocketConnectionError.handshakeRejected(statusCode: 401)
        }

        do {
            try await provider.connect(session)
            Issue.record("Connect must reject an HTTP upgrade failure")
        } catch {
            #expect(error.localizedDescription.contains("401"))
        }

        #expect(try await !provider.isConnected(session))
    }

    @Test(arguments: WebSocketProviderContractCase.allCases)
    func handshakeTimeoutMakesConnectThrow(provider: WebSocketProviderContractCase) async throws {
        let session = provider.makeSession(handshakeTimeout: 0.01) { _, _ in
            throw WebSocketConnectionError.handshakeTimedOut
        }

        do {
            try await provider.connect(session)
            Issue.record("Connect must not succeed after its handshake deadline")
        } catch {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("timed out"))
        }

        #expect(try await !provider.isConnected(session))
    }

    @Test(arguments: WebSocketProviderContractCase.allCases)
    func cancelledConnectThrowsAndStaysDisconnected(provider: WebSocketProviderContractCase) async throws {
        let attempts = ConnectionAttemptCounter()
        let session = provider.makeSession { _, _ in
            await attempts.increment()
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        let connectTask = Task { () -> Error? in
            do {
                try await provider.connect(session)
                return nil
            } catch {
                return error
            }
        }

        while await attempts.value == 0 {
            await Task.yield()
        }
        connectTask.cancel()

        let error = await connectTask.value
        #expect(error is CancellationError)
        #expect(try await !provider.isConnected(session))
    }

    @Test(arguments: WebSocketProviderContractCase.allCases)
    func concurrentConnectDoesNotOpenTwoSockets(provider: WebSocketProviderContractCase) async throws {
        let connection = await provider.successfulConnection()
        let probe = ConnectionFactoryProbe(delay: .milliseconds(100), connection: connection)
        let session = provider.makeSession { _, _ in
            try await probe.open()
        }

        let firstConnect = Task { () -> Error? in
            do {
                try await provider.connect(session)
                return nil
            } catch {
                return error
            }
        }

        while probe.attemptCount == 0 {
            await Task.yield()
        }

        do {
            try await provider.connect(session)
            Issue.record("A concurrent connect must not start a second transport")
        } catch {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("already"))
        }

        let firstError = await firstConnect.value
        let firstErrorDescription = firstError?.localizedDescription ?? "none"
        #expect(firstError == nil, "First connect failed: \(firstErrorDescription)")
        #expect(probe.attemptCount == 1)
        #expect(try await provider.isConnected(session))
        try await session.close()
    }

    @Test(arguments: WebSocketProviderContractCase.allCases)
    func connectionLossYieldsClosedWithoutError(provider: WebSocketProviderContractCase) async throws {
        let session = provider.makeSession()
        let eventsTask = Task {
            var received: [TranscriptionEvent] = []
            for await event in session.events {
                received.append(event)
            }
            return received
        }

        try await provider.finishReceiveLoop(session, after: URLError(.networkConnectionLost))
        let received = await eventsTask.value

        #expect(received.count == 1)
        guard let first = received.first, case .closed = first else {
            Issue.record("Connection loss must yield only .closed")
            return
        }
    }

    @Test(arguments: WebSocketProviderContractCase.allCases)
    func genuineReceiveFailureYieldsErrorThenClosed(provider: WebSocketProviderContractCase) async throws {
        let session = provider.makeSession()
        let eventsTask = Task {
            var received: [TranscriptionEvent] = []
            for await event in session.events {
                received.append(event)
            }
            return received
        }

        try await provider.finishReceiveLoop(session, after: URLError(.timedOut))
        let received = await eventsTask.value

        #expect(received.count == 2)
        guard received.count == 2 else { return }
        guard case .error = received[0] else {
            Issue.record("A genuine transport failure must yield .error first")
            return
        }
        guard case .closed = received[1] else {
            Issue.record("A genuine transport failure must finish with .closed")
            return
        }
    }

    @Test(arguments: WebSocketProviderContractCase.allCases)
    func observabilityIdIsSetThroughStreamingSessionProtocol(provider: WebSocketProviderContractCase) async throws {
        let session: any StreamingSession = provider.makeSession()
        let sessionId = UUID()

        await session.setObservabilitySessionId(sessionId)

        #expect(try await provider.observabilitySessionId(session) == sessionId)
    }
}

private actor ConnectionAttemptCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Suite("Streaming reconnect integration")
struct WebSocketReconnectIntegrationTests {
    @MainActor
    @Test(arguments: WebSocketProviderContractCase.allCases)
    func providerConnectionLossReconnectsBeforeErrorAndSecondDropEndsSession(
        providerCase: WebSocketProviderContractCase
    ) async throws {
        let initialSession = providerCase.makeSession()
        let reconnectedSession = providerCase.makeSession()
        let provider = MultiSessionMockProvider()
        provider.sessions = [initialSession, reconnectedSession]

        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        controller.reconnectEnabled = true

        var errorCount = 0
        var closedCount = 0
        controller.onError = { _ in
            errorCount += 1
            Task { @MainActor in
                await controller.stop(trailingFinalTimeout: 0)
            }
        }
        controller.onSessionClosed = {
            closedCount += 1
        }

        #expect(await controller.start(provider: provider, config: .default))
        #expect(provider.startSessionCallCount == 1)

        try await providerCase.finishReceiveLoop(
            initialSession,
            after: URLError(.networkConnectionLost)
        )

        try await waitUntil {
            provider.startSessionCallCount == 2 && controller.recording
        }

        #expect(errorCount == 0, "Connection loss must not call onError before reconnect")
        #expect(closedCount == 0)

        try await providerCase.finishReceiveLoop(
            reconnectedSession,
            after: URLError(.networkConnectionLost)
        )

        try await waitUntil {
            closedCount == 1 && !controller.recording
        }

        #expect(provider.startSessionCallCount == 2, "Reconnect is limited to one attempt")
        #expect(errorCount == 0, "Reconnect exhaustion surfaces through onSessionClosed")
        #expect(closedCount == 1)
    }
}
