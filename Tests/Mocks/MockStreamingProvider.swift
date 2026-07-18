import Foundation
import Testing
@testable import SpeakFlowCore

/// A test-only streaming provider that returns a pre-configured MockStreamingSession.
/// Set `mockSession` before calling `startSession()` to control what session is returned.
///
/// Uses `@unchecked Sendable` to match the real `DeepgramProvider` pattern —
/// the protocol requires `Sendable` conformance.
final class MockStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    let id: String = ProviderId.deepgram
    var displayName = "Mock Streaming"
    let mode: ProviderMode = .streaming
    var isConfigured: Bool = true
    var authRequirement: ProviderAuthRequirement { .apiKey(providerId: id) }

    /// The session that `startSession()` will return. Set before use.
    var mockSession: MockStreamingSession?

    /// Whether `startSession()` should throw.
    var shouldFailOnStart = false

    /// Specific error to throw from `startSession()`, when set.
    var startError: Error?

    /// How many times `startSession()` was called.
    var startSessionCallCount = 0

    func startSession(config: StreamingSessionConfig) async throws -> StreamingSession {
        startSessionCallCount += 1
        if let startError {
            throw startError
        }
        if shouldFailOnStart {
            throw DeepgramError.connectionFailed("Mock connection failure")
        }
        guard let session = mockSession else {
            throw DeepgramError.connectionFailed("No mock session configured")
        }
        return session
    }

    @MainActor
    func buildSessionConfig() -> StreamingSessionConfig {
        .default
    }
}

// MARK: - MultiSessionMockProvider

/// A streaming provider that returns different sessions on successive `startSession()` calls.
///
/// Used in reconnection tests to simulate:
/// 1. First call: initial session (which will be "dropped")
/// 2. Second call: reconnect session (which succeeds or fails depending on test)
///
/// This is more realistic than `MockStreamingProvider` for testing reconnection paths,
/// because reconnection requires a NEW session object.
final class MultiSessionMockProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    let id: String = ProviderId.deepgram
    let displayName = "Multi-Session Mock"
    let mode: ProviderMode = .streaming
    var isConfigured: Bool = true
    var authRequirement: ProviderAuthRequirement { .apiKey(providerId: id) }

    /// Queue of sessions to return. Each `startSession()` call pops the first entry.
    /// If empty, throws a connection failure.
    var sessions: [any StreamingSession] = []

    /// Number of times `startSession()` was called.
    var startSessionCallCount = 0

    /// Whether the next call should fail (overrides `sessions` queue).
    var nextCallShouldFail = false

    /// Optional delay before returning from startSession (simulates slow reconnect).
    var reconnectDelay: TimeInterval = 0

    func startSession(config: StreamingSessionConfig) async throws -> StreamingSession {
        startSessionCallCount += 1
        if reconnectDelay > 0 {
            try await Task.sleep(for: .seconds(reconnectDelay))
        }
        if nextCallShouldFail {
            nextCallShouldFail = false  // reset after one failure
            throw DeepgramError.connectionFailed("Simulated reconnect failure")
        }
        guard !sessions.isEmpty else {
            throw DeepgramError.connectionFailed("No more sessions available")
        }
        return sessions.removeFirst()
    }

    @MainActor
    func buildSessionConfig() -> StreamingSessionConfig { .default }
}
