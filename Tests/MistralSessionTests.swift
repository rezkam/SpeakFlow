import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - MistralStreamingSession — URL Building

@Suite("MistralStreamingSession — buildURL")
struct MistralBuildURLTests {

    private func makeSession(config: StreamingSessionConfig = .default) -> MistralStreamingSession {
        MistralStreamingSession(apiKey: "test-key", config: config)
    }

    @Test
    func buildURL_includesModel() async {
        let session = makeSession(config: StreamingSessionConfig(model: "voxtral-mini-transcribe-realtime-latest"))
        let url = await session.buildURL()
        #expect(url.absoluteString.contains("model=voxtral-mini-transcribe-realtime-latest"),
                "URL should include model parameter")
    }

    @Test
    func buildURL_usesCorrectHost() async {
        let session = makeSession()
        let url = await session.buildURL()
        #expect(url.host == "api.mistral.ai", "Should connect to Mistral API")
        #expect(url.scheme == "wss", "Should use WebSocket Secure protocol")
        #expect(url.path == "/v1/audio/transcriptions/realtime", "Should target realtime transcription endpoint")
    }

    @Test
    func buildURL_doesNotIncludeLanguageInQuery() async {
        // Unlike Deepgram, Mistral's language is auto-detected — not a URL query param
        let session = makeSession(config: StreamingSessionConfig(language: "fr"))
        let url = await session.buildURL()
        #expect(!url.absoluteString.contains("language="),
                "Mistral realtime URL should not include language param (auto-detected)")
    }

    @Test
    func buildURL_onlyContainsModelQueryParam() async {
        let session = makeSession(config: StreamingSessionConfig(model: "test-model"))
        let url = await session.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        #expect(queryItems.count == 1, "Should only have model query param, got: \(queryItems)")
        #expect(queryItems.first?.name == "model")
        #expect(queryItems.first?.value == "test-model")
    }
}

// MARK: - MistralStreamingSession — JSON Parsing (Protocol Messages)

@Suite("MistralStreamingSession — parseMessage")
struct MistralParseMessageTests {

    private func makeSession() -> MistralStreamingSession {
        MistralStreamingSession(apiKey: "test-key", config: .default)
    }

    // MARK: transcription.text.delta

    @Test
    func parseMessage_textDelta_emitsInterim() async {
        let session = makeSession()
        let json = #"{"type":"transcription.text.delta","text":"Hello"}"#

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
        #expect(result.transcript == "Hello")
        #expect(result.isFinal == false)
        #expect(result.speechFinal == false)
    }

