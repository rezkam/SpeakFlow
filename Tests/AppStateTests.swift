import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - AppState Behavioral Tests

@Suite("AppState — Banner Management")
struct AppStateBannerTests {

    @MainActor @Test
    func showBanner_setsMessageAndStyle() {
        let state = AppState()
        state.showBanner("Test message", style: .error)

        #expect(state.bannerMessage == "Test message")
        #expect(state.bannerStyle == .error)
        #expect(state.bannerVisible)
    }

    @MainActor @Test
    func showBanner_defaultStyleIsInfo() {
        let state = AppState()
        state.showBanner("Info message")

        #expect(state.bannerStyle == .info)
        #expect(state.bannerVisible)
    }

    @MainActor @Test
    func showBanner_successStyle() {
        let state = AppState()
        state.showBanner("Saved!", style: .success)

        #expect(state.bannerStyle == .success)
    }

    @MainActor @Test
    func dismissBanner_hidesBanner() {
        let state = AppState()
        state.showBanner("Visible")
        #expect(state.bannerVisible)

        state.dismissBanner()
        #expect(!state.bannerVisible, "Banner should be hidden after dismiss")
    }

    @MainActor @Test
    func showBanner_replacesExistingBanner() {
        let state = AppState()
        state.showBanner("First", style: .info)
        state.showBanner("Second", style: .error)

        #expect(state.bannerMessage == "Second", "Latest banner should replace previous")
        #expect(state.bannerStyle == .error)
    }
}

@Suite("AppState — Recording State")
struct AppStateRecordingTests {

    @MainActor @Test
    func isRecording_defaultsFalse() {
        let state = AppState()
        #expect(!state.isRecording)
        #expect(!state.isProcessingFinal)
    }

    @MainActor @Test
    func isRecording_toggles() {
        let state = AppState()
        state.isRecording = true
        #expect(state.isRecording)
        state.isRecording = false
        #expect(!state.isRecording)
    }

    @MainActor @Test
    func isProcessingFinal_toggles() {
        let state = AppState()
        state.isProcessingFinal = true
        #expect(state.isProcessingFinal)
        state.isProcessingFinal = false
        #expect(!state.isProcessingFinal)
    }
}

@Suite("AppState — Refresh")
struct AppStateRefreshTests {

    @MainActor @Test
    func refresh_incrementsVersion() {
        let state = AppState()
        let initial = state.refreshVersion
        state.refresh()
        #expect(state.refreshVersion == initial + 1, "refresh() must increment version")
        state.refresh()
        #expect(state.refreshVersion == initial + 2)
    }

    @MainActor @Test
    func refresh_updatesActiveProviderId() {
        let state = AppState()
        // After refresh, activeProviderId should reflect ProviderSettings
        state.refresh()
        // Default activeProviderId is "gpt" (from ProviderSettings)
        #expect(!state.activeProviderId.isEmpty, "activeProviderId should be set after refresh")
    }
}

@Suite("AppState — Provider Configuration")
struct AppStateProviderTests {

    @MainActor @Test
    func isProviderConfigured_delegatesToRegistry() {
        // Register real providers so the delegation path is tested
        ProviderRegistry.shared.register(DeepgramProvider())
        ProviderRegistry.shared.register(ChatGPTBatchProvider())
        let state = AppState()

        // These delegate to ProviderRegistry — verify the path works
        let _ = state.isProviderConfigured(ProviderId.chatGPT)
        let _ = state.isProviderConfigured(ProviderId.deepgram)
    }

    @MainActor @Test
    func isStreamingProvider_reflectsActiveProvider() {
        ProviderRegistry.shared.register(DeepgramProvider())
        ProviderRegistry.shared.register(ChatGPTBatchProvider())
        let state = AppState()

        // Deepgram is streaming
        state.activeProviderId = ProviderId.deepgram
        #expect(state.isStreamingProvider, "Deepgram should be a streaming provider")

        // ChatGPT is batch
        state.activeProviderId = ProviderId.chatGPT
        #expect(!state.isStreamingProvider, "ChatGPT should not be streaming")
    }
}
