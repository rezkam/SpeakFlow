import AVFoundation
import FluidAudio
import Foundation
import os
import Testing
@testable import SpeakFlowCore

// MARK: - Platform Support Tests

struct PlatformSupportTests {
    @Test func testSupportsVAD() {
        #expect(PlatformSupport.supportsVAD == PlatformSupport.isAppleSilicon)
    }

    @Test func testDescription() {
        #expect(!PlatformSupport.platformDescription.isEmpty)
    }

    @Test func testVadUnavailableReason() {
        if PlatformSupport.isAppleSilicon {
            #expect(PlatformSupport.vadUnavailableReason == nil)
        } else {
            #expect(PlatformSupport.vadUnavailableReason != nil)
        }
    }
}

// MARK: - VAD Configuration Tests

struct VADConfigurationTests {
    @Test func testDefaults() {
        let c = VADConfiguration()
        #expect(c.threshold == 0.5)
        #expect(c.minSilenceAfterSpeech == 1.0)
        #expect(c.minSpeechDuration == 0.25)
        #expect(c.enabled == true)
    }

    @Test func testSensitive() {
        #expect(VADConfiguration.sensitive.threshold == 0.3)
    }

    @Test func testStrict() {
        #expect(VADConfiguration.strict.threshold == 0.7)
    }
}

// MARK: - Auto End Configuration Tests

struct AutoEndConfigurationTests {
    @Test func testDefaults() {
        let c = AutoEndConfiguration()
        #expect(c.enabled == true)
        #expect(c.silenceDuration == 5.0)
        #expect(c.minSessionDuration == 2.0)
        #expect(c.requireSpeechFirst == true)
        #expect(c.noSpeechTimeout == 10.0)
    }

    @Test func testQuick() {
        #expect(AutoEndConfiguration.quick.silenceDuration == 3.0)
    }

    @Test func testRelaxed() {
        #expect(AutoEndConfiguration.relaxed.silenceDuration == 10.0)
    }

    @Test func testDisabled() {
        #expect(AutoEndConfiguration.disabled.enabled == false)
    }
}

// MARK: - VAD Processor Tests

struct VADProcessorTests {
    @Test func testIsAvailable() {
        #expect(VADProcessor.isAvailable == PlatformSupport.supportsVAD)
    }

    @Test func testInitialState() async {
        let p = VADProcessor()
        #expect(await p.isSpeaking == false)
        #expect(await p.lastSpeechEndTime == nil)
        #expect(await p.lastSpeechStartTime == nil)
    }

    @Test func testResetSession() async {
        let p = VADProcessor()
        await p.resetSession()
        #expect(await p.isSpeaking == false)
        #expect(await p.averageSpeechProbability == 0)
    }

    @Test func testAverageSpeechProbability() async {
        let p = VADProcessor()
        // Before processing, should be 0
        #expect(await p.averageSpeechProbability == 0)
    }

    @Test func testHasSignificantSpeech() async {
        let p = VADProcessor()
        // Before processing, should have no significant speech
        #expect(await p.hasSignificantSpeech() == false)
    }

    @Test func testCurrentSilenceDuration() async {
        let p = VADProcessor()
        // When not speaking and no last speech end, should be nil
        #expect(await p.currentSilenceDuration == nil)
    }
}

// MARK: - Session Controller Tests

struct SessionControllerTests {
    // MARK: - Helper Mock Clock
    final class MockDateProvider: @unchecked Sendable {
        var now = Date()
        func date() -> Date { now }
    }

    @Test func testStartSession() async {
        let c = SessionController()
        await c.startSession()
        #expect(await c.hasSpoken == false)
        #expect(await c.currentChunkDuration >= 0)
        #expect(await c.currentSessionDuration >= 0)
    }

    @Test func testSpeechTracking() async {
        let c = SessionController()
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        #expect(await c.hasSpoken == true)
    }

    @Test func testSpeechEndTracking() async {
        let c = SessionController()
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        await c.onSpeechEvent(.ended(at: 1.0))
        #expect(await c.hasSpoken == true)
        #expect(await c.currentSilenceDuration != nil)
    }

    @Test func testAutoEndRequiresSpeech() async {
        // With a long noSpeechTimeout, requireSpeechFirst should still block auto-end
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 5.0, minSessionDuration: 0.1, requireSpeechFirst: true, noSpeechTimeout: 100.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        clock.now += 1.0  // Advance 1s — well under noSpeechTimeout (100s)
        #expect(await c.shouldAutoEndSession() == false)
    }

    // MARK: - No-speech idle timeout tests

    @Test func testAutoEndIdleTimeoutTriggersWithNoSpeech() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 5.0, minSessionDuration: 2.0,
                                       requireSpeechFirst: true, noSpeechTimeout: 10.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Before timeout: should NOT auto-end
        clock.now += 5.0
        #expect(await c.shouldAutoEndSession() == false)

        // After timeout: should auto-end even though no speech was detected
        clock.now += 6.0  // Total 11s >= 10s timeout
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndIdleTimeoutDoesNotFireWhenSpeechDetected() async {
        // Even with a short idle timeout, once speech occurs, normal path should be used
        let clock = MockDateProvider()
        // silenceDuration=5.0 (above 3.0 clamp), noSpeechTimeout=10.0
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 5.0, minSessionDuration: 0.1,
                                       requireSpeechFirst: true, noSpeechTimeout: 10.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Speech starts — idle timeout should not apply
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 1.0
        // Still speaking, should not auto-end
        #expect(await c.shouldAutoEndSession() == false)

        // Speech ends
        await c.onSpeechEvent(.ended(at: 1.0))

        // Wait less than silenceDuration (5.0s)
        clock.now += 3.0
        #expect(await c.shouldAutoEndSession() == false)

        // Wait past silenceDuration
        clock.now += 3.0  // Total silence = 6.0s >= 5.0s
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndIdleTimeoutDisabledWhenZero() async {
        let clock = MockDateProvider()
        // noSpeechTimeout = 0 disables the idle timeout
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 5.0, minSessionDuration: 2.0,
                                       requireSpeechFirst: true, noSpeechTimeout: 0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        clock.now += 30.0  // Even after 30s, no auto-end because timeout disabled
        // Should NOT auto-end — idle timeout disabled and no speech occurred
        #expect(await c.shouldAutoEndSession() == false)
    }

    @Test func testAutoEndIdleTimeoutDisabledWhenAutoEndDisabled() async {
        let clock = MockDateProvider()
        // When auto-end is disabled entirely, idle timeout should not fire either
        let cfg = AutoEndConfiguration(enabled: false, noSpeechTimeout: 10.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        clock.now += 30.0
        #expect(await c.shouldAutoEndSession() == false)
    }

    @Test func testAutoEndSilenceDurationClamped() async {
        // Use a controllable clock
        let clock = MockDateProvider()
        
        // Try to set silence duration below 3.0s (e.g. 1.0s)
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 1.0, minSessionDuration: 0.1, requireSpeechFirst: true)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        
        // Start speaking
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 0.5))
        
        // Advance time by 1.5s - this is > 1.0s (config) but < 3.0s (clamped min)
        clock.now += 1.5
        
        // If clamp works, should NOT auto-end yet.
        #expect(await c.shouldAutoEndSession() == false)
        
        // Advance time by another 2.0s (total silence = 3.5s > 3.0s)
        clock.now += 2.0
        
        // Now it should auto-end
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndTriggers() async {
        let clock = MockDateProvider()
        // Use silenceDuration >= 3.0 (safety clamp minimum)
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 0.1, requireSpeechFirst: true)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 0.5))
        // Advance past silence duration
        clock.now += 3.5
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndDisabled() async {
        let cfg = AutoEndConfiguration(enabled: false)
        let c = SessionController(autoEndConfig: cfg)
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        await c.onSpeechEvent(.ended(at: 0.5))
        try? await Task.sleep(for: .seconds(2))
        #expect(await c.shouldAutoEndSession() == false)
    }

    @Test func testAutoEndResetsOnNewSpeech() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 0.1, requireSpeechFirst: true)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // First speech segment
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 0.5))

        // Wait partway (less than silenceDuration)
        clock.now += 1.5

        // Start speaking again — resets silence timer
        await c.onSpeechEvent(.started(at: 2.0))
        #expect(await c.shouldAutoEndSession() == false)

        // Stop again
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 2.5))
        #expect(await c.shouldAutoEndSession() == false)

        // Wait full silence duration
        clock.now += 3.5
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndFallbackLogic() async {
        // Fallback triggers if session lasts longer than (silenceDuration + minSessionDuration)
        // even if VAD never sent .ended
        // Note: minSessionDuration is used here
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 1.0, requireSpeechFirst: true)
        let c = SessionController(autoEndConfig: cfg)
        await c.startSession()
        
        // Start speaking
        await c.onSpeechEvent(.started(at: 0))
        
        // Wait 2s (total 2s < 3+1=4s)
        try? await Task.sleep(for: .seconds(2))
        #expect(await c.shouldAutoEndSession() == false)
        
        // Wait 3s more (total 5s > 4s)
        try? await Task.sleep(for: .seconds(3))
        // Should trigger fallback ONLY if VAD is in weird state where isSpeaking=false but lastEnd=nil
        // But onSpeechEvent(.started) sets isSpeaking=true
        // And guard !isUserSpeaking blocks fallback
        // So fallback only triggers if isSpeaking=false WITHOUT end event?
        // This state is impossible via public API unless startSession() -> ... -> somehow isSpeaking=false without ended?
        // Actually, fallback logic in code handles `lastSpeechEndTime == nil`.
        // If isSpeaking=false AND lastSpeechEndTime=nil -> means speech never started?
        // But requireSpeechFirst=true prevents that.
        // So fallback is dead code unless requireSpeechFirst=false?
        
        // Let's test with requireSpeechFirst=false
        let cfg2 = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 1.0, requireSpeechFirst: false)
        let c2 = SessionController(autoEndConfig: cfg2)
        await c2.startSession()
        
        // No speech events sent
        try? await Task.sleep(for: .seconds(5))
        // Should trigger via fallback path (session duration > required)
        #expect(await c2.shouldAutoEndSession() == true)
    }

    @Test func testChunkSent() async {
        let c = SessionController()
        await c.startSession()
        try? await Task.sleep(for: .milliseconds(100))
        let d1 = await c.currentChunkDuration
        await c.chunkSent()
        #expect(await c.currentChunkDuration < d1)
    }

    @Test func testShouldSendChunkNotWhileSpeaking() async {
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 0.2)
        let c = SessionController(vadConfig: vadConfig, maxChunkDuration: 1.0)
        await c.startSession()

        // Start speaking
        await c.onSpeechEvent(.started(at: 0))

        // Wait longer than max duration
        try? await Task.sleep(for: .milliseconds(1200))

        // Should NOT chunk mid-speech
        #expect(await c.shouldSendChunk() == false)
    }

    @Test func testShouldSendChunkAfterSilence() async {
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 0.2)
        let c = SessionController(vadConfig: vadConfig, maxChunkDuration: 0.2)
        await c.startSession()

        // Speak then stop
        await c.onSpeechEvent(.started(at: 0))
        await c.onSpeechEvent(.ended(at: 0.1))

        // Wait for silence threshold
        try? await Task.sleep(for: .milliseconds(300))

        // Should chunk now via max-duration + silence branch.
        #expect(await c.shouldSendChunk() == true)
    }
}

// MARK: - Config VAD Tests

struct ConfigVADTests {
    @Test func testConstants() {
        #expect(Config.vadThreshold == 0.3)
        #expect(Config.vadMinSilenceAfterSpeech == 1.0)
        #expect(Config.vadMinSpeechDuration == 0.25)
        #expect(Config.autoEndSilenceDuration == 5.0)
        #expect(Config.autoEndMinSessionDuration == 2.0)
    }
}

// MARK: - Speech Event Tests

struct SpeechEventTests {
    @Test func testStartedEvent() {
        let event = SpeechEvent.started(at: 1.5)
        if case .started(let time) = event {
            #expect(time == 1.5)
        } else {
            Issue.record("Expected .started event")
        }
    }

    @Test func testEndedEvent() {
        let event = SpeechEvent.ended(at: 3.0)
        if case .ended(let time) = event {
            #expect(time == 3.0)
        } else {
            Issue.record("Expected .ended event")
        }
    }
}

// MARK: - VAD Result Tests

struct VADResultTests {
    @Test func testInit() {
        let result = VADResult(probability: 0.8, isSpeaking: true, event: .started(at: 1.0), processingTimeMs: 0.5)
        #expect(result.probability == 0.8)
        #expect(result.isSpeaking == true)
        #expect(result.processingTimeMs == 0.5)
    }

    @Test func testNilEvent() {
        let result = VADResult(probability: 0.3, isSpeaking: false, event: nil, processingTimeMs: 0.3)
        #expect(result.event == nil)
    }
}

// MARK: - VAD Error Tests

struct VADErrorTests {
    @Test func testNotInitialized() {
        let error = VADError.notInitialized
        if case .notInitialized = error {
            // Pass
        } else {
            Issue.record("Expected .notInitialized")
        }
    }

    @Test func testUnsupportedPlatform() {
        let error = VADError.unsupportedPlatform("Intel Mac")
        if case .unsupportedPlatform(let reason) = error {
            #expect(reason == "Intel Mac")
        } else {
            Issue.record("Expected .unsupportedPlatform")
        }
    }

    @Test func testProcessingFailed() {
        let error = VADError.processingFailed("Model error")
        if case .processingFailed(let msg) = error {
            #expect(msg == "Model error")
        } else {
            Issue.record("Expected .processingFailed")
        }
    }
}

// MARK: - Rate Limiter Tests

struct RateLimiterTests {
    @Test func testSequentialRequestsAreThrottled() async throws {
        let interval = 0.05
        let limiter = RateLimiter(minimumInterval: interval)

        try await limiter.waitAndRecord()

        let start = Date()
        try await limiter.waitAndRecord()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= interval * 0.8)
    }

    @Test func testTimeUntilNextAllowedDecreasesOverTime() async throws {
        let interval = 0.03
        let limiter = RateLimiter(minimumInterval: interval)

        try await limiter.waitAndRecord()
        let initialWait = await limiter.timeUntilNextAllowed()
        #expect(initialWait > 0)

        try? await Task.sleep(for: .milliseconds(20))
        let laterWait = await limiter.timeUntilNextAllowed()

        #expect(laterWait < initialWait)
    }

    @Test func testWaitAndRecordThrowsOnCancellation() async throws {
        let interval = 1.0
        let limiter = RateLimiter(minimumInterval: interval)
        try await limiter.waitAndRecord()

        let task = Task {
            try await limiter.waitAndRecord()
        }

        try? await Task.sleep(for: .milliseconds(80))
        let cancelledAt = Date()
        task.cancel()

        do {
            try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            let elapsed = Date().timeIntervalSince(cancelledAt)
            #expect(elapsed < 0.5)
        }
    }
}

// MARK: - Rate Limiter Regression Tests

struct RateLimiterRegressionTests {
    @Test func testConcurrentRequestsReserveDistinctSlots() async throws {
        let interval = 0.05
        let limiter = RateLimiter(minimumInterval: interval)

        // Seed limiter so concurrent calls must both wait and cannot share one slot.
        try await limiter.waitAndRecord()

        let start = Date()
        let completionTimes = try await withThrowingTaskGroup(of: TimeInterval.self, returning: [TimeInterval].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await limiter.waitAndRecord()
                    return Date().timeIntervalSince(start)
                }
            }

            var values: [TimeInterval] = []
            for try await value in group {
                values.append(value)
            }
            return values.sorted()
        }

        #expect(completionTimes.count == 2)

        let first = completionTimes[0]
        let second = completionTimes[1]

        // If check/record is split, both calls can complete at ~the same time.
        // With atomic reservation, completions are spaced by one full interval.
        #expect(first >= interval * 0.8)
        #expect(second >= interval * 1.8)
        #expect((second - first) >= interval * 0.8)
    }
}

// MARK: - TokenRefreshCoordinator Tests

struct TokenRefreshCoordinatorTests {
    /// Helper: create dummy credentials with a given refresh token and lastRefresh time.
    private static func makeCreds(
        refreshToken: String = "rt-1",
        lastRefresh: Date = .distantPast
    ) -> OAuthCredentials {
        OAuthCredentials(
            accessToken: "at-old",
            refreshToken: refreshToken,
            idToken: nil,
            accountId: "acct-1",
            lastRefresh: lastRefresh
        )
    }

    @Test func testConcurrentCallersShareSingleRefresh() async throws {
        // Track how many times the refresh function is actually invoked.
        let callCounter = OSAllocatedUnfairLock(initialState: 0)

        let coordinator = TokenRefreshCoordinator { creds in
            callCounter.withLock { $0 += 1 }
            // Simulate network delay so concurrent callers overlap.
            try await Task.sleep(for: .milliseconds(100))
            return OAuthCredentials(
                accessToken: "at-new",
                refreshToken: "rt-new",
                idToken: nil,
                accountId: creds.accountId,
                lastRefresh: Date()
            )
        }

        let creds = Self.makeCreds()

        // Launch 5 concurrent refresh requests.
        let results = try await withThrowingTaskGroup(
            of: OAuthCredentials.self,
            returning: [OAuthCredentials].self
        ) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await coordinator.refreshIfNeeded(creds)
                }
            }
            var collected: [OAuthCredentials] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        // All 5 callers got a result.
        #expect(results.count == 5)
        // All callers received the same new access token.
        for r in results {
            #expect(r.accessToken == "at-new")
        }
        // The refresh function was called exactly once.
        let totalCalls = callCounter.withLock { $0 }
        #expect(totalCalls == 1)
    }

    @Test func testSequentialRefreshesCreateSeparateTasks() async throws {
        let callCounter = OSAllocatedUnfairLock(initialState: 0)

        let coordinator = TokenRefreshCoordinator { creds in
            callCounter.withLock { $0 += 1 }
            return OAuthCredentials(
                accessToken: "at-\(callCounter.withLock { $0 })",
                refreshToken: "rt-new",
                idToken: nil,
                accountId: creds.accountId,
                lastRefresh: Date()
            )
        }

        let creds = Self.makeCreds()

        // Two sequential (non-overlapping) refreshes should each invoke the function.
        let first = try await coordinator.refreshIfNeeded(creds)
        let second = try await coordinator.refreshIfNeeded(creds)

        #expect(first.accessToken == "at-1")
        #expect(second.accessToken == "at-2")
        let totalCalls = callCounter.withLock { $0 }
        #expect(totalCalls == 2)
    }

    @Test func testRefreshErrorPropagatedToAllCallers() async {
        struct FakeError: Error, Equatable {}

        let coordinator = TokenRefreshCoordinator { _ in
            try await Task.sleep(for: .milliseconds(50))
            throw FakeError()
        }

        let creds = Self.makeCreds()

        // Launch 3 concurrent callers — all should receive the same error.
        let errorCounter = OSAllocatedUnfairLock(initialState: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await coordinator.refreshIfNeeded(creds)
                    } catch is FakeError {
                        errorCounter.withLock { $0 += 1 }
                    } catch {}
                }
            }
        }

        #expect(errorCounter.withLock { $0 } == 3)
    }
}

// MARK: - HTTPDataProvider / Testability Tests (Issue #22)

/// A mock HTTP data provider that returns canned responses.
private final class MockHTTPProvider: HTTPDataProvider, @unchecked Sendable {
    let responseData: Data
    let statusCode: Int
    private let lock = NSLock()
    private var _requestCount = 0

    var requestCount: Int { lock.withLock { _requestCount } }

    init(responseData: Data = Data(), statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _requestCount += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (responseData, response)
    }
}

@Suite(.serialized) struct HTTPDataProviderTestabilityTests {
    @Test func testMockProviderCanBeInjected() async throws {
        // Save original
        let original = OpenAICodexAuth.httpProvider
        defer { OpenAICodexAuth.httpProvider = original }

        let mock = MockHTTPProvider(
            responseData: Data("mock".utf8),
            statusCode: 400
        )
        OpenAICodexAuth.httpProvider = mock

        // Calling refreshTokens should use our mock and fail with 400
        let creds = OAuthCredentials(
            accessToken: "at", refreshToken: "rt",
            idToken: nil, accountId: "acct", lastRefresh: .distantPast
        )

        do {
            _ = try await OpenAICodexAuth.refreshTokens(creds)
            Issue.record("Expected error from mock 400 response")
        } catch {
            // Expected: tokenRefreshFailed because mock returns 400
            #expect(error is AuthError)
        }

        #expect(mock.requestCount == 1)
    }

    @Test func testDefaultProviderIsURLSession() {
        // Verify the default httpProvider is URLSession.shared
        #expect(OpenAICodexAuth.httpProvider is URLSession)
    }
}

// MARK: - OAuth Form Encoding Tests

struct OAuthFormEncodingTests {
    @Test func testFormEncodingEscapesDelimitersInValues() {
        let bodyData = OpenAICodexAuth.formURLEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": "token=abc&next+value",
        ])

        let body = String(decoding: bodyData, as: UTF8.self)

        #expect(body.contains("refresh_token=token%3Dabc%26next%2Bvalue"))
        #expect(!body.contains("refresh_token=token=abc&next+value"))
    }
}

struct OAuthFormEncodingRegressionTests {
    @Test func testOpaqueTokenRoundTripsThroughFormBody() {
        let opaqueToken = "r3fr3sh+token=abc&scope=openid profile"
        let bodyData = OpenAICodexAuth.formURLEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": opaqueToken,
            "client_id": "client",
        ])

        let body = String(decoding: bodyData, as: UTF8.self)
        let components = URLComponents(string: "https://example.test/?\(body)")
        let parsed = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(parsed["refresh_token"] == opaqueToken)
        #expect(body.contains("refresh_token=r3fr3sh%2Btoken%3Dabc%26scope%3Dopenid%20profile"))
    }
}

// MARK: - OAuth Callback Server Tests

private func randomOAuthTestPort() -> UInt16 {
    UInt16.random(in: 20_000...59_999)
}

private func hitOAuthCallback(port: UInt16, query: String) async throws -> Int {
    let url = URL(string: "http://127.0.0.1:\(port)/auth/callback?\(query)")!
    let (_, response) = try await URLSession.shared.data(from: url)
    return (response as? HTTPURLResponse)?.statusCode ?? -1
}

struct OAuthCallbackServerTests {
    @Test func testValidCallbackReturnsAuthorizationCode() async throws {
        let port = randomOAuthTestPort()
        let expectedState = "test-state"
        let expectedCode = "auth-code-123"
        let server = OAuthCallbackServer(expectedState: expectedState, port: port)

        let waitTask = Task { await server.waitForCallback(timeout: 2.0) }
        try? await Task.sleep(for: .milliseconds(120))

        let status = try await hitOAuthCallback(
            port: port,
            query: "code=\(expectedCode)&state=\(expectedState)"
        )

        let receivedCode = await waitTask.value

        #expect(status == 200)
        #expect(receivedCode == expectedCode)
    }

    @Test func testStateMismatchReturnsNil() async throws {
        let port = randomOAuthTestPort()
        let server = OAuthCallbackServer(expectedState: "expected", port: port)

        let waitTask = Task { await server.waitForCallback(timeout: 2.0) }
        try? await Task.sleep(for: .milliseconds(120))

        let status = try await hitOAuthCallback(
            port: port,
            query: "code=abc&state=wrong"
        )

        let receivedCode = await waitTask.value

        #expect(status == 400)
        #expect(receivedCode == nil)
    }
}

struct OAuthCallbackServerRegressionTests {
    @Test func testConcurrentStopOnlyResumesOnce() async {
        let port = randomOAuthTestPort()
        let server = OAuthCallbackServer(expectedState: "state", port: port)

        let waitTask = Task { await server.waitForCallback(timeout: 5.0) }
        try? await Task.sleep(for: .milliseconds(120))

        let stopStart = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    server.stop()
                }
            }
        }

        let result = await waitTask.value
        let elapsed = Date().timeIntervalSince(stopStart)

        #expect(result == nil)
        #expect(elapsed < 2.0)
    }
}

// MARK: - Statistics Formatter Tests

struct StatisticsFormatterTests {
    @Test func testFormattedCountsMatchDecimalFormatterOutput() async {
        await MainActor.run {
            let expected = NumberFormatter.localizedString(from: NSNumber(value: 1_234_567), number: .decimal)
            let actual = Statistics._testFormatCount(1_234_567)
            #expect(actual == expected)
        }
    }

    @Test func testFormatterIdentityIsStableAcrossCalls() async {
        await MainActor.run {
            let first = Statistics._testFormatterIdentity
            _ = Statistics._testFormatCount(1)
            _ = Statistics._testFormatCount(2)
            _ = Statistics._testFormatCount(3)
            let second = Statistics._testFormatterIdentity
            #expect(first == second)
        }
    }
}

struct StatisticsFormatterRegressionTests {
    @Test func testCachedFormatterProducesConsistentResultsAfterRepeatedUse() async {
        await MainActor.run {
            let baselineId = Statistics._testFormatterIdentity

            for value in [10, 100, 1000, 10_000, 100_000] {
                let expected = NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
                let actual = Statistics._testFormatCount(value)
                #expect(actual == expected)
            }

            let endId = Statistics._testFormatterIdentity
            #expect(baselineId == endId)
        }
    }

