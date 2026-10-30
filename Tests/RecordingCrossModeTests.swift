import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

private actor HeldCrossModeBatchProvider: BatchTranscriptionProvider {
    nonisolated let id = ProviderId.mistralBatch
    nonisolated let displayName = "Synthetic Batch"
    nonisolated let mode: ProviderMode = .batch
    nonisolated let isConfigured = true
    nonisolated let authRequirement: ProviderAuthRequirement = .apiKey(providerId: ProviderId.mistralBatch)
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func transcribe(audio: Data) async throws -> String {
        await withCheckedContinuation { continuation = $0; started = true }
        return "batch result"
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Recording cross-mode ownership", .serialized)
struct RecordingCrossModeTests {
    @MainActor
    private struct Fixture {
        let controller: RecordingController
        let batch: HeldCrossModeBatchProvider
        let stream: MockStreamingSession
        let providers: SpyProviderSettings
        let transcription: Transcription
        let inserter: SpyTextInserter
        let settings: SpySettings
    }

    @MainActor private func fixture() -> Fixture {
        let providers = SpyProviderSettings()
        providers.storedKeys[ProviderId.deepgram] = "synthetic-key"
        providers.storedKeys[ProviderId.mistralBatch] = "synthetic-key"
        let registry = SpyProviderRegistry()
        let batch = HeldCrossModeBatchProvider()
        let streaming = MockStreamingProvider()
        let stream = MockStreamingSession()
        streaming.mockSession = stream
        registry.register(batch)
        registry.register(streaming)
        let settings = SpySettings()
        settings.streamingTrailingFinalTimeout = 0
        settings.streamingKeepAliveEnabled = false
        let transcription = Transcription()
        let inserter = SpyTextInserter()
        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(), textInserter: inserter, appState: SpyBannerPresenter(),
            providerSettings: providers, providerRegistry: registry, settings: settings,
            transcription: transcription, playSoundEffect: { _ in }
        )
        controller.testMode = .live
        controller.setupTranscriptionCallbacks()
        return Fixture(controller: controller, batch: batch, stream: stream,
                       providers: providers, transcription: transcription, inserter: inserter, settings: settings)
    }

    @MainActor private func stopBatchWithAudio(_ fixture: Fixture) async throws {
        let recorder = try #require(fixture.controller.recorder)
        try await waitUntil { recorder._testIsRecording }
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.2, count: 32_000))
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetVADActive(false)
        fixture.controller.stopRecordingAndSubmit()
        try await waitUntilAsync { await fixture.batch.started }
    }

    @Test @MainActor
    func deadlineRetiresBatchDeliveryBeforePendingSubmitReleasesOwnership() async throws {
        let f = fixture()
        let enterGate = AsyncStream<Void>.makeStream()
        let enterTask = Task { for await _ in enterGate.stream {} }
        f.inserter.pendingTaskAfterEnter = enterTask
        defer {
            enterGate.continuation.finish()
            f.controller.cancelRecording()
            Task { await f.batch.release() }
        }
        f.settings.batchFinalizationTimeoutBase = 0.01
        f.settings.batchFinalizationTimeoutPerChunkSecond = 0
        f.settings.batchFinalizationMaxTimeout = 0.01
        f.providers.activeProviderId = ProviderId.mistralBatch
        f.controller.startRecording()
        try await stopBatchWithAudio(f)
        try await waitUntil { f.inserter.enterKeyPressed }
        #expect(f.controller.isProcessingFinal)
        var responseFinished = false
        f.transcription.taskFinishedForTesting = { responseFinished = true }
        await f.batch.release()
        try await waitUntil { responseFinished }
        try await waitUntilAsync { await f.transcription.queueBridge.isIdle() }

        #expect(f.inserter.insertedTexts.isEmpty)
        #expect(f.inserter.bulkInsertedTexts.isEmpty, "Expired batch delivery must not type after its submit has been queued")
        #expect(f.controller.fullTranscript.isEmpty, "Expired results must not enter session accounting")
        enterGate.continuation.finish()
        await enterTask.value
        try await waitUntil { !f.controller.isProcessingFinal }
    }

    @Test @MainActor
    func retiredBatchResponseCannotTypeOrSubmitIntoStreamingRecording() async throws {
        let f = fixture()
        defer { f.controller.cancelRecording(); Task { await f.batch.release() } }
        f.providers.activeProviderId = ProviderId.mistralBatch
        f.controller.startRecording()
        try await stopBatchWithAudio(f)
        var responseFinished = false
        f.transcription.taskFinishedForTesting = { responseFinished = true }
        f.controller.cancelRecording()
        f.providers.activeProviderId = ProviderId.deepgram
        f.controller.startRecording()
        try await waitUntil { f.controller.liveStreamingController?.isActive == true }
        await f.batch.release()
        try await waitUntil { responseFinished }
        await f.stream.emit(.finalResult(TranscriptionResult(
            transcript: "stream result", isFinal: true, speechFinal: true
        )))
        try await waitUntil { f.inserter.insertedTexts.joined() == "stream result " }
        #expect(f.controller.isRecording)
        #expect(f.controller.fullTranscript == "stream result")
        #expect(!f.inserter.enterKeyPressed)
        #expect(f.inserter.deletedCounts.isEmpty)
    }

    @Test @MainActor
    func retiredStreamingCallbackCannotTypeOrSubmitIntoBatchRecording() async throws {
        let f = fixture()
        defer { f.controller.cancelRecording(); Task { await f.batch.release() } }
        f.providers.activeProviderId = ProviderId.deepgram
        f.controller.startRecording()
        try await waitUntil { f.controller.liveStreamingController?.isActive == true }
        let retired = try #require(f.controller.liveStreamingController?.onTextUpdate)
        f.controller.cancelRecording()
        f.providers.activeProviderId = ProviderId.mistralBatch
        f.controller.startRecording()
        try await stopBatchWithAudio(f)
        retired("retired text", 50, true, "retired text")
        await f.batch.release()
        try await waitUntil { !f.controller.isProcessingFinal }
        #expect(f.inserter.bulkInsertedTexts.joined().trimmingCharacters(in: .whitespaces) == "batch result")
        #expect(f.inserter.deletedCounts.isEmpty)
        #expect(f.inserter.operations.filter { $0 == .pressEnterKey }.count == 1)
        let text = try #require(f.inserter.operations.firstIndex { if case .insertTextInBulk = $0 { return true }; return false })
        let enter = try #require(f.inserter.operations.firstIndex(of: .pressEnterKey))
        #expect(text < enter)
    }
}
