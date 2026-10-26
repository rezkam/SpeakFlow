import Foundation
import Testing
@testable import SpeakFlowCore
import LiveE2EKit

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

private actor HeldTranscriptionService: TranscriptionServiceProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    let fail: Bool

    init(fail: Bool) { self.fail = fail }

    func transcribe(audio: Data) async throws -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
        if fail { throw TranscriptionError.httpError(statusCode: 500, body: "test failure") }
        return "retired response"
    }

    func release() { continuation?.resume(); continuation = nil }
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

    @MainActor @Test
    func providerDiagnosticsKeepOriginalSessionAndOneChunkIdentity() async throws {
        let keys = SpyProviderSettings()
        try keys.setApiKey("fixture-key", for: ProviderId.mistral)
        let provider = MistralBatchProvider(
            providerSettings: keys, settings: SpySettings(), hasAPIKey: { _ in true },
            logger: SpyProviderLogger(), httpDataProvider: MockHTTPProvider(responseData: Data(#"{"text":"fixture"}"#.utf8))
        )
        let transcription = Transcription(statistics: TestStatistics(), service: StubTranscriptionService(mode: .failure))
        transcription.setActiveBatchProvider(provider)
        let original = UUID()
        transcription.setMetricsSession(original)
        let bridge = transcription.queueBridge
        defer { transcription.cancelAll(); bridge.stopListening() }
        let events = TimingEvents()
        var finished = false
        transcription.taskFinishedForTesting = { finished = true }
        let ticket = await bridge.nextSequence()
        try await ProviderTiming.$sink.withValue({ events.append($0) }) {
            transcription.transcribe(ticket: ticket, chunk: AudioChunk(wavData: Data([0]), durationSeconds: 0.25))
            transcription.setMetricsSession(UUID())
            try await waitUntil { finished }
        }
        let finish = try #require(events.values.first { $0.name == "provider_attempt_finished" })
        #expect(finish.sessionId == original, "Diagnostics must not follow replacement recording state")
        let requestId = try #require(finish.metadata["requestId"])
        #expect(events.values.allSatisfy { $0.metadata["requestId"] == requestId && $0.sessionId == original })
        let phases = events.values.filter { $0.name == "provider_phase_finished" }.compactMap { $0.metadata["phase"] }
        #expect(phases.contains("scheduling"))
        #expect(phases.contains("provider_call"))
    }

    @MainActor @Test
    func e2eCompletionTimeoutCancelsRealPendingTranscription() async throws {
        let service = HeldTranscriptionService(fail: false)
        let transcription = Transcription(statistics: TestStatistics(), service: service)
        let bridge = transcription.queueBridge
        var delivered: [String] = []
        var finished = false
        bridge.onTextReady = { delivered.append($0) }
        transcription.taskFinishedForTesting = { finished = true }
        defer {
            Task { await service.release() }
            bridge.stopListening()
            transcription.cancelAll()
        }
        let first = await bridge.nextSequence()
        await bridge.submitResult(ticket: first, text: "hello world")
        try await waitUntil { delivered == ["hello world"] }
        try #require(delivered == ["hello world"])
        let tail = await bridge.nextSequence()
        transcription.transcribe(ticket: tail, chunk: AudioChunk(wavData: Data([0]), durationSeconds: 1))
        try await waitUntilAsync { await service.started }
        try #require(await service.started)
        let completed = await LiveE2ECompletion.wait(
            timeout: .zero, isIdle: { await bridge.isIdle() }, cancel: { transcription.cancelAll() }
        )
        #expect(!completed)
        #expect(!bridge.accepts(tail), "Timeout must retire the actual pending delivery")
        await service.release()
        try await waitUntil { finished }
        try #require(finished)
        #expect(delivered == ["hello world"])
    }

    @MainActor @Test(arguments: [true, false], [true, false])
    func retirementDuringMetricsWriteCannotAffectReplacement(cancel: Bool, fail: Bool) async throws {
        let stats = TestStatistics()
        let service = HeldTranscriptionService(fail: fail)
        let metrics = SessionMetricsStore(storageURL: URL(fileURLWithPath: "/dev/null/test-metrics"))
        let gate = AsyncStream<Void>.makeStream()
        await metrics.setLatencyGateForTesting { for await _ in gate.stream {} }
        let oldId = await metrics.startSession(providerId: "old-provider", mode: .batch)
        let newId = await metrics.startSession(providerId: "new-provider", mode: .batch)
        let transcription = Transcription(statistics: stats, service: service, metricsStore: metrics)
        transcription.setMetricsSession(oldId)
        let bridge = transcription.queueBridge
        var finished = false
        var errors = 0
        var texts: [String] = []
        transcription.taskFinishedForTesting = { finished = true }
        bridge.onChunkError = { _ in errors += 1 }
        bridge.onTextReady = { texts.append($0) }
        defer {
            gate.continuation.finish()
            Task { await service.release() }
            bridge.stopListening()
            transcription.cancelAll()
        }
        let ticket = await bridge.nextSequence()
        transcription.transcribe(ticket: ticket, chunk: AudioChunk(wavData: Data([0]), durationSeconds: 1))
        try await waitUntilAsync { await service.started }
        await service.release()
        try await waitUntilAsync { await metrics.latencyWriteWaitingForTesting }
        if cancel { transcription.cancelAll() } else { await bridge.reset() }
        transcription.setMetricsSession(newId)
        gate.continuation.finish()
        try await waitUntil { finished }
        #expect(stats.totalWords == 0)
        #expect(texts.isEmpty)
        #expect(errors == 0)
        #expect(transcription._testErrorSoundPlayCount == 0)
        let original = try #require(await metrics.activeSession(id: oldId))
        #expect(original.chunksSubmitted == 1)
        #expect(original.sttLatenciesMs.count == 1, "The suspended write must retain its original session ID")
        let replacement = try #require(await metrics.activeSession(id: newId))
        #expect(replacement.sttLatenciesMs.isEmpty)
        #expect(replacement.chunksSubmitted == 0)
        #expect(replacement.chunksSucceeded == 0 && replacement.chunksFailed == 0)
    }

    @MainActor @Test(arguments: [true, false], [true, false])
    func retiredResponseHasNoCurrentSessionEffects(cancel: Bool, fail: Bool) async throws {
        let stats = TestStatistics()
        let service = HeldTranscriptionService(fail: fail)
        let transcription = Transcription(statistics: stats, service: service)
        let bridge = transcription.queueBridge
        var finished = false
        var errors = 0
        var texts: [String] = []
        transcription.taskFinishedForTesting = { finished = true }
        bridge.onChunkError = { _ in errors += 1 }
        bridge.onTextReady = { texts.append($0) }
        defer {
            Task { await service.release() }
            bridge.stopListening()
            transcription.cancelAll()
        }
        let ticket = await bridge.nextSequence()
        transcription.transcribe(ticket: ticket, chunk: AudioChunk(wavData: Data([0]), durationSeconds: 1))
        try await waitUntilAsync { await service.started }
        try #require(await service.started)
        if cancel { transcription.cancelAll() } else { await bridge.reset() }
        await service.release()
        try await waitUntil { finished }
        try #require(finished)
        #expect(errors == 0)
        #expect(transcription._testErrorSoundPlayCount == 0)
        #expect(texts.isEmpty)
        #expect(stats.recordedLatencies.isEmpty)
        #expect(stats.totalWords == 0)
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
        // Cancellation retires delivery. A replacement batch explicitly starts
        // a fresh queue session, just as RecordingController does.
        await transcription.queueBridge.reset()

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

@Suite("TranscriptionQueueBridge — Session-Tagged Delivery", .serialized)
struct TranscriptionQueueSessionDeliveryTests {
    @MainActor @Test(arguments: [false, true])
    func retirementBetweenGenerationReadAndDeliveryDropsOldText(reset: Bool) async throws {
        let transcription = Transcription(statistics: TestStatistics())
        let bridge = transcription.queueBridge
        let gate = AsyncStream<Void>.makeStream()
        var deliverySuspended = false
        var delivered: [String] = []
        bridge.beforeTextDeliveryForTesting = {
            guard !deliverySuspended else { return }
            deliverySuspended = true
            for await _ in gate.stream {}
        }
        bridge.onTextReady = { delivered.append($0) }
        defer {
            gate.continuation.finish()
            bridge.stopListening()
            transcription.cancelAll()
        }
        let old = await bridge.nextSequence()
        await bridge.submitResult(ticket: old, text: "retired")
        try await waitUntil { deliverySuspended }
        try #require(deliverySuspended)
        if reset { await bridge.reset() } else { transcription.cancelAll() }
        gate.continuation.finish()
        // A sentinel in the same stream acknowledges consumption of the old item.
        if !reset { await bridge.reset() }
        let current = await bridge.nextSequence()
        await bridge.submitResult(ticket: current, text: "current")
        try await waitUntil { delivered.contains("current") }
        #expect(delivered == ["current"])
    }

    @MainActor @Test
    func allocationHeldAcrossResetCannotConsumeReplacementSequence() async throws {
        let bridge = TranscriptionQueueBridge()
        let gate = AsyncStream<Void>.makeStream()
        var entered = false
        bridge.beforeSequenceAllocationForTesting = {
            guard !entered else { return }
            entered = true
            for await _ in gate.stream {}
        }
        defer { gate.continuation.finish() }
        let oldTask = Task { @MainActor in await bridge.nextSequence() }
        try await waitUntil { entered }
        try #require(entered)
        await bridge.reset()
        let current = await bridge.nextSequence()
        await bridge.submitResult(ticket: current, text: "")
        #expect(await bridge.isIdle(), "Retired allocation must not hold replacement completion open")
        gate.continuation.finish()
        let old = await oldTask.value
        #expect(old.session != current.session, "A held allocation must retain its originating session")
        #expect(await bridge.getPendingCount() == 0, "Retired allocation must not leave a sequence hole")
    }

    @MainActor @Test
    func cancelAllRetiresBufferedDeliveryWithoutStartingAnotherBatch() async throws {
        let transcription = Transcription(statistics: TestStatistics())
        let bridge = transcription.queueBridge
        let gate = AsyncStream<Void>.makeStream()
        var deliveriesAttempted = 0
        var delivered: [String] = []
        bridge.beforeTextDeliveryForTesting = {
            deliveriesAttempted += 1
            if deliveriesAttempted == 1 {
                for await _ in gate.stream {}
            }
        }
        bridge.onTextReady = { delivered.append($0) }
        defer { gate.continuation.finish(); bridge.stopListening(); transcription.cancelAll() }
        let old = await bridge.nextSequence()
        let sentinel = await bridge.nextSequence()
        await bridge.submitResult(ticket: old, text: "retired")
        try await waitUntil { deliveriesAttempted == 1 }
        try #require(deliveriesAttempted == 1)
        transcription.cancelAll()
        await bridge.submitResult(ticket: sentinel, text: "also retired")
        gate.continuation.finish()
        try await waitUntil { deliveriesAttempted == 2 }
        try #require(deliveriesAttempted == 2)
        #expect(delivered.isEmpty)
    }

    /// Text yielded before a reset but consumed after it must not be delivered
    /// to the new session.
    @MainActor @Test
    func textBufferedBeforeResetIsNotDeliveredAfterIt() async throws {
        let bridge = TranscriptionQueueBridge()
        var delivered: [String] = []
        bridge.onTextReady = { delivered.append($0) }

        // The stream exists (a running bridge created it) but its consumer has
        // not caught up when the session resets.
        _ = await bridge.queue.textStream
        let old = await bridge.nextSequence()
        await bridge.submitResult(ticket: old, text: "old")
        await bridge.reset()

        bridge.startListening()
        defer { bridge.stopListening() }
        let new = await bridge.nextSequence()
        await bridge.submitResult(ticket: new, text: "new")
        try await waitUntil { !delivered.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(delivered == ["new"])
    }
}