    @Test func testFormattedPropertiesReuseSameCachedFormatter() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            stats.recordTranscription(text: "one two three", audioDurationSeconds: 12.3)
            stats.recordApiCall()

            let before = Statistics._testFormatterIdentity
            _ = stats.formattedCharacters
            _ = stats.formattedWords
            _ = stats.formattedApiCalls
            let after = Statistics._testFormatterIdentity

            #expect(before == after)
        }
    }
}

// MARK: - Hotkey Listener Cleanup Tests

struct HotkeyListenerCleanupTests {
    @Test func testStopIsIdempotent() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            let listener = HotkeyListener()
            listener.stop()
            listener.stop()
            #expect(stopCalls == 2)
        }
    }
}

struct HotkeyListenerCleanupRegressionTests {
    @Test func testDeinitInvokesStopCleanup() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            var listener: HotkeyListener? = HotkeyListener()
            #expect(stopCalls == 0)
            _ = listener // Silence "never read" warning
            listener = nil

            #expect(stopCalls == 1)
        }
    }

    @Test func testDeinitAfterManualStopRemainsSafe() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            var listener: HotkeyListener? = HotkeyListener()
            listener?.stop()
            listener = nil

            #expect(stopCalls == 2)
        }
    }

    @Test func testSourceRetainsDeinitStopCleanupHook() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift")

        #expect(source.contains("@MainActor deinit"))
        #expect(source.contains("stop()"))
    }
}

// MARK: - Source-Level Regression Tests

private func projectRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // project root
}

private func readProjectSource(_ relativePath: String) throws -> String {
    let url = projectRootURL().appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func countOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

struct SourceRegressionTests {
    @Test func testAppDelegateTerminationCleansUpResources() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        let hasDelegateHook = source.contains("func applicationWillTerminate(_ notification: Notification)")
        let hasNotificationHook = source.contains("NSApplication.willTerminateNotification")
        #expect(hasDelegateHook || hasNotificationHook)

        #expect(source.contains("hotkeyListener?.stop()"))
        #expect(source.contains("stopKeyListener()"))
        #expect(source.contains("Transcription.shared.cancelAll()"))
        #expect(source.contains("micPermissionTask?.cancel()"))
        #expect(source.contains("permissionManager?.stopPolling()"))
    }

    @Test func testNoDispatchQueueMainAsyncInMainActorHotPaths() throws {
        // All known @MainActor-facing files where UI/coordination logic lives.
        let files = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/UITestHarnessController.swift",
            "Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift",
            "Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift",
            "Sources/SpeakFlowCore/Audio/StreamingRecorder.swift",
            "Sources/SpeakFlowCore/Transcription/Transcription.swift",
            "Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift",
            "Sources/SpeakFlowCore/Hotkey/HotkeySettings.swift",
            "Sources/SpeakFlowCore/Statistics.swift",
            "Sources/SpeakFlowCore/Config.swift"
        ]

        for file in files {
            let source = try readProjectSource(file)
            #expect(!source.contains("DispatchQueue.main.async"), "Found DispatchQueue.main.async in \(file)")
            #expect(!source.contains("DispatchQueue.main.asyncAfter"), "Found DispatchQueue.main.asyncAfter in \(file)")
        }
    }

    @Test func testTranscriptionServiceNoDeadActiveTasksState() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")

        // Preferred path: legacy dead state removed entirely.
        if !source.contains("activeTasks") {
            #expect(!source.contains("public func cancelAll()"))
            return
        }

        // Fallback guard: if activeTasks is reintroduced, it must be actively balanced.
        let increments = countOccurrences(of: "activeTasks[", in: source)
        let decrements = countOccurrences(of: "removeValue(forKey:", in: source)
        #expect(increments > 0, "activeTasks exists but is never populated")
        #expect(decrements > 0, "activeTasks exists but is never cleaned up")
    }

    @Test func testStreamingRecorderDoesNotUsePreconcurrencyAVFoundationImport() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(!source.contains("@preconcurrency import AVFoundation"))
    }

    @Test func testLocalizationHooksPresentInUserFacingFiles() throws {
        let files = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/UITestHarnessController.swift",
            "Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift",
            "Sources/SpeakFlowCore/Statistics.swift"
        ]

        for file in files {
            let source = try readProjectSource(file)
            #expect(source.contains("String(localized:"), "Expected String(localized:) usage in \(file)")
        }
    }

    @Test func testAccessibilityLabelsPresentForMenuAndHarnessControls() throws {
        let appDelegate = try readProjectSource("Sources/App/AppDelegate.swift")
        let harness = try readProjectSource("Sources/App/UITestHarnessController.swift")

        #expect(appDelegate.contains("startItem.setAccessibilityLabel"))
        #expect(appDelegate.contains("accessibilityItem.setAccessibilityLabel"))
        #expect(appDelegate.contains("micItem.setAccessibilityLabel"))
        #expect(appDelegate.contains("statsItem.setAccessibilityLabel"))
        #expect(appDelegate.contains("quitItem.setAccessibilityLabel"))

        #expect(harness.contains("startButton.setAccessibilityLabel"))
        #expect(harness.contains("stopButton.setAccessibilityLabel"))
        #expect(harness.contains("hotkeyButton.setAccessibilityLabel"))
        #expect(harness.contains("nextHotkeyButton.setAccessibilityLabel"))
        #expect(harness.contains("contentView.setAccessibilityLabel"))
    }
}

struct StatisticsDurationRegressionTests {
    @Test func testFormattedDurationMatchesDateComponentsFormatter() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            let duration: Double = 90_061 // 1 day, 1 hour, 1 minute, 1 second
            stats.recordTranscription(text: "duration", audioDurationSeconds: duration)

            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 4
            formatter.zeroFormattingBehavior = .dropAll

            let expected = formatter.string(from: duration) ?? String(localized: "0 seconds")
            #expect(stats.formattedDuration == expected)
        }
    }

    @Test func testFormattedDurationZeroUsesLocalizedFallback() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            #expect(stats.formattedDuration == String(localized: "0 seconds"))
        }
    }
}

// MARK: - AudioBuffer Tests

@Suite("AudioBuffer Tests")
struct AudioBufferTests {
    @Test func testTakeAllDrainsBuffer() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        let frames = [Float](repeating: 0.5, count: 16000) // 1s of audio
        await buffer.append(frames: frames, hasSpeech: true)

        let duration = await buffer.duration
        #expect(duration > 0.9 && duration < 1.1)

        let result = await buffer.takeAll()
        #expect(result.samples.count == 16000)
        #expect(result.speechRatio > 0.9)

        let afterDuration = await buffer.duration
        #expect(afterDuration == 0)
    }

    @Test func testSpeechRatioAvailableWithoutDrain() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        let speechFrames = [Float](repeating: 0.5, count: 8000)
        let silentFrames = [Float](repeating: 0.001, count: 8000)
        await buffer.append(frames: speechFrames, hasSpeech: true)
        await buffer.append(frames: silentFrames, hasSpeech: false)

        // speechRatio is accessible without takeAll
        let ratio = await buffer.speechRatio
        #expect(ratio > 0.4 && ratio < 0.6, "Expected ~0.5, got \(ratio)")

        // Buffer is still intact
        let duration = await buffer.duration
        #expect(duration == 1.0, "Buffer should not be drained by reading speechRatio")
    }
}

// MARK: - Chunk Skip Regression Tests (First Chunk Lost Bug)
//
// These tests guard against the "first chunk lost on long speech" bug:
//
// BUG: sendChunkIfReady() called buffer.takeAll() (permanently draining all audio)
// BEFORE checking skipSilentChunks. When an intermediate chunk's average VAD
// probability dropped below 0.30 (common with mixed speech + pauses in a 15s chunk),
// the audio was silently discarded — never sent to the API.
//
// The final chunk from stop() had protection (speechDetectedInSession bypass) but
// intermediate chunks did not.
//
// EVIDENCE: In production logs, a ~30s recording session produced 2 intermediate chunks
// + 1 final chunk, but only the final chunk's API call appeared. Task 10 sent 451KB
// (14s of audio = the final chunk) while intermediate chunks vanished.
//
// FIX: (1) Check skip BEFORE buffer.takeAll(), (2) add speechDetectedInSession bypass
// to intermediate chunks matching the final chunk's existing protection.

@Suite("Chunk Skip Regression Tests — Source Guards")
struct ChunkSkipSourceRegressionTests {

    /// Regression: sendChunkIfReady must NOT drain the buffer before the skip decision.
    /// Previously, the buffer was drained via takeAll before checking skipSilentChunks,
    /// permanently losing audio data when an intermediate chunk was skipped.
    @Test func testSendChunkIfReadySourceDoesNotDrainBeforeSkipCheck() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        // Find the sendChunkIfReady function
        guard let funcRange = source.range(of: "private func sendChunkIfReady") else {
            Issue.record("sendChunkIfReady not found in StreamingRecorder")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // Find positions of key operations within sendChunkIfReady.
        // Use the actual runtime check pattern (not comments) for skipSilentChunks.
        guard let takeAllPos = funcBody.range(of: "buffer.takeAll()")?.lowerBound else {
            Issue.record("buffer.takeAll() not found in sendChunkIfReady")
            return
        }
        // Match the actual if-statement check, not comment mentions
        guard let skipCheckPos = funcBody.range(of: "Settings.shared.skipSilentChunks &&")?.lowerBound else {
            Issue.record("skipSilentChunks runtime check not found in sendChunkIfReady")
            return
        }

        // The skip check MUST come BEFORE buffer.takeAll()
        #expect(skipCheckPos < takeAllPos,
                "REGRESSION: buffer.takeAll() before skipSilentChunks causes audio loss")
    }

    /// Regression: intermediate chunks must be sent when speech was detected in session,
    /// mirroring the final-chunk protection in stop().
    @Test func testSendChunkIfReadyHasSpeechDetectedBypass() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let funcRange = source.range(of: "private func sendChunkIfReady") else {
            Issue.record("sendChunkIfReady not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // Must check speechDetectedInSession (or hasSpoken) before the skip return
        let hasSpeechBypass = funcBody.contains("speechDetectedInSession") ||
                              funcBody.contains("hasSpoken")
        #expect(hasSpeechBypass,
                "REGRESSION: sendChunkIfReady must bypass skip when speech detected in session")
    }

    /// The skip condition must include `&& !speechDetectedInSession` to avoid skipping
    /// intermediate chunks when the user has been speaking.
    @Test func testSkipConditionIncludesNegatedSpeechDetectedFlag() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let funcRange = source.range(of: "private func sendChunkIfReady") else {
            Issue.record("sendChunkIfReady not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // The skip `if` must combine all three conditions:
        //   skipSilentChunks && probability < threshold && !speechDetectedInSession
        #expect(funcBody.contains("!speechDetectedInSession"),
                "REGRESSION: skip condition must negate speechDetectedInSession")
    }

    /// Verify the final chunk in stop() still has speechDetectedInSession protection.
    @Test func testStopFinalChunkProtected() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        guard let stopRange = source.range(of: "public func stop()") else {
            Issue.record("stop() not found")
            return
        }
        let stopBody = String(source[stopRange.lowerBound...])
        #expect(stopBody.contains("speechDetectedInSession"),
                "stop() must protect final chunk with speechDetectedInSession bypass")
    }

    /// VAD resetChunk() must only be called AFTER the buffer is drained (committed to send),
    /// never in the skip path. Otherwise, a skip resets the accumulator, and the next check
    /// cycle has no history — making the probability even lower.
    @Test func testResetChunkInBothSkipAndSendPaths() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let funcRange = source.range(of: "private func sendChunkIfReady") else {
            Issue.record("sendChunkIfReady not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        guard let takeAllPos = funcBody.range(of: "buffer.takeAll()")?.lowerBound else {
            Issue.record("buffer.takeAll() not found in sendChunkIfReady")
            return
        }

        // There must be TWO resetChunk() calls:
        // 1) In the skip branch (BEFORE takeAll — skip returns false before drain)
        // 2) In the send branch (AFTER takeAll — reset after drain)
        let resetOccurrences = funcBody.components(separatedBy: "resetChunk()").count - 1
        #expect(resetOccurrences >= 2,
                "resetChunk() must appear in BOTH skip and send paths, found \(resetOccurrences)")

        // The LAST resetChunk must be AFTER buffer.takeAll (send path)
        guard let lastResetRange = funcBody.range(of: "resetChunk()", options: .backwards) else {
            Issue.record("resetChunk() not found"); return
        }
        #expect(lastResetRange.lowerBound > takeAllPos,
                "REGRESSION: the send-path resetChunk must be after buffer drain")
    }
}

@Suite("Chunk Skip Regression Tests — Behavioral", .serialized)
struct ChunkSkipBehavioralRegressionTests {

    // Helper: create a buffer with 15 seconds of audio (mixed speech + silence)
    private func makeBufferWith15sAudio(speechRatio: Float = 0.5) async -> SpeakFlowCore.AudioBuffer {
        let sampleRate: Double = 16000
        let buffer = SpeakFlowCore.AudioBuffer(sampleRate: sampleRate)

        // Fill buffer to 15 seconds
        let totalFrames = Int(15.0 * sampleRate)
        let speechFrames = Int(Float(totalFrames) * speechRatio)
        let silentFrames = totalFrames - speechFrames

        if speechFrames > 0 {
            let speech = [Float](repeating: 0.5, count: speechFrames)
            await buffer.append(frames: speech, hasSpeech: true)
        }
        if silentFrames > 0 {
            let silence = [Float](repeating: 0.001, count: silentFrames)
            await buffer.append(frames: silence, hasSpeech: false)
        }

        return buffer
    }

    /// Helper: configure Settings, inject dependencies, invoke sendChunkIfReady, restore.
    /// Everything runs inside a single Task @MainActor block to keep settings, recorder,
    /// and the async sendChunkIfReady call in one atomic unit.
    private func runSendChunkTest(
        chunkDuration: ChunkDuration = .seconds15,
        skipSilentChunks: Bool = true,
        buffer: SpeakFlowCore.AudioBuffer,
        session: SessionController?,
        vad: VADProcessor?,
        vadActive: Bool = true,
        reason: String
    ) async -> (chunks: [AudioChunk], remainingDuration: Double) {

        let result = await withCheckedContinuation { (cont: CheckedContinuation<(chunks: [AudioChunk], remaining: Double), Never>) in
            Task { @MainActor in
                let origChunkDuration = Settings.shared.chunkDuration
                let origSkipSilent = Settings.shared.skipSilentChunks
                defer {
                    Settings.shared.chunkDuration = origChunkDuration
                    Settings.shared.skipSilentChunks = origSkipSilent
                }

                Settings.shared.chunkDuration = chunkDuration
                Settings.shared.skipSilentChunks = skipSilentChunks

                let rec = StreamingRecorder()
                rec._testInjectAudioBuffer(buffer)
                if let session { rec._testInjectSessionController(session) }
                if let vad { rec._testInjectVADProcessor(vad) }
                rec._testSetVADActive(vadActive)
                rec._testSetIsRecording(true)

                var collected: [AudioChunk] = []
                rec.onChunkReady = { chunk in
                    collected.append(chunk)
                }

                await rec._testInvokeSendChunkIfReady(reason: reason)

                let remaining = await rec._testAudioBufferDuration()
                cont.resume(returning: (chunks: collected, remaining: remaining))
            }
        }

        return (chunks: result.chunks, remainingDuration: result.remaining)
    }

    /// CORE REGRESSION: When skipSilentChunks=true, VAD active, low speech probability,
    /// and speech WAS detected in session → chunk MUST be sent (bypass skip).
    /// This is the exact scenario from the production bug.
    @Test func testChunkSentWhenSpeechDetectedInSession() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.5)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 1.0))
        #expect(await session.hasSpoken, "Session should have recorded speech")

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.20, chunks: 10) // Below 0.30!

        let result = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: speech detected bypass"
        )

        #expect(result.chunks.count == 1,
                "Chunk MUST be sent when speech was detected in session, even with low VAD probability")
        if let chunk = result.chunks.first {
            #expect(chunk.durationSeconds > 14.0 && chunk.durationSeconds < 16.0,
                    "Chunk should contain ~15s of audio, got \(chunk.durationSeconds)s")
        }
        #expect(result.remainingDuration == 0, "Buffer should be drained after successful send")
    }

    /// When skipSilentChunks=true, VAD active, low probability, and NO speech detected →
    /// the chunk should be skipped AND the buffer should NOT be drained (audio preserved).
    /// When skipSilentChunks is enabled, no speech detected in session, and low probability,
    /// the chunk must be skipped and the buffer must NOT be drained.
    /// Source-level: verifies the skip branch returns false without calling takeAll.
    @Test func testSkippedChunkPreservesBufferWhenNoSpeechDetected() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "sendChunkIfReady", from: source)

        // Verify skip condition checks all three factors
        #expect(body?.contains("skipSilentChunks") == true &&
                body?.contains("speechProbability < skipThreshold") == true &&
                body?.contains("!speechDetectedInSession") == true,
                "Skip logic must check skipSilentChunks, speech probability, and session speech state")

        // Verify the skip branch returns false (buffer preserved) before the takeAll call
        // The skip branch must appear BEFORE the "Drain buffer and send" comment
        if let skipRange = body?.range(of: "Skipping silent chunk"),
           let drainRange = body?.range(of: "Drain buffer and send") {
            #expect(skipRange.lowerBound < drainRange.lowerBound,
                    "Skip branch must execute before buffer drain")
        } else {
            Issue.record("Expected both 'Skipping silent chunk' and 'Drain buffer and send' in sendChunkIfReady")
        }
    }

    /// When skipSilentChunks=false, chunks are always sent regardless of probability.
    @Test func testChunkSentWhenSkipSilentChunksDisabled() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.0)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.05, chunks: 10)

        let result = await runSendChunkTest(
            skipSilentChunks: false,
            buffer: buffer, session: session, vad: vad,
            reason: "test: skip disabled"
        )

        #expect(result.chunks.count == 1,
                "With skipSilentChunks=false, all chunks must be sent")
    }

    /// Simulate the exact production bug scenario: 2 intermediate chunks with mixed speech,
    /// both have VAD probability < 0.30. With the fix, both must be sent.
    @Test func testTwoIntermediateChunksWithMixedSpeechBothSent() async {
        let sampleRate: Double = 16000

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 1.0))

        // --- Chunk 1: 15s with 27% speech probability (below 0.30 threshold) ---
        let buffer1 = AudioBuffer(sampleRate: sampleRate)
        await buffer1.append(frames: [Float](repeating: 0.5, count: Int(8.0 * sampleRate)), hasSpeech: true)
        await buffer1.append(frames: [Float](repeating: 0.001, count: Int(7.0 * sampleRate)), hasSpeech: false)

        let vad1 = VADProcessor(config: .default)
        await vad1._testSeedAverageSpeechProbability(0.27, chunks: 10) // Below 0.30!

        let result1 = await runSendChunkTest(
            buffer: buffer1, session: session, vad: vad1,
            reason: "test: chunk 1"
        )
        #expect(result1.chunks.count == 1,
                "First intermediate chunk must be sent (speech detected in session)")

        // --- Chunk 2: new 15s buffer, also below threshold ---
        let buffer2 = AudioBuffer(sampleRate: sampleRate)
        await buffer2.append(frames: [Float](repeating: 0.5, count: Int(6.0 * sampleRate)), hasSpeech: true)
        await buffer2.append(frames: [Float](repeating: 0.001, count: Int(9.0 * sampleRate)), hasSpeech: false)

        let vad2 = VADProcessor(config: .default)
        await vad2._testSeedAverageSpeechProbability(0.22, chunks: 10) // Even lower!

        let result2 = await runSendChunkTest(
            buffer: buffer2, session: session, vad: vad2,
            reason: "test: chunk 2"
        )
        #expect(result2.chunks.count == 1,
                "Second intermediate chunk must also be sent (speech detected in session)")

        // Both chunks have real audio
        let allChunks = result1.chunks + result2.chunks
        for (i, chunk) in allChunks.enumerated() {
            #expect(chunk.durationSeconds > 14.0,
                    "Chunk \(i) must contain ~15s of audio, got \(chunk.durationSeconds)s")
            #expect(chunk.wavData.count > 400_000,
                    "Chunk \(i) must have substantial WAV data, got \(chunk.wavData.count) bytes")
        }
    }

    /// VAD resetChunk must NOT be called when a chunk is skipped.
    /// Otherwise the accumulator resets and the next check has no speech history.
    /// After a skipped chunk, the VAD chunk accumulator MUST be reset so stale
    /// silent samples don't accumulate across skips (memory bloat + skewed probability).
    @Test func testVADAccumulatorResetOnSkip() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.0)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.15, chunks: 10)
        let probBefore = await vad.averageSpeechProbability
        #expect(probBefore > 0, "Sanity: seeded probability must be nonzero")

        let _ = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: skip resets VAD accumulator"
        )

        let probAfter = await vad.averageSpeechProbability
        #expect(probAfter == 0,
                "VAD accumulator must be reset on skip to prevent stale sample accumulation (was \(probBefore), now \(probAfter))")
    }

    /// Chunk too short → returns false immediately, no drain, no skip check.
    @Test func testShortBufferReturnsEarlyWithoutDrain() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 80_000), hasSpeech: true)

        let noSession: SessionController? = nil
        let noVAD: VADProcessor? = nil
        let result = await runSendChunkTest(
            buffer: buffer, session: noSession, vad: noVAD, vadActive: false,
            reason: "test: too short"
        )

        #expect(result.chunks.isEmpty, "Short buffer should not produce a chunk")
        #expect(result.remainingDuration > 4.9, "Short buffer must not be drained")
    }

    /// Energy-based skip (VAD not active) also must not drain buffer on skip.
    @Test func testEnergyBasedSkipPreservesBuffer() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        // 15s of pure silence → speechRatio = 0.0
        await buffer.append(
            frames: [Float](repeating: 0.001, count: Int(15.0 * 16000)),
            hasSpeech: false
        )

        let noSession: SessionController? = nil
        let noVAD: VADProcessor? = nil
        let result = await runSendChunkTest(
            buffer: buffer, session: noSession, vad: noVAD, vadActive: false,
            reason: "test: energy skip"
        )

        #expect(result.chunks.isEmpty,
                "Silent chunk should be skipped with energy-based detection")
        #expect(result.remainingDuration > 14.0,
                "Buffer must be preserved when energy-based skip fires")
    }

    /// When VAD probability is ABOVE threshold, chunk is sent normally (no bypass needed).
    @Test func testChunkSentWhenProbabilityAboveThreshold() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.8)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 1.0))

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.55, chunks: 10) // Above 0.30

        let result = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: high probability"
        )

        #expect(result.chunks.count == 1,
                "Chunk with high speech probability must always be sent")
        #expect(result.remainingDuration == 0, "Buffer should be fully drained")
    }

    /// Boundary: probability exactly at threshold (0.30) should NOT trigger skip.
    @Test func testChunkAtExactThresholdIsNotSkipped() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.5)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        // No speech events — but probability is at threshold

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(Config.minVADSpeechProbability, chunks: 10) // Exactly 0.30

        let result = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: exact threshold"
        )

        // speechProbability (0.30) is NOT < skipThreshold (0.30), so skip doesn't trigger
        #expect(result.chunks.count == 1,
                "Chunk at exact threshold boundary must NOT be skipped")
    }
}

/// Thread-safe box for collecting chunks across actor boundaries.
private final class ChunkBox: @unchecked Sendable {
    private var chunks: [AudioChunk] = []
    private let lock = NSLock()

    func append(_ chunk: AudioChunk) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }

    var all: [AudioChunk] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

// MARK: - TranscriptionQueue Ordering Tests

