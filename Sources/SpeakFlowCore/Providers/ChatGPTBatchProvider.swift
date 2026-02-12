import Foundation

/// ChatGPT batch transcription provider.
///
/// Wraps `TranscriptionService` (which handles the ChatGPT backend API, rate limiting,
/// and retry logic) behind the `BatchTranscriptionProvider` protocol.
public final class ChatGPTBatchProvider: BatchTranscriptionProvider, @unchecked Sendable {
    public let id = ProviderId.chatGPT
    public let displayName = "ChatGPT"
    public let mode: ProviderMode = .batch
    public var authRequirement: ProviderAuthRequirement { .oauth }

    public var isConfigured: Bool { OpenAICodexAuth.isLoggedIn }

    public init() {}

    public func transcribe(audio: Data) async throws -> String {
        try await TranscriptionService.shared.transcribe(audio: audio)
    }
}
