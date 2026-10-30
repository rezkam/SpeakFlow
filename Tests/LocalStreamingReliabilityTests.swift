import Foundation
import Testing
@testable import SpeakFlowCore

private actor SlowLocalEngine: LocalStreamingSpeechEngine {
    var waiter: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func reset() async throws {}
    func process(samples: [Float]) async throws -> String {
        started = true
        await withCheckedContinuation { waiter = $0 }
        return "fixture words"
    }
    func finish() async throws -> String { "fixture words" }
    func cleanup() async {}
    func open() { waiter?.resume(); waiter = nil }
}

@Suite("Local streaming reliability", .serialized)
struct LocalStreamingReliabilityTests {
    @MainActor @Test func overflowReportsFailureInsteadOfSilentlyDroppingAudio() async throws {
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == .nemotron1120 })
        let engine = SlowLocalEngine()
        let runtime = LocalSpeechRuntime(root: URL(fileURLWithPath: "/synthetic-model"),
            verify: { _, root in root }, load: { _, _ in engine })
        let lease = try await runtime.acquire(model)
        let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
        let controller = LiveStreamingController(skipAudioCaptureForTesting: true)
        controller.keepAliveEnabled = false
        controller.reconnectEnabled = false
        var failures = 0
        controller.onError = { _ in failures += 1 }
        #expect(await controller.start(provider: provider, config: provider.buildSessionConfig()))
        controller._testEnqueueAudioFrame(Data(repeating: 0, count: 32_000))
        try await waitUntilAsync { await engine.started }
        for _ in 0..<40 { controller._testEnqueueAudioFrame(Data(repeating: 0, count: 32_000)) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(failures == 1)
        #expect(controller._testDroppedAudioChunkCount == 0)
        #expect(!controller.recording)
        await engine.open()
        await controller.cancel()
        await lease.release()
    }
}

private actor FailingLocalFinalEngine: LocalStreamingSpeechEngine {
    func reset() async throws {}
    func process(samples: [Float]) async throws -> String { "fixture words" }
    func finish() async throws -> String { throw LocalSpeechRuntimeError.inferenceFailed }
    func cleanup() async {}
}

extension LocalStreamingReliabilityTests {
    @MainActor @Test func nativeFinalizationFailureCannotCountAsSuccessfulDelivery() async throws {
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == .nemotron1120 })
        let engine = FailingLocalFinalEngine()
        let runtime = LocalSpeechRuntime(root: URL(fileURLWithPath: "/synthetic-model"),
            verify: { _, root in root }, load: { _, _ in engine })
        let lease = try await runtime.acquire(model)
        let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
        let controller = LiveStreamingController(skipAudioCaptureForTesting: true)
        controller.keepAliveEnabled = false
        var failures = 0
        controller.onError = { _ in failures += 1 }
        #expect(await controller.start(provider: provider, config: provider.buildSessionConfig()))
        await controller.stop(trailingFinalTimeout: 0)
        #expect(failures == 1)
        #expect(!controller.finalEventDeliveryCompleted)
        await lease.release()
    }

    @MainActor @Test func stalledNativeAudioDrainCannotFinalizePartialAudioAsSuccess() async throws {
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == .nemotron1120 })
        let engine = SlowLocalEngine()
        let runtime = LocalSpeechRuntime(root: URL(fileURLWithPath: "/synthetic-model"),
            verify: { _, root in root }, load: { _, _ in engine })
        let lease = try await runtime.acquire(model)
        let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
        let controller = LiveStreamingController(skipAudioCaptureForTesting: true)
        controller.keepAliveEnabled = false
        controller.stopDrainTimeout = .milliseconds(30)
        var failures = 0, finals = 0
        controller.onError = { _ in failures += 1 }
        controller.onTextUpdate = { _, _, final, _ in if final { finals += 1 } }
        #expect(await controller.start(provider: provider, config: provider.buildSessionConfig()))
        controller._testEnqueueAudioFrame(Data([0, 0]))
        try await waitUntilAsync { await engine.started }
        await controller.stop(trailingFinalTimeout: 0)
        #expect(failures == 1)
        #expect(!controller.finalEventDeliveryCompleted)
        #expect(finals == 0)
        await engine.open()
        await lease.release()
    }
}
