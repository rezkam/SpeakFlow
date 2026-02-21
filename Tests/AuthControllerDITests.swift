import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - AuthController DI Behavioral Tests

@Suite("AuthController — DI Behavioral Contracts")
struct AuthControllerDITests {

    @Test @MainActor
    func removeApiKeyDelegates() {
        let spyPS = SpyProviderSettings()
        spyPS.activeProviderId = ProviderId.deepgram
        spyPS.storedKeys[ProviderId.deepgram] = "key123"

        let spyReg = SpyProviderRegistry()
        let spyBanner = SpyBannerPresenter()

        let controller = AuthController(
            appState: spyBanner,
            providerSettings: spyPS,
            providerRegistry: spyReg
        )

        controller.handleRemoveApiKey(for: ProviderId.deepgram)

        #expect(spyPS.removedKeys.contains(ProviderId.deepgram))
        #expect(spyBanner.refreshCount > 0)
    }

    @Test @MainActor
    func removeActiveProviderFallsBackToFirstRegistered() {
        let spyPS = SpyProviderSettings()
        spyPS.activeProviderId = ProviderId.deepgram

        let spyReg = SpyProviderRegistry()
        let spyBanner = SpyBannerPresenter()

        let controller = AuthController(
            appState: spyBanner,
            providerSettings: spyPS,
            providerRegistry: spyReg
        )

        controller.handleRemoveApiKey(for: ProviderId.deepgram)

        // With no registered providers, falls back to ProviderId.chatGPT constant
        #expect(spyPS.activeProviderId == ProviderId.chatGPT)
    }

    @Test @MainActor
    func removeNonActiveProviderKeepsCurrentActive() {
        let spyPS = SpyProviderSettings()
        spyPS.activeProviderId = ProviderId.chatGPT
        spyPS.storedKeys[ProviderId.deepgram] = "key456"

        let spyReg = SpyProviderRegistry()
        // Register the active provider as configured so it stays selected
        let chatGPTStub = StubProvider(id: ProviderId.chatGPT, isConfigured: true)
        spyReg.register(chatGPTStub)
        let spyBanner = SpyBannerPresenter()

        let controller = AuthController(
            appState: spyBanner,
            providerSettings: spyPS,
            providerRegistry: spyReg
        )

        controller.handleRemoveApiKey(for: ProviderId.deepgram)

        // Active provider unchanged because it is still configured
        #expect(spyPS.activeProviderId == ProviderId.chatGPT)
        #expect(spyPS.removedKeys.contains(ProviderId.deepgram))
    }

    @Test @MainActor
    func removeSharedKeyFallsBackWhenBatchVariantIsActive() {
        // Scenario: active = mistralBatch, remove key for mistral.
        // Both providers share the same key, so removing "mistral" deconfigures "mistral-batch" too.
        let spyPS = SpyProviderSettings()
        spyPS.activeProviderId = ProviderId.mistralBatch

        let spyReg = SpyProviderRegistry()
        // mistralBatch becomes unconfigured after key removal
        let batchStub = StubProvider(id: ProviderId.mistralBatch, isConfigured: false)
        let fallbackStub = StubProvider(id: ProviderId.chatGPT, isConfigured: true)
        spyReg.register(batchStub)
        spyReg.register(fallbackStub)
        let spyBanner = SpyBannerPresenter()

        let controller = AuthController(
            appState: spyBanner,
            providerSettings: spyPS,
            providerRegistry: spyReg
        )

        controller.handleRemoveApiKey(for: ProviderId.mistral)

        // Should fall back because the active provider is no longer configured
        #expect(spyPS.activeProviderId == ProviderId.chatGPT)
    }

    @Test @MainActor
    func logoutShowsSuccessBanner() {
        let spyBanner = SpyBannerPresenter()
        let controller = AuthController(appState: spyBanner)

        controller.handleLogout()

        #expect(spyBanner.bannerMessages.contains(where: { $0.1 == .success }))
    }

    @Test @MainActor
    func logoutRefreshesState() {
        let spyBanner = SpyBannerPresenter()
        let controller = AuthController(appState: spyBanner)

        controller.handleLogout()

        #expect(spyBanner.refreshCount > 0)
    }
}