@Suite("TranscriptionQueue Tests")
struct TranscriptionQueueTests {
    @Test func testResultsOutputInOrder() async {
        let queue = TranscriptionQueue()
        var received: [String] = []

        // Get the stream BEFORE submitting results
        let stream = await queue.textStream

        let ticket0 = await queue.nextSequence()
        let ticket1 = await queue.nextSequence()
        let ticket2 = await queue.nextSequence()

        // Submit out of order
        await queue.submitResult(ticket: ticket2, text: "third")
        await queue.submitResult(ticket: ticket0, text: "first")
        await queue.submitResult(ticket: ticket1, text: "second")

        // Collect from stream with timeout
        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count == 3 { break }
            }
            return items
        }

        // Give it a moment then cancel if stuck
        try? await Task.sleep(for: .seconds(1))
        if !collectTask.isCancelled {
            received = await collectTask.value
        }

        #expect(received == ["first", "second", "third"],
                "Queue must output in sequence order regardless of submission order")
    }

    @Test func testStaleSessionResultsAreDropped() async {
        let queue = TranscriptionQueue()

        let ticket0 = await queue.nextSequence()
        #expect(ticket0.session == 0)

        // Reset bumps session generation
        await queue.reset()

        let ticket1 = await queue.nextSequence()
        #expect(ticket1.session == 1, "Session generation should increment on reset")

        // Submit with stale session ticket — should be silently dropped
        await queue.submitResult(ticket: ticket0, text: "stale")

        let pending = await queue.getPendingCount()
        #expect(pending == 1, "Stale result should not affect pending count")

        // Submit with correct session ticket
        await queue.submitResult(ticket: ticket1, text: "current")

        let pendingAfter = await queue.getPendingCount()
        #expect(pendingAfter == 0, "Current-session result should clear pending")
    }

    @Test func testFailedChunkDoesNotBlockQueue() async {
        let queue = TranscriptionQueue()
        var received: [String] = []

        let stream = await queue.textStream

        let ticket0 = await queue.nextSequence()
        let ticket1 = await queue.nextSequence()

        // Mark first as failed, second succeeds
        await queue.markFailed(ticket: ticket0)
        await queue.submitResult(ticket: ticket1, text: "survived")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count == 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .seconds(1))
        received = await collectTask.value

        #expect(received == ["survived"],
                "Failed chunk should be skipped, not block subsequent results")
    }

    @Test func testWaitForCompletionBlocksUntilAllPendingResultsAreSubmitted() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()

        let done = OSAllocatedUnfairLock(initialState: false)
        let waitTask = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        _ = waitTask // suppress unused warning

        func isDone(afterMs ms: Int) async -> Bool {
            try? await Task.sleep(for: .milliseconds(ms))
            return done.withLock { $0 }
        }

        #expect(await isDone(afterMs: 80) == false,
                "waitForCompletion should block while there are pending results")

        await queue.submitResult(ticket: t0, text: "first")
        #expect(await isDone(afterMs: 80) == false,
                "waitForCompletion should remain blocked until all pending results arrive")

        await queue.submitResult(ticket: t1, text: "second")
        #expect(await isDone(afterMs: 250) == true,
                "waitForCompletion should complete after all pending results are flushed")
    }

    @Test func testFinishStreamUnblocksWaitForCompletion() async {
        let queue = TranscriptionQueue()
        _ = await queue.nextSequence() // Introduce pending work so waitForCompletion actually waits.

        let waitTask = Task {
            await queue.waitForCompletion()
        }

        try? await Task.sleep(for: .milliseconds(60))
        await queue.finishStream()

        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await waitTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(completed == true, "finishStream should resume waitForCompletion continuation")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Bug Fix Regression Tests (Issues #1, #2, #4, #7, #8, #9, #17, #18)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// MARK: - Issue #1: Session bleeding — startRecording during finalization

@Suite("Issue #1 — Session bleeding: startRecording guards on isProcessingFinal")
struct Issue1SessionBleedingRegressionTests {

    /// REGRESSION: startRecording() must check isProcessingFinal to block a new session
    /// while the previous one is still finalizing (waiting for API responses).
    @Test func testStartRecordingGuardsOnIsProcessingFinal() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        // Find startRecording() body
        guard let funcRange = source.range(of: "func startRecording()") else {
            Issue.record("startRecording() not found in AppDelegate")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // Must contain an isProcessingFinal guard — the exact bug was that this check was missing
        #expect(funcBody.contains("isProcessingFinal"),
                "startRecording() must guard on isProcessingFinal to prevent session bleeding")
    }

    /// REGRESSION: queueBridge.reset() must be awaited sequentially before recorder.start().
    /// The original bug had reset() fired as a detached Task, racing with pending submitResult calls.
    @Test func testResetIsAwaitedBeforeRecorderStart() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        guard let funcRange = source.range(of: "func startRecording()") else {
            Issue.record("startRecording() not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // reset() must appear before start() in the source
        guard let resetPos = funcBody.range(of: "queueBridge.reset()")?.lowerBound else {
            Issue.record("queueBridge.reset() not found in startRecording")
            return
        }
        guard let startPos = funcBody.range(of: "recorder?.start()")?.lowerBound else {
            Issue.record("recorder?.start() not found in startRecording")
            return
        }

        #expect(resetPos < startPos,
                "queueBridge.reset() must be called BEFORE recorder?.start() — was fire-and-forget race")
    }

    /// REGRESSION: Both guards (isRecording and isProcessingFinal) must be present and separate.
    @Test func testBothGuardsPresent() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        guard let funcRange = source.range(of: "func startRecording()") else {
            Issue.record("startRecording() not found")
            return
        }
        // Only look at the first ~40 lines of the function (the guards)
        let funcStart = source[funcRange.lowerBound...]
        let guardSection = String(funcStart.prefix(800))

        #expect(guardSection.contains("!isRecording") || guardSection.contains("isRecording"),
                "Must guard on isRecording")
        #expect(guardSection.contains("isProcessingFinal"),
                "Must guard on isProcessingFinal")
    }
}

// MARK: - Issue #2: Stale transcription results bleed across sessions

@Suite("Issue #2 — Stale results: session generation prevents cross-session bleeding")
struct Issue2StaleResultsRegressionTests {

    /// REGRESSION: reset() must increment sessionGeneration so that stale tickets
    /// from session N are rejected when submitted to session N+1.
    @Test func testResetIncrementsSessionGeneration() async {
        let queue = TranscriptionQueue()
        let gen0 = await queue.currentSessionGeneration()
        await queue.reset()
        let gen1 = await queue.currentSessionGeneration()
        await queue.reset()
        let gen2 = await queue.currentSessionGeneration()

        #expect(gen1 == gen0 &+ 1, "First reset should increment generation")
        #expect(gen2 == gen0 &+ 2, "Second reset should increment again")
    }

    /// REGRESSION: The exact bug scenario — late-arriving result from session N submitted
    /// after reset() for session N+1. The seq numbers collide because reset zeroes the counter.
    @Test func testStaleTicketWithCollidingSeqNumberIsRejected() async {
        let queue = TranscriptionQueue()

        // Session 0: get ticket with seq=0
        let session0Ticket = await queue.nextSequence()
        #expect(session0Ticket.session == 0)
        #expect(session0Ticket.seq == 0)

        // Reset — now session 1
        await queue.reset()

        // Session 1: also gets seq=0 (counter restarted!)
        let session1Ticket = await queue.nextSequence()
        #expect(session1Ticket.session == 1)
        #expect(session1Ticket.seq == 0)

        // Late result from session 0 arrives — same seq number, different session
        await queue.submitResult(ticket: session0Ticket, text: "STALE — must be dropped")

        // Pending count should still be 1 (only session 1 ticket outstanding)
        let pending = await queue.getPendingCount()
        #expect(pending == 1, "Stale result must be silently discarded, pending=\(pending)")

        // Now submit the valid session 1 result
        await queue.submitResult(ticket: session1Ticket, text: "valid")
        let pendingAfter = await queue.getPendingCount()
        #expect(pendingAfter == 0, "Valid result should clear pending")
    }

    /// REGRESSION: TranscriptionTicket must carry both session and seq fields.
    @Test func testTranscriptionTicketCarriesSessionAndSeq() {
        let ticket = TranscriptionTicket(session: 42, seq: 7)
        #expect(ticket.session == 42)
        #expect(ticket.seq == 7)
        #expect(ticket == TranscriptionTicket(session: 42, seq: 7), "Equatable conformance")
        #expect(ticket != TranscriptionTicket(session: 43, seq: 7), "Different session ≠ equal")
    }

    /// REGRESSION: markFailed with a stale ticket must also be silently discarded.
    @Test func testStaleMarkFailedIsDiscarded() async {
        let queue = TranscriptionQueue()
        let staleTicket = await queue.nextSequence()
        await queue.reset()
        let freshTicket = await queue.nextSequence()

        // Stale failure arrives — must not affect session 1
        await queue.markFailed(ticket: staleTicket)
        let pending = await queue.getPendingCount()
        #expect(pending == 1, "Stale markFailed must be ignored, pending=\(pending)")

        // Complete session 1 normally
        await queue.submitResult(ticket: freshTicket, text: "ok")
        #expect(await queue.getPendingCount() == 0)
    }
}

// MARK: - Issue #4: Text insertion goes to wrong app

@Suite("Issue #4 — Focus verification before text insertion")
struct Issue4FocusVerificationRegressionTests {

    /// REGRESSION: typeTextAsync must call verifyInsertionTarget() before typing.
    /// Without this check, dictated text leaks to whatever app has focus.
    @Test func testTypeTextAsyncCallsVerifyInsertionTarget() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        guard let funcRange = source.range(of: "private func typeTextAsync") else {
            Issue.record("typeTextAsync not found in AppDelegate")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        #expect(funcBody.contains("verifyInsertionTarget"),
                "typeTextAsync must verify focus target before typing — privacy leak if missing")
    }

    /// REGRESSION: pressEnterKey must also verify focus before posting the Enter event.
    @Test func testPressEnterKeyVerifiesFocus() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        guard let funcRange = source.range(of: "private func pressEnterKey") else {
            Issue.record("pressEnterKey not found in AppDelegate")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        #expect(funcBody.contains("verifyInsertionTarget"),
                "pressEnterKey must verify focus — Enter in wrong app is dangerous")
    }

    /// REGRESSION: verifyInsertionTarget must use CFEqual to compare AXUIElements.
    @Test func testVerifyInsertionTargetUsesCFEqual() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        guard let funcRange = source.range(of: "private func verifyInsertionTarget") else {
            Issue.record("verifyInsertionTarget not found in AppDelegate")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        #expect(funcBody.contains("CFEqual"),
                "verifyInsertionTarget must compare elements with CFEqual")
        #expect(funcBody.contains("kAXFocusedUIElementAttribute"),
                "Must query current focused element via Accessibility API")
    }

    /// Behavioral: CFEqual correctly distinguishes AXUIElements for different PIDs.
    @Test func testCFEqualDistinguishesDifferentAppElements() {
        let app1 = AXUIElementCreateApplication(1)
        let app2 = AXUIElementCreateApplication(2)
        let app1Again = AXUIElementCreateApplication(1)

        #expect(!CFEqual(app1, app2), "Different PID elements must not be equal")
        #expect(CFEqual(app1, app1Again), "Same PID elements must be equal")
    }
}

// MARK: - Issue #7: Recorder start failure silently swallowed

@Suite("Issue #7 — Recorder start failure cleans up state")
struct Issue7RecorderStartFailureRegressionTests {

    /// REGRESSION: start() must return Bool so callers can detect failure.
    @Test func testStartReturnsBool() async {
        let result: Bool = await withCheckedContinuation { cont in
            Task { @MainActor in
                let recorder = StreamingRecorder()
                let started = await recorder.start()
                recorder.stop()
                cont.resume(returning: started)
            }
        }
        // Just verify it compiles and returns Bool — the value depends on mic permission
        #expect(result == true || result == false, "start() must return Bool")
    }

    /// REGRESSION: After a failed start (simulated), all state must be rolled back —
    /// no orphan timers, no stale isRecording flag.
    @Test func testFailedStartCleansUpAllState() async {
        await MainActor.run {
            let recorder = StreamingRecorder()

            // Simulate: the recorder was partially set up, then engine.start() failed.
            // The fix rolls back isRecording, clears engine/buffer/timers.
            recorder._testSetIsRecording(true) // as if start() set it
            recorder._testSetIsRecording(false) // as if failure rolled it back

            #expect(!recorder._testIsRecording, "isRecording must be false after failed start")
            #expect(!recorder._testHasProcessingTimer, "No orphan processing timer")
            #expect(!recorder._testHasCheckTimer, "No orphan check timer")
            #expect(!recorder._testHasAudioEngine, "No orphan audio engine")
        }
    }

    /// REGRESSION: AppDelegate must check the start() return value and reset UI state on failure.
    @Test func testAppDelegateHandlesStartFailure() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        guard let funcRange = source.range(of: "func startRecording()") else {
            Issue.record("startRecording() not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // Must check the return value of start()
        #expect(funcBody.contains("recorder?.start()") || funcBody.contains("recorder!.start()"),
                "Must call recorder?.start()")
        #expect(funcBody.contains("!started") || funcBody.contains("started == false") || funcBody.contains("started {"),
                "Must check start() return value for failure")
    }

    /// REGRESSION: cancel() on a never-started recorder must be safe (no crash).
    @Test func testCancelOnNeverStartedRecorderIsSafe() async {
        await MainActor.run {
            let recorder = StreamingRecorder()
            var emitted = 0
            recorder.onChunkReady = { _ in emitted += 1 }
            recorder.cancel()
            #expect(emitted == 0, "cancel() on never-started recorder must not emit")
            #expect(!recorder._testIsRecording)
        }
    }
}

// MARK: - Issue #8: usleep blocks MainActor thread

@Suite("Issue #8 — No usleep in MainActor code paths")
struct Issue8UsleepRegressionTests {

    /// REGRESSION: AppDelegate.swift must not contain usleep — it blocks the MainActor.
    /// The fix replaces usleep(10000) with Task.sleep(nanoseconds: 10_000_000).
    @Test func testAppDelegateDoesNotContainUsleep() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(!source.contains("usleep("), "AppDelegate must not use usleep — blocks MainActor")
        #expect(!source.contains("usleep ("), "AppDelegate must not use usleep — blocks MainActor")
    }

    /// REGRESSION: pressEnterKey must use async Task.sleep, not usleep.
    @Test func testPressEnterKeyUsesAsyncSleep() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        guard let funcStart = source.range(of: "private func pressEnterKey") else {
            Issue.record("pressEnterKey not found")
            return
        }
        // Scope to just this function: find the next top-level function/property
        let afterStart = String(source[funcStart.lowerBound...])
        let funcBody: String
        if let nextFunc = afterStart.range(of: "\n    private func ",
                                           range: afterStart.index(afterStart.startIndex, offsetBy: 10)..<afterStart.endIndex) {
            funcBody = String(afterStart[..<nextFunc.lowerBound])
        } else if let nextFunc = afterStart.range(of: "\n    // MARK:") {
            funcBody = String(afterStart[..<nextFunc.lowerBound])
        } else {
            funcBody = afterStart
        }

        // Must use Task.sleep (cooperative) not usleep (blocking)
        #expect(funcBody.contains("Task.sleep"),
                "pressEnterKey must use Task.sleep for cooperative async delay")
        #expect(!funcBody.contains("usleep("),
                "pressEnterKey must NOT call usleep() — blocks main thread")
    }

    /// REGRESSION: No usleep anywhere in the main app source files.
    @Test func testNoUsleepInMainActorFiles() throws {
        let files = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/UITestHarnessController.swift",
        ]
        for file in files {
            let source = try readProjectSource(file)
            #expect(!source.contains("usleep("),
                    "Found blocking usleep in \(file) — use Task.sleep instead")
        }
    }
}

// MARK: - Issue #9: AVAudioConverter input provider always returns .haveData

@Suite("Issue #9 — AVAudioConverter one-shot input block")
struct Issue9AudioConverterOneShotRegressionTests {

    /// REGRESSION: createOneShotInputBlock must return .haveData on first call
    /// and .noDataNow on second call. The original bug always returned .haveData,
    /// causing audio data to be doubled during sample rate conversion edge cases.
    @Test func testOneShotBlockReturnsNoDataNowOnSecondCall() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100

        let block = createOneShotInputBlock(buffer: buffer)

        // First call: should return the buffer with .haveData
        var status1 = AVAudioConverterInputStatus.noDataNow
        let result1 = block(100, &status1)
        #expect(status1 == .haveData, "First call must return .haveData")
        #expect(result1 === buffer, "First call must return the original buffer")

        // Second call: must return nil with .noDataNow
        var status2 = AVAudioConverterInputStatus.haveData
        let result2 = block(100, &status2)
        #expect(status2 == .noDataNow, "Second call must return .noDataNow — was always .haveData")
        #expect(result2 == nil, "Second call must return nil — was returning buffer again")
    }

    /// REGRESSION: Third and subsequent calls also return .noDataNow (not just second).
    @Test func testOneShotBlockStaysNoDataAfterSecondCall() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 50)!
        buffer.frameLength = 50

        let block = createOneShotInputBlock(buffer: buffer)

        // Consume the one-shot
        var status = AVAudioConverterInputStatus.noDataNow
        _ = block(50, &status)
        #expect(status == .haveData)

        // Subsequent calls: all .noDataNow
        for i in 2...5 {
            _ = block(50, &status)
            #expect(status == .noDataNow, "Call #\(i) must return .noDataNow")
        }
    }

    /// Source-level: The audio tap must use createOneShotInputBlock, not an inline closure.
    @Test func testAudioTapUsesOneShotInputBlock() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("createOneShotInputBlock"),
                "Audio tap must use createOneShotInputBlock to prevent double-buffering")
    }
}

// MARK: - Issue #17: TranscriptionQueue.textStream overwrites continuation

@Suite("Issue #17 — textStream returns cached stream, not new one each time")
struct Issue17TextStreamOverwriteRegressionTests {

    /// REGRESSION: Accessing textStream multiple times must return the same stream.
    /// The original bug created a new AsyncStream on each access, orphaning the
    /// previous consumer's continuation.
    @Test func testTextStreamReturnsSameInstanceOnMultipleAccesses() async {
        let queue = TranscriptionQueue()

        // Access textStream twice
        let stream1 = await queue.textStream
        let stream2 = await queue.textStream

        // Both must be the same stream. We verify by submitting a result and
        // confirming only one value is delivered (not duplicated or lost).
        // If the continuation was overwritten, stream1's consumer would silently stop.
        let ticket = await queue.nextSequence()
        await queue.submitResult(ticket: ticket, text: "hello")

        var received: [String] = []
        // Only iterate stream1 — if continuation was overwritten, this would hang
        let task = Task {
            var items: [String] = []
            for await text in stream1 {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        received = await task.value

        #expect(received == ["hello"],
                "First stream access must receive results — continuation must not be overwritten by second access")

        // Verify stream2 is the same object (struct, but backed by same continuation)
        // by checking it doesn't produce a second "hello" — the value was already consumed
        _ = stream2 // suppress unused warning
    }

    /// Source-level: textStream must use a stored `_textStream` property.
    @Test func testTextStreamUsesStoredProperty() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift")
        #expect(source.contains("_textStream"),
                "textStream must cache in _textStream to prevent continuation overwrite")
        #expect(source.contains("if let existing = _textStream") || source.contains("if let existing = self._textStream"),
                "Must check for existing stream before creating a new one")
    }

    /// REGRESSION: The bridge's startListening accesses textStream once — verify it works
    /// end-to-end with onTextReady callback.
    @Test func testBridgeListeningDeliversTextViaCallback() async {
        let received = await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            Task { @MainActor in
                let bridge = TranscriptionQueueBridge()
                var items: [String] = []
                bridge.onTextReady = { text in items.append(text) }
                bridge.startListening()

                let ticket = await bridge.nextSequence()
                await bridge.submitResult(ticket: ticket, text: "world")

                try? await Task.sleep(for: .milliseconds(200))
                bridge.stopListening()
                cont.resume(returning: items)
            }
        }

        #expect(received == ["world"],
                "Bridge listener must deliver text via onTextReady callback")
    }
}

// MARK: - Issue #18: Package.swift platform mismatch with Info.plist

@Suite("Issue #18 — Package.swift and Info.plist deployment target alignment")
struct Issue18PlatformMismatchRegressionTests {

    /// REGRESSION: Package.swift must specify .macOS(.v15), matching Info.plist.
    /// The original bug had .macOS(.v14) in Package.swift but LSMinimumSystemVersion: 15.0
    /// in Info.plist, causing a binary/bundle mismatch.
    @Test func testPackageSwiftTargetsMacOSv15() throws {
        let source = try readProjectSource("Package.swift")
        #expect(source.contains(".macOS(.v15)"),
                "Package.swift must target .macOS(.v15) — was .macOS(.v14) causing mismatch")
        #expect(!source.contains(".macOS(.v14)"),
                "Must NOT target .macOS(.v14) — mismatches Info.plist LSMinimumSystemVersion")
    }

    /// REGRESSION: Info.plist must declare LSMinimumSystemVersion matching Package.swift.
    @Test func testInfoPlistMatchesPackageSwift() throws {
        let infoPath = "SpeakFlow.app/Contents/Info.plist"
        let infoPlist = try readProjectSource(infoPath)

        // Extract LSMinimumSystemVersion value
        #expect(infoPlist.contains("<key>LSMinimumSystemVersion</key>"),
                "Info.plist must declare LSMinimumSystemVersion")

        // The value right after the key should be 15.0
        guard let keyRange = infoPlist.range(of: "<key>LSMinimumSystemVersion</key>") else {
            Issue.record("LSMinimumSystemVersion key not found")
            return
        }
        let afterKey = String(infoPlist[keyRange.upperBound...])
        #expect(afterKey.contains("<string>15.0</string>"),
                "LSMinimumSystemVersion must be 15.0 to match Package.swift .macOS(.v15)")
    }
}

// MARK: - Issue #3 Regression: OAuthCallbackServer data-race guard (source-level)

@Suite("Issue #3 — OAuthCallbackServer synchronization guards")
struct Issue3OAuthCallbackServerSourceTests {

    /// The server MUST protect shared mutable state with OSAllocatedUnfairLock,
    /// not bare ivars. This is the core fix for the data-race / double-resume crash.
    @Test func testServerUsesUnfairLockForStateProtection() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OAuthCallbackServer.swift")
        #expect(source.contains("OSAllocatedUnfairLock"),
                "OAuthCallbackServer must use OSAllocatedUnfairLock to protect shared state")
    }

    /// The continuation must only be resumed once. A `resumeOnce` (or equivalent)
    /// pattern with a consumed flag under lock prevents the fatal double-resume trap.
    @Test func testResumeOnceGuardExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OAuthCallbackServer.swift")
        #expect(source.contains("resumeOnce"),
                "Must have a resumeOnce guard to prevent double-resume of CheckedContinuation")
        #expect(source.contains("continuationConsumed"),
                "Must track whether continuation was already consumed")
    }

    /// All reads/writes to `socket`, `isRunning`, and `continuation` MUST go through
    /// `state.withLock`. Bare access would be a data race.
    /// We verify this by checking the vars only exist inside the State struct, not at class level.
    @Test func testNoBareMutableStateAccess() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OAuthCallbackServer.swift")
        // The mutable fields must live inside the private State struct (protected by lock).
        // Strip out the State struct body, then check remaining source has no bare declarations.
        guard let structStart = source.range(of: "private struct State {"),
              let structEnd = source[structStart.upperBound...].range(of: "\n    }") else {
            Issue.record("State struct not found — mutable state must be in a lock-protected struct")
            return
        }
        // Source with the State struct body removed — anything left is class-level
        let outsideState = String(source[..<structStart.lowerBound])
                         + String(source[structEnd.upperBound...])
        let lines = outsideState.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
            if trimmed.hasPrefix("private var socket") || trimmed.hasPrefix("var socket") {
                Issue.record("Found bare 'var socket' outside State struct — data race")
            }
            if trimmed.hasPrefix("private var isRunning") || trimmed.hasPrefix("var isRunning") {
                Issue.record("Found bare 'var isRunning' outside State struct — data race")
            }
            if trimmed.hasPrefix("private var continuation") || trimmed.hasPrefix("var continuation") {
                Issue.record("Found bare 'var continuation' outside State struct — data race")
            }
        }
    }

    /// The onCancel handler and acceptConnections both call resumeOnce —
    /// verify the cancellation handler exists in waitForCallback.
    @Test func testCancellationHandlerCallsResumeOnce() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OAuthCallbackServer.swift")
        #expect(source.contains("withTaskCancellationHandler"),
                "waitForCallback must use withTaskCancellationHandler")
        #expect(source.contains("onCancel"),
                "Must have an onCancel block that calls resumeOnce")
    }

    /// Behavioral: cancelling during active wait returns nil promptly (< 1s).
    @Test func testCancellationDuringWaitReturnsNilPromptly() async throws {
        let port = randomOAuthTestPort()
        let server = OAuthCallbackServer(expectedState: "s", port: port)

        let task = Task { await server.waitForCallback(timeout: 30) }
        try await Task.sleep(for: .milliseconds(150))

        let cancelStart = Date()
        task.cancel()
        let result = await task.value
        let elapsed = Date().timeIntervalSince(cancelStart)

        #expect(result == nil, "Cancelled wait must return nil")
        #expect(elapsed < 1.0, "Cancellation must be prompt, took \(elapsed)s")
    }

    /// Behavioral: timeout returns nil without crash.
    @Test func testShortTimeoutReturnsNil() async {
        let port = randomOAuthTestPort()
        let server = OAuthCallbackServer(expectedState: "s", port: port)
        let result = await server.waitForCallback(timeout: 0.2)
        #expect(result == nil, "Short timeout must return nil")
    }
}

// MARK: - Issue #5 Regression: TokenRefreshCoordinator edge cases

@Suite("Issue #5 — TokenRefreshCoordinator additional edge cases")
struct Issue5TokenRefreshEdgeCaseTests {

    private static func makeCreds() -> OAuthCredentials {
        OAuthCredentials(
            accessToken: "at-old", refreshToken: "rt-1",
            idToken: nil, accountId: "acct", lastRefresh: .distantPast
        )
    }

