import Foundation

/// Abstracts Transcription coordinator for dependency injection.
@MainActor
public protocol TranscriptionCoordinating: AnyObject {
    var queueBridge: TranscriptionQueueBridge { get }
    func transcribe(ticket: TranscriptionTicket, chunk: AudioChunk)
    func cancelAll()
}
