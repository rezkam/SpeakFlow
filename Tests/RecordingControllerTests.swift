import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - RecordingController Behavioral Tests

@Suite("RecordingController — Provider Configuration Gate")
struct RecordingControllerProviderGateTests {

    /// Helper to create a testable RecordingController with spy dependencies.
    /// Sets isUITestMode = true so system permission checks (Accessibility, Mic) are skipped.
    @MainActor
    private func makeController() -> (RecordingController, SpyKeyInterceptor, SpyTextInserter, SpyBannerPresenter) {
        let keyInterceptor = SpyKeyInterceptor()
        let textInserter = SpyTextInserter()
        let banner = SpyBannerPresenter()
        let controller = RecordingController(
            keyInterceptor: keyInterceptor,
            textInserter: textInserter,
            appState: banner
        )
        controller.isUITestMode = true
        controller.useMockRecordingInUITests = false
        return (controller, keyInterceptor, textInserter, banner)
    }

    @MainActor @Test
    func startRecordingWithUnconfiguredProviderDoesNotRecord() {
        let (controller, _, _, _) = makeController()
        controller.startRecording()
        #expect(!controller.isRecording, "Should not start recording when no provider is configured")
    }

    @MainActor @Test
    func startRecordingWithUnconfiguredProviderShowsBanner() {
        let (controller, _, _, banner) = makeController()
        controller.startRecording()
        #expect(banner.bannerMessages.count == 1, "Should show exactly one banner")
        #expect(banner.bannerMessages.first?.1 == .error, "Banner should be error style")
        #expect(banner.bannerMessages.first?.0.contains("provider") == true, "Banner should mention provider")
    }

    @MainActor @Test
    func doubleStartIgnored() {
        let (controller, _, _, _) = makeController()
        controller.isRecording = true
        controller.startRecording()
        // If double start wasn't ignored, state would reset
        #expect(controller.isRecording, "Second startRecording while recording should be a no-op")
    }

    @MainActor @Test
    func startDuringProcessingFinalBlocked() {
        let (controller, _, _, _) = makeController()
        controller.isProcessingFinal = true
        controller.startRecording()
        #expect(!controller.isRecording, "Should not start recording while processing final")
        #expect(controller.isProcessingFinal, "Processing final should remain true")
    }
}

@Suite("RecordingController — Callback Wiring")
struct RecordingControllerCallbackTests {

    @MainActor @Test
    func escapeCallbackWired() {
        let keyInterceptor = SpyKeyInterceptor()
        _ = RecordingController(
            keyInterceptor: keyInterceptor,
            textInserter: SpyTextInserter(),
            appState: SpyBannerPresenter()
        )
        #expect(keyInterceptor.onEscapePressed != nil, "Escape callback must be wired on init")
    }

    @MainActor @Test
    func enterCallbackWired() {
        let keyInterceptor = SpyKeyInterceptor()
        _ = RecordingController(
            keyInterceptor: keyInterceptor,
            textInserter: SpyTextInserter(),
            appState: SpyBannerPresenter()
        )
        #expect(keyInterceptor.onEnterPressed != nil, "Enter callback must be wired on init")
    }

    @MainActor @Test
    func enterDuringProcessingFinalSetsEnterFlag() {
        let keyInterceptor = SpyKeyInterceptor()
        let controller = RecordingController(
            keyInterceptor: keyInterceptor,
            textInserter: SpyTextInserter(),
            appState: SpyBannerPresenter()
        )
        controller.isProcessingFinal = true
        keyInterceptor.onEnterPressed?()
        #expect(controller.shouldPressEnterOnComplete, "Enter during processing-final should set flag")
    }
}

@Suite("RecordingController — Cancel & Shutdown")
struct RecordingControllerCleanupTests {

    @MainActor @Test
    func cancelRecordingStopsKeyInterceptor() {
        let keyInterceptor = SpyKeyInterceptor()
        let controller = RecordingController(
            keyInterceptor: keyInterceptor,
            textInserter: SpyTextInserter(),
            appState: SpyBannerPresenter()
        )
        controller.isRecording = true
        controller.cancelRecording()
        #expect(keyInterceptor.stopCallCount >= 1, "Cancel must stop key interceptor")
    }

    @MainActor @Test
    func cancelRecordingResetsTextInserter() {
        let textInserter = SpyTextInserter()
        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(),
            textInserter: textInserter,
            appState: SpyBannerPresenter()
        )
        controller.isRecording = true
        controller.cancelRecording()
        #expect(textInserter.cancelCalled, "Cancel must reset text inserter")
    }

    @MainActor @Test
    func cancelRecordingResetsState() {
        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(),
            textInserter: SpyTextInserter(),
            appState: SpyBannerPresenter()
        )
        controller.isRecording = true
        controller.cancelRecording()
        #expect(!controller.isRecording, "isRecording must be false after cancel")
        #expect(!controller.isProcessingFinal, "isProcessingFinal must be false after cancel")
    }

    @MainActor @Test
    func shutdownCleansUpAllResources() {
        let keyInterceptor = SpyKeyInterceptor()
        let textInserter = SpyTextInserter()
        let controller = RecordingController(
            keyInterceptor: keyInterceptor,
            textInserter: textInserter,
            appState: SpyBannerPresenter()
        )
        controller.isRecording = true
        controller.shutdown()
        #expect(keyInterceptor.stopCallCount >= 1, "Shutdown must stop key interceptor")
        #expect(textInserter.cancelCalled, "Shutdown must cancel text inserter")
        #expect(!controller.isRecording, "isRecording must be false after shutdown")
        #expect(!controller.isProcessingFinal, "isProcessingFinal must be false after shutdown")
    }

    @MainActor @Test
    func shutdownIdempotent() {
        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(),
            textInserter: SpyTextInserter(),
            appState: SpyBannerPresenter()
        )
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
        let banner = SpyBannerPresenter()
        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(),
            textInserter: SpyTextInserter(),
            appState: banner
        )
        controller.isRecording = true
        #expect(banner.isRecording, "Setting isRecording should sync to appState")
        controller.isRecording = false
        #expect(!banner.isRecording, "Clearing isRecording should sync to appState")
    }

    @MainActor @Test
    func isProcessingFinalSyncsToAppState() {
        let banner = SpyBannerPresenter()
        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(),
            textInserter: SpyTextInserter(),
            appState: banner
        )
        controller.isProcessingFinal = true
        #expect(banner.isProcessingFinal, "Setting isProcessingFinal should sync to appState")
        controller.isProcessingFinal = false
        #expect(!banner.isProcessingFinal, "Clearing isProcessingFinal should sync to appState")
    }
}
