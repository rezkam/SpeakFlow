import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Local VAD readiness")
struct LocalVADReadinessTests {
    @Test @MainActor func missingVADRefusesStartBeforeCapturingTargetOrKeys() {
        let registry = SpyProviderRegistry()
        registry.register(StubProvider(id: "batch-fixture", mode: .batch, isConfigured: true))
        let providerSettings = SpyProviderSettings()
        providerSettings.activeProviderId = "batch-fixture"
        let text = SpyTextInserter(), keys = SpyKeyInterceptor(), banner = SpyBannerPresenter()
        let controller = RecordingController(keyInterceptor: keys, textInserter: text, appState: banner,
            providerSettings: providerSettings, providerRegistry: registry, settings: SpySettings(),
            playSoundEffect: { _ in }, validateModelAssets: { _, _ in throw LocalModelError.missingVAD })
        controller.testMode = .live
        controller.startRecording()
        #expect(!controller.isRecording)
        #expect(!text.captureTargetCalled)
        #expect(keys.startCallCount == 0)
        #expect(banner.bannerMessages.last?.0 == LocalModelError.missingVAD.localizedDescription)
    }

    @Test @MainActor func missingVADBlocksBatchReadinessWithoutBlockingCloudStreaming() {
        let registry = SpyProviderRegistry()
        registry.register(StubProvider(id: "batch-fixture", mode: .batch, isConfigured: true))
        registry.register(StubProvider(id: "stream-fixture", mode: .streaming, isConfigured: true))
        let state = AppState(providerRegistry: registry, vadAvailability: { false })
        state.accessibilityGranted = true
        state.microphoneGranted = true
        state.vadEnabled = true
        state.activeProviderId = "batch-fixture"
        #expect(!state.canStartDictation, "An absent VAD must block a pipeline that requires it")
        state.activeProviderId = "stream-fixture"
        #expect(state.canStartDictation, "Cloud streaming uses server-side endpointing")
        state.activeProviderId = "batch-fixture"
        state.vadEnabled = false
        #expect(state.canStartDictation, "An explicitly disabled VAD does not require model assets")
    }
}
