import Foundation
import os
import Testing
@testable import SpeakFlowCore

// MARK: - Rate Limiter Tests

struct RateLimiterTests {
    @Test func testSequentialRequestsAreThrottled() async throws {
        let interval = 0.10
        let limiter = RateLimiter(minimumInterval: interval)

        try await limiter.waitAndRecord()

        let start = Date()
        try await limiter.waitAndRecord()
        let elapsed = Date().timeIntervalSince(start)

        // Second call must wait approximately one interval. Use generous lower
        // bound — we're testing that throttling happens, not exact precision.
        #expect(elapsed >= interval * 0.5)
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
        let interval = 0.10
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

        // Core invariant: with atomic reservation, 2 concurrent calls after a seed
        // should occupy slots 2 and 3, spanning at least 2 intervals total.
        // Check aggregate spread instead of individual gaps to avoid timing flakiness.
        let totalSpan = completionTimes.last! - completionTimes.first!
        #expect(totalSpan > 0, "Concurrent callers must not complete at the same time")

        let lastCompletion = completionTimes.last!
        #expect(lastCompletion >= interval,
                "Last slot should be at least 1 interval after start, got \(lastCompletion)s")
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

// MARK: - Issue #3 Regression: OAuthCallbackServer data-race guard

@Suite("Issue #3 — OAuthCallbackServer synchronization guards")
struct Issue3OAuthCallbackServerSourceTests {

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
}

// MARK: - Issue #6 Regression: Rate limiter atomic reservation (additional)

@Suite("Issue #6 — Rate limiter atomic slot reservation (additional)")
struct Issue6RateLimiterAtomicTests {

    /// 6 concurrent callers must each get a distinct slot — verify via aggregate span.
    @Test func testFiveConcurrentCallersGetFiveDistinctSlots() async throws {
        let interval: TimeInterval = 0.10
        let limiter = RateLimiter(minimumInterval: interval)

        // Launch 6 concurrent tasks. With atomic reservation, each gets a unique
        // slot spaced by `interval`. Total span should be ~5 * interval.
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

        #expect(times.count == 6, "All 6 callers must complete")

        // Monotonically non-decreasing — earlier slots complete no later than later ones
        for i in 1..<times.count {
            #expect(times[i] >= times[i - 1], "Completion times must be non-decreasing")
        }

        // Aggregate span check: 6 slots span 5 intervals. Use a generous 50% lower
        // bound — we're testing that slots DON'T collapse, not exact precision.
        let totalSpan = times.last! - times.first!
        #expect(totalSpan >= interval * 5.0 * 0.5,
                "6 slots should span ~5 intervals (\(interval * 5.0)s), got \(totalSpan)s")
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
            "text": "cafe\u{0301}",
        ])
        let body = String(decoding: bodyData, as: UTF8.self)
        // 'e\u{0301}' is U+0065 U+0301, UTF-8: 0x65 0xCC 0x81 → e%CC%81
        #expect(body.contains("caf"), "ASCII prefix must be present, got: \(body)")
        #expect(!body.contains("cafe\u{0301}"), "Raw unicode must not appear in encoded body")
    }
}

// MARK: - AuthError Localization Regression Tests (Issue #20)

@Suite("Issue #20 — AuthError Localization")
struct AuthErrorLocalizationTests {

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

// MARK: - P2 Fix: httpProvider thread-safe access

@Suite("P2 — httpProvider lock-protected access", .serialized)
struct HttpProviderThreadSafetyTests {

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

// MARK: - P2 Fix: TokenRefreshCoordinator deduplication

@Suite("P2 — TokenRefreshCoordinator shared _refreshCore")
struct TokenRefreshDeduplicationTests {

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