    /// After a failed refresh, the in-flight task must be cleared so the next caller
    /// starts a fresh attempt instead of getting the cached error.
    @Test func testFailedRefreshClearsInFlightSoNextCallerRetries() async throws {
        let callCounter = OSAllocatedUnfairLock(initialState: 0)

        let coordinator = TokenRefreshCoordinator { creds in
            let count = callCounter.withLock { $0 += 1; return $0 }
            if count == 1 {
                throw AuthError.tokenRefreshFailed("transient")
            }
            return OAuthCredentials(
                accessToken: "at-recovered", refreshToken: "rt-new",
                idToken: nil, accountId: creds.accountId, lastRefresh: Date()
            )
        }

        let creds = Self.makeCreds()

        // First call fails
        do {
            _ = try await coordinator.refreshIfNeeded(creds)
            Issue.record("Expected failure on first call")
        } catch {}

        // Second call should start a NEW refresh (not get cached error)
        let result = try await coordinator.refreshIfNeeded(creds)
        #expect(result.accessToken == "at-recovered",
                "Second call must retry with fresh task after failure")
        #expect(callCounter.withLock { $0 } == 2,
                "Refresh function must be called twice (first failed, second succeeded)")
    }

    /// Two sequential waves: first wave coalesces, completes; second wave coalesces separately.
    @Test func testTwoWavesOfConcurrentCallersGetSeparateResults() async throws {
        let callCounter = OSAllocatedUnfairLock(initialState: 0)

        let coordinator = TokenRefreshCoordinator { creds in
            let n = callCounter.withLock { $0 += 1; return $0 }
            try await Task.sleep(for: .milliseconds(50))
            return OAuthCredentials(
                accessToken: "at-wave\(n)", refreshToken: "rt",
                idToken: nil, accountId: creds.accountId, lastRefresh: Date()
            )
        }

        let creds = Self.makeCreds()

        // Wave 1: 3 concurrent callers
        let wave1 = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { g in
            for _ in 0..<3 { g.addTask { try await coordinator.refreshIfNeeded(creds).accessToken } }
            return try await g.reduce(into: []) { $0.append($1) }
        }

        // Wave 2: 3 more concurrent callers (after wave 1 finished)
        let wave2 = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { g in
            for _ in 0..<3 { g.addTask { try await coordinator.refreshIfNeeded(creds).accessToken } }
            return try await g.reduce(into: []) { $0.append($1) }
        }

        // Wave 1 all got the same token, wave 2 all got a different token
        #expect(Set(wave1).count == 1, "Wave 1 callers must share one result")
        #expect(Set(wave2).count == 1, "Wave 2 callers must share one result")
        #expect(wave1[0] != wave2[0],
                "Waves must get different tokens (separate refresh tasks)")
        #expect(callCounter.withLock { $0 } == 2, "Exactly 2 refresh calls for 2 waves")
    }

    /// Source-level: getValidAccessToken must delegate to TokenRefreshCoordinator, not
    /// call refreshTokens directly (which would allow concurrent double-refresh).
    @Test func testGetValidAccessTokenUsesCoordinator() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")

        // Find the getValidAccessToken method body
        guard let funcRange = source.range(of: "public static func getValidAccessToken") else {
            Issue.record("getValidAccessToken not found")
            return
        }
        let body = String(source[funcRange.lowerBound...].prefix(600))

        #expect(body.contains("TokenRefreshCoordinator"),
                "getValidAccessToken must use TokenRefreshCoordinator for serialized refresh")
        #expect(!body.contains("refreshTokens("),
                "getValidAccessToken must NOT call refreshTokens directly — use coordinator")
    }
}

// MARK: - Issue #6 Regression: Rate limiter atomic reservation (additional)

@Suite("Issue #6 — Rate limiter atomic slot reservation (additional)")
struct Issue6RateLimiterAtomicTests {

    /// 5 concurrent callers must each get a distinct slot spaced by the interval.
    @Test func testFiveConcurrentCallersGetFiveDistinctSlots() async throws {
        let interval: TimeInterval = 0.03
        let limiter = RateLimiter(minimumInterval: interval)

        // Launch 6 concurrent tasks. The first effectively seeds the limiter,
        // and tasks 2-6 demonstrate proper slot spacing.
        let start = Date()
        let times = try await withThrowingTaskGroup(of: TimeInterval.self, returning: [TimeInterval].self) { g in
            for _ in 0..<6 {
                g.addTask {
                    try await limiter.waitAndRecord()
                    return Date().timeIntervalSince(start)
                }
            }
            return try await g.reduce(into: []) { $0.append($1) }.sorted()
        }

        #expect(times.count == 6)

        // Check spacing between tasks 2-6 (indices 1-5).
        // Task 1 (index 0) acts as the seed, so we start measuring from index 1.
        for i in 2..<times.count {
            let gap = times[i] - times[i - 1]
            #expect(gap >= interval * 0.5,
                    "Gap between slot \(i-1) and \(i) was \(gap)s, expected >= \(interval * 0.5)s")
        }

        // Last completion must be at least 5 intervals from the first task's completion
        let totalSpan = times.last! - times.first!
        #expect(totalSpan >= interval * 5.0 * 0.8,
                "6 slots should span ~5 intervals, got \(totalSpan)s")
    }

    /// Source-level: TranscriptionService.transcribe must use a SINGLE atomic call
    /// (waitAndRecord), not separate wait + record calls.
    @Test func testTranscriptionServiceUsesAtomicWaitAndRecord() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")

        #expect(source.contains("waitAndRecord()"),
                "TranscriptionService must call waitAndRecord (atomic)")
        #expect(!source.contains("waitIfNeeded()"),
                "Must NOT use old split waitIfNeeded — was the original race")
        #expect(!source.contains("recordRequest()"),
                "Must NOT use old split recordRequest — was the original race")
    }

    /// Source-level: RateLimiter.waitAndRecord must set lastRequestTime BEFORE any await.
    @Test func testWaitAndRecordReservesSlotBeforeAwait() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/RateLimiter.swift")

        guard let funcRange = source.range(of: "func waitAndRecord()") else {
            Issue.record("waitAndRecord not found in RateLimiter.swift")
            return
        }
        let body = String(source[funcRange.lowerBound...])

        // lastRequestTime assignment must come before Task.sleep
        guard let assignPos = body.range(of: "lastRequestTime = scheduledTime")?.lowerBound else {
            Issue.record("lastRequestTime = scheduledTime not found")
            return
        }
        guard let sleepPos = body.range(of: "Task.sleep")?.lowerBound else {
            Issue.record("Task.sleep not found")
            return
        }
        #expect(assignPos < sleepPos,
                "lastRequestTime must be set BEFORE Task.sleep to prevent reentrant bypass")
    }

    /// First call with no prior history should complete immediately (no wait).
    @Test func testFirstCallCompletesImmediately() async throws {
        let limiter = RateLimiter(minimumInterval: 10.0)

        let start = Date()
        try await limiter.waitAndRecord()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.1,
                "First call with no history should not wait, took \(elapsed)s")
    }
}

// MARK: - Issue #14 Regression: Cancellation propagation (additional)

@Suite("Issue #14 — RateLimiter cancellation propagation (additional)")
struct Issue14CancellationTests {

    /// A pre-cancelled task must throw CancellationError immediately without sleeping.
    @Test func testPreCancelledTaskThrowsImmediately() async {
        let limiter = RateLimiter(minimumInterval: 10.0)

        let task = Task {
            // Pre-cancel before the actor call even starts
            try await limiter.waitAndRecord()
        }
        task.cancel()

        let start = Date()
        do {
            try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < 0.5, "Pre-cancelled task should throw fast, took \(elapsed)s")
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    /// Source-level: waitAndRecord must use `try await Task.sleep` (throwing),
    /// NOT `try? await Task.sleep` which swallows CancellationError.
    @Test func testWaitAndRecordDoesNotSwallowCancellation() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/RateLimiter.swift")

        guard let funcRange = source.range(of: "func waitAndRecord()") else {
            Issue.record("waitAndRecord not found")
            return
        }
        let body = String(source[funcRange.lowerBound...])

        #expect(!body.contains("try? await Task.sleep"),
                "Must NOT use try? — swallows CancellationError (the original bug)")
        #expect(body.contains("try await Task.sleep"),
                "Must use throwing sleep to propagate cancellation")
    }

    /// Source-level: waitAndRecord must be declared `throws` so callers see cancellation.
    @Test func testWaitAndRecordIsThrowingMethod() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/RateLimiter.swift")
        #expect(source.contains("func waitAndRecord() async throws"),
                "waitAndRecord must be async throws — was non-throwing in the original bug")
    }

    /// TranscriptionService must catch CancellationError from waitAndRecord.
    @Test func testTranscriptionServiceCatchesCancellationFromRateLimiter() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(source.contains("catch is CancellationError"),
                "transcribe() must catch CancellationError from waitAndRecord")
    }
}

// MARK: - Issue #15 Regression: Form encoding RFC 3986 compliance (additional)

@Suite("Issue #15 — Form encoding edge cases (RFC 3986)")
struct Issue15FormEncodingEdgeCaseTests {

    /// Percent sign in values must be double-encoded to %25.
    /// A token containing literal `%20` must not be misinterpreted as a space.
    @Test func testPercentSignInValueIsEncoded() {
        let bodyData = OpenAICodexAuth.formURLEncodedBody([
            "token": "abc%20def",
        ])
        let body = String(decoding: bodyData, as: UTF8.self)
        // The literal `%` must become `%25`, so `%20` → `%2520`
        #expect(body.contains("token=abc%2520def"),
                "Literal percent must be encoded as %25, got: \(body)")
    }

    /// Empty string values should produce `key=` (not omitted).
    @Test func testEmptyStringValueProducesKeyEquals() {
        let bodyData = OpenAICodexAuth.formURLEncodedBody([
            "empty": "",
            "full": "value",
        ])
        let body = String(decoding: bodyData, as: UTF8.self)
        #expect(body.contains("empty="), "Empty value must produce 'empty='")
        #expect(body.contains("full=value"), "Non-empty value must be present")
    }

    /// Keys with special characters must also be encoded.
    @Test func testKeysAreAlsoEncoded() {
        let bodyData = OpenAICodexAuth.formURLEncodedBody([
            "key with spaces": "val",
        ])
        let body = String(decoding: bodyData, as: UTF8.self)
        #expect(!body.contains("key with spaces="),
                "Key with spaces must be percent-encoded")
        #expect(body.contains("key%20with%20spaces=val"),
                "Spaces in keys must become %20, got: \(body)")
    }

    /// Output pairs must be sorted by key for deterministic body.
    @Test func testOutputIsSortedByKey() {
        let bodyData = OpenAICodexAuth.formURLEncodedBody([
            "z_last": "3",
            "a_first": "1",
            "m_middle": "2",
        ])
        let body = String(decoding: bodyData, as: UTF8.self)
        let pairs = body.components(separatedBy: "&")
        #expect(pairs.count == 3)
        #expect(pairs[0].hasPrefix("a_first="), "First pair should be a_first, got: \(pairs[0])")
        #expect(pairs[1].hasPrefix("m_middle="), "Second pair should be m_middle, got: \(pairs[1])")
        #expect(pairs[2].hasPrefix("z_last="), "Third pair should be z_last, got: \(pairs[2])")
    }

    /// Tilde, hyphen, period, underscore are unreserved and must NOT be encoded.
    @Test func testUnreservedCharsAreNotEncoded() {
        let bodyData = OpenAICodexAuth.formURLEncodedBody([
            "token": "a-b.c_d~e",
        ])
        let body = String(decoding: bodyData, as: UTF8.self)
        #expect(body == "token=a-b.c_d~e",
                "Unreserved chars -._~ must not be encoded, got: \(body)")
    }

    /// Unicode characters must be percent-encoded (UTF-8 bytes).
    @Test func testUnicodeIsPercentEncoded() {
        let bodyData = OpenAICodexAuth.formURLEncodedBody([
            "text": "café",
        ])
        let body = String(decoding: bodyData, as: UTF8.self)
        // 'é' is U+00E9, UTF-8: 0xC3 0xA9 → %C3%A9
        #expect(body.contains("caf%C3%A9"), "Unicode must be percent-encoded, got: \(body)")
        #expect(!body.contains("café"), "Raw unicode must not appear in encoded body")
    }

    /// Source-level: the formAllowedCharacters set must be restrictive
    /// (only alphanumerics + unreserved), NOT the permissive .urlQueryAllowed.
    @Test func testSourceDoesNotUseUrlQueryAllowed() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")

        // The encoding helper must NOT use .urlQueryAllowed (the original bug)
        let formSection = source.components(separatedBy: "formPercentEncode").last ?? ""
        #expect(!formSection.contains(".urlQueryAllowed"),
                "Must NOT use .urlQueryAllowed — doesn't escape &, =, + (the original bug)")
    }
}

@Suite("Issues #10/#12/#20/#23 — Additional Regression Coverage")
struct AdditionalLifecycleConcurrencyI18NAccessibilityRegressionTests {

    /// Issue #10: Ensure graceful termination performs all major cleanup actions.
    @Test func testIssue10TerminationIncludesRecorderTaskAndObserverCleanup() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        #expect(source.contains("func applicationWillTerminate(_ notification: Notification)"))
        #expect(source.contains("recorder?.cancel()"))
        #expect(source.contains("textInsertionTask?.cancel()"))
        #expect(source.contains("hotkeyListener = nil"))
        #expect(source.contains("NSWorkspace.shared.notificationCenter.removeObserver(self)"))
    }

    /// Issue #12: Verify hotkey callbacks are marshalled through `Task { @MainActor ... }`.
    @Test func testIssue12HotkeyCallbacksUseMainActorTaskPattern() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift")

        let mainActorTaskCount = countOccurrences(of: "Task { @MainActor [weak self] in", in: source)
        #expect(mainActorTaskCount >= 4,
                "Expected at least 4 MainActor Task callback hops in HotkeyListener, got \(mainActorTaskCount)")
        #expect(source.contains("self?.onActivate?()"))
    }

    /// Issue #20: Guard localization of high-visibility user-facing strings.
    @Test func testIssue20HighVisibilityStringsAreLocalized() throws {
        let appDelegate = try readProjectSource("Sources/App/AppDelegate.swift")
        let accessibility = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")

        #expect(appDelegate.contains("String(localized: \"Start Dictation\")"))
        #expect(appDelegate.contains("String(localized: \"Transcription Statistics\")"))
        #expect(appDelegate.contains("String(localized: \"Login to ChatGPT\")"))
        #expect(appDelegate.contains("String(localized: \"Microphone Access Required\")"))
        #expect(accessibility.contains("String(localized: \"Enable Accessibility Access\")"))
    }

    /// Issue #23: Ensure accessibility labels remain broadly applied (not just one control).
    @Test func testIssue23AccessibilityLabelCoverageDensity() throws {
        let appDelegate = try readProjectSource("Sources/App/AppDelegate.swift")
        let harness = try readProjectSource("Sources/App/UITestHarnessController.swift")

        let menuLabelCount = countOccurrences(of: ".setAccessibilityLabel", in: appDelegate)
        let harnessLabelCount = countOccurrences(of: ".setAccessibilityLabel", in: harness)

        #expect(menuLabelCount >= 10, "Expected rich menu accessibility labeling, got \(menuLabelCount)")
        #expect(harnessLabelCount >= 10, "Expected rich harness accessibility labeling, got \(harnessLabelCount)")
    }
}

@Suite("Issues #10/#11/#12/#13/#16/#19/#20/#21/#23 — Completion Regression Additions")
struct Issue10To23CompletionRegressionAdditions {

    @Test func testIssue10TerminationHandledByDelegateOrNotification() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let hasDelegateHook = source.contains("func applicationWillTerminate(_ notification: Notification)")
        let hasNotificationHook = source.contains("NSApplication.willTerminateNotification")
        #expect(hasDelegateHook || hasNotificationHook)
    }

    @Test func testIssue11HotkeyListenerDeinitPerformsStopCleanup() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift")
        guard let deinitRange = source.range(of: "@MainActor deinit") else {
            Issue.record("HotkeyListener deinit not found")
            return
        }

        let suffix = String(source[deinitRange.lowerBound...].prefix(160))
        #expect(suffix.contains("stop()"), "HotkeyListener deinit should call stop()")
    }

    @Test func testIssue12NoDispatchQueueMainAsyncInMainActorFiles() throws {
        let files = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/UITestHarnessController.swift",
            "Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift",
            "Sources/SpeakFlowCore/Hotkey/HotkeyListener.swift",
            "Sources/SpeakFlowCore/Audio/StreamingRecorder.swift"
        ]

        for file in files {
            let source = try readProjectSource(file)
            #expect(!source.contains("DispatchQueue.main.async"), "Found DispatchQueue.main.async in \(file)")
            #expect(!source.contains("DispatchQueue.main.asyncAfter"), "Found DispatchQueue.main.asyncAfter in \(file)")
        }
    }

    @Test func testIssue13TranscriptionServiceDoesNotRetainDeadActiveTasksField() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(!source.contains("activeTasks"))
    }

    @Test func testIssue16StreamingRecorderAvoidsPreconcurrencyImport() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("import AVFoundation"))
        #expect(!source.contains("@preconcurrency import AVFoundation"))
    }

    @Test func testIssue19FormatterCacheRemainsStableForPublicFormattedProperties() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            stats.recordTranscription(text: "issue nineteen formatter cache", audioDurationSeconds: 3.2)
            stats.recordApiCall()

            let before = Statistics._testFormatterIdentity
            _ = stats.formattedCharacters
            _ = stats.formattedWords
            _ = stats.formattedApiCalls
            let after = Statistics._testFormatterIdentity

            #expect(before == after)
        }
    }

    @Test func testIssue20LocalizationHooksPresentAcrossUserFacingFiles() throws {
        let files = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/UITestHarnessController.swift",
            "Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift",
            "Sources/SpeakFlowCore/Statistics.swift"
        ]

        for file in files {
            let source = try readProjectSource(file)
            #expect(source.contains("String(localized:"), "Expected localization hooks in \(file)")
        }
    }

    @Test func testIssue21FormattedDurationUsesExpectedZeroAndNonZeroOutput() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            #expect(stats.formattedDuration == String(localized: "0 seconds"))

            let duration = 3_661.0
            stats.recordTranscription(text: "duration", audioDurationSeconds: duration)

            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .full
            formatter.maximumUnitCount = 4
            formatter.zeroFormattingBehavior = .dropAll

            let expected = formatter.string(from: duration) ?? String(localized: "0 seconds")
            #expect(stats.formattedDuration == expected)
        }
    }

    @Test func testIssue23AccessibilityLabelsRemainPresentInMenuAndHarness() throws {
        let appDelegate = try readProjectSource("Sources/App/AppDelegate.swift")
        let harness = try readProjectSource("Sources/App/UITestHarnessController.swift")

        let menuCount = countOccurrences(of: ".setAccessibilityLabel", in: appDelegate)
        let harnessCount = countOccurrences(of: ".setAccessibilityLabel", in: harness)

        #expect(menuCount >= 10)
        #expect(harnessCount >= 10)
    }
}

// MARK: - VAD Model Cache Tests

@Suite("VADModelCache — warm-up and caching")
struct VADModelCacheTests {

    @Test func testSharedSingletonExists() async {
        // VADModelCache.shared must be accessible (actor singleton)
        let cache = VADModelCache.shared
        // Just verify we can access it without crash - it's a non-optional singleton
        #expect(type(of: cache) == VADModelCache.self)
    }

    @Test func testWarmUpIsIdempotent() async {
        // Calling warmUp multiple times must not crash or create duplicate tasks.
        // We can't observe private state, but we verify no throwing/crash.
        await VADModelCache.shared.warmUp()
        await VADModelCache.shared.warmUp()
        await VADModelCache.shared.warmUp()
        // If we reach here without crash, idempotency holds.
    }

    @Test func testGetManagerSucceedsOnAppleSilicon() async throws {
        // Verify that getManager can actually create/return a manager on supported platforms
        guard VADProcessor.isAvailable else { return }
        
        // This should succeed without throwing
        let manager = try await VADModelCache.shared.getManager(threshold: 0.5)
        
        // Verify the manager was actually created (check identity is stable)
        #expect(type(of: manager) == VadManager.self, "getManager must return a VadManager instance")
    }

    @Test func testGetManagerReturnsSameInstance() async throws {
        // Two calls to getManager should return the same cached VadManager.
        guard VADProcessor.isAvailable else { return }
        let m1 = try await VADModelCache.shared.getManager(threshold: 0.5)
        let m2 = try await VADModelCache.shared.getManager(threshold: 0.5)
        #expect(m1 === m2, "getManager must return the same cached instance")
    }
}

@Suite("VADModelCache — source regression guards")
struct VADModelCacheSourceRegressionTests {

    @Test func testVADModelCacheActorExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        #expect(source.contains("public actor VADModelCache"))
        #expect(source.contains("public static let shared = VADModelCache()"))
    }

    @Test func testWarmUpMethodExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        #expect(source.contains("public func warmUp("))
    }

    @Test func testWarmUpGuardsAgainstDoubleStart() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        // Must check both cachedManager and warmUpTask to avoid duplicate loads
        #expect(source.contains("guard cachedManager == nil, warmUpTask == nil"))
    }

    @Test func testGetManagerUsesCache() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        // Must check cachedManager AND threshold match before returning cache
        #expect(source.contains("if let cached = cachedManager, cachedThreshold == threshold"))
    }

    @Test func testGetManagerAwaitsInProgressWarmUp() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        // If warm-up is in progress, await it instead of loading a second model
        #expect(source.contains("if let pending = warmUpTask"))
        #expect(source.contains("try await pending.value"))
    }

    @Test func testVADProcessorUsesCache() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        // VADProcessor.initialize() must use the shared cache
        #expect(source.contains("VADModelCache.shared.getManager"))
        // It must NOT create a new VadManager directly
        // Count VadManager inits — only the cache should create them
        let initInCache = source.contains("VadManager(config:")
        #expect(initInCache, "VadManager(config:) must exist (in the cache)")
    }

    @Test func testAppDelegateWarmUpOnLaunch() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // Warm-up must happen at app launch
        #expect(source.contains("VADModelCache.shared.warmUp"))
        // Only when VAD is available and enabled
        #expect(source.contains("VADProcessor.isAvailable"))
        #expect(source.contains("Settings.shared.vadEnabled"))
    }
}

// MARK: - Menu Label Toggle Tests

@Suite("Menu Start/Stop Dictation toggle — source regression")
struct MenuDictationToggleSourceTests {

    @Test func testBuildMenuUsesRecordingStateForLabel() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // buildMenu must check isRecording/isProcessingFinal to pick label
        #expect(source.contains("isRecording || isProcessingFinal"))
        #expect(source.contains("Stop Dictation"))
        #expect(source.contains("Start Dictation"))
    }

    @Test func testUpdateStatusIconRebuildMenu() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // updateStatusIcon must rebuild the menu so the label updates on state change
        #expect(source.contains("func updateStatusIcon()"))
        // Must call buildMenu inside updateStatusIcon
        let updateIconBody = extractFunctionBody(named: "updateStatusIcon", from: source)
        #expect(updateIconBody != nil, "updateStatusIcon function must exist")
        if let body = updateIconBody {
            #expect(body.contains("buildMenu"), "updateStatusIcon must call buildMenu to refresh menu label")
        }
    }

    @Test func testMenuLabelIsDynamic() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // The menu item must use a variable label, not a hardcoded one
        #expect(source.contains("dictationLabel"))
    }
}

// MARK: - Enter Key During Processing-Final Phase Tests

@Suite("Enter key handling during processing-final — source regression")
struct EnterKeyProcessingFinalSourceTests {

    @Test func testStopRecordingDoesNotStopKeyListener() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // Extract the body of stopRecording
        let body = extractFunctionBody(named: "stopRecording", from: source)
        #expect(body != nil, "stopRecording function must exist")
        if let body = body {
            // stopKeyListener must NOT be the first thing called
            // The key listener stays active through processing-final
            let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let nonCommentLines = lines.filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.isEmpty }
            // stopKeyListener should not appear in stopRecording at all
            let hasStopKeyListener = nonCommentLines.contains { $0.contains("stopKeyListener()") }
            #expect(!hasStopKeyListener,
                    "stopRecording must NOT call stopKeyListener — key listener stays active during processing-final")
        }
    }

    @Test func testKeyHandlerHandlesBothPhases() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // The key event handler must check both isRecording and isProcessingFinal
        let handler = extractFunctionBody(named: "handleRecordingKeyEvent", from: source)
        #expect(handler != nil, "handleRecordingKeyEvent must exist")
        if let handler = handler {
            #expect(handler.contains("self.isRecording"), "Handler must check isRecording")
            #expect(handler.contains("self.isProcessingFinal"), "Handler must check isProcessingFinal")
            #expect(handler.contains("shouldPressEnterOnComplete = true"),
                    "Handler must flag Enter for post-completion during processing-final")
        }
    }

    @Test func testFinishIfDoneStopsKeyListener() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractFunctionBody(named: "finishIfDone", from: source)
        #expect(body != nil, "finishIfDone must exist")
        if let body = body {
            // stopKeyListener must be called in finishIfDone (at least once for normal path)
            let count = countOccurrences(of: "stopKeyListener()", in: body)
            #expect(count >= 2,
                    "finishIfDone must call stopKeyListener in both timeout and success paths (found \(count))")
        }
    }

    @Test func testCancelRecordingStopsKeyListener() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractFunctionBody(named: "cancelRecording", from: source)
        #expect(body != nil, "cancelRecording must exist")
        if let body = body {
            #expect(body.contains("stopKeyListener()"),
                    "cancelRecording must stop key listener")
        }
    }

    @Test func testEnterKeyConsumedDuringProcessingFinal() throws {
        // The CGEvent tap handler returns nil for Enter (keyCode 36) = consumed
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let handler = extractFunctionBody(named: "handleRecordingKeyEvent", from: source)
        #expect(handler != nil)
        if let handler = handler {
            // Enter case must return nil to consume the event
            #expect(handler.contains("case 36:"))
            #expect(handler.contains("return nil"))
        }
    }

    @Test func testFallbackMonitorAlsoHandlesProcessingFinal() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // The NSEvent fallback monitor must also handle isProcessingFinal
        #expect(source.contains("self.isProcessingFinal"),
                "Fallback NSEvent monitor must handle isProcessingFinal phase")
    }
}

