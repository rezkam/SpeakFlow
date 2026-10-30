import Foundation
import Testing
@testable import SpeakFlowCore

private actor ProviderBatchEngine: LocalBatchSpeechEngine {
    private(set) var received: [Float] = []
    func transcribe(samples: [Float]) async throws -> String { received = samples; return "fixture words" }
    func cleanup() async {}
}

private actor ProviderStreamingEngine: LocalStreamingSpeechEngine {
    private(set) var resets = 0
    private(set) var finishes = 0
    private(set) var calls = 0
    func reset() async throws { resets += 1; calls = 0 }
    func process(samples: [Float]) async throws -> String {
        calls += 1
        return calls == 1 ? "hello" : "yellow there"
    }
    func finish() async throws -> String { finishes += 1; return "yellow there now" }
    func cleanup() async {}
}

private actor ProviderEventRecorder {
    private(set) var partials: [String] = []
    private(set) var finals: [String] = []
    private(set) var speechFinals = 0
    private(set) var utteranceEnds = 0
    func record(_ event: TranscriptionEvent) {
        switch event {
        case .interim(let result): partials.append(result.transcript)
        case .finalResult(let result):
            finals.append(result.transcript)
            if result.isFinal && result.speechFinal { speechFinals += 1 }
        case .utteranceEnd: utteranceEnds += 1
        default: break
        }
    }
}

private actor ProviderPauseGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async { started = true; await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume(); waiter = nil }
}

private actor ProviderBlockedEngine: LocalStreamingSpeechEngine {
    let gate: ProviderPauseGate
    let holdFinal: Bool
    init(gate: ProviderPauseGate, holdFinal: Bool) { self.gate = gate; self.holdFinal = holdFinal }
    func reset() async throws {}
    func process(samples: [Float]) async throws -> String {
        if !holdFinal { await gate.wait() }
        return "late fixture words"
    }
    func finish() async throws -> String {
        if holdFinal { await gate.wait() }
        return "late fixture final"
    }
    func cleanup() async {}
}

