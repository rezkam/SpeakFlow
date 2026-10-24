import AppKit
import OSLog
import SpeakFlowCore

protocol OAuthCallbackServing: AnyObject, Sendable {
    func prepareForCallback() -> Bool
    func waitForPreparedCallback(timeout: TimeInterval) async -> String?
    func stop()
}

extension OAuthCallbackServer: OAuthCallbackServing {}

/// Manages authentication flows (ChatGPT OAuth, Deepgram API keys).
///
/// Extracted from AppDelegate to keep auth/account logic separate
/// from app lifecycle and recording concerns.
@MainActor
final class AuthController {
    static let shared = AuthController()

    private(set) var oauthCallbackServer: (any OAuthCallbackServing)?

    let appState: any BannerPresenting
    let providerSettings: any ProviderSettingsProviding
    let providerRegistry: any ProviderRegistryProviding
    private let callbackServerFactory: (String) -> any OAuthCallbackServing
    private let openAuthorizationURL: (URL) -> Void
    private let exchangeAuthorizationCode: (String, OpenAICodexAuth.AuthorizationFlow) async throws -> Void
    private let deleteChatGPTCredentials: () throws -> Void

    init(
        appState: any BannerPresenting = SpeakFlow.AppState.shared,
        providerSettings: any ProviderSettingsProviding = ProviderSettings.shared,
        providerRegistry: any ProviderRegistryProviding = ProviderRegistry.shared,
        callbackServerFactory: @escaping (String) -> any OAuthCallbackServing = {
            OAuthCallbackServer(expectedState: $0)
        },
        openAuthorizationURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        exchangeAuthorizationCode: @escaping (
            String,
            OpenAICodexAuth.AuthorizationFlow
        ) async throws -> Void = { code, flow in
            _ = try await OpenAICodexAuth.exchangeCodeForTokens(code: code, flow: flow)
        },
        deleteChatGPTCredentials: @escaping () throws -> Void = { try OpenAICodexAuth.deleteCredentials() }
    ) {
        self.appState = appState
        self.providerSettings = providerSettings
        self.providerRegistry = providerRegistry
        self.callbackServerFactory = callbackServerFactory
        self.openAuthorizationURL = openAuthorizationURL
        self.exchangeAuthorizationCode = exchangeAuthorizationCode
        self.deleteChatGPTCredentials = deleteChatGPTCredentials
    }

    // MARK: - ChatGPT

    func handleLoginAction() {
        if OpenAICodexAuth.isLoggedIn {
            appState.showBanner("Already logged in to ChatGPT")
        } else {
            startLoginFlow()
        }
    }

    func handleLogout() {
        do {
            try deleteChatGPTCredentials()
        } catch {
            Logger.auth.error("Logout failed: \(error.localizedDescription, privacy: .public)")
            appState.refresh()
            appState.showBanner(
                "Logout failed — your ChatGPT credentials could not be removed. \(error.localizedDescription)",
                style: .error, duration: 8
            )
            return
        }
        appState.refresh()
        appState.showBanner("Logged out from ChatGPT", style: .success)
    }

    func startLoginFlow() {
        let flow: OpenAICodexAuth.AuthorizationFlow
        do {
            flow = try OpenAICodexAuth.createAuthorizationFlow()
        } catch {
            Logger.auth.error("Failed to create OAuth authorization flow: \(error.localizedDescription)")
            appState.showBanner("Login failed — could not initialize secure OAuth flow", style: .error)
            return
        }
        let server = callbackServerFactory(flow.state)

        // Bind/listen before opening the browser to avoid a startup race where
        // the callback arrives before the local server is ready.
        guard server.prepareForCallback() else {
            appState.showBanner("Login failed — could not start callback server", style: .error)
            return
        }

        oauthCallbackServer = server
        openAuthorizationURL(flow.url)

        Task { [weak self] in
            let code = await server.waitForPreparedCallback(timeout: 120)
            await MainActor.run {
                guard let self else { return }
                self.oauthCallbackServer = nil
                if let code {
                    self.exchangeCodeForTokens(code: code, flow: flow)
                } else {
                    Logger.auth.error("OAuth callback failed or timed out")
                    self.appState.showBanner(
                        "Login failed or timed out. Please try again.",
                        style: .error,
                        duration: 8
                    )
                }
            }
        }
    }

    // MARK: - API Key Management

    func handleRemoveApiKey(for providerId: String) {
        do {
            try providerSettings.removeApiKey(for: providerId)
        } catch {
            Logger.auth.error("Removing API key failed: \(error.localizedDescription, privacy: .public)")
            appState.showBanner(
                "Could not remove the API key. \(error.localizedDescription)",
                style: .error, duration: 8
            )
            return
        }
        let activeId = providerSettings.activeProviderId
        if !(providerRegistry.provider(for: activeId)?.isConfigured ?? false) {
            // Fall back to the first remaining configured provider, or first registered
            let fallback = providerRegistry.configuredProviders.first
                ?? providerRegistry.allProviders.first
            providerSettings.activeProviderId = fallback?.id ?? ProviderId.chatGPT
        }
        appState.refresh()
    }

    // MARK: - Cleanup

    func shutdown() {
        oauthCallbackServer?.stop()
        oauthCallbackServer = nil
    }

    // MARK: - Private

    private func exchangeCodeForTokens(code: String, flow: OpenAICodexAuth.AuthorizationFlow) {
        let exchangeAuthorizationCode = self.exchangeAuthorizationCode
        Task {
            do {
                try await exchangeAuthorizationCode(code, flow)
                await MainActor.run {
                    appState.refresh()
                    appState.showBanner("Login successful — ChatGPT transcription ready", style: .success)
                }
            } catch {
                Logger.auth.error("OAuth token exchange failed: \(error)")
                await MainActor.run {
                    appState.showBanner("Login failed — please try again", style: .error)
                }
            }
        }
    }
}
