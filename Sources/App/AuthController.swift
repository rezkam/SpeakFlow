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

    init() {}

    // MARK: - ChatGPT

    func handleLoginAction() {
        if OpenAICodexAuth.isLoggedIn {
            AppState.shared.showBanner("Already logged in to ChatGPT")
        } else {
            startLoginFlow()
        }
    }

    func handleLogout() {
        OpenAICodexAuth.deleteCredentials()
        AppState.shared.refresh()
        AppState.shared.showBanner("Logged out from ChatGPT", style: .success)
    }

    func startLoginFlow() {
        let flow = OpenAICodexAuth.createAuthorizationFlow()
        let server = OAuthCallbackServer(expectedState: flow.state)
        oauthCallbackServer = server
        NSWorkspace.shared.open(flow.url)
        Task {
            let code = await server.waitForCallback(timeout: 120)
            await MainActor.run {
                self.oauthCallbackServer = nil
                if let code { self.exchangeCodeForTokens(code: code, flow: flow) }
            }
        }
    }

    // MARK: - API Key Management

    func handleRemoveApiKey(for providerId: String) {
        ProviderSettings.shared.removeApiKey(for: providerId)
        if ProviderSettings.shared.activeProviderId == providerId {
            // Fall back to the first remaining configured provider, or first registered
            let fallback = ProviderRegistry.shared.configuredProviders.first
                ?? ProviderRegistry.shared.allProviders.first
            ProviderSettings.shared.activeProviderId = fallback?.id ?? ProviderId.chatGPT
        }
        AppState.shared.refresh()
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
                    AppState.shared.refresh()
                    AppState.shared.showBanner("Login successful — ChatGPT transcription ready", style: .success)
                }
            } catch {
                Logger.auth.error("OAuth token exchange failed: \(error)")
                await MainActor.run {
                    AppState.shared.showBanner("Login failed — please try again", style: .error)
                }
            }
        }
    }
}
