import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

private struct RequiredVADLocalProvider: LocalRecordingPreparing {
    let id = "local:fixture"
    let displayName = "Local fixture"
    let mode: ProviderMode = .batch
    let isConfigured = true
    let authRequirement: ProviderAuthRequirement = .none
    func prepareRecording() async throws -> PreparedLocalRecording { throw LocalSpeechRuntimeError.loadFailed }
}

@Suite("Local VAD readiness")
struct LocalVADReadinessTests {
    @Test @MainActor func missingVADRefusesStartBeforeCapturingTargetOrKeys() {
        let registry = SpyProviderRegistry()
        registry.register(RequiredVADLocalProvider())
        let providerSettings = SpyProviderSettings()
        providerSettings.activeProviderId = "local:fixture"
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

    @Test @MainActor func missingVADBlocksOnlyTheSelectedLocalBatchProvider() {
        let registry = SpyProviderRegistry()
        registry.register(StubProvider(id: "batch-fixture", mode: .batch, isConfigured: true))
        registry.register(StubProvider(id: "stream-fixture", mode: .streaming, isConfigured: true))
        registry.register(RequiredVADLocalProvider())
        let state = AppState(providerRegistry: registry, vadAvailability: { false })
        state.accessibilityGranted = true
        state.microphoneGranted = true
        state.vadEnabled = true
        state.activeProviderId = "batch-fixture"
        #expect(state.canStartDictation, "Cloud batch must remain usable without local assets")
        #expect(!state.needsVADInstallation)
        #expect(state.usesBasicCloudBatchRecording)
        state.activeProviderId = "local:fixture"
        #expect(!state.canStartDictation, "A selected local batch provider still requires its VAD")
        #expect(state.needsVADInstallation)
        state.activeProviderId = "stream-fixture"
        #expect(!state.usesBasicCloudBatchRecording)
        #expect(state.canStartDictation, "Cloud streaming uses server-side endpointing")
        state.activeProviderId = "batch-fixture"
        state.vadEnabled = false
        #expect(state.canStartDictation, "An explicitly disabled VAD does not require model assets")
    }
}
