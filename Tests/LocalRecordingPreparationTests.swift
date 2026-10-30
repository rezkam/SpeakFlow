import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

private actor RecordingLoadGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async { started = true; await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume(); waiter = nil }
}
private actor RecordingLocalEngine: LocalBatchSpeechEngine, LocalStreamingSpeechEngine {
    private(set) var cleanups = 0
    func transcribe(samples: [Float]) async throws -> String { "fixture text" }
    func reset() async throws {}
    func process(samples: [Float]) async throws -> String { "fixture text" }
    func finish() async throws -> String { "fixture final" }
    func cleanup() async { cleanups += 1 }
}

@Suite("Local recording preparation")
struct LocalRecordingPreparationTests {
    @MainActor private struct Fixture {
        let controller: RecordingController
        let key: SpyKeyInterceptor
        let text: SpyTextInserter
        let banner: SpyBannerPresenter
        let providerSettings: SpyProviderSettings
        let runtime: LocalSpeechRuntime
        let gate: RecordingLoadGate
        let engine: RecordingLocalEngine
    }

    @MainActor private func setup(_ id: LocalSpeechModelID = .parakeet110M) throws -> Fixture {
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == id })
        let gate = RecordingLoadGate(), engine = RecordingLocalEngine()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/pending-recording-\(UUID().uuidString)")
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory },
            load: { _, _ in await gate.wait(); return engine })
        let availability = LocalSpeechAvailability()
        availability.setReady(true)
        let provider = LocalRecordingProvider(model: model, runtime: runtime, availability: availability)
        let registry = SpyProviderRegistry(), providerSettings = SpyProviderSettings(), settings = SpySettings()
        settings.vadEnabled = false
        registry.register(provider)
        providerSettings.activeProviderId = provider.id
        let (controller, key, text, banner) = makeTestRecordingController(providerSettings: providerSettings,
            providerRegistry: registry, settings: settings)
        text.targetPid = 42
        return Fixture(controller: controller, key: key, text: text, banner: banner,
            providerSettings: providerSettings, runtime: runtime, gate: gate, engine: engine)
    }

    @MainActor @Test(arguments: ["enter", "escape", "hotkey"])
    func pendingStartKeepsTheMicrophoneOffAndCancelsWithoutSubmit(action: String) async throws {
        let fixture = try setup()
        let controller = fixture.controller, key = fixture.key
        let text = fixture.text
        let runtime = fixture.runtime
        let gate = fixture.gate, engine = fixture.engine
        controller.startRecording()
        #expect(controller.isPreparingLocalModel)
        #expect(!controller.isRecording && controller.recorder == nil && controller.liveStreamingController == nil)
        #expect(key.pendingStartCallCount == 1 && key.startCallCount == 0)
        try await waitUntilAsync { await gate.started }
        switch action {
        case "enter": key.onEnterPressed?()
        case "escape": key.onEscapePressed?()
        default: controller.toggle()
        }
        #expect(!controller.isPreparingLocalModel && !controller.isRecording)
        #expect(!text.enterKeyPressed)
        await gate.open()
        try await waitUntilAsync { await engine.cleanups == 1 }
        #expect(await runtime.snapshot().inUse.isEmpty)
    }

    @MainActor @Test(arguments: ["focus", "provider", "shutdown"])
    func latePreparationCannotStartAfterItsTargetOrOwnerChanged(change: String) async throws {
        let fixture = try setup()
        let controller = fixture.controller
        let text = fixture.text
        let providerSettings = fixture.providerSettings, runtime = fixture.runtime
        let gate = fixture.gate
        controller.startRecording()
        try await waitUntilAsync { await gate.started }
        switch change {
        case "focus": text.targetIsFrontmost = false
        case "provider": providerSettings.activeProviderId = "fixture-other"
        default: controller.shutdown()
        }
        await gate.open()
        try await waitUntilAsync { @MainActor in !controller.isPreparingLocalModel }
        #expect(!controller.isRecording && controller.recorder == nil && controller.liveStreamingController == nil)
        #expect(!text.enterKeyPressed)
        try await waitUntilAsync { await runtime.snapshot().inUse.isEmpty }
    }

    @MainActor @Test func aPreparedNativeSessionStartsThroughTheExistingRecordingFlow() async throws {
        let fixture = try setup(.nemotron1120)
        let controller = fixture.controller, key = fixture.key
        let text = fixture.text
        let runtime = fixture.runtime
        let gate = fixture.gate
        controller.startRecording()
        try await waitUntilAsync { await gate.started }
        #expect(controller.liveStreamingController == nil)
        await gate.open()
        try await waitUntilAsync { @MainActor in controller.liveStreamingController?.recording == true }
        #expect(controller.isRecording && !controller.isPreparingLocalModel)
        #expect(key.startCallCount == 1 && key.pendingStartCallCount == 1)
        #expect(controller.liveStreamingController?.keepAliveEnabled == false)
        #expect(controller.liveStreamingController?.reconnectEnabled == false)
        #expect(text.operations.filter { $0 == .captureTarget }.count == 1)
        controller.cancelRecording()
        try await waitUntilAsync { await runtime.snapshot().inUse.isEmpty }
        try await runtime.unload(.nemotron1120)
    }

    @MainActor @Test func unavailableKeyboardCancellationRefusesPreparation() async throws {
        let fixture = try setup()
        let controller = fixture.controller, key = fixture.key
        let text = fixture.text, banner = fixture.banner
        let runtime = fixture.runtime
        let gate = fixture.gate
        key.pendingStartSucceeds = false
        controller.startRecording()
        #expect(!controller.isPreparingLocalModel && !controller.isRecording)
        #expect(controller.recorder == nil && controller.liveStreamingController == nil)
        #expect(await gate.started == false)
        #expect(await runtime.snapshot().loading == nil)
        #expect(banner.bannerMessages.count == 1)
        #expect(!text.enterKeyPressed)
    }

    @MainActor @Test func pendingEnterDrainedAtReadinessCannotTurnIntoARecordingSubmit() async throws {
        let fixture = try setup()
        let controller = fixture.controller, key = fixture.key
        let text = fixture.text
        let runtime = fixture.runtime
        let gate = fixture.gate
        controller.startRecording()
        try await waitUntilAsync { await gate.started }
        key.onStop = { key.onEnterPressed?() }
        await gate.open()
        try await waitUntilAsync { @MainActor in !controller.isPreparingLocalModel }
        #expect(!controller.isRecording && controller.recorder == nil)
        #expect(!text.enterKeyPressed)
        try await waitUntilAsync { await runtime.snapshot().inUse.isEmpty }
    }

}


