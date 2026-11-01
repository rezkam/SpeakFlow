import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

private struct IndependentCloudBatch: BatchTranscriptionProvider {
    let id: String
    let displayName = "Cloud fixture"
    let mode: ProviderMode = .batch
    let isConfigured = true
    let authRequirement: ProviderAuthRequirement = .none
    func transcribe(audio: Data) async throws -> String { "fixture text" }
}

@Suite("Cloud provider independence", .serialized)
struct CloudProviderIndependenceTests {
    @MainActor @Test func cloudRecordingSkipsNativeVADInitializationWhenOptionalAssetsAreAbsent() async {
        let settings = SpySettings()
        settings.vadEnabled = true
        let recorder = StreamingRecorder(settings: settings, localVADEnabled: false)
        recorder.forceVADInitializationForTesting = true
        recorder.beforeVADInitializationForTesting = {
            Issue.record("A cloud recording without optional VAD must never enter the model loader")
            throw LocalModelError.missingVAD
        }
        #expect(await recorder.start())
        #expect(settings.vadEnabled)
        recorder.cancel()
        await recorder.waitForStopCompletion()
    }

    @MainActor @Test func verifiedOptionalVADRemainsEnabledForCloudBatch() async throws {
        let registry = SpyProviderRegistry(), providers = SpyProviderSettings()
        registry.register(IndependentCloudBatch(id: ProviderId.chatGPT))
        providers.activeProviderId = ProviderId.chatGPT
        let text = SpyTextInserter()
        text.targetPid = 42
        var validations = 0
        let controller = RecordingController(keyInterceptor: SpyKeyInterceptor(), textInserter: text,
            appState: SpyBannerPresenter(), providerSettings: providers, providerRegistry: registry,
            settings: SpySettings(), transcription: SpyTranscription(), playSoundEffect: { _ in },
            validateModelAssets: { _, _ in validations += 1 })
        controller.testMode = .live
        controller.startRecording()
        defer { controller.cancelRecording() }
        try await waitUntil { controller.recorder?._testIsRecording == true }
        #expect(validations == 1)
        #expect(controller.recorder?.localVADEnabled == true)
    }

    @MainActor @Test(arguments: [ProviderId.chatGPT, ProviderId.mistralBatch, ProviderId.deepgram], [false, true])
    func cloudStartsWithoutLocalAssetsEvenDuringModelOperations(id: String, modelBusy: Bool) async throws {
        let registry = SpyProviderRegistry(), providers = SpyProviderSettings(), settings = SpySettings()
        let provider: any TranscriptionProvider = id == ProviderId.deepgram
            ? MockStreamingProvider() : IndependentCloudBatch(id: id)
        registry.register(provider)
        providers.activeProviderId = id
        settings.vadEnabled = true
        let text = SpyTextInserter(), keys = SpyKeyInterceptor(), banner = SpyBannerPresenter(), transcription = SpyTranscription()
        text.targetPid = 42
        var validations = 0
        let controller = RecordingController(keyInterceptor: keys, textInserter: text, appState: banner,
            providerSettings: providers, providerRegistry: registry, settings: settings, transcription: transcription,
            playSoundEffect: { _ in }, validateModelAssets: { _, _ in
                validations += 1
                throw LocalModelError.missingVAD
            })
        controller.testMode = .live
        controller.modelOperationInProgress = { modelBusy }
        controller.startRecording()
        defer { controller.cancelRecording() }
        #expect(controller.isRecording)
        #expect(text.captureTargetCalled && keys.startCallCount == 1)
        #expect(!controller.isPreparingLocalModel)
        #expect(!banner.bannerMessages.contains { $0.1 == .error })
        #expect(settings.vadEnabled, "Keep the saved preference unchanged")
        if provider.mode == .batch {
            try await waitUntil { controller.recorder?._testIsRecording == true }
            #expect(transcription.activeBatchProvider?.id == id)
            #expect(controller.recorder?.localVADEnabled == false)
            #expect(banner.bannerMessages.contains { $0.1 == .info })
        } else {
            #expect(validations == 0, "Cloud streaming must not inspect local VAD assets")
        }
    }
}
