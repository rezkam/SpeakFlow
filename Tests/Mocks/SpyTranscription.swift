import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
final class SpyTranscription: TranscriptionCoordinating {
    let queueBridge = TranscriptionQueueBridge()
    var transcribeCalls: [(TranscriptionTicket, AudioChunk)] = []
    var cancelAllCount = 0

    func transcribe(ticket: TranscriptionTicket, chunk: AudioChunk) {
        transcribeCalls.append((ticket, chunk))
    }

    func cancelAll() {
        cancelAllCount += 1
    }
}
