import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
final class SpyTranscription: TranscriptionCoordinating {
    let queueBridge = TranscriptionQueueBridge()
    var transcribeCalls: [(TranscriptionTicket, AudioChunk)] = []
    var cancelAllCount = 0
    var activeBatchProvider: (any BatchTranscriptionProvider)?
    var metricsSessionHistory: [UUID?] = []

    func transcribe(ticket: TranscriptionTicket, chunk: AudioChunk) {
        transcribeCalls.append((ticket, chunk))
    }

    func cancelAll() {
        cancelAllCount += 1
    }

    func setMetricsSession(_ sessionId: UUID?) {
        metricsSessionHistory.append(sessionId)
    }

    func setActiveBatchProvider(_ provider: (any BatchTranscriptionProvider)?) {
        activeBatchProvider = provider
    }
}
