import Foundation
@testable import SpeakFlowCore

/// A test-only streaming session that emits events programmatically.
/// Use `emit(_:)` to push events and inspect `sentAudioChunks` / `finalizeCalled` / `closeCalled`
/// to verify what the system under test did with the session.
actor MockStreamingSession: StreamingSession {
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    nonisolated let events: AsyncStream<TranscriptionEvent>

    var sentAudioChunks: [Data] = []
    var finalizeCalled = false
    var closeCalled = false
    var keepAliveCalled = false

    init() {
        var cont: AsyncStream<TranscriptionEvent>.Continuation!
        self.events = AsyncStream<TranscriptionEvent> { c in cont = c }
        self.continuation = cont
    }

    // MARK: - StreamingSession conformance

    func sendAudio(_ data: Data) async throws {
        sentAudioChunks.append(data)
    }

    func finalize() async throws {
        finalizeCalled = true
    }

    func close() async throws {
        closeCalled = true
        continuation.finish()
    }

    func keepAlive() async throws {
        keepAliveCalled = true
    }

    // MARK: - Test helpers

    /// Emit a transcription event into the events stream.
    func emit(_ event: TranscriptionEvent) {
        continuation.yield(event)
    }

    /// Signal end of events stream.
    func finish() {
        continuation.finish()
    }
}
