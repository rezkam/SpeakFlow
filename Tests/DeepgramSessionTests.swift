import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - DeepgramStreamingSession — URL Building

@Suite("DeepgramStreamingSession — buildURL")
struct DeepgramBuildURLTests {

    private func makeSession(config: StreamingSessionConfig = .default) -> DeepgramStreamingSession {
        DeepgramStreamingSession(apiKey: "test-key", config: config)
    }

    @Test
    func buildURL_includesModel() async {
        let session = makeSession(config: StreamingSessionConfig(model: "nova-3"))
        let url = await session.buildURL()
        #expect(url.absoluteString.contains("model=nova-3"),
                "URL should include model parameter")
    }

    @Test
    func buildURL_includesLanguage() async {
        let session = makeSession(config: StreamingSessionConfig(language: "fr"))
        let url = await session.buildURL()
        #expect(url.absoluteString.contains("language=fr"),
                "URL should include language parameter")
    }

    @Test
    func buildURL_includesEncoding() async {
        let session = makeSession(config: StreamingSessionConfig(encoding: .linear16))
        let url = await session.buildURL()
        #expect(url.absoluteString.contains("encoding=linear16"),
                "URL should include encoding parameter")
    }

    @Test
    func buildURL_smartFormatEnabled() async {
        let session = makeSession(config: StreamingSessionConfig(smartFormat: true))
        let url = await session.buildURL()
        #expect(url.absoluteString.contains("smart_format=true"),
                "URL should include smart_format=true")
    }

    @Test
    func buildURL_smartFormatDisabled() async {
        let session = makeSession(config: StreamingSessionConfig(smartFormat: false))
        let url = await session.buildURL()
        #expect(url.absoluteString.contains("smart_format=false"),
                "URL should include smart_format=false")
    }

    @Test
    func buildURL_usesCorrectHost() async {
        let session = makeSession()
        let url = await session.buildURL()
        #expect(url.host == "api.deepgram.com", "Should connect to Deepgram API")
        #expect(url.scheme == "wss", "Should use WebSocket Secure protocol")
        #expect(url.path == "/v1/listen", "Should target /v1/listen endpoint")
    }
}

// MARK: - Deepgram WebSocket Handshake

@Suite("WebSocket opening handshake")
struct WebSocketOpeningHandshakeTests {
    @Test
    func didOpenCompletesHandshake() async throws {
        let handshake = WebSocketOpeningHandshake()

        handshake._testDidOpen()

        try await handshake.waitForOpen(timeout: 1)
    }

    @Test
    func rejectedUpgradePreservesHTTPStatus() async {
        let handshake = WebSocketOpeningHandshake()
        handshake._testDidComplete(
            error: URLError(.badServerResponse),
            statusCode: 401
        )

        do {
            try await handshake.waitForOpen(timeout: 1)
            Issue.record("Expected HTTP 401 handshake rejection")
        } catch let error as WebSocketConnectionError {
            guard case .handshakeRejected(let statusCode) = error else {
                Issue.record("Expected handshakeRejected, got \(error)")
                return
            }
            #expect(statusCode == 401)
        } catch {
            Issue.record("Expected WebSocketConnectionError, got \(error)")
        }
    }

    @Test
    func handshakeTimesOutWithoutDelegateCompletion() async {
        let handshake = WebSocketOpeningHandshake()

        do {
            try await handshake.waitForOpen(timeout: 0.01)
            Issue.record("Expected handshake timeout")
        } catch let error as WebSocketConnectionError {
            guard case .handshakeTimedOut = error else {
                Issue.record("Expected handshakeTimedOut, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected WebSocketConnectionError, got \(error)")
        }
    }

    @Test
    func cancellationCompletesHandshakeWaiter() async {
        let handshake = WebSocketOpeningHandshake()
        let waitTask = Task { () -> Error? in
            do {
                try await handshake.waitForOpen(timeout: 30)
                return nil
            } catch {
                return error
            }
        }

        await Task.yield()
        waitTask.cancel()

        #expect(await waitTask.value is CancellationError)
    }

    @Test
    func sessionStaysDisconnectedWhenHandshakeFails() async {
        let session = DeepgramStreamingSession(
            apiKey: "revoked-key",
            config: .default,
            connectionFactory: { _, _ in
                throw WebSocketConnectionError.handshakeRejected(statusCode: 401)
            }
        )

        do {
            try await session.connect()
            Issue.record("Expected connect() to reject the failed handshake")
        } catch let error as DeepgramError {
            guard case .handshakeRejected(let statusCode) = error else {
                Issue.record("Expected handshakeRejected, got \(error)")
                return
            }
            #expect(statusCode == 401)
        } catch {
            Issue.record("Expected DeepgramError, got \(error)")
        }

        #expect(!(await session._testIsConnected()))
    }
}

// MARK: - DeepgramStreamingSession — JSON Parsing

@Suite("DeepgramStreamingSession — parseMessage")
struct DeepgramParseMessageTests {

    private func makeSession() -> DeepgramStreamingSession {
        DeepgramStreamingSession(apiKey: "test-key", config: .default)
    }

    @Test
    func parseMessage_finalResult_emitsEvent() async {
        let session = makeSession()
        let json = """
        {"type":"Results","channel":{"alternatives":[{"transcript":"hello world","confidence":0.99}]},"is_final":true,"speech_final":false,"start":0.0,"duration":1.5}
        """

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                break
            }
            return events
        }

