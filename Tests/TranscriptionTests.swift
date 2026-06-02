import Foundation
import Testing
@testable import SpeakFlowCore

@MainActor
private final class TestStatistics: StatisticsProviding {
    var totalSecondsTranscribed: Double = 0
    var totalCharacters: Int = 0
    var totalWords: Int = 0
    var totalApiCalls: Int = 0
    var recordedLatencies: [TimeInterval] = []
    /// Each entry captures one `recordRecording(providerId:, language:)` call.
    var recordedRecordings: [(providerId: String?, language: String?)] = []
    var apiCallCount: Int { totalApiCalls }
    var wordCount: Int { totalWords }
    var formattedDuration: String { "0s" }
    var formattedCharacters: String { "0" }
    var formattedWords: String { "0" }
    var formattedApiCalls: String { "0" }
    var sttLatencyP50Ms: Double { 0 }
    var sttLatencyP95Ms: Double { 0 }
    var sttLatencyP99Ms: Double { 0 }

    func recordTranscription(text: String, audioDurationSeconds: Double) {
        totalSecondsTranscribed += audioDurationSeconds
        totalCharacters += text.count
        totalWords += text.split(separator: " ").count
    }

    func recordApiCall() {
        totalApiCalls += 1
    }

    func recordRecording(providerId: String?, language: String?) {
        recordedRecordings.append((providerId, language))
    }

    func recordSTTLatency(seconds: TimeInterval) {
        recordedLatencies.append(seconds)
    }

    func reset() {
        totalSecondsTranscribed = 0
        totalCharacters = 0
        totalWords = 0
        totalApiCalls = 0
        recordedRecordings = []
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
        #expect(stats.recordedLatencies.isEmpty,
                "Cancelled transcriptions should not be recorded as STT latency")
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
        #expect(stats.recordedLatencies.count == 1,
                "Failed requests should still record observed STT latency")
    }
}

// MARK: - onChunkError callback tests

@Suite("Transcription onChunkError callback", .serialized)
struct TranscriptionOnChunkErrorTests {