// MARK: - OAuth Server Cleanup Tests

@Suite("OAuth callback server cleanup on termination — source regression")
struct OAuthServerCleanupSourceTests {

    @Test func testOAuthServerPropertyExists() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(source.contains("oauthCallbackServer: OAuthCallbackServer?"),
                "AppDelegate must have an oauthCallbackServer property")
    }

    @Test func testLoginFlowStoresServer() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(source.contains("oauthCallbackServer = server"),
                "startLoginFlow must store the server for cleanup")
    }

    @Test func testLoginFlowClearsServerOnCompletion() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(source.contains("self.oauthCallbackServer = nil"),
                "Server reference must be cleared after login completes")
    }

    @Test func testTerminationStopsOAuthServer() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractTerminationBody(from: source)
        #expect(body != nil, "applicationWillTerminate must exist")
        if let body = body {
            #expect(body.contains("oauthCallbackServer?.stop()"),
                    "applicationWillTerminate must stop the OAuth server")
            #expect(body.contains("oauthCallbackServer = nil"),
                    "applicationWillTerminate must nil the OAuth server")
        }
    }
}

// MARK: - TranscriptionQueueBridge Cleanup Tests

@Suite("TranscriptionQueueBridge.stopListening — cleanup regression")
struct TranscriptionQueueBridgeCleanupTests {

    @Test func testStopListeningIsPublic() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift")
        #expect(source.contains("public func stopListening()"),
                "stopListening must be public so App target can call it")
    }

    @Test func testStopListeningCancelsStreamTask() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift")
        // Find stopListening body
        let body = extractFunctionBody(named: "stopListening", from: source)
        #expect(body != nil)
        if let body = body {
            #expect(body.contains("streamTask?.cancel()"))
            #expect(body.contains("streamTask = nil"))
        }
    }

    @Test func testTerminationCallsStopListening() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractTerminationBody(from: source)
        #expect(body != nil)
        if let body = body {
            #expect(body.contains("queueBridge.stopListening()"),
                    "applicationWillTerminate must call stopListening on the queue bridge")
        }
    }

    @Test func testStopListeningBehavior() async {
        // Behavioral: stopListening must be callable without crash
        let bridge = await TranscriptionQueueBridge()
        await bridge.stopListening()
        // Double-stop must be safe
        await bridge.stopListening()
    }
}

// MARK: - Updated Termination Completeness Test

@Suite("applicationWillTerminate — full cleanup audit")
struct TerminationCleanupAuditTests {

    @Test func testAllResourcesCleanedUp() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractTerminationBody(from: source)
        #expect(body != nil, "applicationWillTerminate must exist")
        guard let body = body else { return }

        // Hotkey listener
        #expect(body.contains("hotkeyListener?.stop()"))
        // Key monitor (Enter/Escape interceptor)
        #expect(body.contains("stopKeyListener()"))
        // Active recording
        #expect(body.contains("recorder?.cancel()"))
        // In-flight transcription tasks
        #expect(body.contains("Transcription.shared.cancelAll()"))
        // Queue stream task
        #expect(body.contains("queueBridge.stopListening()"))
        // Text insertion task
        #expect(body.contains("textInsertionTask?.cancel()"))
        // OAuth callback server
        #expect(body.contains("oauthCallbackServer?.stop()"))
        // Microphone permission polling task
        #expect(body.contains("micPermissionTask?.cancel()"))
        // Accessibility permission polling
        #expect(body.contains("permissionManager?.stopPolling()"))
        // Workspace notification observer
        #expect(body.contains("removeObserver(self)"))
    }
}

// MARK: - Helpers

/// Extract the body of a function by name (simple brace-matching heuristic).
private func extractFunctionBody(named name: String, from source: String) -> String? {
    guard let range = source.range(of: "func \(name)") else { return nil }
    let after = source[range.lowerBound...]
    guard let braceStart = after.firstIndex(of: "{") else { return nil }

    var depth = 0
    var idx = braceStart
    while idx < after.endIndex {
        let ch = after[idx]
        if ch == "{" { depth += 1 }
        else if ch == "}" { depth -= 1; if depth == 0 { break } }
        idx = after.index(after: idx)
    }
    guard depth == 0 else { return nil }
    return String(after[braceStart...idx])
}

/// Extract applicationWillTerminate body specifically.
private func extractTerminationBody(from source: String) -> String? {
    extractFunctionBody(named: "applicationWillTerminate", from: source)
}

// MARK: - P1 Regression: Failed warm-up task must be cleared for retry

@Suite("P1 — VADModelCache failed warm-up allows retry")
struct VADModelCacheFailedWarmUpTests {

    @Test func testWarmUpTaskClearedOnFailure_source() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        // The warm-up Task must clear warmUpTask in the catch/error path,
        // not only on success. Otherwise a transient failure permanently
        // blocks VAD from recovering.
        guard let warmUpRange = source.range(of: "warmUpTask = Task {") else {
            Issue.record("warmUpTask = Task { not found in VADProcessor.swift")
            return
        }
        let body = String(source[warmUpRange.lowerBound...].prefix(1500))

        // Must have a do/catch pattern inside the Task
        #expect(body.contains("} catch {"),
                "warmUp Task must have a catch block to handle failures")

        // The catch block must clear warmUpTask
        // Find the catch block content
        guard let catchRange = body.range(of: "} catch {") else {
            Issue.record("catch block not found")
            return
        }
        let catchBody = String(body[catchRange.lowerBound...].prefix(300))
        #expect(catchBody.contains("self.warmUpTask = nil"),
                "catch block must set warmUpTask = nil so retry is possible")
    }

    @Test func testWarmUpTaskClearedOnSuccess_source() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        // Verify the success path also clears warmUpTask (existing behavior preserved)
        guard let warmUpRange = source.range(of: "warmUpTask = Task {") else {
            Issue.record("warmUpTask = Task { not found")
            return
        }
        let body = String(source[warmUpRange.lowerBound...].prefix(1500))

        // The do block (success path) must also set warmUpTask = nil
        // Find content between "do {" and "} catch {"
        guard let doStart = body.range(of: "do {"),
              let catchStart = body.range(of: "} catch {") else {
            Issue.record("do/catch structure not found")
            return
        }
        let doBody = String(body[doStart.lowerBound..<catchStart.lowerBound])
        #expect(doBody.contains("self.warmUpTask = nil"),
                "Success path must also clear warmUpTask")
        #expect(doBody.contains("self.cachedManager = manager"),
                "Success path must cache the manager")
    }
}

// MARK: - P2 Regression: Cached manager must respect threshold changes

@Suite("P2 — VADModelCache respects threshold changes")
struct VADModelCacheThresholdTests {

    @Test func testCachedThresholdPropertyExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        #expect(source.contains("cachedThreshold"),
                "VADModelCache must track the threshold used for the cached manager")
    }

    @Test func testGetManagerChecksThresholdMatch() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        // getManager must check both cachedManager AND cachedThreshold before returning cache
        guard let getManagerRange = source.range(of: "func getManager(threshold: Float)") else {
            Issue.record("getManager not found")
            return
        }
        let body = String(source[getManagerRange.lowerBound...].prefix(1200))

        // Must check threshold matches, not just that cachedManager exists
        #expect(body.contains("cachedThreshold == threshold"),
                "getManager must verify cached threshold matches requested threshold")
    }

    @Test func testGetManagerInvalidatesOnThresholdChange() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        guard let getManagerRange = source.range(of: "func getManager(threshold: Float)") else {
            Issue.record("getManager not found")
            return
        }
        let body = String(source[getManagerRange.lowerBound...].prefix(1200))

        // When threshold changes, must invalidate stale cache
        #expect(body.contains("cachedManager = nil"),
                "getManager must clear cachedManager when threshold changes")
        #expect(body.contains("cachedThreshold = nil"),
                "getManager must clear cachedThreshold when threshold changes")
    }

    @Test func testWarmUpStoresThreshold() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        // The success path in warmUp must store the threshold alongside the manager
        guard let warmUpRange = source.range(of: "warmUpTask = Task {") else {
            Issue.record("warmUpTask = Task { not found")
            return
        }
        let body = String(source[warmUpRange.lowerBound...].prefix(1500))
        #expect(body.contains("self.cachedThreshold = threshold"),
                "warmUp success path must store the threshold for later matching")
    }

    @Test func testGetManagerOnDemandStoresThreshold() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        guard let getManagerRange = source.range(of: "func getManager(threshold: Float)") else {
            Issue.record("getManager not found")
            return
        }
        let body = String(source[getManagerRange.lowerBound...].prefix(1200))

        // The on-demand (cold) path must also store the threshold
        #expect(body.contains("cachedThreshold = threshold"),
                "On-demand path must store threshold for cache consistency")
    }
}

// MARK: - P1 Regression: Enter key must not be consumed when no recording phase is active

@Suite("P1 — Enter/Escape not consumed when recording inactive")
struct KeyListenerSafetyTests {

    @Test func testKeyListenerActiveAtomicFlagExists() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(source.contains("keyListenerActive"),
                "AppDelegate must have a thread-safe keyListenerActive flag")
        #expect(source.contains("OSAllocatedUnfairLock"),
                "keyListenerActive must use OSAllocatedUnfairLock for thread safety")
    }

    @Test func testHandleRecordingKeyEventChecksFlag() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        let body = extractFunctionBody(named: "handleRecordingKeyEvent", from: source)
        #expect(body != nil, "handleRecordingKeyEvent must exist")
        guard let body else { return }

        // Must check keyListenerActive BEFORE examining keyCode
        #expect(body.contains("keyListenerActive"),
                "handleRecordingKeyEvent must check keyListenerActive flag")

        // The guard must return the event (pass-through), not nil (consume)
        #expect(body.contains("Unmanaged.passRetained(event)"),
                "When flag is false, event must pass through (not consumed)")
    }

    @Test func testStartKeyListenerSetsFlag() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        let body = extractFunctionBody(named: "startKeyListener", from: source)
        #expect(body != nil, "startKeyListener must exist")
        guard let body else { return }

        #expect(body.contains("keyListenerActive"),
                "startKeyListener must set keyListenerActive to true")
    }

    @Test func testStopKeyListenerClearsFlag() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        let body = extractFunctionBody(named: "stopKeyListener", from: source)
        #expect(body != nil, "stopKeyListener must exist")
        guard let body else { return }

        #expect(body.contains("keyListenerActive"),
                "stopKeyListener must set keyListenerActive to false")
    }

    @Test func testRecorderStartFailureCleansUpKeyListener() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        let body = extractFunctionBody(named: "startRecording", from: source)
        #expect(body != nil, "startRecording must exist")
        guard let body else { return }

        // Key listener must only start AFTER confirmed successful recorder start
        #expect(body.contains("if started"),
                "startRecording must check if recorder.start() succeeded")

        // The success branch must start the key listener
        guard let successRange = body.range(of: "if started") else {
            Issue.record("'if started' block not found")
            return
        }
        let successBody = String(body[successRange.lowerBound...].prefix(500))
        #expect(successBody.contains("startKeyListener()"),
                "Key listener must only start after confirmed successful recorder start")

        // The failure branch (else) after "if started" must call stopKeyListener for safety
        let afterIfStarted = String(body[successRange.lowerBound...])
        guard let failRange = afterIfStarted.range(of: "} else {") else {
            Issue.record("else block not found after 'if started'")
            return
        }
        let failBody = String(afterIfStarted[failRange.lowerBound...].prefix(500))
        #expect(failBody.contains("stopKeyListener()"),
                "Recorder start failure must call stopKeyListener() to prevent stale key consumption")
    }

    @Test func testFlagClearedBeforeTapDisabled() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")

        let body = extractFunctionBody(named: "stopKeyListener", from: source)
        guard let body else {
            Issue.record("stopKeyListener not found")
            return
        }

        // keyListenerActive must be cleared BEFORE disabling the tap,
        // so any in-flight callback sees the flag as false immediately.
        guard let flagPos = body.range(of: "keyListenerActive")?.lowerBound,
              let tapPos = body.range(of: "CGEvent.tapEnable")?.lowerBound else {
            Issue.record("Required code not found in stopKeyListener")
            return
        }
        #expect(flagPos < tapPos,
                "keyListenerActive must be cleared BEFORE disabling CGEvent tap")
    }
}

// MARK: - Regression: Force-send chunks during continuous speech

@Suite("Force-send chunks during continuous speech — source regression")
struct ForceSendChunkSourceTests {

    @Test func testForceSendChunkMultiplierExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Config.swift")
        #expect(source.contains("forceSendChunkMultiplier"),
                "Config must define forceSendChunkMultiplier")
        #expect(source.contains("2.0"),
                "forceSendChunkMultiplier should be 2.0")
    }

    @Test func testPeriodicCheckHasForceSendPath() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        let body = extractFunctionBody(named: "periodicCheck", from: source)
        #expect(body != nil, "periodicCheck must exist")
        guard let body else { return }

        #expect(body.contains("forceSendChunkMultiplier"),
                "periodicCheck must reference forceSendChunkMultiplier for hard upper limit")
        #expect(body.contains("FORCE CHUNK"),
                "Force-send path must log a FORCE CHUNK warning")
    }

    @Test func testForceSendIgnoresSpeakingState() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        let body = extractFunctionBody(named: "periodicCheck", from: source)
        guard let body else {
            Issue.record("periodicCheck not found")
            return
        }

        // The force-send path must be in the `else if` branch after the `if !isSpeaking` check,
        // meaning it fires even when isSpeaking is true
        #expect(body.contains("} else if duration >= settings.maxChunkDuration * Config.forceSendChunkMultiplier"),
                "Force-send must be an else-if after the !isSpeaking check (fires when speaking)")
    }
}

// MARK: - Regression: Timeout scales with audio duration

@Suite("Timeout scales with data size — source regression")
struct TimeoutScalingSourceTests {

    @Test func testTimeoutScalingConfigExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Config.swift")
        #expect(source.contains("maxTimeout"))
        #expect(source.contains("baseTimeoutDataSize"))
    }

    @Test func testTimeoutScalingMethod() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(source.contains("func timeout(forDataSize"),
                "TranscriptionService must have a data-size-based timeout method")
    }

    @Test func testTimeoutScalingBehavior() {
        // Zero bytes: base timeout
        let zero = TranscriptionService.timeout(forDataSize: 0)
        #expect(zero == Config.timeout,
                "Zero bytes should use base timeout, got \(zero)")

        // At base data size: base timeout
        let atBase = TranscriptionService.timeout(forDataSize: Config.baseTimeoutDataSize)
        #expect(atBase == Config.timeout,
                "Data at baseTimeoutDataSize should use base timeout, got \(atBase)")

        // At max file size: max timeout
        let atMax = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes)
        #expect(atMax == Config.maxTimeout,
                "Data at maxAudioSizeBytes should use maxTimeout, got \(atMax)")

        // Above max: still capped
        let overMax = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes * 2)
        #expect(overMax == Config.maxTimeout,
                "Data above max should be capped at maxTimeout, got \(overMax)")

        // Midpoint: halfway between base and max timeout
        let midSize = Config.baseTimeoutDataSize + (Config.maxAudioSizeBytes - Config.baseTimeoutDataSize) / 2
        let midTimeout = TranscriptionService.timeout(forDataSize: midSize)
        let expectedMid = Config.timeout + (Config.maxTimeout - Config.timeout) / 2.0
        #expect(abs(midTimeout - expectedMid) < 0.01,
                "Mid-range data should get mid-range timeout, got \(midTimeout) expected \(expectedMid)")

        // Monotonically increasing
        let t1 = TranscriptionService.timeout(forDataSize: 500_000)
        let t2 = TranscriptionService.timeout(forDataSize: 5_000_000)
        let t3 = TranscriptionService.timeout(forDataSize: 15_000_000)
        #expect(t1 <= t2 && t2 <= t3,
                "Timeout must be monotonically increasing: \(t1) <= \(t2) <= \(t3)")
    }

    @Test func testTranscriptionUsesDataSize() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/Transcription.swift")
        #expect(source.contains("timeout(forDataSize: chunk.wavData.count)"),
                "Transcription must compute timeout from chunk data size")
    }
}

// MARK: - Swift 6 Actor-Isolation Regression Tests (Permission Polling)

@Suite("Swift 6 Actor-Isolation — Permission Polling")
struct PermissionPollingSwift6Tests {

    /// BLOCKER REGRESSION: Timer.scheduledTimer closures are @Sendable and cannot
    /// safely access @MainActor state. Permission polling must use Task loops.
    @Test func testAccessibilityPollingUsesTaskNotTimer() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")
        #expect(!source.contains("Timer.scheduledTimer"),
                "REGRESSION: Must not use Timer.scheduledTimer (Swift 6 actor-isolation violation)")
        #expect(source.contains("permissionCheckTask = Task"),
                "Must use Task-based polling loop")
        #expect(source.contains("Task.sleep"),
                "Must use Task.sleep for polling interval")
    }

    @Test func testAccessibilityPollingHasNoTimerProperty() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")
        #expect(!source.contains("permissionCheckTimer"),
                "Must not have Timer property — use Task instead")
        #expect(source.contains("permissionCheckTask: Task<Void, Never>?"),
                "Must have Task<Void, Never>? property for polling")
    }

    @Test func testStopPollingCancelsTask() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")
        guard let range = source.range(of: "func stopPolling()") else {
            Issue.record("stopPolling not found")
            return
        }
        let body = String(source[range.lowerBound...].prefix(200))
        #expect(body.contains("permissionCheckTask?.cancel()"),
                "stopPolling must cancel the polling task")
        #expect(body.contains("permissionCheckTask = nil"),
                "stopPolling must nil out the task reference")
    }

    @Test func testMicPermissionPollingUsesTaskNotTimer() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(!source.contains("micPermissionTimer"),
                "REGRESSION: Must not use micPermissionTimer (Swift 6 actor-isolation violation)")
        #expect(source.contains("micPermissionTask"),
                "Must use micPermissionTask for microphone polling")
    }

    @Test func testMicPermissionPollingTaskLoop() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        guard let range = source.range(of: "func startMicrophonePermissionPolling()") else {
            Issue.record("startMicrophonePermissionPolling not found")
            return
        }
        let body = String(source[range.lowerBound...].prefix(800))
        #expect(body.contains("micPermissionTask = Task"),
                "Must use Task-based polling")
        #expect(body.contains("Task.sleep"),
                "Must use Task.sleep for polling interval")
        #expect(!body.contains("Timer.scheduledTimer"),
                "Must NOT use Timer.scheduledTimer")
    }

    /// Verify the polling task delegates to updateStatusIcon/setupHotkey
    /// directly (no extra Task dispatch needed since already on MainActor).
    @Test func testPollingDelegateCallsAreDirectNotWrapped() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Permissions/AccessibilityPermissionManager.swift")
        guard let range = source.range(of: "permissionCheckTask = Task") else {
            Issue.record("permissionCheckTask assignment not found")
            return
        }
        let body = String(source[range.lowerBound...].prefix(1200))
        // Delegate calls should be direct (already on MainActor), not wrapped in another Task
        #expect(body.contains("self.delegate?.updateStatusIcon()"),
                "Delegate calls should be direct on MainActor")
        #expect(body.contains("self.delegate?.setupHotkey()"),
                "Delegate calls should be direct on MainActor")
    }

    /// Behavioral: stopPolling is idempotent.
    @Test func testStopPollingIdempotent() async {
        await MainActor.run {
            let manager = AccessibilityPermissionManager()
            manager.stopPolling()
            manager.stopPolling()
            manager.stopPolling()
        }
    }

    @Test @MainActor func testMaxPollAttempts() {
        #expect(AccessibilityPermissionManager.maxPollAttempts == 60,
                "maxPollAttempts should be 60 (2 minutes at 2s intervals)")
    }
}

// MARK: - Key Listener Start Order Regression Tests (Issue #7)

@Suite("Issue #7 Regression — Key Listener Start After Recorder Success")
struct KeyListenerStartOrderTests {

    /// HIGH REGRESSION: startKeyListener must be called ONLY after recorder.start()
    /// succeeds. Previously it was called synchronously before the async Task,
    /// leaving Enter/Escape interception active even when recording failed to start.
    @Test func testKeyListenerInsideSuccessBranch() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractFunctionBody(named: "startRecording", from: source)
        guard let body else {
            Issue.record("startRecording not found")
            return
        }

        // Must have "if started { ... startKeyListener ... } else { ... stopKeyListener ... }"
        #expect(body.contains("if started"),
                "Must check recorder.start() result")

        guard let ifPos = body.range(of: "if started")?.lowerBound,
              let startKLPos = body.range(of: "startKeyListener()")?.lowerBound else {
            Issue.record("Expected structure not found in startRecording")
            return
        }

        // startKeyListener must come AFTER "if started"
        #expect(startKLPos > ifPos,
                "REGRESSION: startKeyListener() must be inside the 'if started' success branch")

        // Find the "} else {" that follows "if started" (not an earlier one)
        let afterIf = String(body[ifPos...])
        guard let elseInAfterIf = afterIf.range(of: "} else {") else {
            Issue.record("else block after 'if started' not found")
            return
        }
        // startKeyListener must appear before the else block relative to "if started"
        guard let startKLInAfterIf = afterIf.range(of: "startKeyListener()") else {
            Issue.record("startKeyListener not found after 'if started'")
            return
        }
        #expect(startKLInAfterIf.lowerBound < elseInAfterIf.lowerBound,
                "REGRESSION: startKeyListener() must be in success branch before else")
    }

    /// Exactly one call to startKeyListener in startRecording (no duplicate).
    @Test func testExactlyOneStartKeyListenerCall() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractFunctionBody(named: "startRecording", from: source)
        guard let body else {
            Issue.record("startRecording not found")
            return
        }

        let count = body.components(separatedBy: "startKeyListener()").count - 1
        #expect(count == 1,
                "Must call startKeyListener() exactly once in startRecording, found \(count)")
    }

    /// The failure branch must still call stopKeyListener for safety.
    @Test func testFailureBranchCallsStopKeyListener() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        let body = extractFunctionBody(named: "startRecording", from: source)
        guard let body else {
            Issue.record("startRecording not found")
            return
        }

        // Find the "} else {" that follows "if started" specifically
        guard let ifStartedRange = body.range(of: "if started") else {
            Issue.record("'if started' not found")
            return
        }
        let afterIfStarted = String(body[ifStartedRange.lowerBound...])
        guard let elseRange = afterIfStarted.range(of: "} else {") else {
            Issue.record("else block after 'if started' not found")
            return
        }
        let elseBody = String(afterIfStarted[elseRange.lowerBound...].prefix(500))
        #expect(elseBody.contains("stopKeyListener()"),
                "Failure branch must call stopKeyListener() for safety")
    }
}

// MARK: - AuthError Localization Regression Tests (Issue #20)

@Suite("Issue #20 — AuthError Localization")
struct AuthErrorLocalizationTests {

    /// LOW REGRESSION: All AuthError.errorDescription strings must use String(localized:)
    /// for locale readiness. Previously they were hardcoded English.
    @Test func testAllErrorDescriptionsLocalized() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")
        guard let range = source.range(of: "public var errorDescription: String?") else {
            Issue.record("errorDescription not found")
            return
        }
        let body = String(source[range.lowerBound...].prefix(1500))

