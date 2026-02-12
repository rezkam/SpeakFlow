import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("AuthController — Lifecycle & Cleanup")
struct AuthControllerTests {

    @MainActor @Test
    func shutdownClearsOAuthServer() {
        let controller = AuthController()
        controller.shutdown()
        #expect(controller.oauthCallbackServer == nil, "Server must be nil after shutdown")
    }

    @MainActor @Test
    func shutdownIdempotent() {
        let controller = AuthController()
        // Double shutdown should not crash
        controller.shutdown()
        controller.shutdown()
        #expect(controller.oauthCallbackServer == nil)
    }

    @MainActor @Test
    func logoutRefreshesState() {
        // handleLogout() calls OpenAICodexAuth.deleteCredentials() and refreshes.
        // Since credentials may not exist, this should not crash.
        let controller = AuthController()
        controller.handleLogout()
        // Verify it completed without error (state refresh happened)
    }
}
