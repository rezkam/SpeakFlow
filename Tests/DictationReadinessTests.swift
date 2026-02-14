import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

/// Integration tests verifying that the menu bar dictation button disabled state
/// correctly reflects the combined permission + provider requirements.
///
/// These tests wire real AppState with real ProviderRegistry (via SpyProviderRegistry)
/// and real RecordingController, verifying alignment between the UI guard
/// (`canStartDictation`) and the runtime guard (`startRecording()`).
@Suite("Dictation Readiness — Integration")
struct DictationReadinessIntegrationTests {

    /// Wires a RecordingController with a real AppState (not SpyBannerPresenter),
    /// so we can test both `canStartDictation` and `startRecording()` together.
    @MainActor
    private func makeIntegrationPair(
        providers: [StubProvider] = []
    ) -> (RecordingController, AppState, SpyProviderRegistry) {
        SoundEffect.isMuted = true
        let registry = SpyProviderRegistry()
        for p in providers { registry.register(p) }

        let state = AppState(providerRegistry: registry)
        let providerSettings = SpyProviderSettings()
        if let first = providers.first {
            providerSettings.activeProviderId = first.id
        }

        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(),
            textInserter: SpyTextInserter(),
            appState: state,
            providerSettings: providerSettings,
            providerRegistry: registry
        )
        controller.testMode = .live
        return (controller, state, registry)
    }

    // MARK: - canStartDictation guards all prerequisites

    @MainActor @Test
    func dictationDisabledWithNoPermissionsNoProviders() {
        let (_, state, _) = makeIntegrationPair()
        state.accessibilityGranted = false
        state.microphoneGranted = false

        #expect(!state.canStartDictation)
    }

    @MainActor @Test
    func dictationDisabledWithPermissionsButNoProvider() {
        let (_, state, _) = makeIntegrationPair()
        state.accessibilityGranted = true
        state.microphoneGranted = true

        #expect(!state.canStartDictation, "Permissions alone should not enable dictation")
    }

    @MainActor @Test
    func dictationDisabledWithProviderButNoAccessibility() {
        let stub = StubProvider(isConfigured: true)
        let (_, state, _) = makeIntegrationPair(providers: [stub])
        state.accessibilityGranted = false
        state.microphoneGranted = true

        #expect(!state.canStartDictation, "Provider alone should not enable dictation")
    }

    @MainActor @Test
    func dictationDisabledWithProviderButNoMicrophone() {
        let stub = StubProvider(isConfigured: true)
        let (_, state, _) = makeIntegrationPair(providers: [stub])
        state.accessibilityGranted = true
        state.microphoneGranted = false

        #expect(!state.canStartDictation, "Missing microphone should disable dictation")
    }

    @MainActor @Test
    func dictationEnabledWhenAllPrerequisitesMet() {
        let stub = StubProvider(isConfigured: true)
        let (_, state, _) = makeIntegrationPair(providers: [stub])
        state.accessibilityGranted = true
        state.microphoneGranted = true

        #expect(state.canStartDictation, "All prerequisites met — dictation should be enabled")
    }

    // MARK: - UI guard aligns with runtime guard

    @MainActor @Test
    func runtimeGuardBlocksWhenProviderNotConfigured() {
        let stub = StubProvider(isConfigured: false)
        let (controller, state, _) = makeIntegrationPair(providers: [stub])
        state.accessibilityGranted = true
        state.microphoneGranted = true

        // UI guard says no
        #expect(!state.canStartDictation)

        // Runtime guard also says no
        controller.startRecording()
        #expect(!controller.isRecording, "Recording should be blocked by unconfigured provider")
    }

    @MainActor @Test
    func runtimeGuardBlocksWhenNoProvidersExist() {
        let (controller, state, _) = makeIntegrationPair()
        state.accessibilityGranted = true
        state.microphoneGranted = true

        // UI guard says no
        #expect(!state.canStartDictation)

        // Runtime guard also says no
        controller.startRecording()
        #expect(!controller.isRecording, "Recording should be blocked with no providers")
    }

    // MARK: - State transitions

    @MainActor @Test
    func grantingPermissionsMakesDictationAvailable() {
        let stub = StubProvider(isConfigured: true)
        let (_, state, _) = makeIntegrationPair(providers: [stub])

        // Start with no permissions
        state.accessibilityGranted = false
        state.microphoneGranted = false
        #expect(!state.canStartDictation)

        // Grant accessibility only
        state.accessibilityGranted = true
        #expect(!state.canStartDictation, "Still need microphone")

        // Grant microphone too
        state.microphoneGranted = true
        #expect(state.canStartDictation, "Both permissions granted — should be ready")
    }

    @MainActor @Test
    func configuringProviderMakesDictationAvailable() {
        let stub = StubProvider(isConfigured: false)
        let (_, state, _) = makeIntegrationPair(providers: [stub])
        state.accessibilityGranted = true
        state.microphoneGranted = true
        #expect(!state.canStartDictation, "Unconfigured provider — should be disabled")

        // User configures their API key
        stub.stubbedIsConfigured = true
        #expect(state.canStartDictation, "Provider now configured — should be enabled")
    }

    @MainActor @Test
    func removingProviderConfigDisablesDictation() {
        let stub = StubProvider(isConfigured: true)
        let (_, state, _) = makeIntegrationPair(providers: [stub])
        state.accessibilityGranted = true
        state.microphoneGranted = true
        #expect(state.canStartDictation)

        // User removes their API key
        stub.stubbedIsConfigured = false
        #expect(!state.canStartDictation, "Provider deconfigured — should be disabled")
    }

    @MainActor @Test
    func multipleProvidersOneConfiguredSuffices() {
        let unconfigured = StubProvider(id: "a", isConfigured: false)
        let configured = StubProvider(id: "b", isConfigured: true)
        let (_, state, _) = makeIntegrationPair(providers: [unconfigured, configured])
        state.accessibilityGranted = true
        state.microphoneGranted = true

        #expect(state.canStartDictation, "One configured provider should be enough")
    }

    // MARK: - Recording during active session

    @MainActor @Test
    func stopDictationAvailableDuringRecording() {
        let stub = StubProvider(isConfigured: true)
        let (controller, state, _) = makeIntegrationPair(providers: [stub])
        state.accessibilityGranted = true
        state.microphoneGranted = true

        // Simulate active recording (set directly since we can't actually record)
        controller.isRecording = true

        // Even if permissions were revoked mid-recording, the stop action must work.
        // The menu bar condition is: .disabled(!state.isRecording && !state.canStartDictation)
        // During recording, isRecording=true makes the button enabled regardless.
        state.accessibilityGranted = false
        let menuDisabled = !state.isRecording && !state.canStartDictation
        #expect(!menuDisabled, "Stop Dictation must remain clickable during active recording")
    }
}