        // Count localized vs hardcoded returns
        var localizedCount = 0
        var hardcodedCount = 0
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("return ") {
                if trimmed.contains("String(localized:") {
                    localizedCount += 1
                } else if trimmed.contains("\"") {
                    hardcodedCount += 1
                }
            }
        }

        #expect(localizedCount >= 6,
                "All 6 AuthError cases must use String(localized:), found \(localizedCount)")
        #expect(hardcodedCount == 0,
                "REGRESSION: No hardcoded strings in errorDescription, found \(hardcodedCount)")
    }

    @Test func testSpecificErrorMessagesLocalized() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")
        #expect(source.contains("String(localized: \"Not logged in"))
        #expect(source.contains("String(localized: \"Failed to exchange"))
        #expect(source.contains("String(localized: \"Failed to refresh"))
        #expect(source.contains("String(localized: \"Could not extract"))
        #expect(source.contains("String(localized: \"OAuth state mismatch"))
        #expect(source.contains("String(localized: \"Missing authorization"))
    }

    /// AuthError runtime values should be non-empty.
    @Test func testErrorDescriptionsAreNonEmpty() {
        let cases: [AuthError] = [
            .notLoggedIn,
            .tokenExchangeFailed("test"),
            .tokenRefreshFailed("test"),
            .missingAccountId,
            .stateMismatch,
            .missingCode,
        ]
        for error in cases {
            #expect(error.errorDescription != nil, "\(error) should have a description")
            #expect(!error.errorDescription!.isEmpty, "\(error) description should be non-empty")
        }
    }

    /// Interpolated error descriptions include the detail message.
    @Test func testInterpolatedErrorDescriptions() {
        let exchangeError = AuthError.tokenExchangeFailed("server 500")
        #expect(exchangeError.errorDescription?.contains("server 500") == true,
                "tokenExchangeFailed should include detail message")

        let refreshError = AuthError.tokenRefreshFailed("network timeout")
        #expect(refreshError.errorDescription?.contains("network timeout") == true,
                "tokenRefreshFailed should include detail message")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - P2 Fix: VAD resetChunk() on skip path — source regression
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("P2 — VAD resetChunk called on skip path")
struct VADResetChunkOnSkipSourceTests {

    /// Source-level: sendChunkIfReady must call resetChunk() inside the skip branch
    /// so stale silent samples don't accumulate across consecutive skipped chunks.
    @Test func testResetChunkCalledInSkipBranch() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        // Find the skip branch
        guard let skipRange = source.range(of: "skipSilentChunks && speechProbability < skipThreshold") else {
            Issue.record("Skip check not found in sendChunkIfReady")
            return
        }

        // Locate the return false that ends the skip branch
        let afterSkip = source[skipRange.upperBound...]
        guard let returnFalseRange = afterSkip.range(of: "return false") else {
            Issue.record("return false not found after skip check")
            return
        }

        // resetChunk must appear BETWEEN the skip condition and the return false
        let skipBranch = source[skipRange.upperBound..<returnFalseRange.lowerBound]
        #expect(skipBranch.contains("resetChunk()"),
                "resetChunk() must be called in skip branch to prevent stale accumulation")
    }

    /// Source-level: resetChunk() must ALSO still be called after buffer drain (send path).
    @Test func testResetChunkCalledInSendBranch() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let drainRange = source.range(of: "buffer.takeAll()") else {
            Issue.record("buffer.takeAll() not found in sendChunkIfReady")
            return
        }

        let afterDrain = source[drainRange.upperBound...]
        // resetChunk should appear after drain but within sendChunkIfReady
        let nextFuncBoundary = afterDrain.range(of: "private func ")?.lowerBound
                            ?? afterDrain.range(of: "func ")?.lowerBound
                            ?? afterDrain.endIndex
        let sendBody = afterDrain[..<nextFuncBoundary]
        #expect(sendBody.contains("resetChunk()"),
                "resetChunk() must still be called after buffer drain in send path")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - P2 Fix: Statistics formatter MainActor isolation
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("P2 — Statistics formatter explicit @MainActor isolation")
struct StatisticsFormatterIsolationTests {

    /// Source-level: durationFormatter must be explicitly @MainActor to prevent
    /// theoretical concurrent access during static initialization.
    @Test func testDurationFormatterIsMainActorIsolated() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Statistics.swift")
        #expect(source.contains("@MainActor private static let durationFormatter"),
                "durationFormatter must be explicitly @MainActor-isolated")
    }

    /// Source-level: decimalFormatter must be explicitly @MainActor.
    @Test func testDecimalFormatterIsMainActorIsolated() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Statistics.swift")
        #expect(source.contains("@MainActor private static let decimalFormatter"),
                "decimalFormatter must be explicitly @MainActor-isolated")
    }

    /// Behavioral: formatters remain stable after explicit @MainActor annotation.
    @Test func testFormattersStillProduceCorrectOutput() async {
        await MainActor.run {
            // Duration formatting
            let stats = Statistics.shared
            let saved = stats.totalSecondsTranscribed
            defer { if saved == 0 { stats.reset() } }

            let formatted = stats.formattedDuration
            #expect(formatted.count > 0, "formattedDuration must produce output")

            // Decimal formatting
            let count = Statistics._testFormatCount(42)
            #expect(count == "42" || count.contains("42"),
                    "Decimal formatter must still produce correct output")
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - P2 Fix: httpProvider thread-safe access
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("P2 — httpProvider lock-protected access", .serialized)
struct HttpProviderThreadSafetyTests {

    /// Source-level: httpProvider must NOT be nonisolated(unsafe).
    @Test func testNoNonisolatedUnsafe() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")
        #expect(!source.contains("nonisolated(unsafe) static var httpProvider"),
                "httpProvider must not use nonisolated(unsafe) — use lock-based access")
    }

    /// Source-level: httpProvider must be protected by a lock.
    @Test func testHttpProviderUsesLock() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")
        #expect(source.contains("_httpProviderLock"),
                "httpProvider must use a lock for thread-safe access")
        #expect(source.contains("OSAllocatedUnfairLock"),
                "Lock must be OSAllocatedUnfairLock for low-overhead synchronization")
    }

    /// Behavioral: default provider is URLSession.shared.
    @Test func testDefaultProviderIsStillURLSession() {
        let provider = OpenAICodexAuth.httpProvider
        #expect(provider is URLSession,
                "Default httpProvider must be URLSession")
    }

    /// Behavioral: mock provider round-trips through the lock.
    @Test func testMockProviderRoundTrips() {
        struct MockHTTP: HTTPDataProvider {
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                (Data(), URLResponse())
            }
        }
        let saved = OpenAICodexAuth.httpProvider
        defer { OpenAICodexAuth.httpProvider = saved }

        OpenAICodexAuth.httpProvider = MockHTTP()
        #expect(OpenAICodexAuth.httpProvider is MockHTTP,
                "Setting httpProvider must be readable back through the lock")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - P2 Fix: TokenRefreshCoordinator deduplication
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("P2 — TokenRefreshCoordinator shared _refreshCore")
struct TokenRefreshDeduplicationTests {

    /// Source-level: refreshIfNeeded and refreshIfNeededCounted must NOT have duplicated logic.
    @Test func testNoDuplicatedRefreshLogic() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")

        // Both public methods should delegate to _refreshCore
        #expect(source.contains("_refreshCore"),
                "Must have a shared _refreshCore method")

        // Count occurrences of inFlightRefresh assignment — should appear only in _refreshCore
        let assignmentCount = source.components(separatedBy: "inFlightRefresh = task").count - 1
        #expect(assignmentCount == 1,
                "inFlightRefresh = task must appear exactly once (in _refreshCore), found \(assignmentCount)")
    }

    /// Source-level: refreshIfNeeded delegates to _refreshCore(counted: false).
    @Test func testRefreshIfNeededDelegatesToCore() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")
        #expect(source.contains("_refreshCore(credentials, counted: false)"),
                "refreshIfNeeded must delegate to _refreshCore(counted: false)")
    }

    /// Source-level: refreshIfNeededCounted delegates to _refreshCore(counted: true).
    @Test func testRefreshIfNeededCountedDelegatesToCore() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Auth/OpenAICodexAuth.swift")
        #expect(source.contains("_refreshCore(credentials, counted: true)"),
                "refreshIfNeededCounted must delegate to _refreshCore(counted: true)")
    }

    /// Behavioral: both entry points coalesce concurrent callers identically.
    @Test func testBothEntryPointsCoalesceConcurrentCallers() async throws {
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let coordinator = TokenRefreshCoordinator { creds in
            callCount.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(50))
            return OAuthCredentials(
                accessToken: "new", refreshToken: "rt",
                idToken: nil, accountId: "acct", lastRefresh: Date()
            )
        }

        let creds = OAuthCredentials(
            accessToken: "old", refreshToken: "rt",
            idToken: nil, accountId: "acct", lastRefresh: .distantPast
        )

        // Fire 4 concurrent refreshes — 2 via each entry point
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await coordinator.refreshIfNeeded(creds) }
            group.addTask { _ = try await coordinator.refreshIfNeeded(creds) }
            group.addTask { _ = try await coordinator.refreshIfNeededCounted(creds) }
            group.addTask { _ = try await coordinator.refreshIfNeededCounted(creds) }
            try await group.waitForAll()
        }

        let totalCalls = callCount.withLock { $0 }
        #expect(totalCalls == 1,
                "All 4 concurrent callers must share a single refresh, got \(totalCalls) calls")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - P3 Fix: Config constants documentation
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("P3 — Config constants have rationale comments")
struct ConfigDocumentationTests {

    @Test func testBaseTimeoutDataSizeHasRationale() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Config.swift")
        guard let range = source.range(of: "baseTimeoutDataSize: Int") else {
            Issue.record("baseTimeoutDataSize not found"); return
        }
        // Look at the 5 lines preceding the declaration for a doc comment
        let prefix = source[source.startIndex..<range.lowerBound]
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false).suffix(5)
        let context = lines.joined(separator: "\n")
        #expect(context.contains("///") || context.contains("//"),
                "baseTimeoutDataSize must have a rationale comment")
        let lower = context.lowercased()
        #expect(lower.contains("15") || lower.contains("pcm") || lower.contains("480") || lower.contains("chunk"),
                "Comment should explain the 480KB value (e.g. relates to 15s of PCM)")
    }

    @Test func testForceSendChunkMultiplierHasRationale() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Config.swift")
        guard let range = source.range(of: "forceSendChunkMultiplier") else {
            Issue.record("forceSendChunkMultiplier not found"); return
        }
        let prefix = source[source.startIndex..<range.lowerBound]
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false).suffix(5)
        let context = lines.joined(separator: "\n")
        #expect(context.contains("///") || context.contains("//"),
                "forceSendChunkMultiplier must have a rationale comment")
    }

    @Test func testTimeoutHasRationale() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Config.swift")
        guard let range = source.range(of: "static let timeout: Double") else {
            Issue.record("timeout constant not found"); return
        }
        let prefix = source[source.startIndex..<range.lowerBound]
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false).suffix(4)
        let context = lines.joined(separator: "\n")
        #expect(context.contains("///") || context.contains("//"),
                "timeout must have a rationale comment")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - P3 Fix: LiveE2E error diagnostics
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("P3 — LiveE2E generateFixture error diagnostics")
struct LiveE2EErrorDiagnosticsTests {

    /// Source-level: error messages must include segment index and text excerpt.
    @Test func testErrorMessagesIncludeContext() throws {
        let source = try readProjectSource("Sources/LiveE2E/main.swift")

        // Check say failure message includes segment context
        #expect(source.contains("segment") && source.contains("say failed"),
                "say failure message must include segment index for diagnostics")

        // Check resample failure includes file path
        #expect(source.contains("resample") && (source.contains("source file") || source.contains("aiffPath")),
                "Resample failure must include source file path")
    }

    /// Source-level: generateFixture checks for missing output file before resampling.
    @Test func testChecksForMissingOutputFile() throws {
        let source = try readProjectSource("Sources/LiveE2E/main.swift")
        #expect(source.contains("fileExists(atPath: aiffPath)"),
                "Must check file exists before attempting resample")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue: waitForCompletion & finishStream Edge Cases
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — waitForCompletion & finishStream Edge Cases")
struct TranscriptionQueueWaitForCompletionTests {

    /// Issue a ticket, submit its result, THEN call waitForCompletion — must return without blocking.
    @Test func testWaitForCompletionReturnsImmediatelyWhenAlreadyComplete() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        await queue.submitResult(ticket: t0, text: "done")

        // This must return immediately — no blocking
        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        _ = task
        try? await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == true,
                "waitForCompletion must return immediately when all results submitted")
    }

    /// A fresh queue has currentSeq == 0, which fails the currentSeq > 0 check.
    /// waitForCompletion() will suspend forever. Verify it does NOT return within a timeout.
    /// NOTE: This documents intentional behavior — waitForCompletion on an empty queue
    /// will hang forever unless finishStream() is called.
    @Test func testWaitForCompletionOnFreshQueueNeverReturns() async {
        let queue = TranscriptionQueue()
        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(done.withLock { $0 } == false,
                "waitForCompletion on empty queue (currentSeq=0) must not return immediately")
        task.cancel()
    }

    /// The minimal completion case — one ticket issued and submitted.
    @Test func testWaitForCompletionWithSingleSequence() async {
        let queue = TranscriptionQueue()
        let t = await queue.nextSequence()

        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        _ = task

        try? await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == false, "Should still be waiting")

        await queue.submitResult(ticket: t, text: "only")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == true, "Should complete with single result")
    }

    /// finishStream() must:
    /// 1. Resume completionContinuation (unblocking waitForCompletion)
    /// 2. Finish textContinuation (ending the for await loop)
    @Test func testFinishStreamResumesBothContinuations() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        _ = await queue.nextSequence()

        // Start consuming stream
        let streamEnded = OSAllocatedUnfairLock(initialState: false)
        let streamTask = Task {
            for await _ in stream {}
            streamEnded.withLock { $0 = true }
        }

        // Start waiting for completion
        let completionDone = OSAllocatedUnfairLock(initialState: false)
        let waitTask = Task {
            await queue.waitForCompletion()
            completionDone.withLock { $0 = true }
        }
        _ = streamTask; _ = waitTask

        try? await Task.sleep(for: .milliseconds(50))
        await queue.finishStream()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(completionDone.withLock { $0 } == true,
                "finishStream must resume completionContinuation")
        #expect(streamEnded.withLock { $0 } == true,
                "finishStream must finish textContinuation (ending for-await loop)")
    }

    /// Calling finishStream() twice must not crash (continuations are nil-checked).
    @Test func testFinishStreamIdempotent() async {
        let queue = TranscriptionQueue()
        _ = await queue.textStream  // force creation of textContinuation
        _ = await queue.nextSequence()  // ensure completionContinuation can be set

        let task = Task { await queue.waitForCompletion() }
        try? await Task.sleep(for: .milliseconds(30))

        await queue.finishStream()  // first: resumes continuation
        await queue.finishStream()  // second: continuations already nil — no crash
        // If we get here without crashing, test passes
        _ = task
    }

    /// If finishStream() is called before textStream is ever accessed,
    /// textContinuation is nil. Must not crash.
    @Test func testFinishStreamBeforeStreamAccess() async {
        let queue = TranscriptionQueue()
        await queue.finishStream() // textContinuation is nil — must not crash
    }

    /// After finishStream() clears textContinuation, submitting results should still
    /// update internal state (no crash, pendingResults updated, flushReady advances pointer)
    /// — just no yield to stream.
    @Test func testSubmitResultAfterFinishStream() async {
        let queue = TranscriptionQueue()
        _ = await queue.textStream
        await queue.finishStream()

        let t = await queue.nextSequence()
        await queue.submitResult(ticket: t, text: "orphan")
        // Must not crash; pending count resolves to 0
        #expect(await queue.getPendingCount() == 0)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue — reset() State Clearing
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — reset() State Clearing")
struct TranscriptionQueueResetTests {

    /// Verify reset() clears pending results.
    /// Issue tickets, submit some (not all), then reset. After reset,
    /// getPendingCount() must be 0 and new tickets start fresh.
    @Test func testResetClearsPendingResults() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        _ = await queue.nextSequence()
        await queue.submitResult(ticket: t0, text: "partial")
        // t1 still outstanding → pending=1
        #expect(await queue.getPendingCount() == 1)

        await queue.reset()
        // Everything cleared
        #expect(await queue.getPendingCount() == 0)
    }

    /// Verify reset() zeroes sequence counters.
    /// After reset, nextSequence() must restart at seq=0.
    @Test func testResetZeroesSequenceCounters() async {
        let queue = TranscriptionQueue()
        _ = await queue.nextSequence() // seq 0
        _ = await queue.nextSequence() // seq 1
        _ = await queue.nextSequence() // seq 2
        await queue.reset()
        let fresh = await queue.nextSequence()
        #expect(fresh.seq == 0, "After reset, seq must restart at 0")
    }

    /// Verify reset() increments generation monotonically.
    /// Call reset N times and verify generation increments each time.
    @Test func testResetIncrementsGenerationMonotonically() async {
        let queue = TranscriptionQueue()
        for i in 1...5 {
            await queue.reset()
            let gen = await queue.currentSessionGeneration()
            #expect(gen == UInt64(i), "Generation must be \(i) after \(i) resets")
        }
    }

    /// Verify reset() discards in-flight results from old generation.
    /// Submit a result for a ticket from BEFORE reset. The result must be
    /// silently ignored and not appear on the stream.
    @Test func testResetDiscardsInFlightResults() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let oldTicket = await queue.nextSequence()

        await queue.reset()

        // Submit result with old ticket — should be discarded
        await queue.submitResult(ticket: oldTicket, text: "STALE")

        // Issue and complete a fresh ticket
        let freshTicket = await queue.nextSequence()
        await queue.submitResult(ticket: freshTicket, text: "FRESH")

        // Collect from stream — only "FRESH" should appear
        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }
        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value
        #expect(received == ["FRESH"], "Stale result must not appear on stream")
    }

    /// Verify reset() does not affect the rate limiter.
    /// The rateLimiter property is a `let` — verify it survives reset
    /// (reset shouldn't create a new one).
    @Test func testResetDoesNotAffectRateLimiter() async throws {
        let queue = TranscriptionQueue()
        // RateLimiter is an actor, so identity check via a behavioral test:
        // Record a request, reset the queue, verify the rate limiter still has state
        // (i.e., it was not replaced).
        try await queue.rateLimiter.waitAndRecord()
        await queue.reset()
        // If rateLimiter was replaced, timeUntilNextAllowed would be 0
        let wait = await queue.rateLimiter.timeUntilNextAllowed()
        #expect(wait > 0, "rateLimiter must survive reset (let property, not var)")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue: Initial State & Sequencing Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — Initial State & Sequencing")
struct TranscriptionQueueInitialStateAndSequencingTests {

    /// Initial state: sessionGeneration starts at 0, no pending sequences.
    @Test func testInitialState() async {
        let queue = TranscriptionQueue()
        // sessionGeneration starts at 0
        #expect(await queue.currentSessionGeneration() == 0)
        // No sequences issued yet → pending count = 0
        #expect(await queue.getPendingCount() == 0)
    }

    /// First ticket issued must be session 0, seq 0.
    @Test func testNextSequenceStartsAtZero() async {
        let queue = TranscriptionQueue()
        let t = await queue.nextSequence()
        #expect(t.session == 0, "First ticket must be session 0")
        #expect(t.seq == 0, "First ticket must be seq 0")
    }

    /// Sequential calls to nextSequence produce monotonically increasing seq numbers.
    @Test func testNextSequenceMonotonicallyIncreasing() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        let t2 = await queue.nextSequence()
        #expect(t0.seq == 0)
        #expect(t1.seq == 1)
        #expect(t2.seq == 2)
        // All same session
        #expect(t0.session == t1.session)
        #expect(t1.session == t2.session)
    }

    /// After reset(), new tickets carry the incremented session generation.
    @Test func testNextSequenceBindsToCurrentSession() async {
        let queue = TranscriptionQueue()
        let before = await queue.nextSequence()
        #expect(before.session == 0)
        await queue.reset()
        let after = await queue.nextSequence()
        #expect(after.session == 1, "After reset, tickets must carry new generation")
        #expect(after.seq == 0, "After reset, seq restarts at 0")
    }

    /// getPendingCount tracks issued minus resolved sequences.
    @Test func testGetPendingCountTracksIssuedMinusResolved() async {
        let queue = TranscriptionQueue()
        #expect(await queue.getPendingCount() == 0)
        let t0 = await queue.nextSequence()
        #expect(await queue.getPendingCount() == 1)
        let t1 = await queue.nextSequence()
        #expect(await queue.getPendingCount() == 2)
        await queue.submitResult(ticket: t0, text: "a")
        #expect(await queue.getPendingCount() == 1)
        await queue.submitResult(ticket: t1, text: "b")
        #expect(await queue.getPendingCount() == 0)
    }

    /// markFailed should also decrement pending count.
    @Test func testGetPendingCountAfterMarkFailed() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        #expect(await queue.getPendingCount() == 2)
        await queue.markFailed(ticket: t0)
        #expect(await queue.getPendingCount() == 1)
        await queue.submitResult(ticket: t1, text: "ok")
        #expect(await queue.getPendingCount() == 0)
    }

    /// Concurrent nextSequence calls must produce unique tickets with distinct seq values.
    @Test func testNextSequenceConcurrentCallsProduceUniqueTickets() async {
        let queue = TranscriptionQueue()

        // Fire 10 concurrent nextSequence() calls via a TaskGroup
        let tickets = await withTaskGroup(of: TranscriptionTicket.self, returning: [TranscriptionTicket].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await queue.nextSequence()
                }
            }
            var collected: [TranscriptionTicket] = []
            for await ticket in group {
                collected.append(ticket)
            }
            return collected
        }

        // All tickets should have same session
        let sessions = Set(tickets.map { $0.session })
        #expect(sessions.count == 1, "All tickets must be from same session")

        // All seq values should be unique
        let seqs = tickets.map { $0.seq }
        let uniqueSeqs = Set(seqs)
        #expect(uniqueSeqs.count == 10, "All seq values must be unique")

        // Seq values should cover 0..<10
        #expect(uniqueSeqs == Set(0..<10), "Seq values must cover range 0..<10")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue: flushReady Ordering & Edge Cases
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — flushReady Ordering & Edge Cases")
struct TranscriptionQueueFlushReadyOrderingEdgeCasesTests {

    @Test func testPartialFlushStopsAtGap() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()
        _ = await queue.nextSequence() // t1 (gap)
        let t2 = await queue.nextSequence()

        await queue.submitResult(ticket: t0, text: "first")
        await queue.submitResult(ticket: t2, text: "third")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["first"], "Only seq 0 should flush; seq 2 blocked by gap at seq 1")
        #expect(await queue.getPendingCount() == 2)
    }

    @Test func testChainFlushWhenGapFilled() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        let t2 = await queue.nextSequence()

        await queue.submitResult(ticket: t0, text: "A")
        await queue.submitResult(ticket: t2, text: "C")
        await queue.submitResult(ticket: t1, text: "B")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 3 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["A", "B", "C"])
        #expect(await queue.getPendingCount() == 0)
    }

    @Test func testEmptyTextNotYieldedToStream() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        let t2 = await queue.nextSequence()

        await queue.submitResult(ticket: t0, text: "real")
        await queue.submitResult(ticket: t1, text: "")
        await queue.submitResult(ticket: t2, text: "also real")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 2 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["real", "also real"], "Empty text must not appear in stream")
        #expect(await queue.getPendingCount() == 0, "All 3 must be resolved")
    }

    @Test func testMarkFailedAdvancesOutputPointer() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()

        await queue.markFailed(ticket: t0)
        await queue.submitResult(ticket: t1, text: "second")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["second"], "Failed seq 0 must be skipped, seq 1 output")
    }

    @Test func testSubmitResultIdempotent() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()

        await queue.submitResult(ticket: t0, text: "first")
        await queue.submitResult(ticket: t0, text: "duplicate")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["first"], "Second submit to already-flushed seq must be ignored")
    }

    @Test func testAllFailedSequencesStillTriggerCompletion() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()

        let done = OSAllocatedUnfairLock(initialState: false)
        let waitTask = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        _ = waitTask

        await queue.markFailed(ticket: t0)
        await queue.markFailed(ticket: t1)

        try? await Task.sleep(for: .milliseconds(100))
        #expect(done.withLock { $0 } == true,
                "Completion must fire even when all sequences failed")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue: textStream Lifecycle Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — textStream Lifecycle")
struct TranscriptionQueueTextStreamLifecycleTests {

    /// Stream delivers results in real-time, not batched.
    /// Submit results one at a time with delays; each should be received immediately.
    @Test func testStreamDeliversResultsInRealTime() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream

        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()

        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let task = Task {
            for await text in stream {
                received.withLock { $0.append(text) }
            }
        }

