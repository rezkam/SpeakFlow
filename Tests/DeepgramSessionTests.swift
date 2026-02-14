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
        {"type":"UtteranceEnd","last_word_end":2.5}
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
        {"type":"SpeechStarted","timestamp":1.23}
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
