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
        let registry = SpyProviderRegistry()
        let configured = StubProvider(id: "test-cfg", isConfigured: true)
        let unconfigured = StubProvider(id: "test-ucfg", isConfigured: false)
        registry.register(configured)
        registry.register(unconfigured)
        let state = AppState(providerRegistry: registry)

        #expect(state.isProviderConfigured("test-cfg"), "Configured provider should return true")
        #expect(!state.isProviderConfigured("test-ucfg"), "Unconfigured provider should return false")
        #expect(!state.isProviderConfigured("nonexistent"), "Unknown provider should return false")
    }

    @MainActor @Test
    func isStreamingProvider_reflectsActiveProvider() {
        let registry = SpyProviderRegistry()
        let streaming = StubProvider(id: "stream", mode: .streaming, isConfigured: true)
        let batch = StubProvider(id: "batch", mode: .batch, isConfigured: true)
        registry.register(streaming)
        registry.register(batch)
        let state = AppState(providerRegistry: registry)

        state.activeProviderId = "stream"
        #expect(state.isStreamingProvider, "Streaming provider should be detected")

        state.activeProviderId = "batch"
        #expect(!state.isStreamingProvider, "Batch provider should not be streaming")
    }
}

// MARK: - Dictation Readiness (Menu Bar)

@Suite("AppState — canStartDictation")
struct AppStateCanStartDictationTests {

    /// Creates an AppState with an isolated SpyProviderRegistry for clean test state.
    @MainActor
    private func makeState(
        providers: [StubProvider] = []
    ) -> (AppState, SpyProviderRegistry) {
        let registry = SpyProviderRegistry()
        for p in providers { registry.register(p) }
        let state = AppState(providerRegistry: registry)
        return (state, registry)
    }

    @MainActor @Test
    func disabledWhenAccessibilityNotGranted() {
        let (state, _) = makeState(providers: [StubProvider(isConfigured: true)])
        state.accessibilityGranted = false
        state.microphoneGranted = true

        #expect(!state.canStartDictation, "Must not start dictation without accessibility")
    }

    @MainActor @Test
    func disabledWhenMicrophoneNotGranted() {
        let (state, _) = makeState(providers: [StubProvider(isConfigured: true)])
        state.accessibilityGranted = true
        state.microphoneGranted = false

        #expect(!state.canStartDictation, "Must not start dictation without microphone")
    }

    @MainActor @Test
    func disabledWhenNoProviderConfigured() {
        let (state, _) = makeState(providers: [StubProvider(isConfigured: false)])
        state.accessibilityGranted = true
        state.microphoneGranted = true

        #expect(!state.canStartDictation, "Must not start dictation without configured provider")
    }

    @MainActor @Test
    func disabledWhenNoProvidersRegistered() {
        let (state, _) = makeState()
        state.accessibilityGranted = true
        state.microphoneGranted = true

        #expect(!state.canStartDictation, "Must not start dictation without any providers")
    }

    @MainActor @Test
    func disabledWhenBothPermissionsMissing() {
        let (state, _) = makeState(providers: [StubProvider(isConfigured: true)])
        state.accessibilityGranted = false
        state.microphoneGranted = false

        #expect(!state.canStartDictation, "Must not start dictation without any permissions")
    }

    @MainActor @Test
    func enabledWhenAllPrerequisitesMet() {
        let (state, _) = makeState(providers: [StubProvider(isConfigured: true)])
        state.accessibilityGranted = true
        state.microphoneGranted = true

        #expect(state.canStartDictation, "Should allow dictation when all prerequisites are met")
    }

    @MainActor @Test
    func reactsToPermissionChanges() {
        let (state, _) = makeState(providers: [StubProvider(isConfigured: true)])
        state.accessibilityGranted = false
        state.microphoneGranted = true
        #expect(!state.canStartDictation)

        state.accessibilityGranted = true
        #expect(state.canStartDictation, "Should become available after granting accessibility")
    }

    @MainActor @Test
    func reactsToProviderConfigChange() {
        let stub = StubProvider(isConfigured: false)
        let (state, _) = makeState(providers: [stub])
        state.accessibilityGranted = true
        state.microphoneGranted = true
        #expect(!state.canStartDictation)

        stub.stubbedIsConfigured = true
        #expect(state.canStartDictation, "Should become available after configuring provider")
    }

    @MainActor @Test
    func enabledWithMultipleProvidersOneConfigured() {
        let unconfigured = StubProvider(id: "a", isConfigured: false)
        let configured = StubProvider(id: "b", isConfigured: true)
        let (state, _) = makeState(providers: [unconfigured, configured])
        state.accessibilityGranted = true
        state.microphoneGranted = true

        #expect(state.canStartDictation, "One configured provider should be sufficient")
    }
}