    @Test
    func parseMessage_textDelta_accumulatesPending() async {
        let session = makeSession()

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"Hello "}"#)
        try? await Task.sleep(for: .milliseconds(30))
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"world"}"#)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        #expect(events.count == 2)

        // First delta: "Hello "
        guard case .interim(let r1) = events[0] else {
            Issue.record("Expected .interim for first delta"); return
        }
        #expect(r1.transcript == "Hello ")

        // Second delta: accumulated "Hello world"
        guard case .interim(let r2) = events[1] else {
            Issue.record("Expected .interim for second delta"); return
        }
        #expect(r2.transcript == "Hello world")
    }

    @Test
    func parseMessage_textDelta_emptyTextIgnored() async {
        let session = makeSession()

        // Empty text should not produce an event
        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                break
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(#"{"type":"transcription.text.delta","text":""}"#)
        try? await Task.sleep(for: .milliseconds(50))
        // Send a real delta to complete the test
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"ok"}"#)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        guard case .interim(let result) = events.first else {
            Issue.record("Expected .interim"); return
        }
        #expect(result.transcript == "ok", "Empty delta should have been skipped")
    }

    // MARK: transcription.segment

    @Test
    func parseMessage_segment_emitsFinalAndUtteranceEnd() async {
        let session = makeSession()
        let segmentJson = #"{"type":"transcription.segment","text":"Hello world","start":1.5,"end":3.2}"#

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(segmentJson)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        #expect(events.count == 2, "Segment should emit finalResult + utteranceEnd")

        // First: finalResult
        guard case .finalResult(let result) = events[0] else {
            Issue.record("Expected .finalResult, got: \(events[0])"); return
        }
        #expect(result.transcript == "Hello world")
        #expect(result.isFinal == true)
        #expect(result.speechFinal == true)
        #expect(result.start == 1.5)
        #expect(abs(result.duration - 1.7) < 0.01, "Duration should be end - start = 1.7")

        // Second: utteranceEnd
        guard case .utteranceEnd(let lastWordEnd) = events[1] else {
            Issue.record("Expected .utteranceEnd, got: \(events[1])"); return
        }
        #expect(abs(lastWordEnd - 3.2) < 0.01, "lastWordEnd should be segment end time")
    }

    @Test
    func parseMessage_segment_usesPendingTextAsFallback() async {
        let session = makeSession()

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                // Skip interim, capture final + utteranceEnd
                if events.count == 3 { break }
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        // First accumulate some delta text
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"accumulated text"}"#)
        try? await Task.sleep(for: .milliseconds(30))
        // Then segment without text — should use accumulated pending text
        await session.parseMessage(#"{"type":"transcription.segment","text":"","start":0,"end":1}"#)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        // Should have: interim("accumulated text"), finalResult("accumulated text"), utteranceEnd
        let finals = events.compactMap { event -> TranscriptionResult? in
            if case .finalResult(let r) = event { return r }
            return nil
        }
        #expect(finals.count == 1)
        #expect(finals[0].transcript == "accumulated text",
                "Segment with empty text should use accumulated pending delta text")
    }

    @Test
    func parseMessage_segment_resetsPendingText() async {
        let session = makeSession()

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if events.count == 4 { break }
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        // Accumulate + segment
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"first"}"#)
        try? await Task.sleep(for: .milliseconds(20))
        await session.parseMessage(#"{"type":"transcription.segment","text":"first","start":0,"end":1}"#)
        try? await Task.sleep(for: .milliseconds(20))
        // New delta after segment should start fresh
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"second"}"#)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        let interims = events.compactMap { event -> TranscriptionResult? in
            if case .interim(let r) = event { return r }
            return nil
        }
        // Last interim should be just "second", not "firstsecond"
        let lastInterim = interims.last
        #expect(lastInterim?.transcript == "second",
                "After segment, pending text should reset. Got: \(lastInterim?.transcript ?? "nil")")
    }

    // MARK: transcription.language

    @Test
    func parseMessage_language_doesNotCrash() async {
        let session = makeSession()
        // Language events are informational — just ensure no crash
        await session.parseMessage(#"{"type":"transcription.language","audio_language":"en"}"#)
        await session.parseMessage(#"{"type":"transcription.language","audio_language":"fr"}"#)
    }

    // MARK: transcription.done

    @Test
    func parseMessage_done_flushesPendingText() async {
        let session = makeSession()

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"trailing"}"#)
        try? await Task.sleep(for: .milliseconds(20))
        await session.parseMessage(#"{"type":"transcription.done","text":"trailing","model":"voxtral","usage":{}}"#)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        let finals = events.compactMap { event -> TranscriptionResult? in
            if case .finalResult(let r) = event { return r }
            return nil
        }
        #expect(finals.count == 1)
        #expect(finals[0].transcript == "trailing")
        #expect(finals[0].isFinal == true)
    }

    // MARK: session.created

    @Test
    func parseMessage_sessionCreated_emitsMetadata() async {
        let session = makeSession()
        let json = #"{"type":"session.created","session":{"request_id":"ws-abc123","model":"voxtral","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#

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
        #expect(requestId == "ws-abc123")
    }

    // MARK: error

    @Test
    func parseMessage_error_emitsError() async {
        let session = makeSession()
        let json = #"{"type":"error","error":{"message":"Rate limit exceeded","code":429}}"#

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
        guard case .error(let error) = events.first else {
            Issue.record("Expected .error, got: \(events)")
            return
        }
        let desc = error.localizedDescription
        #expect(desc.contains("Rate limit exceeded") || desc.contains("429"),
                "Error should contain the message or code, got: \(desc)")
    }

    @Test
    func parseMessage_error_withDictMessage() async {
        let session = makeSession()
        // The SDK supports message as string OR dict with "detail" key
        let json = #"{"type":"error","error":{"message":{"detail":"Bad audio format"},"code":400}}"#

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
        guard case .error(let error) = events.first else {
            Issue.record("Expected .error"); return
        }
        #expect(error.localizedDescription.contains("Bad audio format"))
    }

    // MARK: session.updated

    @Test
    func parseMessage_sessionUpdated_doesNotCrash() async {
        let session = makeSession()
        // session.updated is informational — just ensure no crash or unexpected event
        await session.parseMessage(#"{"type":"session.updated","session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#)
    }

    // MARK: close() flushes pending text
    //
    // Note: these tests call close() on a session that was never connect()ed,
    // so isConnected == false and the stream is never finished. We collect events
    // by listening for a bounded number of events before calling close(), then
    // verifying what arrived — same pattern as the other parseMessage tests.

    @Test
    func close_flushesPendingDeltaText() async {
        let session = makeSession()

        // Collect up to 3 events (2 interims + 1 final from close flush)
        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if events.count == 3 { break }
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"pending "}"#)
        try? await Task.sleep(for: .milliseconds(20))
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"text"}"#)
        try? await Task.sleep(for: .milliseconds(20))

        // Force close() to yield the pending flush by marking session connected
        // so the flush branch runs, then collect the finalResult
        await session._testSetConnected(true)
        try? await session.close()
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        let finals = events.compactMap { e -> TranscriptionResult? in
            if case .finalResult(let r) = e { return r } else { return nil }
        }
        #expect(finals.count == 1, "close() must flush pending delta text as a final result")
        #expect(finals[0].transcript == "pending text",
                "Flushed text must contain all accumulated deltas")
        #expect(finals[0].isFinal == true)
        #expect(finals[0].speechFinal == true)
    }

    @Test
    func close_withNoPendingText_doesNotEmitFinal() async {
        let session = makeSession()

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                // If anything arrives, grab it and stop
                break
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session._testSetConnected(true)
        try? await session.close()
        // Give close time to flush (it should produce nothing)
        try? await Task.sleep(for: .milliseconds(80))
        eventTask.cancel()

        // Nothing should have been emitted
        let events = await eventTask.value
        let finals = events.compactMap { e -> TranscriptionResult? in
            if case .finalResult(let r) = e { return r } else { return nil }
        }
        #expect(finals.isEmpty, "close() with no pending text must not emit a final result")
    }

    @Test
    func close_afterSegment_doesNotDoubleFinal() async {
        let session = makeSession()

        // Expect: interim, finalResult (segment), utteranceEnd, then nothing extra from close
        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if events.count == 3 { break }
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"hello"}"#)
        try? await Task.sleep(for: .milliseconds(20))
        await session.parseMessage(#"{"type":"transcription.segment","text":"hello","start":0,"end":1}"#)
        try? await Task.sleep(for: .milliseconds(50))

        // close() after segment: pendingDeltaText was reset, so no extra flush
        await session._testSetConnected(true)
        try? await session.close()
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        let finals = events.compactMap { e -> TranscriptionResult? in
            if case .finalResult(let r) = e { return r } else { return nil }
        }
        #expect(finals.count == 1,
                "Only the segment should produce a final, not close(). Got \(finals.count)")
        #expect(finals[0].transcript == "hello")
    }

    @Test
    func close_isIdempotent() async {
        let session = makeSession()

        let eventTask = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if events.count == 2 { break } // interim + final from first close
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(50))
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"once"}"#)
        try? await Task.sleep(for: .milliseconds(20))

        await session._testSetConnected(true)
        try? await session.close()
        // Second close should be a no-op (isConnected is now false)
        try? await session.close()
        try? await Task.sleep(for: .milliseconds(50))

        let events = await eventTask.value
        let finals = events.compactMap { e -> TranscriptionResult? in
            if case .finalResult(let r) = e { return r } else { return nil }
        }
        #expect(finals.count == 1, "Double close must not double-flush. Got \(finals.count)")
        #expect(finals[0].transcript == "once")
    }

    // MARK: Malformed input

    @Test
    func parseMessage_malformedJSON_doesNotCrash() async {
        let session = makeSession()
        await session.parseMessage("{not valid json")
        await session.parseMessage("")
        await session.parseMessage("[]")
        await session.parseMessage(#"{"type":42}"#)  // type is not a string
        await session.parseMessage(#"{"no_type_field":true}"#)
    }

    @Test
    func parseMessage_unknownType_doesNotCrash() async {
        let session = makeSession()
        await session.parseMessage(#"{"type":"some.future.event","data":"whatever"}"#)
    }
}

// MARK: - MistralProvider — Configuration & Metadata

@Suite("MistralProvider — Configuration")
struct MistralProviderConfigTests {

    @Test @MainActor func testMistralProvider_isStreamingMode() {
        let provider = MistralProvider()
        #expect(provider.mode == .streaming)
        #expect(provider.id == ProviderId.mistral)
        #expect(provider.displayName == "Mistral")
    }

    @Test @MainActor func testMistralBatchProvider_isBatchMode() {
        let provider = MistralBatchProvider()
        #expect(provider.mode == .batch)
        #expect(provider.id == ProviderId.mistralBatch)
        #expect(provider.displayName == "Mistral")
    }

    @Test @MainActor func testMistralProvider_sharesApiKeyWithBatch() {
        let realtimeProvider = MistralProvider()
        let batchProvider = MistralBatchProvider()
        // Both should reference the same ProviderId.mistral for API key storage
        if case .apiKey(let realtimeKeyId) = realtimeProvider.authRequirement,
           case .apiKey(let batchKeyId) = batchProvider.authRequirement {
            #expect(realtimeKeyId == batchKeyId,
                    "Both Mistral providers must share the same API key ID")
            #expect(realtimeKeyId == ProviderId.mistral)
        } else {
            Issue.record("Both Mistral providers must use .apiKey auth")
        }
    }

    @Test @MainActor func testMistralProvider_notConfiguredWithoutKey() {
        let provider = MistralProvider()
        // In test mode, UnifiedAuthStorage uses isolated temp dir — no key present
        #expect(!provider.isConfigured,
                "Mistral should not be configured without an API key")
    }

    @Test @MainActor func testMistralBatchProvider_notConfiguredWithoutKey() {
        let provider = MistralBatchProvider()
        #expect(!provider.isConfigured,
                "Mistral batch should not be configured without an API key")
    }

    @Test @MainActor func testMistralProvider_startSessionFailsWithoutKey() async {
        // Skip when MISTRAL_API_KEY env var is set — ProviderSettings falls back to env
        guard ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] == nil else { return }
        let provider = MistralProvider()
        do {
            _ = try await provider.startSession(config: .default)
            Issue.record("Should throw missingApiKey")
        } catch let error as MistralError {
            if case .missingApiKey = error {} else {
                Issue.record("Expected .missingApiKey, got: \(error)")
            }
        } catch {
            Issue.record("Expected MistralError, got: \(error)")
        }
    }

    @Test @MainActor func testMistralBatchProvider_transcribeFailsWithoutKey() async {
        // Skip when MISTRAL_API_KEY env var is set — ProviderSettings falls back to env
        guard ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] == nil else { return }
        let provider = MistralBatchProvider()
        do {
            _ = try await provider.transcribe(audio: Data())
            Issue.record("Should throw missingApiKey")
        } catch let error as MistralBatchError {
            if case .missingApiKey = error {} else {
                Issue.record("Expected .missingApiKey, got: \(error)")
            }
        } catch {
            Issue.record("Expected MistralBatchError, got: \(error)")
        }
    }

    @Test @MainActor func testMistralProvider_buildSessionConfig() {
        let config = MistralProvider().buildSessionConfig()
        #expect(config.sampleRate == 16000, "Mistral requires 16kHz PCM")
        #expect(config.encoding == .linear16, "Mistral requires linear16 (pcm_s16le)")
        #expect(config.model == "voxtral-mini-transcribe-realtime-2602")
    }
}