@Suite("Local speech providers")
struct LocalSpeechProviderTests {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".agents/test-fixtures/local-provider-\(UUID().uuidString)") }
    private func model(_ id: LocalSpeechModelID) throws -> LocalSpeechModel {
        try #require(LocalSpeechCatalog.models().first { $0.id == id })
    }

    @Test func batchDecodesOnlyTheRecordingWAVAndRetainsItsModelIdentity() async throws {
        let engine = ProviderBatchEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in engine })
        let model = try model(.parakeet110M), lease = try await runtime.acquire(model)
        let provider = LocalBatchSpeechProvider(lease: lease)
        #expect(provider.id == model.providerID)
        #expect(provider.mode == .batch && provider.isConfigured)
        guard case .none = provider.authRequirement else { Issue.record("Local speech must not require credentials"); return }
        let wav = WavEncoder.encode(samples: [-1, -0.5, 0, 0.5, 1], sampleRate: 16000)
        #expect(try await provider.transcribe(audio: wav) == "fixture words")
        let samples = await engine.received
        #expect(samples.count == 5)
        #expect(abs(samples[1] + 0.5) < 0.001 && abs(samples[3] - 0.5) < 0.001)
        await lease.release()
        try await runtime.unload(model.id)
    }

    @Test(arguments: ["truncated", "wrong-rate", "wrong-size", "stereo", "odd-pcm"])
    func malformedAudioFailsBeforeInference(variant: String) async throws {
        let engine = ProviderBatchEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in engine })
        let model = try model(.parakeetV2), lease = try await runtime.acquire(model)
        let provider = LocalBatchSpeechProvider(lease: lease)
        var wav = WavEncoder.encode(samples: [0, 0.25, -0.25], sampleRate: 16000)
        switch variant {
        case "truncated": wav = Data(wav.prefix(43))
        case "wrong-rate": wav[24] = 0
        case "wrong-size": wav[40] = 0
        case "stereo": wav[22] = 2
        default: wav.append(0)
        }
        await #expect(throws: LocalSpeechAudioError.invalidAudio) { try await provider.transcribe(audio: wav) }
        #expect(await engine.received.isEmpty)
        await lease.release()
        try await runtime.unload(model.id)
    }

    @Test func streamingPublishesCumulativeCorrectionsAndExactlyOneTrailingFinal() async throws {
        let engine = ProviderStreamingEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in engine })
        let model = try model(.nemotron1120), lease = try await runtime.acquire(model)
        let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
        #expect(provider.id == model.providerID && provider.mode == .streaming)
        let session = try await provider.startSession(config: await provider.buildSessionConfig())
        let recorder = ProviderEventRecorder()
        let reader = Task { for await event in session.events { await recorder.record(event) } }
        try await session.sendAudio(Data([0, 0, 0, 32]))
        try await waitUntilAsync { await recorder.partials.count == 1 }
        try await session.sendAudio(Data([0, 0]))
        try await waitUntilAsync { await recorder.partials.count == 2 }
        try await session.finalize()
        try await session.finalize()
        try await session.close()
        await reader.value
        #expect(await recorder.partials == ["hello", "yellow there"])
        #expect(await recorder.finals == ["yellow there now"])
        #expect(await recorder.speechFinals == 1)
        #expect(await recorder.utteranceEnds == 0)
        #expect(await engine.resets == 1)
        #expect(await engine.finishes == 1)
        // The recording owns its model through insertion and submit, after transport closes.
        #expect(await runtime.snapshot().inUse == [model.id])
        await lease.release()
        try await runtime.unload(model.id)
    }

    @Test func localSessionRejectsWrongEncodingAndCannotBeStartedTwice() async throws {
        let engine = ProviderStreamingEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in engine })
        let model = try model(.nemotron1120), lease = try await runtime.acquire(model)
        let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
        await #expect(throws: LocalSpeechAudioError.invalidAudio) {
            _ = try await provider.startSession(config: StreamingSessionConfig(encoding: .opus))
        }
        let session = try await provider.startSession(config: await provider.buildSessionConfig())
        await #expect(throws: LocalModelError.busy) { _ = try await provider.startSession(config: await provider.buildSessionConfig()) }
        await #expect(throws: LocalSpeechAudioError.invalidAudio) { try await session.sendAudio(Data([0])) }
        try await session.close()
        await #expect(throws: CancellationError.self) { try await session.sendAudio(Data([0, 0])) }
        await lease.release()
        try await runtime.unload(model.id)
    }

    @Test(arguments: [false, true])
    func closeRetiresCallbacksImmediatelyWhileNativeWorkFinishes(holdFinal: Bool) async throws {
        let gate = ProviderPauseGate()
        let engine = ProviderBlockedEngine(gate: gate, holdFinal: holdFinal)
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in engine })
        let model = try model(.nemotron1120), lease = try await runtime.acquire(model)
        let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
        let session = try await provider.startSession(config: await provider.buildSessionConfig())
        let recorder = ProviderEventRecorder()
        let reader = Task { for await event in session.events { await recorder.record(event) } }
        let work = Task {
            if holdFinal { try await session.finalize() } else { try await session.sendAudio(Data([0, 0])) }
        }
        try await waitUntilAsync { await gate.started }
        try await session.close()
        await lease.release()
        #expect(await runtime.snapshot().inUse == [model.id])
        await gate.open()
        await #expect(throws: LocalSpeechRuntimeError.expiredLease) { try await work.value }
        await reader.value
        #expect(await recorder.partials.isEmpty)
        #expect(await recorder.finals.isEmpty)
        #expect(await runtime.snapshot().inUse.isEmpty)
        try await runtime.unload(model.id)
    }

    @MainActor @Test func normalStopDrainsNativeAudioAndDeliversItsFinalThroughTheExistingController() async throws {
        let engine = ProviderStreamingEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in engine })
        let model = try model(.nemotron1120), lease = try await runtime.acquire(model)
        let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
        let controller = LiveStreamingController(skipAudioCaptureForTesting: true)
        controller.keepAliveEnabled = false
        controller.reconnectEnabled = false
        controller.autoEndSilenceDuration = 0
        controller.turnStartStrategies = [.firstTranscription]
        var finals: [String] = []
        controller.onTextUpdate = { _, _, isFinal, fullText in if isFinal { finals.append(fullText) } }
        #expect(await controller.start(provider: provider, config: provider.buildSessionConfig()))
        controller._testEnqueueAudioFrame(Data([0, 0]))
        controller._testEnqueueAudioFrame(Data([0, 0]))
        await controller.stop(trailingFinalTimeout: 0)
        #expect(await engine.calls == 2)
        #expect(await engine.finishes == 1)
        #expect(finals == ["yellow there now"])
        #expect(controller._testAudioCaptureIsNil)
        #expect(await runtime.snapshot().inUse == [model.id])
        await lease.release()
        try await runtime.unload(model.id)
    }

}
