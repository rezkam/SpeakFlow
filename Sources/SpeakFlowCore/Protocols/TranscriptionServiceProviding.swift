import Foundation

/// Abstracts TranscriptionService for dependency injection.
public protocol TranscriptionServiceProviding: Sendable {
    func transcribe(audio: Data) async throws -> String
}
