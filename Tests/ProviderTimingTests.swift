import Foundation
import Testing
@testable import SpeakFlowCore

final class TimingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProviderTiming.Event] = []
    func append(_ event: ProviderTiming.Event) { lock.withLock { events.append(event) } }
    var values: [ProviderTiming.Event] { lock.withLock { events } }
}

private actor RetryingTimingHTTP: HTTPDataProvider {
    private var count = 0
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: count == 1 ? 503 : 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"text":"fixture"}"#.utf8), response)
    }
}

private struct FailingTimingHTTP: HTTPDataProvider {
    let code: URLError.Code
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "fixture-sensitive-error"])
    }
}

@Suite("Provider request timing", .serialized)
struct ProviderTimingTests {
    @Test func chatGPTAttemptsRemainCorrelatedAcrossRetry() async throws {
        let http = RetryingTimingHTTP()
        let service = TranscriptionService(
            loadCredentials: {
                try await Task.sleep(for: .milliseconds(20))
                return AuthCredentials(accessToken: "fixture-token", accountId: "fixture-account")
            },
            httpDataProvider: http, rateLimiter: RateLimiter(minimumInterval: 0)
        )
        let events = TimingEvents()
        let context = ProviderTiming.Correlation(sessionId: UUID())
        let text = try await ProviderTiming.$sink.withValue({ events.append($0) }) {
            try await ProviderTiming.$correlation.withValue(context) {
                try await service.transcribe(audio: Data([0]))
            }
        }
        #expect(text == "fixture")
        let finishes = events.values.filter { $0.name == "provider_attempt_finished" }
        #expect(finishes.count == 2)
        #expect(finishes.map { $0.metadata["outcome"] } == ["http_error", "success"])
        #expect(finishes.map { $0.metadata["httpStatus"] } == ["503", "200"])
        #expect(finishes.map { $0.metadata["attempt"] } == ["1", "2"])
        #expect(finishes.allSatisfy { $0.metadata["requestId"] == context.requestId.uuidString && $0.sessionId == context.sessionId })
        let phases = events.values.filter { $0.name == "provider_phase_finished" }
        for phase in ["rate_limit", "authentication", "request_build", "transport", "decode", "retry_delay"] {
            #expect(phases.contains { $0.metadata["phase"] == phase }, "Missing local phase: \(phase)")
        }
        let authentication = phases.filter { $0.metadata["phase"] == "authentication" }
        #expect(authentication.count == 2)
        #expect(authentication.allSatisfy { (Double($0.metadata["elapsedMs"] ?? "") ?? 0) >= 10 })
        #expect(phases.allSatisfy { $0.metadata["requestId"] == context.requestId.uuidString })
    }

    @Test @MainActor
    func batchFailuresHaveCategoricalOutcomes() async throws {
        let keys = SpyProviderSettings()
        try keys.setApiKey("fixture-secret", for: ProviderId.mistral)
        for (status, outcome) in [(429, "rate_limited"), (503, "http_error"), (401, "authentication_error"), (200, "invalid_response")] {
            let provider = MistralBatchProvider(
                providerSettings: keys, settings: SpySettings(), hasAPIKey: { _ in true },
                logger: SpyProviderLogger(), httpDataProvider: MockHTTPProvider(responseData: Data("fixture body".utf8), statusCode: status)
            )
            let events = TimingEvents()
            await ProviderTiming.$sink.withValue({ events.append($0) }) {
                do { _ = try await provider.transcribe(audio: Data([0])) } catch { }
            }
            let finishes = events.values.filter { $0.name == "provider_attempt_finished" }
            #expect(finishes.count == 1)
            let event = try #require(finishes.first)
            #expect(event.metadata["outcome"] == outcome)
            #expect(event.metadata["httpStatus"] == String(status))
            #expect(!String(describing: event.metadata).contains("fixture body"))
        }
    }

    @Test @MainActor
    func transportFailuresRetainOnlyNumericCodes() async throws {
        let keys = SpyProviderSettings()
        try keys.setApiKey("fixture-secret", for: ProviderId.mistral)
        for (code, outcome) in [(URLError.Code.timedOut, "timeout"), (.cancelled, "cancelled"), (.cannotConnectToHost, "transport_error")] {
            let provider = MistralBatchProvider(
                providerSettings: keys, settings: SpySettings(), hasAPIKey: { _ in true }, logger: SpyProviderLogger(),
                httpDataProvider: FailingTimingHTTP(code: code)
            )
            let events = TimingEvents()
            await ProviderTiming.$sink.withValue({ events.append($0) }) {
                do { _ = try await provider.transcribe(audio: Data([0])) } catch { }
            }
            let event = try #require(events.values.last { $0.name == "provider_attempt_finished" })
            #expect(event.metadata["outcome"] == outcome)
            #expect(event.metadata["urlErrorCode"] == String(code.rawValue))
            #expect(event.metadata["httpStatus"] == nil)
            #expect(!String(describing: event.metadata).contains("fixture-sensitive-error"))
        }
    }

    @Test @MainActor
    func batchSuccessLogsAnAttemptWithoutPayloads() async throws {
        let keys = SpyProviderSettings()
        try keys.setApiKey("fixture-secret", for: ProviderId.mistral)
        let provider = MistralBatchProvider(
            providerSettings: keys, settings: SpySettings(), hasAPIKey: { _ in true },
            logger: SpyProviderLogger(),
            httpDataProvider: MockHTTPProvider(responseData: Data(#"{"text":"fixture transcript"}"#.utf8))
        )
        let events = TimingEvents()
        let result = try await ProviderTiming.$sink.withValue({ events.append($0) }) {
            try await provider.transcribe(audio: Data("fixture audio".utf8))
        }
        #expect(result == "fixture transcript")
        let finishes = events.values.filter { $0.name == "provider_attempt_finished" }
        #expect(finishes.count == 1, "Every actual provider attempt needs one terminal timing event")
        let event = try #require(finishes.first)
        #expect(event.metadata["outcome"] == "success")
        #expect(event.metadata["httpStatus"] == "200")
        #expect(event.metadata["attempt"] == "1")
        #expect(Double(event.metadata["elapsedMs"] ?? "") != nil)
        let phases = events.values.filter { $0.name == "provider_phase_finished" }.compactMap { $0.metadata["phase"] }
        #expect(phases == ["configuration", "request_build", "transport", "decode"])
        let serialized = String(describing: events.values.map(\.metadata))
        for payload in ["fixture-secret", "fixture transcript", "fixture audio", "https://", "Authorization"] {
            #expect(!serialized.contains(payload), "Timing metadata must never contain payloads, credentials, or URLs")
        }
    }
}
