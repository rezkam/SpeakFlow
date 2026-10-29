import Foundation
import Testing
@testable import SpeakFlowCore
@testable import SpeakFlow

@MainActor
private final class EventDeliveryGate {
    var entered = false
    private var held: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { held = $0 }
    }
    func release() { held?.resume(); held = nil }
}

private actor CloseFinalSession: StreamingSession {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private(set) var closed = false
    let finishes: Bool
    init(finishes: Bool = true) {
        let pair = AsyncStream<TranscriptionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.finishes = finishes
    }
    func sendAudio(_ data: Data) async throws {}
    func keepAlive() async throws {}
    func finalize() async throws {}
    func close() async throws {
        continuation.yield(.finalResult(.init(transcript: "terminal words", isFinal: true, speechFinal: true)))
        closed = true
        if finishes { continuation.finish() }
    }
    func finish() { continuation.finish() }
}

@Suite("Controller asynchronous terminal event drain", .serialized)
struct StreamingEventDrainTests {
    @Test @MainActor
    func stopWaitsForActualDeliveryBeforeReturning() async throws {
        let session = CloseFinalSession()
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        let collector = TextUpdateCollector()
        collector.wire(controller)
        let gate = EventDeliveryGate()
        controller.beforeEventDelivery = { await gate.pause() }
        try #require(await controller.start(provider: provider, config: .default))
        var stopped = false
        let stopping = Task { await controller.stop(trailingFinalTimeout: 0); stopped = true }
        try await waitUntilAsync { await session.closed }
        try await waitUntil { gate.entered }
        // Allow stop's close continuation to resume while the listener is held.
        try await Task.sleep(for: .milliseconds(30))
        #expect(!stopped, "Provider yield/close is not controller delivery acknowledgement")
        #expect(collector.finals.isEmpty)
        gate.release()
        await stopping.value
        #expect(collector.finals.map(\.fullText) == ["terminal words"])
        #expect(collector.finals.flatMap { $0.fullText.split(separator: " ") }.count == 2)
    }

    @Test(arguments: [false, true]) @MainActor
    func closeFinalReachesInsertionAndAccountingBeforeSubmit(expire: Bool) async throws {
        let session = CloseFinalSession()
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let providerSettings = SpyProviderSettings()
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "synthetic-key"
        let registry = SpyProviderRegistry()
        registry.register(provider)
        let settings = SpySettings()
        settings.streamingTrailingFinalTimeout = 0
        settings.streamingKeepAliveEnabled = false
        let (recording, _, inserter, _) = makeTestRecordingController(
            providerSettings: providerSettings, providerRegistry: registry, settings: settings
        )
        let initialWords = Statistics.shared.totalWords
        recording.startRecording()
        defer { recording.cancelRecording() }
        try await waitUntil { recording.liveStreamingController?.isActive == true }
        let metricsId = try #require(recording.testCurrentMetricsSessionId)
        let controller = try #require(recording.liveStreamingController)
        let gate = EventDeliveryGate()
        if expire { controller.controlMessageTimeout = 0.05 }
        controller.beforeEventDelivery = { await gate.pause() }
        recording.stopRecordingAndSubmit()
        try await waitUntil { gate.entered }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!inserter.operations.contains(.pressEnterKey))
        #expect(Statistics.shared.totalWords == initialWords)
        if expire {
            try await waitUntil { !recording.isProcessingFinal }
            gate.release()
            #expect(!inserter.operations.contains(.pressEnterKey), "A final-delivery timeout must not submit incomplete text")
            return
        }
        gate.release()
        try await waitUntil { !recording.isProcessingFinal }
        #expect(inserter.insertedTexts.joined() == "terminal words ")
        #expect(inserter.operations.count { $0 == .pressEnterKey } == 1)
        let textIndex = try #require(inserter.operations.firstIndex(of: .insertText("terminal words ")))
        let enterIndex = try #require(inserter.operations.firstIndex(of: .pressEnterKey))
        #expect(textIndex < enterIndex)
        #expect(Statistics.shared.totalWords == initialWords + 2)
        let completed = await SessionMetricsStore.shared.recentCompletedSessions(limit: 200)
        let metrics = try #require(completed.first { $0.sessionId == metricsId })
        #expect(metrics.wordsProduced == 2)
    }

    @Test @MainActor
    func nonterminatingStreamDoesNotHoldStopForever() async throws {
        let session = CloseFinalSession(finishes: false)
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        controller.controlMessageTimeout = 0.05
        try #require(await controller.start(provider: provider, config: .default))
        let started = ContinuousClock.now
        await controller.stop(trailingFinalTimeout: 0)
        #expect(ContinuousClock.now - started < .seconds(1))
        await session.finish()
    }

    @Test @MainActor
    func deadlineRetiresHeldDelivery() async throws {
        let session = CloseFinalSession()
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        controller.controlMessageTimeout = 0.05
        let collector = TextUpdateCollector()
        collector.wire(controller)
        let gate = EventDeliveryGate()
        controller.beforeEventDelivery = { await gate.pause() }
        try #require(await controller.start(provider: provider, config: .default))
        await controller.stop(trailingFinalTimeout: 0)
        #expect(gate.entered)
        gate.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(collector.finals.isEmpty, "Timed-out delivery cannot run after terminal settlement")
    }

    @Test(arguments: [false, true]) @MainActor
    func cancellationDiscardsDequeuedFinal(replace: Bool) async throws {
        let session = CloseFinalSession()
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        let collector = TextUpdateCollector()
        collector.wire(controller)
        let gate = EventDeliveryGate()
        controller.beforeEventDelivery = { await gate.pause() }
        try #require(await controller.start(provider: provider, config: .default))
        let stopping = Task { await controller.stop(trailingFinalTimeout: 0) }
        try await waitUntil { gate.entered }
        await controller.cancel()
        controller.beforeEventDelivery = nil
        if replace {
            provider.mockSession = MockStreamingSession()
            try #require(await controller.start(provider: provider, config: .default))
        }
        gate.release()
        await stopping.value
        // Let the cancelled listener resume from the held dequeue boundary.
        try await Task.sleep(for: .milliseconds(20))
        #expect(collector.finals.isEmpty)
        if replace { #expect(controller.isActive) }
        await controller.cancel()
    }
}
