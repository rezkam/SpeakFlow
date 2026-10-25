import Foundation
import Testing
import os
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

private actor HeldOAuthCallbackServer: OAuthCallbackServing {
    private var continuation: CheckedContinuation<String?, Never>?
    private(set) var waiting = false
    nonisolated let stops = OSAllocatedUnfairLock(initialState: 0)
    nonisolated func prepareForCallback() -> Bool { true }
    nonisolated func stop() { stops.withLock { $0 += 1 } }
    func waitForPreparedCallback(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation {
            continuation = $0
            waiting = true
        }
    }
    func respond(_ code: String?) {
        continuation?.resume(returning: code)
        continuation = nil
    }
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
    @Test(arguments: [false, true]) @MainActor
    func retiredCallbackCannotStartExchange(replace: Bool) async throws {
        let first = HeldOAuthCallbackServer()
        var factories = 0
        var exchanges = 0
        let controller = AuthController(
            appState: SpyBannerPresenter(), providerSettings: SpyProviderSettings(), providerRegistry: SpyProviderRegistry(),
            callbackServerFactory: { _ in
                factories += 1
                return factories == 1 ? first : StubOAuthCallbackServer(result: nil)
            },
            openAuthorizationURL: { _ in },
            exchangeAuthorizationCode: { _, _ in exchanges += 1 },
            deleteChatGPTCredentials: {}
        )
        defer { controller.shutdown(); Task { await first.respond(nil) } }
        controller.startLoginFlow()
        let old = try #require(controller.loginTask)
        try await waitUntilAsync { await first.waiting }
        try #require(await first.waiting)
        if replace { controller.startLoginFlow() } else { controller.handleLogout() }
        await first.respond("retired-code")
        await old.value
        // The owned task includes callback and exchange, so completion is the barrier.
        #expect(exchanges == 0)
        #expect(first.stops.withLock { $0 } == 1)
    }


    @Test(arguments: [false, true]) @MainActor
    func exchangeCompletingAfterLogoutCannotAnnounceLogin(fail: Bool) async throws {
        let response = HeldOAuthCallbackServer()
        let banner = SpyBannerPresenter()
        let controller = AuthController(
            appState: banner, providerSettings: SpyProviderSettings(), providerRegistry: SpyProviderRegistry(),
            callbackServerFactory: { _ in StubOAuthCallbackServer(result: "code") },
            openAuthorizationURL: { _ in },
            exchangeAuthorizationCode: { _, _ in
                _ = await response.waitForPreparedCallback(timeout: 0)
                if fail { throw TranscriptionError.httpError(statusCode: 500, body: "test failure") }
            },
            deleteChatGPTCredentials: {}
        )
        defer { controller.shutdown(); Task { await response.respond(nil) } }
        controller.startLoginFlow()
        let task = try #require(controller.loginTask)
        try await waitUntilAsync { await response.waiting }
        try #require(await response.waiting)
        controller.handleLogout()
        await response.respond("finished")
        await task.value
        #expect(banner.bannerMessages.count == 1)
        #expect(banner.bannerMessages.first?.0 == "Logged out from ChatGPT")
    }

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