// MARK: - MistralError — Localized Descriptions

@Suite("MistralError — Error Messages")
struct MistralErrorTests {

    @Test func testMistralError_descriptions() {
        let errors: [(MistralError, String)] = [
            (.missingApiKey, "not configured"),
            (.connectionFailed("timeout"), "timeout"),
            (.sessionClosed, "closed"),
            (.serverError("rate limit", code: 429), "429"),
        ]
        for (error, expected) in errors {
            let desc = error.localizedDescription
            #expect(desc.localizedLowercase.contains(expected.lowercased()),
                    "Error '\(error)' description should contain '\(expected)', got: \(desc)")
        }
    }

    @Test func testMistralBatchError_descriptions() {
        let errors: [(MistralBatchError, String)] = [
            (.missingApiKey, "not configured"),
            (.rateLimited, "Rate limited"),
            (.audioTooLarge(size: 30_000_000), "too large"),
            (.httpError(statusCode: 500, body: "internal"), "500"),
        ]
        for (error, expected) in errors {
            let desc = error.localizedDescription
            #expect(desc.contains(expected),
                    "Error '\(error)' description should contain '\(expected)', got: \(desc)")
        }
    }

    @Test func testMistralBatchError_retryability() {
        #expect(MistralBatchError.rateLimited.isRetryable)
        #expect(MistralBatchError.networkError("timeout").isRetryable)
        #expect(MistralBatchError.httpError(statusCode: 500, body: "").isRetryable)
        #expect(MistralBatchError.httpError(statusCode: 502, body: "").isRetryable)
        #expect(!MistralBatchError.httpError(statusCode: 400, body: "").isRetryable)
        #expect(!MistralBatchError.missingApiKey.isRetryable)
        #expect(!MistralBatchError.audioTooLarge(size: 1).isRetryable)
        #expect(!MistralBatchError.invalidResponse("bad").isRetryable)
    }
}