extension LocalRecordingPreparationTests {
    @MainActor @Test func sleepCancelsPendingPreparationWithoutSubmitOrAutomaticRestart() async throws {
        let fixture = try setup()
        let controller = fixture.controller, gate = fixture.gate, text = fixture.text
        controller.startRecording()
        try await waitUntilAsync { await gate.started }
        controller.prepareForSystemSleep()
        #expect(!controller.isPreparingLocalModel && !controller.isRecording)
        #expect(!text.enterKeyPressed)
        await gate.open()
        try await waitUntilAsync { await fixture.engine.cleanups == 1 }
        #expect(!controller.isRecording && controller.recorder == nil)
    }
}


extension LocalRecordingPreparationTests {
    @MainActor @Test func oneDeadlineBoundsTheWholePendingStartAndKeepsTheMicrophoneOff() async throws {
        let fixture = try setup()
        let controller = fixture.controller, gate = fixture.gate
        controller.localPreparationTimeout = .milliseconds(30)
        controller.startRecording()
        try await waitUntilAsync { await gate.started }
        try await waitUntil { !controller.isPreparingLocalModel }
        #expect(!controller.isRecording && controller.recorder == nil)
        #expect(fixture.banner.bannerMessages.last?.0 == LocalSpeechRuntimeError.loadTimedOut.localizedDescription)
        #expect(!fixture.text.enterKeyPressed)
        await gate.open()
        try await waitUntilAsync { await fixture.engine.cleanups == 1 }
        #expect(!controller.isRecording)
    }
}

extension LocalRecordingPreparationTests {
    @MainActor @Test func localBatchFailureCancelsTheSessionAndWithholdsSubmit() async throws {
        let fixture = try setup()
        let controller = fixture.controller, gate = fixture.gate
        controller.setupTranscriptionCallbacks()
        controller.startRecording()
        try await waitUntilAsync { await gate.started }
        await gate.open()
        try await waitUntil { controller.recorder?._testIsRecording == true }
        controller.shouldPressEnterOnComplete = true
        controller.transcription.queueBridge.onChunkError?(LocalSpeechRuntimeError.inferenceFailed)
        #expect(!controller.isRecording && !controller.isProcessingFinal)
        #expect(!controller.shouldPressEnterOnComplete && !fixture.text.enterKeyPressed)
        controller.cancelRecording()
    }
}

extension LocalRecordingPreparationTests {
    @MainActor @Test func captureOverflowCancelsLocalBatchBeforeAnySubmit() async throws {
        let fixture = try setup()
        let controller = fixture.controller, gate = fixture.gate
        controller.startRecording()
        try await waitUntilAsync { await gate.started }
        await gate.open()
        try await waitUntil { controller.recorder?._testIsRecording == true }
        let recorder = try #require(controller.recorder)
        controller.shouldPressEnterOnComplete = true
        for _ in 0..<101 { recorder._testEnqueueSamples([0]) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!controller.isRecording && !controller.isProcessingFinal)
        #expect(!fixture.text.enterKeyPressed && !controller.shouldPressEnterOnComplete)
        #expect(fixture.banner.bannerMessages.last?.0 == LocalSpeechRuntimeError.audioBacklog.localizedDescription)
        controller.cancelRecording()
        await recorder.waitForStopCompletion()
    }
}

extension LocalRecordingPreparationTests {
    @MainActor @Test func aLocalFinalizationDeadlineWithholdsSubmitAndReportsFailure() async throws {
        let fixture = try setup()
        let controller = fixture.controller, gate = fixture.gate
        let settings = try #require(controller.settings as? SpySettings)
        settings.batchFinalizationTimeoutBase = 0.03
        settings.batchFinalizationTimeoutPerChunkSecond = 0
        settings.batchFinalizationMaxTimeout = 0.03
        controller.startRecording()
        try await waitUntilAsync { await gate.started }
        await gate.open()
        try await waitUntil { controller.recorder?._testIsRecording == true }
        _ = await controller.transcription.queueBridge.nextSequence()
        controller.stopRecordingAndSubmit()
        try await waitUntil { !controller.isRecording && !controller.isProcessingFinal }
        #expect(!fixture.text.enterKeyPressed)
        #expect(fixture.banner.bannerMessages.last?.1 == .error)
    }
}
