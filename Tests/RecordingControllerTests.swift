import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - RecordingController Behavioral Tests

@Suite("RecordingController — Provider Configuration Gate")
struct RecordingControllerProviderGateTests {

    @MainActor @Test
    func startRecordingWithUnconfiguredProviderDoesNotRecord() {
        let (controller, _, _, _) = makeTestRecordingController()
        controller.startRecording()
        #expect(!controller.isRecording, "Should not start recording when no provider is configured")
    }

    @MainActor @Test
    func startRecordingWithUnconfiguredProviderShowsBanner() {
        let (controller, _, _, banner) = makeTestRecordingController()
        controller.startRecording()
        #expect(banner.bannerMessages.count == 1, "Should show exactly one banner")
        #expect(banner.bannerMessages.first?.1 == .error, "Banner should be error style")
        #expect(banner.bannerMessages.first?.0.contains("provider") == true, "Banner should mention provider")
    }

    @MainActor @Test
    func doubleStartIgnored() {
        let (controller, _, _, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.startRecording()
        // If double start wasn't ignored, state would reset
        #expect(controller.isRecording, "Second startRecording while recording should be a no-op")
    }

    @MainActor @Test
    func startDuringProcessingFinalBlockedWhenRestartDisabled() {
        let settings = SpySettings()
        settings.hotkeyRestartsRecording = false
        let (controller, _, _, _) = makeTestRecordingController(settings: settings)
        controller.isProcessingFinal = true
        controller.startRecording()
        #expect(!controller.isRecording, "Should not start recording while processing final")
        #expect(controller.isProcessingFinal, "Processing final should remain true")
    }
}

@Suite("RecordingController — Hotkey Restart During Processing")
struct RecordingControllerHotkeyRestartTests {

    @MainActor @Test
    func hotkeyDuringProcessingFinalRestartsWhenEnabled() {
        let settings = SpySettings()
        settings.hotkeyRestartsRecording = true

        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let mockProvider = MockStreamingProvider()
        mockProvider.isConfigured = true
        mockProvider.mockSession = MockStreamingSession()
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(mockProvider)

        let (controller, _, textInserter, _) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings
        )

        controller.startRecording()
        #expect(controller.isRecording)

        controller.stopRecording(reason: .hotkey)
        #expect(controller.isProcessingFinal)

        // Press hotkey again — should cancel and restart
        controller.startRecording()
        #expect(controller.isRecording)
        #expect(!controller.isProcessingFinal)
        #expect(textInserter.cancelCalled)
    }

    @MainActor @Test
    func hotkeyDuringProcessingFinalBlocksWhenDisabled() {
        let settings = SpySettings()
        settings.hotkeyRestartsRecording = false

        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let mockProvider = MockStreamingProvider()
        mockProvider.isConfigured = true
        mockProvider.mockSession = MockStreamingSession()
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(mockProvider)

        let (controller, _, _, _) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings
        )

        controller.startRecording()
        controller.stopRecording(reason: .hotkey)
        #expect(controller.isProcessingFinal)

        // Press hotkey again — should NOT restart
        controller.startRecording()
        #expect(!controller.isRecording)
        #expect(controller.isProcessingFinal)
    }
}

@Suite("RecordingController — Callback Wiring")
struct RecordingControllerCallbackTests {

    @MainActor @Test
    func escapeCallbackWired() {
        let (_, keyInterceptor, _, _) = makeTestRecordingController()
        #expect(keyInterceptor.onEscapePressed != nil, "Escape callback must be wired on init")
    }

    @MainActor @Test
    func enterCallbackWired() {
        let (_, keyInterceptor, _, _) = makeTestRecordingController()
        #expect(keyInterceptor.onEnterPressed != nil, "Enter callback must be wired on init")
    }

    @MainActor @Test
    func enterDuringProcessingFinalSetsEnterFlag() {
        let (controller, keyInterceptor, _, _) = makeTestRecordingController()
        controller.isProcessingFinal = true
        keyInterceptor.onEnterPressed?()
        #expect(controller.shouldPressEnterOnComplete, "Enter during processing-final should set flag")
    }
}

@Suite("RecordingController — Cancel & Shutdown")
struct RecordingControllerCleanupTests {

    @MainActor @Test
    func cancelRecordingStopsKeyInterceptor() {
        let (controller, keyInterceptor, _, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.cancelRecording()
        #expect(keyInterceptor.stopCallCount >= 1, "Cancel must stop key interceptor")
    }

    @MainActor @Test
    func cancelRecordingResetsTextInserter() {
        let (controller, _, textInserter, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.cancelRecording()
        #expect(textInserter.cancelCalled, "Cancel must reset text inserter")
    }

    @MainActor @Test
    func cancelRecordingResetsState() {
        let (controller, _, _, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.cancelRecording()
        #expect(!controller.isRecording, "isRecording must be false after cancel")
        #expect(!controller.isProcessingFinal, "isProcessingFinal must be false after cancel")
    }

    @MainActor @Test
    func shutdownCleansUpAllResources() {
        let (controller, keyInterceptor, textInserter, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.shutdown()
        #expect(keyInterceptor.stopCallCount >= 1, "Shutdown must stop key interceptor")
        #expect(textInserter.cancelCalled, "Shutdown must cancel text inserter")
        #expect(!controller.isRecording, "isRecording must be false after shutdown")
        #expect(!controller.isProcessingFinal, "isProcessingFinal must be false after shutdown")
    }

    @MainActor @Test
    func shutdownIdempotent() {
        let (controller, _, _, _) = makeTestRecordingController()
        // Shutdown when nothing is active should not crash
        controller.shutdown()
        controller.shutdown()
        #expect(!controller.isRecording)
    }
}

@Suite("RecordingController — State Sync with AppState")
struct RecordingControllerStateSyncTests {

    @MainActor @Test
    func isRecordingSyncsToAppState() {
        let (controller, _, _, banner) = makeTestRecordingController()
        controller.isRecording = true
        #expect(banner.isRecording, "Setting isRecording should sync to appState")
        controller.isRecording = false
        #expect(!banner.isRecording, "Clearing isRecording should sync to appState")
    }

    @MainActor @Test
    func isProcessingFinalSyncsToAppState() {
        let (controller, _, _, banner) = makeTestRecordingController()
        controller.isProcessingFinal = true
        #expect(banner.isProcessingFinal, "Setting isProcessingFinal should sync to appState")
        controller.isProcessingFinal = false
        #expect(!banner.isProcessingFinal, "Clearing isProcessingFinal should sync to appState")
    }
}
