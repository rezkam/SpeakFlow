import Foundation

/// Abstracts Transcription coordinator for dependency injection.
@MainActor
public protocol TranscriptionCoordinating: AnyObject {
    var queueBridge: TranscriptionQueueBridge { get }
    func transcribe(ticket: TranscriptionTicket, chunk: AudioChunk)
    func cancelAll()
    func setMetricsSession(_ sessionId: UUID?)
    /// Set the batch provider to dispatch chunks through.
    /// Pass `nil` to revert to the default (ChatGPT) service.
    func setActiveBatchProvider(_ provider: (any BatchTranscriptionProvider)?)
}

extension TranscriptionCoordinating {
    public func setMetricsSession(_: UUID?) {}
    public func setActiveBatchProvider(_: (any BatchTranscriptionProvider)?) {}
}
