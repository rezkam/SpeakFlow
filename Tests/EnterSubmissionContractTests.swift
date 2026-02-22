import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Enter Submission Contract — Integration")
struct EnterSubmissionContractTests {

    @MainActor
    private func makeStreamingContext() -> StreamingTestContext {
        let transcription = SpyTranscription()
        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let settings = SpySettings()
        let keyInterceptor = SpyKeyInterceptor()
        let textInserter = SpyTextInserter()
        let banner = SpyBannerPresenter()

        let mockSession = MockStreamingSession()
        let mockProvider = MockStreamingProvider()
        mockProvider.isConfigured = true
        mockProvider.mockSession = mockSession

        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(mockProvider)

        let controller = RecordingController(
            keyInterceptor: keyInterceptor,
            textInserter: textInserter,
            appState: banner,
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings,
            transcription: transcription
        )
        controller.testMode = .live

        return StreamingTestContext(
            controller: controller, provider: mockProvider, session: mockSession,
            textInserter: textInserter, banner: banner, keyInterceptor: keyInterceptor
        )
    }

    /// Regression guard:
    /// In streaming mode, submit must queue Enter while target focus context is still intact.
    /// Resetting before Enter can clear target tracking and make behavior intermittent.
    @MainActor @Test
    func streamingSubmitPressesEnterBeforeReset() async throws {
        let ctx = makeStreamingContext()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created")
            return
        }

        lsc.handleEvent(.finalResult(TranscriptionResult(
            transcript: "hello world",
            isFinal: true,
            speechFinal: true
        )))

        ctx.controller.stopRecordingAndSubmit()

        try await waitUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
            ctx.textInserter.operations.contains(.pressEnterKey)
            && ctx.textInserter.operations.contains(.reset)
        }

        let enterIndex = ctx.textInserter.operations.firstIndex(of: .pressEnterKey)
        let resetIndex = ctx.textInserter.operations.firstIndex(of: .reset)
        #expect(enterIndex != nil, "Submit must trigger Enter")
        #expect(resetIndex != nil, "Submit finalization must reset inserter state")
        if let enterIndex, let resetIndex {
            #expect(
                enterIndex < resetIndex,
                "Enter must be queued before reset in streaming submit path"
            )
        }
    }

    /// Regression guard:
    /// Batch completion should queue Enter before reset for the same reason.
    @MainActor @Test
    func batchFinishQueuesEnterBeforeReset() async throws {
        let controller = RecordingController(
            keyInterceptor: SpyKeyInterceptor(),
            textInserter: SpyTextInserter(),
            appState: SpyBannerPresenter(),
            providerSettings: SpyProviderSettings(),
            providerRegistry: SpyProviderRegistry(),
            settings: SpySettings(),
            transcription: SpyTranscription()
        )
        controller.testMode = .live
        guard let textInserter = controller.textInserter as? SpyTextInserter else {
            Issue.record("Expected SpyTextInserter")
            return
        }
        controller.isProcessingFinal = true
        controller.fullTranscript = "final text"
        controller.shouldPressEnterOnComplete = true

        controller.finishIfDone()

        try await waitUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
            textInserter.operations.contains(.pressEnterKey)
            && textInserter.operations.contains(.reset)
        }

        let enterIndex = textInserter.operations.firstIndex(of: .pressEnterKey)
        let resetIndex = textInserter.operations.firstIndex(of: .reset)
        #expect(enterIndex != nil, "Finish must trigger Enter when requested")
        #expect(resetIndex != nil, "Finish finalization must reset inserter state")
        if let enterIndex, let resetIndex {
            #expect(
                enterIndex < resetIndex,
                "Enter must be queued before reset in batch finish path"
            )
        }
    }

    /// Regression guard:
    /// Enter during the same recording lifecycle is one-shot. A second Enter press while
    /// processing-final must not produce a second synthetic Enter key event.
    @MainActor @Test
    func enterSubmitIsOneShotPerRecordingLifecycle() async throws {
        let ctx = makeStreamingContext()
        ctx.controller.startRecording()
        guard ctx.keyInterceptor.onEnterPressed != nil else {
            Issue.record("Enter callback not wired")
            return
        }

        // First Enter stops and arms submit.
        ctx.keyInterceptor.onEnterPressed?()
        // Second Enter arrives while processing-final is active.
        ctx.keyInterceptor.onEnterPressed?()

        try await waitUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
            ctx.textInserter.operations.contains(.reset)
        }

        let enterCount = ctx.textInserter.operations.filter { $0 == .pressEnterKey }.count
        #expect(enterCount == 1, "Submit path must synthesize Enter exactly once")
    }

    /// Regression guard:
    /// Enter capture is one-shot. Once Enter has been captured in a lifecycle,
    /// additional Enter callbacks must not re-arm submit.
    @MainActor @Test
    func secondEnterDoesNotRearmSubmitFlag() {
        let ctx = makeStreamingContext()

        ctx.controller.isProcessingFinal = true
        ctx.keyInterceptor.onEnterPressed?()
        #expect(ctx.controller.shouldPressEnterOnComplete, "First Enter should arm submit")

        // Simulate consumption of the first request and verify second Enter is ignored.
        ctx.controller.shouldPressEnterOnComplete = false
        ctx.keyInterceptor.onEnterPressed?()
        #expect(!ctx.controller.shouldPressEnterOnComplete,
                "Second Enter in the same lifecycle must not re-arm submit")
    }
}
