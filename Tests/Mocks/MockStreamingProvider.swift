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
    let displayName = "Mock Streaming"
    let mode: ProviderMode = .streaming
    var isConfigured: Bool = true
    var authRequirement: ProviderAuthRequirement { .apiKey(providerId: id) }

    /// The session that `startSession()` will return. Set before use.
    var mockSession: MockStreamingSession?

    /// Whether `startSession()` should throw.
    var shouldFailOnStart = false

    /// How many times `startSession()` was called.
    var startSessionCallCount = 0

    func startSession(config: StreamingSessionConfig) async throws -> StreamingSession {
        startSessionCallCount += 1
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