// MARK: - Mistral Settings — Defaults & Persistence

@Suite("Mistral Settings — Defaults")
struct MistralSettingsTests {

    @Test @MainActor func testMistralSettingsDefaults() {
        let settings = Settings.shared
        #expect(settings.mistralModel == "voxtral-mini-transcribe-realtime-2602")
        #expect(settings.mistralBatchModel == "voxtral-mini-latest")
        #expect(settings.mistralLanguage == "en")
        #expect(settings.mistralTemperature == 0.0)
        #expect(settings.mistralDiarize == false)
    }

    @Test @MainActor func testMistralSettings_roundTrip() {
        let settings = Settings.shared
        let origModel = settings.mistralBatchModel
        let origLang = settings.mistralLanguage
        let origTemp = settings.mistralTemperature
        let origDiarize = settings.mistralDiarize
        defer {
            settings.mistralBatchModel = origModel
            settings.mistralLanguage = origLang
            settings.mistralTemperature = origTemp
            settings.mistralDiarize = origDiarize
        }

        settings.mistralBatchModel = "voxtral-mini-latest"
        settings.mistralLanguage = "fr"
        settings.mistralTemperature = 0.5
        settings.mistralDiarize = true

        #expect(settings.mistralBatchModel == "voxtral-mini-latest")
        #expect(settings.mistralLanguage == "fr")
        #expect(settings.mistralTemperature == 0.5)
        #expect(settings.mistralDiarize == true)
    }
}