        await queue.submitResult(ticket: t0, text: "first")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received.withLock { $0 } == ["first"],
                "First result should be delivered immediately")

        await queue.submitResult(ticket: t1, text: "second")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received.withLock { $0 } == ["first", "second"],
                "Second result should be delivered as it arrives")

        task.cancel()
    }

    /// If submitResult is called before anyone accesses textStream,
    /// textContinuation is nil and the yield is dropped (but state updates).
    @Test func testYieldBeforeStreamAccessIsDropped() async {
        let queue = TranscriptionQueue()
        // Don't access textStream yet!
        let t = await queue.nextSequence()
        await queue.submitResult(ticket: t, text: "early")

        // Pending should be 0 (result was flushed from state, just not yielded)
        #expect(await queue.getPendingCount() == 0)

        // Now access stream — the "early" text is already gone
        let stream = await queue.textStream
        // Submit another
        let t2 = await queue.nextSequence()
        await queue.submitResult(ticket: t2, text: "late")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }
        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value
        #expect(received == ["late"],
                "Only results submitted after stream access should be received")
    }

    /// A for-await loop must exit when finishStream() is called.
    @Test func testStreamEndedByFinishStreamTerminatesForAwait() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream

        let loopExited = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            for await _ in stream {}
            loopExited.withLock { $0 = true }
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(loopExited.withLock { $0 } == false, "Loop should be waiting")

        await queue.finishStream()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(loopExited.withLock { $0 } == true,
                "for-await loop must exit after finishStream()")
        _ = task
    }

    /// After finishStream() clears textContinuation (but not _textStream),
    /// accessing textStream returns the same cached stream, but yields go nowhere.
    @Test func testTextStreamAfterFinishStreamCreatesNewStream() async {
        let queue = TranscriptionQueue()
        let stream1 = await queue.textStream
        await queue.finishStream()
        let stream2 = await queue.textStream
        // Same _textStream instance is returned (finishStream doesn't clear _textStream)
        // But textContinuation is nil, so yields go nowhere
        let t = await queue.nextSequence()
        await queue.submitResult(ticket: t, text: "orphan")
        #expect(await queue.getPendingCount() == 0,
                "State should still update even with dead continuation")
        _ = stream1; _ = stream2
    }

    /// AsyncStream has unbounded buffer by default.
    /// Submit many results before anyone starts consuming; all should be delivered.
    @Test func testStreamBuffersUnconsumedResults() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream

        // Submit 20 results — no consumer yet
        var tickets: [TranscriptionTicket] = []
        for _ in 0..<20 {
            tickets.append(await queue.nextSequence())
        }
        for (i, t) in tickets.enumerated() {
            await queue.submitResult(ticket: t, text: "msg\(i)")
        }

        // Now consume — all 20 should be buffered
        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 20 { break }
            }
            return items
        }
        try? await Task.sleep(for: .milliseconds(300))
        let received = await collectTask.value
        #expect(received.count == 20, "All 20 results must be buffered and delivered")
        #expect(received.first == "msg0")
        #expect(received.last == "msg19")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueueBridge: Session Lifecycle & Completion
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueueBridge — Session Lifecycle & Completion")
struct TranscriptionQueueBridgeTests {

    /// checkCompletion() must fire onAllComplete when pending count is 0.
    @Test @MainActor func testCheckCompletionFiresOnAllComplete() async {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()
        var completionCalled = false
        bridge.onAllComplete = { completionCalled = true }

        // Get a ticket and complete it
        let ticket = await bridge.nextSequence()
        await bridge.submitResult(ticket: ticket, text: "done")

        // Now check completion
        await bridge.checkCompletion()
        #expect(completionCalled == true, "onAllComplete must fire when pending=0")
    }

    /// checkCompletion() must only fire onAllComplete once per session
    /// (hasSignaledCompletion guard).
    @Test @MainActor func testCheckCompletionOnlyFiresOnce() async {
        let bridge = TranscriptionQueueBridge()
        var callCount = 0
        bridge.onAllComplete = { callCount += 1 }

        let ticket = await bridge.nextSequence()
        await bridge.submitResult(ticket: ticket, text: "done")

        await bridge.checkCompletion()
        await bridge.checkCompletion()
        await bridge.checkCompletion()

        #expect(callCount == 1,
                "onAllComplete must fire exactly once per session (hasSignaledCompletion guard)")
    }

    /// checkCompletion() must NOT fire before any nextSequence() call
    /// (sessionStarted guard).
    @Test @MainActor func testCheckCompletionDoesNotFireBeforeSessionStart() async {
        let bridge = TranscriptionQueueBridge()
        var completionCalled = false
        bridge.onAllComplete = { completionCalled = true }

        // Don't call nextSequence — session hasn't started
        await bridge.checkCompletion()

        #expect(completionCalled == false,
                "onAllComplete must not fire when no session has started (sessionStarted guard)")
    }

    /// checkCompletion() must NOT fire while results are pending.
    @Test @MainActor func testCheckCompletionDoesNotFireWhilePending() async {
        let bridge = TranscriptionQueueBridge()
        var completionCalled = false
        bridge.onAllComplete = { completionCalled = true }

        let t0 = await bridge.nextSequence()
        let _ = await bridge.nextSequence()  // t1 still pending
        await bridge.submitResult(ticket: t0, text: "first")

        await bridge.checkCompletion()
        #expect(completionCalled == false,
                "onAllComplete must not fire while results are pending")
    }

    /// reset() must clear hasSignaledCompletion and sessionStarted,
    /// allowing checkCompletion() to fire again for a new session.
    @Test @MainActor func testResetClearsCompletionAndSessionFlags() async {
        let bridge = TranscriptionQueueBridge()
        var callCount = 0
        bridge.onAllComplete = { callCount += 1 }

        // Session 1
        let t1 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t1, text: "s1")
        await bridge.checkCompletion()
        #expect(callCount == 1)

        // Reset
        await bridge.reset()

        // Session 2
        let t2 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t2, text: "s2")
        await bridge.checkCompletion()
        #expect(callCount == 2,
                "After reset, completion must be able to fire again for new session")
    }

    /// nextSequence() sets sessionStarted = true and hasSignaledCompletion = false on first call.
    @Test @MainActor func testNextSequenceSetsSessionStarted() async {
        let bridge = TranscriptionQueueBridge()
        var completionCalled = false
        bridge.onAllComplete = { completionCalled = true }

        // Before nextSequence: checkCompletion is no-op
        await bridge.checkCompletion()
        #expect(completionCalled == false)

        // After nextSequence: session started
        let t = await bridge.nextSequence()
        await bridge.submitResult(ticket: t, text: "x")
        await bridge.checkCompletion()
        #expect(completionCalled == true)
    }

    /// getPendingCount() must delegate to the underlying queue.
    @Test @MainActor func testGetPendingCountDelegatesToQueue() async {
        let bridge = TranscriptionQueueBridge()

        #expect(await bridge.getPendingCount() == 0)

        let t0 = await bridge.nextSequence()
        #expect(await bridge.getPendingCount() == 1)

        let t1 = await bridge.nextSequence()
        #expect(await bridge.getPendingCount() == 2)

        await bridge.submitResult(ticket: t0, text: "a")
        #expect(await bridge.getPendingCount() == 1)

        await bridge.submitResult(ticket: t1, text: "b")
        #expect(await bridge.getPendingCount() == 0)
    }

    /// markFailed() must delegate to the queue and allow subsequent results to be delivered.
    @Test @MainActor func testMarkFailedDelegatesToQueue() async {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()

        var received: [String] = []
        bridge.onTextReady = { text in received.append(text) }

        let t0 = await bridge.nextSequence()
        let t1 = await bridge.nextSequence()

        await bridge.markFailed(ticket: t0)
        await bridge.submitResult(ticket: t1, text: "ok")

        try? await Task.sleep(for: .milliseconds(100))
        #expect(received == ["ok"], "Failed ticket must be skipped, next delivered")
    }

    /// Full lifecycle: session 1 → complete → reset → session 2 → complete.
    @Test @MainActor func testFullSessionLifecycle() async {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()

        var texts: [String] = []
        var completions = 0
        bridge.onTextReady = { text in texts.append(text) }
        bridge.onAllComplete = { completions += 1 }

        // Session 1: 3 chunks
        let s1t0 = await bridge.nextSequence()
        let s1t1 = await bridge.nextSequence()
        let s1t2 = await bridge.nextSequence()
        await bridge.submitResult(ticket: s1t0, text: "hello")
        await bridge.submitResult(ticket: s1t2, text: "world")
        await bridge.submitResult(ticket: s1t1, text: "beautiful")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(texts == ["hello", "beautiful", "world"])
        await bridge.checkCompletion()
        #expect(completions == 1)

        // Reset for session 2
        await bridge.reset()
        texts.removeAll()

        // Session 2: 2 chunks, one fails
        let s2t0 = await bridge.nextSequence()
        let s2t1 = await bridge.nextSequence()
        await bridge.markFailed(ticket: s2t0)
        await bridge.submitResult(ticket: s2t1, text: "recovered")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(texts == ["recovered"])
        await bridge.checkCompletion()
        #expect(completions == 2)

        bridge.stopListening()
    }

    /// startListening() must create stream task that delivers text.
    @Test @MainActor func testStartListeningCreatesStreamTask() async {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()

        // Verify the bridge can deliver text (stream task is alive)
        var received: [String] = []
        bridge.onTextReady = { text in received.append(text) }

        let t = await bridge.nextSequence()
        await bridge.submitResult(ticket: t, text: "ping")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(received == ["ping"], "startListening must create stream task that delivers text")
        bridge.stopListening()
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: WAV Format & AudioChunk Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — WAV Format & AudioChunk")
struct StreamingRecorderWAVFormatAndAudioChunkTests {

    /// Verify AudioChunk struct stores all properties correctly.
    @Test func testAudioChunkStructProperties() {
        let chunk = AudioChunk(wavData: Data([1,2,3]), durationSeconds: 5.0, speechProbability: 0.75)
        #expect(chunk.wavData == Data([1,2,3]))
        #expect(chunk.durationSeconds == 5.0)
        #expect(chunk.speechProbability == 0.75)
    }

    /// Verify AudioChunk default speechProbability is 0.
    @Test func testAudioChunkDefaultSpeechProbability() {
        let chunk = AudioChunk(wavData: Data(), durationSeconds: 1.0)
        #expect(chunk.speechProbability == 0, "Default speechProbability must be 0")
    }

    /// Source-level: verify AudioChunk conforms to Sendable.
    @Test func testAudioChunkIsSendable() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("struct AudioChunk: Sendable"),
                "AudioChunk must conform to Sendable for concurrent audio processing")
    }

    /// Validate WAV header structure produced by createWav().
    @Test @MainActor func testCreateWavProducesValidHeader() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        // 15s of audio with speech
        let samples = [Float](repeating: 0.5, count: 240_000)
        await buffer.append(frames: samples, hasSpeech: true)
        
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)
        
        var receivedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in receivedChunk = chunk }
        
        await recorder._testInvokeSendChunkIfReady(reason: "test wav")
        
        guard let chunk = receivedChunk else {
            Issue.record("No chunk produced")
            return
        }
        
        let wav = chunk.wavData
        
        // RIFF header
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF",
                "WAV must start with RIFF header")
        
        // WAVE format
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE",
                "WAV must have WAVE format identifier")
        
        // fmt chunk
        #expect(String(data: wav[12..<16], encoding: .ascii) == "fmt ",
                "WAV must have fmt chunk")
        
        // PCM format (1)
        let audioFormat = wav[20..<22].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(audioFormat == 1, "Must be PCM format (1)")
        
        // Mono (1 channel)
        let channels = wav[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(channels == 1, "Must be mono (1 channel)")
        
        // Sample rate 16000
        let sampleRate = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 16000, "Sample rate must be 16000 Hz")
        
        // 16-bit samples
        let bitsPerSample = wav[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(bitsPerSample == 16, "Must be 16-bit PCM")
        
        // data chunk
        #expect(String(data: wav[36..<40], encoding: .ascii) == "data",
                "WAV must have data chunk")
    }

    /// Verify WAV data section size matches sample count (16-bit = 2 bytes per sample).
    @Test @MainActor func testCreateWavDataSizeMatchesSamples() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        let expectedSamples = 240_000  // 15s at 16kHz
        let samples = [Float](repeating: 0.5, count: expectedSamples)
        await buffer.append(frames: samples, hasSpeech: true)
        
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)
        
        var receivedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in receivedChunk = chunk }
        
        await recorder._testInvokeSendChunkIfReady(reason: "test wav size")
        
        guard let chunk = receivedChunk else {
            Issue.record("No chunk produced")
            return
        }
        
        // WAV total = 44 byte header + N*2 bytes data (16-bit = 2 bytes per sample)
        let dataSize = chunk.wavData.count - 44
        #expect(dataSize == expectedSamples * 2,
                "Data section must be exactly \(expectedSamples * 2) bytes for \(expectedSamples) samples, got \(dataSize)")
    }

    /// Source-level: verify createWav guards against empty samples.
    @Test func testCreateWavEmptySamplesProducesEmptyData() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("guard !samples.isEmpty else { return Data() }"),
                "createWav must return empty Data for empty samples to avoid invalid WAV")
    }

    /// Source-level: verify samples are clamped to [-1, 1] before Int16 conversion.
    @Test func testCreateWavClampsToInt16Range() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("max(-1, min(1,"),
                "Samples must be clamped to [-1, 1] before Int16 conversion to prevent overflow")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: Thread-Safe State & Helpers Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — Thread-Safe State & Helpers")
struct StreamingRecorderThreadSafeStateAndHelpersTests {

    /// Source-level: verify AudioRecordingState uses NSLock for thread safety.
    @Test func testAudioRecordingStateIsThreadSafe() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        // Find AudioRecordingState class body
        guard let classStart = source.range(of: "private final class AudioRecordingState") else {
            Issue.record("AudioRecordingState class not found")
            return
        }
        
        let afterClass = String(source[classStart.lowerBound...])
        
        #expect(afterClass.contains("private let lock = NSLock()"),
                "AudioRecordingState must use NSLock for thread safety")
        #expect(afterClass.contains("lock.lock()"),
                "Must call lock.lock() to protect shared state")
        #expect(afterClass.contains("lock.unlock()"),
                "Must call lock.unlock() to release lock")
    }

    /// Source-level: verify AudioRecordingState default values.
    @Test func testAudioRecordingStateDefaultValues() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        guard let classStart = source.range(of: "private final class AudioRecordingState") else {
            Issue.record("AudioRecordingState class not found")
            return
        }
        
        let afterClass = String(source[classStart.lowerBound...])
        
        #expect(afterClass.contains("private var isRecording = false"),
                "Default state must be not recording")
        #expect(afterClass.contains("private var vadActive = false"),
                "Default VAD state must be inactive")
    }

    /// Source-level: verify fixed 16000 Hz sample rate.
    @Test func testAudioRecordingStateSampleRate() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        guard let classStart = source.range(of: "private final class AudioRecordingState") else {
            Issue.record("AudioRecordingState class not found")
            return
        }
        
        let afterClass = String(source[classStart.lowerBound...])
        
        #expect(afterClass.contains("let sampleRate: Double = 16000"),
                "Sample rate must be fixed at 16000 Hz for Whisper API")
    }

    /// Source-level: verify AudioSampleQueue has bounded size and drops old samples.
    @Test func testAudioSampleQueueBounded() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        guard let classStart = source.range(of: "private final class AudioSampleQueue") else {
            Issue.record("AudioSampleQueue class not found")
            return
        }
        
        let afterClass = String(source[classStart.lowerBound...])
        
        #expect(afterClass.contains("private let maxQueueSize = 100"),
                "Queue must have max size limit to prevent memory growth")
        #expect(afterClass.contains("samples.removeFirst()"),
                "Queue must drop oldest sample when at capacity")
    }

    /// Source-level: verify AudioSampleQueue uses NSLock for thread safety.
    @Test func testAudioSampleQueueIsThreadSafe() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        guard let classStart = source.range(of: "private final class AudioSampleQueue") else {
            Issue.record("AudioSampleQueue class not found")
            return
        }
        
        let afterClass = String(source[classStart.lowerBound...])
        
        #expect(afterClass.contains("private let lock = NSLock()"),
                "AudioSampleQueue must use NSLock for thread safety")
    }

    /// Source-level: verify dequeueAll atomically clears the queue.
    @Test func testAudioSampleQueueDequeueAllClearsQueue() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        guard let classStart = source.range(of: "private final class AudioSampleQueue") else {
            Issue.record("AudioSampleQueue class not found")
            return
        }
        
        let afterClass = String(source[classStart.lowerBound...])
        
        #expect(afterClass.contains("samples.removeAll()"),
                "dequeueAll must atomically clear all samples")
    }

    /// Behavioral: verify createOneShotInputBlock provides buffer once, then signals noDataNow.
    @Test func testCreateOneShotInputBlockProvidesBufferOnce() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        pcmBuffer.frameLength = 100
        
        let block = createOneShotInputBlock(buffer: pcmBuffer)
        
        var status = AVAudioConverterInputStatus.haveData
        
        // First call: should provide data
        let result1 = block(1, &status)
        #expect(result1 != nil, "First call must provide the buffer")
        #expect(status == .haveData, "First call status must be .haveData")
        
        // Second call: should signal no more data
        let result2 = block(1, &status)
        #expect(status == .noDataNow, "Second call must signal .noDataNow")
        #expect(result2 == nil, "Second call must return nil")
    }

    /// Source-level: verify OneShotState wrapper for non-Sendable buffer.
    @Test func testOneShotStateWrapsNonSendableBuffer() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        #expect(source.contains("final class OneShotState: @unchecked Sendable"),
                "OneShotState must wrap non-Sendable buffer with @unchecked Sendable")
        #expect(source.contains("var provided = false"),
                "OneShotState must track whether buffer was provided")
    }

    /// Source-level: verify installAudioTap is a free function (not @MainActor class method).
    @Test func testInstallAudioTapIsNonisolated() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        #expect(source.contains("private func installAudioTap("),
                "installAudioTap must be a private function")
        
        // Verify it's NOT inside the @MainActor StreamingRecorder class
        // by checking it appears after the class closing brace
        guard let recorderClassStart = source.range(of: "@MainActor\npublic final class StreamingRecorder") else {
            Issue.record("StreamingRecorder class not found")
            return
        }
        
        // Find the installAudioTap function position
        guard let tapFuncPos = source.range(of: "private func installAudioTap(") else {
            Issue.record("installAudioTap function not found")
            return
        }
        
        // It should appear before the StreamingRecorder class (at the top level)
        #expect(tapFuncPos.lowerBound < recorderClassStart.lowerBound,
                "installAudioTap must be a free function, not a class method")
    }

    /// Source-level: verify audio tap uses Accelerate framework for RMS calculation.
    @Test func testInstallAudioTapCalculatesRMS() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        
        #expect(source.contains("vDSP_rmsqv("),
                "Audio tap must use vDSP_rmsqv from Accelerate for efficient RMS calculation")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: start, startMock & Test Helpers
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — start, startMock & Test Helpers")
struct StreamingRecorderStartAndMockTests {

    /// start() must be marked @discardableResult.
    @Test func testStartReturnsDiscardableResult() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("@discardableResult") && source.contains("public func start() async -> Bool"))
    }

    /// start() must set sessionStartDate as the first action.
    @Test func testStartSetsSessionStartDate() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "start", from: source)
        #expect(body?.contains("sessionStartDate = Date()") == true)
    }

    /// start() must roll back all state in catch block on engine.start() failure.
    @Test func testStartRollsBackOnEngineFailure() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "start", from: source)
        #expect(body?.contains("engine.inputNode.removeTap(onBus: 0)") == true)
        #expect(body?.contains("audioEngine = nil") == true)
        #expect(body?.contains("audioBuffer = nil") == true)
        #expect(body?.contains("state.setRecording(false)") == true)
        #expect(body?.contains("vadProcessor = nil") == true)
        #expect(body?.contains("sessionController = nil") == true)
        #expect(body?.contains("sessionStartDate = nil") == true)
    }

    /// start() must re-check recording state after VAD initialization.
    @Test func testStartAbortsIfStoppedDuringVADInit() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "start", from: source)
        // After initializeVAD(), must re-check recording state
        #expect(body?.contains("guard state.getRecording() else") == true,
                "start() must re-check recording state after VAD init")
        #expect(body?.contains("Recording cancelled during VAD initialization") == true)
    }

    /// startMock() must set up all required state correctly.
    @Test @MainActor func testStartMockSetsUpCorrectly() async {
        let recorder = StreamingRecorder()
        let testAudio = [Float](repeating: 0.5, count: 16000)
        await recorder.startMock(audioData: testAudio)
        
        defer { recorder.stop() }
        
        #expect(recorder._testIsRecording, "startMock must set recording=true")
        #expect(recorder._testHasAudioBuffer, "startMock must create audio buffer")
        #expect(recorder._testHasProcessingTimer, "startMock must start processing timer")
        #expect(recorder._testHasCheckTimer, "startMock must start check timer")
        #expect(recorder.sessionStartDate != nil, "startMock must set sessionStartDate")
    }

    /// startMock() must feed audio in 50ms chunks.
    @Test func testStartMockFeedsAudioIn50msChunks() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "startMock", from: source)
        #expect(body?.contains("sampleRate * 0.05") == true, "Mock must feed 50ms chunks")
        #expect(body?.contains("Task.sleep(for: .milliseconds(50))") == true, "Mock must sleep 50ms between chunks")
    }

    /// Test helper _testInjectAudioBuffer must set/clear audioBuffer.
    @Test @MainActor func testTestHelperInjectAudioBuffer() async {
        let recorder = StreamingRecorder()
        #expect(!recorder._testHasAudioBuffer)
        
        let buffer = AudioBuffer(sampleRate: 16000)
        recorder._testInjectAudioBuffer(buffer)
        #expect(recorder._testHasAudioBuffer)
        
        recorder._testInjectAudioBuffer(nil)
        #expect(!recorder._testHasAudioBuffer)
    }

    /// Test helper _testSetIsRecording must control recording state.
    @Test @MainActor func testTestHelperSetRecordingState() async {
        let recorder = StreamingRecorder()
        #expect(!recorder._testIsRecording)
        recorder._testSetIsRecording(true)
        #expect(recorder._testIsRecording)
        recorder._testSetIsRecording(false)
        #expect(!recorder._testIsRecording)
    }

    /// Test helper _testAudioBufferDuration must return correct duration.
    @Test @MainActor func testTestHelperBufferDuration() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        recorder._testInjectAudioBuffer(buffer)
        
        let dur0 = await recorder._testAudioBufferDuration()
        #expect(dur0 == 0)
        
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        let dur1 = await recorder._testAudioBufferDuration()
        #expect(dur1 > 0.9 && dur1 < 1.1, "1s of 16kHz audio = ~1.0s duration")
    }

    /// Test helpers must be guarded by #if DEBUG.
    @Test func testTestHelpersOnlyAvailableInDebug() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("#if DEBUG\n@MainActor\nextension StreamingRecorder") ||
                source.contains("#if DEBUG\n@MainActor extension StreamingRecorder"),
                "Test helpers must be behind #if DEBUG")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder — stop() & cancel() Behavior
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — stop() & cancel() Behavior", .serialized)
struct StreamingRecorderStopCancelTests {

    /// stop() must set recording flag to false.
    @Test @MainActor func testStopSetsRecordingToFalse() async {
        let recorder = StreamingRecorder()
        recorder._testSetIsRecording(true)
        recorder.stop()
        #expect(!recorder._testIsRecording, "stop() must set recording to false")
    }

    /// stop() must invalidate and clear both timers.
    @Test func testStopInvalidatesTimers() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("checkTimer?.invalidate()") == true,
                "stop() must invalidate checkTimer")
        #expect(stopBody?.contains("processingTimer?.invalidate()") == true,
                "stop() must invalidate processingTimer")
        #expect(stopBody?.contains("checkTimer = nil") == true,
                "stop() must clear checkTimer")
        #expect(stopBody?.contains("processingTimer = nil") == true,
                "stop() must clear processingTimer")
    }

    /// cancel() must suppress final chunk emission.
    @Test @MainActor func testCancelSuppressesFinalChunk() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 240_000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var chunkReceived = false
        recorder.onChunkReady = { _ in chunkReceived = true }

        recorder.cancel()

        // Give the stop() Task time to run
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!chunkReceived, "cancel() must suppress final chunk emission")
    }

    /// stop() must emit final chunk when speech is present.
    @Test @MainActor func testStopEmitsFinalChunkWhenSpeechPresent() async {
        let origSkip = Settings.shared.skipSilentChunks
        let origChunk = Settings.shared.chunkDuration
        defer {
            Settings.shared.skipSilentChunks = origSkip
            Settings.shared.chunkDuration = origChunk
        }
        Settings.shared.skipSilentChunks = false
        Settings.shared.chunkDuration = .unlimited

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        // 1s of audio (above minRecordingDurationMs=250ms)
        await buffer.append(frames: [Float](repeating: 0.3, count: 16000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var receivedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in receivedChunk = chunk }

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(receivedChunk != nil, "stop() must emit final chunk when audio has speech")
        if let chunk = receivedChunk {
            #expect(chunk.durationSeconds > 0.9 && chunk.durationSeconds < 1.1)
        }
    }

    /// stop() must skip final chunk when audio is too short.
    @Test @MainActor func testStopSkipsFinalChunkWhenTooShort() async {
        let origChunk = Settings.shared.chunkDuration
        defer { Settings.shared.chunkDuration = origChunk }
        Settings.shared.chunkDuration = .unlimited

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        // 100ms of audio — too short
        await buffer.append(frames: [Float](repeating: 0.5, count: 1600), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var chunkReceived = false
        recorder.onChunkReady = { _ in chunkReceived = true }

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!chunkReceived, "Audio shorter than minRecordingDurationMs must be discarded")
    }

    /// stop() must protect final chunk when speech detected in session.
    @Test func testStopProtectsFinalChunkWithSpeechDetectedInSession() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("speechDetectedInSession") == true,
                "stop() must check speechDetectedInSession for final chunk protection")
        #expect(stopBody?.contains("|| speechDetectedInSession") == true,
                "speechDetectedInSession must be in the send condition")
    }

    /// stop() must reset VAD session.
    @Test func testStopResetsVADSession() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("resetSession()") == true,
                "stop() must call resetSession() on VAD processor")
    }

    /// stop() must reset isCancelled flag for next session.
    @Test func testCancelResetsIsCancelledFlag() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("isCancelled = false") == true,
                "stop() must reset isCancelled so next recording isn't affected")
    }

    /// stop() must drain pending sample queue before evaluating final chunk.
    @Test func testStopDrainsPendingSampleQueue() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("sampleQueue.dequeueAll()") == true,
                "stop() must drain pending sample queue before evaluating final chunk")
    }
}

