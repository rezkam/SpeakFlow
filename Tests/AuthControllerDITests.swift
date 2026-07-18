import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

private final class StubOAuthCallbackServer: OAuthCallbackServing, @unchecked Sendable {
    private let result: String?

    init(result: String?) {
        self.result = result
    }

    func prepareForCallback() -> Bool { true }
    func waitForPreparedCallback(timeout: TimeInterval) async -> String? { result }
    func stop() {}
}

private actor OAuthExchangeProbe {
    private(set) var code: String?

    func record(code: String) {
        self.code = code
    }
}

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

    @Test @MainActor
    func nilOAuthCallbackShowsFailureBanner() async throws {
        let spyBanner = SpyBannerPresenter()
        let server = StubOAuthCallbackServer(result: nil)
        let controller = AuthController(
            appState: spyBanner,
            callbackServerFactory: { _ in server },
            openAuthorizationURL: { _ in }
        )

        controller.startLoginFlow()

        try await waitUntil {
            controller.oauthCallbackServer == nil
        }
        #expect(spyBanner.bannerMessages.contains(where: {
            $0.1 == .error && $0.0 == "Login failed or timed out. Please try again."
        }))
    }

    @Test @MainActor
    func oauthCodeDoesNotShowFailureBanner() async throws {
        let spyBanner = SpyBannerPresenter()
        let server = StubOAuthCallbackServer(result: "test-code")
        let exchangeProbe = OAuthExchangeProbe()
        let controller = AuthController(
            appState: spyBanner,
            callbackServerFactory: { _ in server },
            openAuthorizationURL: { _ in },
            exchangeAuthorizationCode: { code, _ in
                await exchangeProbe.record(code: code)
            }
        )

        controller.startLoginFlow()

        try await waitUntilAsync {
            await exchangeProbe.code == "test-code"
        }
        #expect(!spyBanner.bannerMessages.contains(where: { $0.1 == .error }))
    }
}
