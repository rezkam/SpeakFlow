import AppKit
import OSLog
import SpeakFlowCore

/// Manages authentication flows (ChatGPT OAuth, Deepgram API keys).
///
/// Extracted from AppDelegate to keep auth/account logic separate
/// from app lifecycle and recording concerns.
@MainActor
final class AuthController {
    static let shared = AuthController()

    private(set) var oauthCallbackServer: OAuthCallbackServer?

    let appState: any BannerPresenting
    let providerSettings: any ProviderSettingsProviding
    let providerRegistry: any ProviderRegistryProviding

    init(
        appState: any BannerPresenting = SpeakFlow.AppState.shared,
        providerSettings: any ProviderSettingsProviding = ProviderSettings.shared,
        providerRegistry: any ProviderRegistryProviding = ProviderRegistry.shared
    ) {
        self.appState = appState
        self.providerSettings = providerSettings
        self.providerRegistry = providerRegistry
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
        OpenAICodexAuth.deleteCredentials()
        appState.refresh()
        appState.showBanner("Logged out from ChatGPT", style: .success)
    }

    func startLoginFlow() {
        let flow = OpenAICodexAuth.createAuthorizationFlow()
        let server = OAuthCallbackServer(expectedState: flow.state)
        oauthCallbackServer = server
        NSWorkspace.shared.open(flow.url)
        Task { [weak self] in
            let code = await server.waitForCallback(timeout: 120)
            await MainActor.run {
                guard let self else { return }
                self.oauthCallbackServer = nil
                if let code { self.exchangeCodeForTokens(code: code, flow: flow) }
            }
        }
    }

    // MARK: - API Key Management

    func handleRemoveApiKey(for providerId: String) {
        providerSettings.removeApiKey(for: providerId)
        if providerSettings.activeProviderId == providerId {
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
        Task {
            do {
                _ = try await OpenAICodexAuth.exchangeCodeForTokens(code: code, flow: flow)
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