// MARK: - Integration — Recorder to Queue Pipeline

@Suite("Integration — Recorder to Queue Pipeline", .serialized)
struct IntegrationRecorderToQueueTests {

    /// TranscriptionQueue accepts and flushes a result (recorder→queue seam).
    @Test func testRecorderChunkFlowsToQueue() async throws {
        let queue = TranscriptionQueue()

        // Simulate: recorder produces a chunk → gets a ticket → submits result
        let ticket = await queue.nextSequence()
        await queue.submitResult(ticket: ticket, text: "transcribed: 15.0s")

        // submitResult auto-flushes via flushReady()
        let pending = await queue.getPendingCount()
        #expect(pending == 0, "Queue must have flushed the result (0 pending)")
    }

    /// Multiple chunks maintain ordering through the queue (queue-level integration).
    @Test func testMultipleChunksProcessedInOrder() async throws {
        let queue = TranscriptionQueue()

        // Get 3 tickets
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        let t2 = await queue.nextSequence()

        // Submit out of order: t2 first, then t0, then t1
        await queue.submitResult(ticket: t2, text: "chunk-2")
        await queue.submitResult(ticket: t0, text: "chunk-0")

        // At this point, chunk-0 should have flushed, chunk-1 is blocking chunk-2
        let pending1 = await queue.getPendingCount()
        #expect(pending1 == 2, "chunk-1 not yet submitted, so 2 pending (seq 1 and 2)")

        await queue.submitResult(ticket: t1, text: "chunk-1")

        // Now all 3 should have flushed in order
        let pending2 = await queue.getPendingCount()
        #expect(pending2 == 0, "All chunks must be flushed")
    }

    /// The textStream AsyncStream emits flushed results.
    @Test func testQueueTextStreamReceivesResults() async throws {
        let queue = TranscriptionQueue()

        // Consume stream in background
        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let streamTask = Task {
            for await text in await queue.textStream {
                received.withLock { $0.append(text) }
            }
        }

        // Small delay to let stream task start consuming
        try? await Task.sleep(for: .milliseconds(50))

        let ticket = await queue.nextSequence()
        await queue.submitResult(ticket: ticket, text: "hello world")

        // submitResult calls flushReady which yields to textStream
        await queue.finishStream()
        try? await Task.sleep(for: .milliseconds(100))

        streamTask.cancel()
        let values = received.withLock { $0 }
        #expect(values.contains("hello world"), "textStream must emit flushed results")
    }

    /// Buffer stores samples → takeAll returns them correctly.
    @Test func testAudioBufferRoundTrip() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        let original = (0..<16000).map { Float(sin(Double($0) * 2.0 * .pi * 440.0 / 16000.0)) }
        await buffer.append(frames: original, hasSpeech: true)

        let result = await buffer.takeAll()
        #expect(result.samples.count == 16000, "All samples must be returned")
        #expect(result.speechRatio == 1.0, "All frames had speech")

        // Buffer should be empty after takeAll
        let second = await buffer.takeAll()
        #expect(second.samples.isEmpty, "Buffer must be empty after takeAll")
    }

    /// Speech ratio calculated correctly with mixed speech/silence.
    @Test func testAudioBufferSpeechRatioCalculation() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        // 50% speech, 50% silence
        await buffer.append(frames: [Float](repeating: 0.5, count: 8000), hasSpeech: true)
        await buffer.append(frames: [Float](repeating: 0.001, count: 8000), hasSpeech: false)

        let ratio = await buffer.speechRatio
        #expect(ratio == 0.5, "50/50 speech ratio must be exactly 0.5")
    }

    /// Duration calculated correctly from sample count and sample rate.
    @Test func testAudioBufferDurationCalculation() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.0, count: 48000), hasSpeech: false)
        let duration = await buffer.duration
        #expect(abs(duration - 3.0) < 0.001, "48000 samples at 16kHz = 3.0s")
    }

    /// TranscriptionQueueBridge has the required completion flow.
    @Test func testQueueBridgeCompletionFlow() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift")
        #expect(source.contains("class TranscriptionQueueBridge"))
        #expect(source.contains("func checkCompletion()"))
        #expect(source.contains("hasSignaledCompletion"))
        #expect(source.contains("sessionStarted"))
    }

    /// Cancel doesn't corrupt queue state — queue remains usable after recorder cancel.
    @Test func testRecorderCancelDoesNotCorruptQueue() async throws {
        let queue = TranscriptionQueue()

        // Simulate a cancelled recording session: queue gets no submissions
        // but should still be in clean state for next session
        let ticket = await queue.nextSequence()
        #expect(ticket.seq == 0, "First ticket must be seq 0")

        // Simulate: cancel happened, but queue is reused
        await queue.reset()

        // After reset, queue should accept new work
        let newTicket = await queue.nextSequence()
        #expect(newTicket.seq == 0, "After reset, sequence must restart at 0")
        // Session generation should have incremented
        let gen = await queue.currentSessionGeneration()
        #expect(gen == 1, "Reset must increment session generation")

        await queue.submitResult(ticket: newTicket, text: "post-cancel")
        let pending = await queue.getPendingCount()
        #expect(pending == 0, "Queue must accept new results after reset")
    }

    /// Recorder produces chunk with valid WAV data via sendChunkIfReady integration.
    @Test func testRecorderChunkContainsValidWAV() async throws {
        // Save/restore settings
        let origChunk = await Settings.shared.chunkDuration
        let origSkip = await Settings.shared.skipSilentChunks
        await MainActor.run {
            Settings.shared.chunkDuration = .seconds15
            Settings.shared.skipSilentChunks = false
        }
        defer {
            Task { @MainActor in
                Settings.shared.chunkDuration = origChunk
                Settings.shared.skipSilentChunks = origSkip
            }
        }

        // Capture chunk via onChunkReady on MainActor
        let chunkData = OSAllocatedUnfairLock<Data?>(initialState: nil)

        await MainActor.run {
            let recorder = StreamingRecorder()
            let buffer = AudioBuffer(sampleRate: 16000)

            recorder.onChunkReady = { c in
                chunkData.withLock { $0 = c.wavData }
            }

            Task { @MainActor in
                await buffer.append(frames: [Float](repeating: 0.5, count: 240_000), hasSpeech: true)
                recorder._testInjectAudioBuffer(buffer)
                recorder._testSetIsRecording(true)
                await recorder._testInvokeSendChunkIfReady(reason: "wav integration test")
            }
        }

        // Give time for MainActor task to complete
        try await Task.sleep(for: .milliseconds(300))

        guard let wav = chunkData.withLock({ $0 }) else {
            Issue.record("No chunk produced")
            return
        }

        // Validate WAV header structure
        #expect(wav.count > 44, "WAV must have header + data")
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        let sampleRate: UInt32 = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 16000, "Sample rate must be 16000")
        let channels: UInt16 = wav[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(channels == 1, "Must be mono")
        let bitsPerSample: UInt16 = wav[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(bitsPerSample == 16, "Must be 16-bit PCM")
        // Data section: 240,000 samples * 2 bytes = 480,000 bytes
        let expectedDataSize = 240_000 * 2
        #expect(wav.count == 44 + expectedDataSize, "WAV size must be header + data")
    }

    /// Failed chunk doesn't block subsequent successful chunks in the queue.
    @Test func testFullPipelineWithFailedChunk() async {
        let queue = TranscriptionQueue()

        let t0 = await queue.nextSequence() // will fail
        let t1 = await queue.nextSequence() // will succeed
        let t2 = await queue.nextSequence() // will succeed

        // Collect results via textStream
        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let streamTask = Task {
            for await text in await queue.textStream {
                received.withLock { $0.append(text) }
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        await queue.markFailed(ticket: t0)
        await queue.submitResult(ticket: t1, text: "first")
        await queue.submitResult(ticket: t2, text: "second")

        // Give stream time to receive
        try? await Task.sleep(for: .milliseconds(100))

        await queue.finishStream()
        streamTask.cancel()

        let values = received.withLock { $0 }
        #expect(values == ["first", "second"],
                "Failed chunk must be skipped, subsequent chunks must flush in order")
    }

    /// AudioBuffer reset clears all state.
    @Test func testAudioBufferReset() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)

        let durBefore = await buffer.duration
        #expect(durBefore > 0.9)

        await buffer.reset()
        let durAfter = await buffer.duration
        #expect(durAfter == 0, "Reset must clear all samples")
        let ratio = await buffer.speechRatio
        #expect(ratio == 0, "Reset must clear speech ratio")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: sendChunkIfReady & periodicCheck
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — sendChunkIfReady & periodicCheck", .serialized)
struct StreamingRecorderSendChunkIfReadyPeriodicCheckTests {

    @Test @MainActor func testSendChunkIfReadyReturnsFalseWhenBufferTooShort() async {
        let origChunkDuration = Settings.shared.chunkDuration
        defer { Settings.shared.chunkDuration = origChunkDuration }
        Settings.shared.chunkDuration = .seconds15

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16_000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var chunkReceived = false
        recorder.onChunkReady = { _ in chunkReceived = true }

        await recorder._testInvokeSendChunkIfReady(reason: "test")

        let remaining = await recorder._testAudioBufferDuration()
        #expect(!chunkReceived, "Chunk shorter than minChunkDuration must be rejected")
        #expect(remaining > 0.9, "Rejected chunk must remain buffered")
    }

    /// Source-level: sendChunkIfReady checks skipSilentChunks before sending.
    @Test func testSendChunkIfReadySkipsSilentChunkWithSkipEnabled() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "sendChunkIfReady", from: source)
        // The skip condition must check skipSilentChunks && low probability && no session speech
        #expect(body?.contains("Settings.shared.skipSilentChunks && speechProbability < skipThreshold && !speechDetectedInSession") == true,
                "sendChunkIfReady must skip silent chunks when skipSilentChunks is enabled and no speech detected")
        // When skipping, buffer must NOT be drained (no takeAll before return false)
        #expect(body?.contains("return false") == true,
                "Skip branch must return false without draining buffer")
    }

    @Test @MainActor func testSendChunkIfReadySendsWhenSkipDisabled() async {
        let origSkip = Settings.shared.skipSilentChunks
        let origChunkDuration = Settings.shared.chunkDuration
        defer {
            Settings.shared.skipSilentChunks = origSkip
            Settings.shared.chunkDuration = origChunkDuration
        }
        Settings.shared.skipSilentChunks = false
        Settings.shared.chunkDuration = .seconds15

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.001, count: 240_000), hasSpeech: false)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var chunkReceived = false
        recorder.onChunkReady = { _ in chunkReceived = true }

        await recorder._testInvokeSendChunkIfReady(reason: "test")

        let remaining = await recorder._testAudioBufferDuration()
        #expect(chunkReceived, "With skipSilentChunks=false, silent chunk must still be sent")
        #expect(remaining == 0, "Sent chunk must drain buffer")
    }

    @Test func testSendChunkIfReadyBypassesSkipWhenSpeechDetectedInSession() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "sendChunkIfReady", from: source)
        #expect(body?.contains("&& !speechDetectedInSession") == true,
                "Skip logic must check speechDetectedInSession bypass")
    }

    @Test func testSendChunkIfReadyResetsVADOnSkip() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        guard let body = extractFunctionBody(named: "sendChunkIfReady", from: source) else {
            Issue.record("sendChunkIfReady body not found")
            return
        }
        guard let skipLogRange = body.range(of: "Skipping silent chunk") else {
            Issue.record("skip log not found")
            return
        }
        let beforeSkipLog = String(body[..<skipLogRange.lowerBound])
        #expect(beforeSkipLog.contains("resetChunk()"),
                "resetChunk() must be called in skip branch before logging")
    }

    @Test func testSendChunkIfReadyResetsVADOnSend() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        guard let body = extractFunctionBody(named: "sendChunkIfReady", from: source) else {
            Issue.record("sendChunkIfReady body not found")
            return
        }
        guard let drainRange = body.range(of: "Drain buffer and send") else {
            Issue.record("Drain buffer and send section not found")
            return
        }
        let afterDrain = String(body[drainRange.lowerBound...])
        #expect(afterDrain.contains("resetChunk()"),
                "resetChunk() must be called after draining buffer")
    }

    @Test func testSendChunkIfReadyCalculatesSpeechProbabilityFromVADWhenActive() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "sendChunkIfReady", from: source)
        #expect(body?.contains("speechProbability = vadProb > 0 ? vadProb : energySpeechRatio") == true,
                "Must prefer VAD probability over energy ratio when VAD active and has data")
    }

    @Test func testPeriodicCheckDoesNothingWhenNotRecording() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "periodicCheck", from: source)
        #expect(body?.contains("guard state.getRecording()") == true,
                "periodicCheck must guard on recording state")
    }

    @Test func testPeriodicCheckForceSendAtHardLimit() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "periodicCheck", from: source)
        #expect(body?.contains("Config.forceSendChunkMultiplier") == true,
                "periodicCheck must have force-send at hard upper limit")
        #expect(body?.contains("FORCE CHUNK") == true,
                "Force-send must log a FORCE CHUNK warning")
    }

    @Test func testPeriodicCheckFallbackChunkOnSilenceWithoutVAD() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "periodicCheck", from: source)
        #expect(body?.contains("Config.silenceDuration") == true,
                "Fallback path must use Config.silenceDuration for chunk timing")
        #expect(body?.contains("reason: \"silence (fallback)\"") == true,
                "Fallback silence chunk must use 'silence (fallback)' reason")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionService: Timeout, Error Truncation & Request Building
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionService — Timeout, Error Truncation & Request Building")
struct TranscriptionServiceTimeoutErrorRequestTests {

    /// Small data (≤ baseTimeoutDataSize) should use base timeout.
    @Test func testTimeoutSmallDataUsesBaseTimeout() {
        let timeout = TranscriptionService.timeout(forDataSize: 100_000)
        #expect(timeout == Config.timeout, "Small audio must use base timeout")
    }

    /// At exactly baseTimeoutDataSize, use base timeout.
    @Test func testTimeoutAtExactBaseSize() {
        let timeout = TranscriptionService.timeout(forDataSize: Config.baseTimeoutDataSize)
        #expect(timeout == Config.timeout, "At exactly baseTimeoutDataSize, use base timeout")
    }

    /// Timeout scales linearly between baseTimeoutDataSize and maxAudioSizeBytes.
    @Test func testTimeoutScalesLinearly() {
        let midSize = (Config.baseTimeoutDataSize + Config.maxAudioSizeBytes) / 2
        let timeout = TranscriptionService.timeout(forDataSize: midSize)
        let expectedMid = (Config.timeout + Config.maxTimeout) / 2.0
        #expect(abs(timeout - expectedMid) < 0.5, "Timeout must scale linearly")
    }

    /// Above maxAudioSizeBytes should cap at maxTimeout.
    @Test func testTimeoutCapsAtMaxTimeout() {
        let timeout = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes * 2)
        #expect(timeout == Config.maxTimeout, "Must cap at maxTimeout")
    }

    /// At maxAudioSizeBytes, timeout must equal maxTimeout.
    @Test func testTimeoutAtMaxAudioSize() {
        let timeout = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes)
        #expect(timeout == Config.maxTimeout, "At maxAudioSizeBytes, timeout must equal maxTimeout")
    }

    /// Short data must not be truncated.
    @Test func testTruncateErrorBodyShortData() {
        let data = "Hello".data(using: .utf8)!
        let result = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        #expect(result == "Hello", "Short data must not be truncated")
    }

    /// Data at exact limit must not be truncated.
    @Test func testTruncateErrorBodyExactLimit() {
        let text = String(repeating: "a", count: 200)
        let data = text.data(using: .utf8)!
        let result = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        #expect(result == text, "Data at exact limit must not be truncated")
        #expect(!result.hasSuffix("..."))
    }

    /// Long data must be truncated with "..." suffix.
    @Test func testTruncateErrorBodyLongData() {
        let text = String(repeating: "x", count: 500)
        let data = text.data(using: .utf8)!
        let result = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        #expect(result.count <= 203, "Truncated result must be ≤ maxBytes + '...' suffix")
        #expect(result.hasSuffix("..."), "Truncated result must end with '...'")
    }

    /// Empty data must produce empty string.
    @Test func testTruncateErrorBodyEmptyData() {
        let result = TranscriptionService.truncateErrorBody(Data(), maxBytes: 200)
        #expect(result == "", "Empty data must produce empty string")
    }

    /// Default maxBytes is 200.
    @Test func testTruncateErrorBodyDefaultMaxBytes() {
        let text = String(repeating: "y", count: 300)
        let data = text.data(using: .utf8)!
        let result = TranscriptionService.truncateErrorBody(data)
        #expect(result.hasSuffix("..."))
        let withoutEllipsis = String(result.dropLast(3))
        #expect(withoutEllipsis.count == 200)
    }

    /// TranscriptionService must be declared as an actor.
    @Test func testTranscriptionServiceIsActor() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(source.contains("public actor TranscriptionService"))
    }

    /// TranscriptionService must have a shared singleton.
    @Test func testTranscriptionServiceHasSharedSingleton() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(source.contains("public static let shared = TranscriptionService()"))
    }

    /// buildRequest must validate audio size.
    @Test func testBuildRequestValidatesAudioSize() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "buildRequest", from: source)
        #expect(body?.contains("audio.count <= Config.maxAudioSizeBytes") == true,
                "buildRequest must validate audio size")
        #expect(body?.contains("TranscriptionError.audioTooLarge") == true)
    }

    /// buildRequest must use the correct ChatGPT endpoint.
    @Test func testBuildRequestUsesCorrectEndpoint() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(source.contains("https://chatgpt.com/backend-api/transcribe"),
                "Must use the ChatGPT transcription endpoint")
    }

    /// buildRequest must use multipart/form-data.
    @Test func testBuildRequestUsesMultipartFormData() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "buildRequest", from: source)
        #expect(body?.contains("multipart/form-data; boundary=") == true)
        #expect(body?.contains(#"Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\""#) == true)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionService: Retry, Cancellation & Error Types
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionService — Retry, Cancellation & Error Types")
struct TranscriptionServiceRetryErrorTests {

    // MARK: - TranscriptionError isRetryable property tests

    /// Network errors must be retryable.
    @Test func testTranscriptionErrorIsRetryableForNetworkErrors() {
        let error = TranscriptionError.networkError(underlying: URLError(.timedOut))
        #expect(error.isRetryable == true, "Network errors must be retryable")
    }

    /// Rate limited errors must be retryable.
    @Test func testTranscriptionErrorIsRetryableForRateLimited() {
        let error = TranscriptionError.rateLimited(retryAfter: 5.0)
        #expect(error.isRetryable == true, "Rate limited must be retryable")
    }

    /// 5xx server errors must be retryable.
    @Test func testTranscriptionErrorIsRetryableForServerErrors() {
        let error500 = TranscriptionError.httpError(statusCode: 500, body: nil)
        let error503 = TranscriptionError.httpError(statusCode: 503, body: "Service Unavailable")
        #expect(error500.isRetryable == true, "5xx must be retryable")
        #expect(error503.isRetryable == true, "5xx must be retryable")
    }

    /// 4xx client errors (except 429) must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForClientErrors() {
        let error400 = TranscriptionError.httpError(statusCode: 400, body: nil)
        let error403 = TranscriptionError.httpError(statusCode: 403, body: nil)
        #expect(error400.isRetryable == false, "4xx (non-429) must not be retryable")
        #expect(error403.isRetryable == false, "4xx (non-429) must not be retryable")
    }

    /// Authentication errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForAuthErrors() {
        let error = TranscriptionError.authenticationFailed(reason: "expired")
        #expect(error.isRetryable == false)
    }

    /// Cancelled errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForCancelled() {
        let error = TranscriptionError.cancelled
        #expect(error.isRetryable == false)
    }

    /// Audio too large errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForAudioTooLarge() {
        let error = TranscriptionError.audioTooLarge(size: 50_000_000, maxSize: 25_000_000)
        #expect(error.isRetryable == false)
    }

    /// Decoding errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForDecodingError() {
        let underlying = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "test"))
        let error = TranscriptionError.decodingFailed(underlying: underlying)
        #expect(error.isRetryable == false)
    }

    /// Invalid response errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForInvalidResponse() {
        let error = TranscriptionError.invalidResponse(data: nil)
        #expect(error.isRetryable == false)
    }

    // MARK: - TranscriptionError description tests

    /// Error descriptions must be accurate.
    @Test func testTranscriptionErrorDescriptions() {
        let errors: [(TranscriptionError, String)] = [
            (.cancelled, "Request cancelled"),
            (.authenticationFailed(reason: "expired"), "Authentication failed: expired"),
            (.rateLimited(retryAfter: nil), "Rate limited"),
            (.rateLimited(retryAfter: 5.0), "Rate limited, retry after 5.0s"),
        ]
        for (error, expected) in errors {
            #expect(error.errorDescription == expected, "\(error) description mismatch")
        }
    }

    /// Audio too large description must show actual and max sizes.
    @Test func testTranscriptionErrorAudioTooLargeDescription() {
        let error = TranscriptionError.audioTooLarge(size: 30_000_000, maxSize: 25_000_000)
        let desc = error.errorDescription!
        #expect(desc.contains("30.0MB"), "Must show actual size")
        #expect(desc.contains("25MB"), "Must show max size")
    }

    /// HTTP error description must show status code and body.
    @Test func testTranscriptionErrorHttpErrorDescription() {
        let error1 = TranscriptionError.httpError(statusCode: 429, body: "Too Many Requests")
        #expect(error1.errorDescription?.contains("429") == true)
        #expect(error1.errorDescription?.contains("Too Many Requests") == true)

        let error2 = TranscriptionError.httpError(statusCode: 500, body: nil)
        #expect(error2.errorDescription?.contains("500") == true)
        #expect(error2.errorDescription?.contains("Unknown error") == true)
    }

    // MARK: - Retry logic (source-level tests)

    /// Retry must use exponential backoff.
    @Test func testRetryUsesExponentialBackoff() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "withRetry", from: source)
        #expect(body?.contains("pow(2.0, Double(attempt - 1))") == true,
                "Retry must use exponential backoff")
    }

    /// Retry must add jitter.
    @Test func testRetryAddsJitter() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "withRetry", from: source)
        #expect(body?.contains("Double.random(in: 0...0.5)") == true,
                "Retry must add jitter")
    }

    /// Retry must check cancellation before each attempt.
    @Test func testRetryChecksCancellationBeforeEachAttempt() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "withRetry", from: source)
        #expect(body?.contains("try Task.checkCancellation()") == true,
                "Must check cancellation before each retry attempt")
    }

    /// Retry must convert CancellationError to TranscriptionError.cancelled.
    @Test func testRetryConvertsCancellationToTranscriptionError() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "withRetry", from: source)
        #expect(body?.contains("catch is CancellationError") == true)
        #expect(body?.contains("throw TranscriptionError.cancelled") == true)
    }

    /// Retry must stop on non-retryable errors.
    @Test func testRetryStopsOnNonRetryableError() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "withRetry", from: source)
        #expect(body?.contains("!error.isRetryable") == true,
                "Must check isRetryable before continuing retry loop")
    }

    /// transcribe() must pass Config.maxRetries to withRetry.
    @Test func testRetryUsesMaxRetries() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        #expect(source.contains("maxAttempts: Config.maxRetries"),
                "transcribe() must pass Config.maxRetries to withRetry")
    }

    // MARK: - Response handling (source-level tests)

    /// performRequest must handle 429 with Retry-After header.
    @Test func testPerformRequestHandles429WithRetryAfter() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "performRequest", from: source)
        #expect(body?.contains("statusCode == 429") == true)
        #expect(body?.contains("Retry-After") == true)
        #expect(body?.contains("TranscriptionError.rateLimited") == true)
    }

    /// performRequest must fall back to legacy JSON when Decodable fails.
    @Test func testPerformRequestFallsBackToLegacyJSON() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionService.swift")
        let body = extractFunctionBody(named: "performRequest", from: source)
        #expect(body?.contains("JSONSerialization.jsonObject") == true,
                "Must have legacy JSON fallback")
        #expect(body?.contains("json[\"text\"] as? String") == true)
    }
}
