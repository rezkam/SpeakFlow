import Foundation
import Testing
@testable import SpeakFlowCore

@MainActor
private final class TestStatistics: StatisticsProviding {
    var totalSecondsTranscribed: Double = 0
    var totalCharacters: Int = 0
    var totalWords: Int = 0
    var totalApiCalls: Int = 0
    var apiCallCount: Int { totalApiCalls }
    var wordCount: Int { totalWords }
    var formattedDuration: String { "0s" }
    var formattedCharacters: String { "0" }
    var formattedWords: String { "0" }
    var formattedApiCalls: String { "0" }

    func recordTranscription(text: String, audioDurationSeconds: Double) {
        totalSecondsTranscribed += audioDurationSeconds
        totalCharacters += text.count
        totalWords += text.split(separator: " ").count
    }

    func recordApiCall() {
        totalApiCalls += 1
    }

    func reset() {
        totalSecondsTranscribed = 0
        totalCharacters = 0
        totalWords = 0
        totalApiCalls = 0
    }
}

private actor StubTranscriptionService: TranscriptionServiceProviding {
    enum Mode {
        case cancelled
        case failure
        case success(String)
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func transcribe(audio: Data) async throws -> String {
        switch mode {
        case .cancelled:
            throw TranscriptionError.cancelled
        case .failure:
            throw TranscriptionError.httpError(statusCode: 500, body: "boom")
        case .success(let text):
            return text
        }
    }
}

@Suite("Transcription cancellation behavior", .serialized)
struct TranscriptionCancellationBehaviorTests {
    @MainActor
    private func awaitQueueDrain(_ bridge: TranscriptionQueueBridge) async {
        for _ in 0..<80 {
            if await bridge.getPendingCount() == 0 { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor
    @Test
    func cancelledChunkDoesNotPlayErrorSound() async {
        let stats = TestStatistics()
        let service = StubTranscriptionService(mode: .cancelled)
        let transcription = Transcription(statistics: stats, service: service)

        let previousMute = SoundEffect.isMuted
        SoundEffect.isMuted = true
        defer {
            SoundEffect.isMuted = previousMute
            transcription.queueBridge.stopListening()
        }

        let ticket = await transcription.queueBridge.nextSequence()
        transcription.transcribe(
            ticket: ticket,
            chunk: AudioChunk(wavData: Data([0x00]), durationSeconds: 0.1)
        )

        await awaitQueueDrain(transcription.queueBridge)

        #expect(await transcription.queueBridge.getPendingCount() == 0)
        #expect(transcription._testErrorSoundPlayCount == 0,
                "Cancellation should not trigger error UX sound")
    }

    @MainActor
    @Test
    func nonCancellationFailureStillPlaysErrorSound() async {
        let stats = TestStatistics()
        let service = StubTranscriptionService(mode: .failure)
        let transcription = Transcription(statistics: stats, service: service)

        let previousMute = SoundEffect.isMuted
        SoundEffect.isMuted = true
        defer {
            SoundEffect.isMuted = previousMute
            transcription.queueBridge.stopListening()
        }

        let ticket = await transcription.queueBridge.nextSequence()
        transcription.transcribe(
            ticket: ticket,
            chunk: AudioChunk(wavData: Data([0x00]), durationSeconds: 0.1)
        )

        await awaitQueueDrain(transcription.queueBridge)

        #expect(transcription._testErrorSoundPlayCount == 1,
                "True transcription failures should still play one error sound")
    }
}