    @MainActor
    private func awaitQueueDrain(_ bridge: TranscriptionQueueBridge) async {
        for _ in 0..<80 {
            if await bridge.getPendingCount() == 0 { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor @Test
    func nonCancellationErrorFiresOnChunkError() async {
        let service = StubTranscriptionService(mode: .failure)
        let transcription = Transcription(statistics: TestStatistics(), service: service)
        defer { transcription.queueBridge.stopListening() }

        var capturedError: Error?
        transcription.queueBridge.onChunkError = { capturedError = $0 }

        let ticket = await transcription.queueBridge.nextSequence()
        transcription.transcribe(ticket: ticket,
                                 chunk: AudioChunk(wavData: Data([0x00]), durationSeconds: 0.1))
        await awaitQueueDrain(transcription.queueBridge)

        #expect(capturedError != nil, "onChunkError must fire on non-cancellation failure")
    }

    @MainActor @Test
    func cancellationErrorDoesNotFireOnChunkError() async {
        let service = StubTranscriptionService(mode: .cancelled)
        let transcription = Transcription(statistics: TestStatistics(), service: service)
        defer { transcription.queueBridge.stopListening() }

        var errorFired = false
        transcription.queueBridge.onChunkError = { _ in errorFired = true }

        let ticket = await transcription.queueBridge.nextSequence()
        transcription.transcribe(ticket: ticket,
                                 chunk: AudioChunk(wavData: Data([0x00]), durationSeconds: 0.1))
        await awaitQueueDrain(transcription.queueBridge)

        #expect(!errorFired, "onChunkError must NOT fire for cancellation errors")
    }

    @MainActor @Test
    func activeBatchProviderDispatchesChunks() async {
        let service = StubTranscriptionService(mode: .failure) // should never be called
        let transcription = Transcription(statistics: TestStatistics(), service: service)
        defer { transcription.queueBridge.stopListening() }

        let batchProvider = StubBatchProvider(result: "hello from batch")
        transcription.setActiveBatchProvider(batchProvider)

        var received: [String] = []
        transcription.queueBridge.onTextReady = { received.append($0) }

        let ticket = await transcription.queueBridge.nextSequence()
        transcription.transcribe(ticket: ticket,
                                 chunk: AudioChunk(wavData: Data([0x00]), durationSeconds: 0.1))
        await awaitQueueDrain(transcription.queueBridge)

        #expect(received == ["hello from batch"],
                "Active batch provider must be used instead of default service")
    }

    @MainActor @Test
    func cancelAllClearsActiveBatchProvider() async {
        let service = StubTranscriptionService(mode: .success("fallback"))
        let transcription = Transcription(statistics: TestStatistics(), service: service)
        defer { transcription.queueBridge.stopListening() }

        transcription.setActiveBatchProvider(StubBatchProvider(result: "batch"))
        transcription.cancelAll()

        var received: [String] = []
        transcription.queueBridge.onTextReady = { received.append($0) }

        let ticket = await transcription.queueBridge.nextSequence()
        transcription.transcribe(ticket: ticket,
                                 chunk: AudioChunk(wavData: Data([0x00]), durationSeconds: 0.1))
        await awaitQueueDrain(transcription.queueBridge)

        #expect(received == ["fallback"],
                "cancelAll must clear activeBatchProvider so default service is used")
    }
}

// MARK: - Stub batch provider

private final class StubBatchProvider: BatchTranscriptionProvider, @unchecked Sendable {
    let id = "stub-batch"
    let displayName = "Stub Batch"
    let mode: ProviderMode = .batch
    let authRequirement: ProviderAuthRequirement = .apiKey(providerId: "stub-batch")
    var isConfigured: Bool { true }
    private let result: String
    init(result: String) { self.result = result }
    func transcribe(audio: Data) async throws -> String { result }
    func validateAPIKey(_ key: String) async -> String? { nil }
}

// MARK: - Recording-vs-chunk accounting

/// Batch dictation: a single user recording is split into many chunks.
/// `Transcription` should count each chunk send as one API call, but must NOT
/// inflate user-recording counters (per-provider, per-language, daily, period)
/// per chunk: those represent user recordings, which is the caller's concern.
@Suite("Transcription chunk accounting", .serialized)
struct TranscriptionChunkRecordingTests {
    @MainActor
    private func awaitQueueDrain(_ bridge: TranscriptionQueueBridge) async {
        for _ in 0..<80 {
            if await bridge.getPendingCount() == 0 { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor @Test
    func successfulChunkTranscriptionCountsOneApiCallPerChunk() async {
        let stats = TestStatistics()
        let service = StubTranscriptionService(mode: .success("hello"))
        let transcription = Transcription(statistics: stats, service: service)
        let previousMute = SoundEffect.isMuted
        SoundEffect.isMuted = true
        defer {
            SoundEffect.isMuted = previousMute
            transcription.queueBridge.stopListening()
        }

        for _ in 0..<4 {
            let ticket = await transcription.queueBridge.nextSequence()
            transcription.transcribe(
                ticket: ticket,
                chunk: AudioChunk(wavData: Data([0x00]), durationSeconds: 0.1)
            )
        }
        await awaitQueueDrain(transcription.queueBridge)

        #expect(
            stats.totalApiCalls == 4,
            "Each chunk send is one provider API request; four chunks must report four API calls"
        )
        #expect(
            stats.recordedRecordings.isEmpty,
            "Transcription must not increment per-recording counters; recording count is the caller's responsibility"
        )
    }

    @MainActor @Test
    func failedChunkTranscriptionStillCountsOneApiCall() async {
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

        #expect(
            stats.totalApiCalls == 1,
            "Failed chunk send still consumed one provider request slot, so API-call counter should grow"
        )
        #expect(
            stats.recordedRecordings.isEmpty,
            "Failed chunks must not add to per-recording counters; chunks are not recordings"
        )
    }
}