@Suite("MistralStreamingSession — close() resource cleanup")
struct MistralCloseCleanupTests {
    @Test
    func closeInvalidatesURLSessionEvenWhenNotConnected() async throws {
        let session = MistralStreamingSession(apiKey: "test-key", config: .default)
        await session._testSetConnected(false)
        await session._testSetURLSession(URLSession(configuration: .ephemeral))

        try await session.close()

        #expect(await session._testDidInvalidateURLSession(),
                "close() must invalidate URLSession even when isConnected=false")
    }
}

@Suite("MistralStreamingSession — transcript log privacy")
struct MistralTranscriptPrivacySourceTests {
    @Test
    func transcriptLogsAreNotPublic() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/SpeakFlowCore/Providers/MistralProvider.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("logger.debug(\"delta: \\(text, privacy: .public)"))
        #expect(!source.contains("\\(segmentText, privacy: .public)"))
    }
}

@Suite("MistralBatchProvider — transcript log privacy")
struct MistralBatchTranscriptPrivacySourceTests {
    @Test
    func transcriptLogsAreNotPublic() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/SpeakFlowCore/Providers/MistralBatchProvider.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("\\(result.text.prefix(80), privacy: .public)"))
        #expect(!source.contains("\\(bodyText, privacy: .public)"))
    }
}
