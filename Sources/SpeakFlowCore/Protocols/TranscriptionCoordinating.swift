import Foundation

/// Abstracts Transcription coordinator for dependency injection.
@MainActor
public protocol TranscriptionCoordinating: AnyObject {
    var queueBridge: TranscriptionQueueBridge { get }
    func transcribe(ticket: TranscriptionTicket, chunk: AudioChunk)
    func cancelAll()
    func setMetricsSession(_ sessionId: UUID?)
}

extension TranscriptionCoordinating {
    public func setMetricsSession(_: UUID?) {}
}
