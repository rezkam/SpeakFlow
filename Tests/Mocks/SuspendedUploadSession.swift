import Foundation
@testable import SpeakFlowCore

/// Holds a network send until cancellation/close, without using live services.
actor SuspendedUploadSession: StreamingSession {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private let eventsContinuation: AsyncStream<TranscriptionEvent>.Continuation
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation
    private(set) var sendStarted = false
    private(set) var uploads = 0

    init() {
        (events, eventsContinuation) = AsyncStream.makeStream()
        (gate, gateContinuation) = AsyncStream.makeStream()
    }

    func sendAudio(_ data: Data) async throws {
        sendStarted = true
        for await _ in gate { break }
        try Task.checkCancellation()
        uploads += 1
    }

    func resumeUploads() { gateContinuation.finish() }

    func finalize() async throws {}
    func keepAlive() async throws {}
    func close() async throws {
        gateContinuation.finish()
        eventsContinuation.finish()
    }
}