        // Brief delay to ensure listener is ready
        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(json)
        // Give event time to propagate
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        guard case .finalResult(let result) = events.first else {
            Issue.record("Expected .finalResult, got: \(events)")
            return
        }
        #expect(result.transcript == "hello world")
        #expect(result.isFinal == true)
    }

    @Test
    func parseMessage_interimResult_emitsEvent() async {
        let session = makeSession()
        let json = """
        {"type":"Results","channel":{"alternatives":[{"transcript":"hel","confidence":0.5}]},"is_final":false,"speech_final":false,"start":0.0,"duration":0.5}
        """

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                break
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(json)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        guard case .interim(let result) = events.first else {
            Issue.record("Expected .interim, got: \(events)")
            return
        }
        #expect(result.transcript == "hel")
        #expect(result.isFinal == false)
    }

    @Test
    func parseMessage_utteranceEnd_emitsEvent() async {
        let session = makeSession()
        let json = """
        {"type":"UtteranceEnd","channel":[0],"last_word_end":2.5}
        """

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                break
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(json)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        guard case .utteranceEnd(let lastWordEnd) = events.first else {
            Issue.record("Expected .utteranceEnd, got: \(events)")
            return
        }
        #expect(lastWordEnd == 2.5)
    }

    @Test
    func parseMessage_metadata_emitsEvent() async {
        let session = makeSession()
        let json = """
        {"type":"Metadata","request_id":"abc123","transaction_key":"tx456"}
        """

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                break
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(json)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        guard case .metadata(let requestId) = events.first else {
            Issue.record("Expected .metadata, got: \(events)")
            return
        }
        #expect(requestId == "abc123")
    }

    @Test
    func parseMessage_speechStarted_emitsEvent() async {
        let session = makeSession()
        let json = """
        {"type":"SpeechStarted","channel":[0],"timestamp":1.23}
        """

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                break
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(json)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        guard case .speechStarted(let timestamp) = events.first else {
            Issue.record("Expected .speechStarted, got: \(events)")
            return
        }
        #expect(timestamp == 1.23)
    }

    @Test
    func parseMessage_malformedJSON_doesNotCrash() async {
        let session = makeSession()
        // Malformed JSON should be handled gracefully (logged, no crash)
        await session.parseMessage("{not valid json")
        await session.parseMessage("")
        await session.parseMessage("[]")
        // If we get here without crash, the test passes
    }
}

@Suite("DeepgramStreamingSession — close() resource cleanup")
struct DeepgramCloseCleanupTests {
    @Test
    func closeInvalidatesURLSessionEvenWhenNotConnected() async throws {
        let session = DeepgramStreamingSession(apiKey: "test-key", config: .default)
        await session._testSetConnected(false)
        await session._testSetURLSession(URLSession(configuration: .ephemeral))

        try await session.close()

        #expect(await session._testDidInvalidateURLSession(),
                "close() must invalidate URLSession even when isConnected=false")
    }
}

@Suite("DeepgramStreamingSession — receive failure routing")
struct DeepgramReceiveFailureRoutingTests {
    private func events(after error: Error) async -> [TranscriptionEvent] {
        let session = DeepgramStreamingSession(apiKey: "test-key", config: .default)
        let eventsTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
            }
            return events
        }

        await session._testFinishReceiveLoop(after: error)
        return await eventsTask.value
    }

    @Test
    func networkConnectionLost_emitsOnlyClosed() async {
        let received = await events(after: URLError(.networkConnectionLost))

        #expect(received.count == 1)
        guard let event = received.first, case .closed = event else {
            Issue.record("Connection loss must emit only .closed so reconnect can run")
            return
        }
    }

    @Test
    func connectionReset_emitsOnlyClosed() async {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let received = await events(after: error)

        #expect(received.count == 1)
        guard let event = received.first, case .closed = event else {
            Issue.record("Connection reset must emit only .closed so reconnect can run")
            return
        }
    }

    @Test
    func timeout_emitsErrorThenClosed() async {
        let received = await events(after: URLError(.timedOut))

        #expect(received.count == 2)
        guard received.count == 2 else { return }
        guard case .error = received[0] else {
            Issue.record("A genuine receive failure must still emit .error")
            return
        }
        guard case .closed = received[1] else {
            Issue.record("The event stream must finish with .closed")
            return
        }
    }
}

@Suite("DeepgramStreamingSession — transcript log privacy")
struct DeepgramTranscriptPrivacyTests {
    @Test
    func finalAndInterimTranscriptLogsArePrivate() async {
        let logger = SpyProviderLogger()
        let session = DeepgramStreamingSession(apiKey: "test-key", config: .default, logger: logger)
        let finalSentinel = "deepgram-final-private-sentinel"
        let interimSentinel = "deepgram-interim-private-sentinel"

        await session.parseMessage("""
        {"type":"Results","channel":{"alternatives":[{"transcript":"\(finalSentinel)","confidence":0.99}]},"is_final":true}
        """)
        await session.parseMessage("""
        {"type":"Results","channel":{"alternatives":[{"transcript":"\(interimSentinel)","confidence":0.5}]},"is_final":false}
        """)

        let transcriptEntries = logger.capturedEntries().filter {
            $0.message.contains(finalSentinel) || $0.message.contains(interimSentinel)
        }
        #expect(transcriptEntries.count == 2, "Final and interim parsing must both log their transcript")
        #expect(transcriptEntries.allSatisfy { $0.visibility == .privateHash })
        #expect(!transcriptEntries.contains { $0.visibility == .public })
        #expect(transcriptEntries.contains { $0.level == .info && $0.message.contains(finalSentinel) })
        #expect(transcriptEntries.contains { $0.level == .debug && $0.message.contains(interimSentinel) })
    }
}
