import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - Streaming Recording Path Tests

/// Holds all dependencies for streaming recording tests.
@MainActor
struct StreamingTestContext {
    let controller: RecordingController
    let provider: MockStreamingProvider
    let session: MockStreamingSession
    let textInserter: SpyTextInserter
    let banner: SpyBannerPresenter
    let keyInterceptor: SpyKeyInterceptor
}

@Suite("RecordingController — Streaming Recording Lifecycle")
struct StreamingRecordingTests {

    /// Creates a testable RecordingController wired with a MockStreamingProvider.
    /// Builds on the shared `makeTestRecordingController()` and adds streaming-specific mocks.
    @MainActor
    private func makeController(
        providerConfigured: Bool = true,
        providerShouldFail: Bool = false
    ) -> StreamingTestContext {
        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let settings = SpySettings()

        // Zero trailing-final timeout so stop tasks complete without a real wait.
        settings.streamingTrailingFinalTimeout = 0.0

        let mockSession = MockStreamingSession()
        let mockProvider = MockStreamingProvider()
        mockProvider.isConfigured = providerConfigured
        mockProvider.mockSession = mockSession
        mockProvider.shouldFailOnStart = providerShouldFail

        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(mockProvider)

        let (controller, ki, ti, bp) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings
        )

        return StreamingTestContext(
            controller: controller, provider: mockProvider, session: mockSession,
            textInserter: ti, banner: bp, keyInterceptor: ki
        )
    }

    // MARK: - Start

    @MainActor @Test
    func startStreamingRecording_createsLiveController() async throws {
        let ctx = makeController()
        ctx.controller.startRecording()
        #expect(ctx.controller.liveStreamingController != nil,
                "Streaming provider should create a LiveStreamingController")
        #expect(ctx.controller.isRecording, "Should be in recording state")
    }

    @MainActor @Test
    func startStreamingRecording_capturesTarget() {
        let ctx = makeController()
        ctx.controller.startRecording()
        #expect(ctx.textInserter.captureTargetCalled,
                "Must capture accessibility target before streaming")
    }

    @MainActor @Test
    func startStreamingRecording_startsKeyInterceptor() {
        let ctx = makeController()
        ctx.controller.startRecording()
        #expect(ctx.keyInterceptor.startCallCount >= 1,
                "Must start key interceptor for Escape/Enter handling")
    }

    // MARK: - LiveStreamingController Event Handling

    @MainActor @Test
    func streamingRecording_interimText_insertsPartial() {
        let ctx = makeController()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        let interim = TranscriptionResult(transcript: "hello world", isFinal: false)
        lsc.handleEvent(.interim(interim))

        #expect(ctx.textInserter.insertedTexts.contains(where: { $0.contains("hello world") }),
                "Interim text should be inserted via TextInserter")
    }

    @MainActor @Test
    func streamingRecording_finalText_commitsFinal() {
        let ctx = makeController()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        let result = TranscriptionResult(transcript: "hello world", isFinal: true, speechFinal: true)
        lsc.handleEvent(.finalResult(result))

        #expect(!ctx.textInserter.insertedTexts.isEmpty, "Final text should be inserted")
    }

    @MainActor @Test
    func streamingRecording_finalUpdatesFullTranscript() {
        let ctx = makeController()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        let result = TranscriptionResult(transcript: "hello world", isFinal: true)
        lsc.handleEvent(.finalResult(result))

        #expect(ctx.controller.fullTranscript.contains("hello world"),
                "Full transcript should accumulate final text")
    }

    @MainActor @Test
    func streamingRecording_trailingFinalCountsTowardSessionMetrics() async throws {
        let ctx = makeController()
        ctx.controller.startRecording()

        guard let sessionId = ctx.controller.testCurrentMetricsSessionId else {
            Issue.record("Metrics session was not started")
            return
        }
        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created")
            return
        }

        ctx.controller.stopRecording(reason: .hotkey)
        lsc.handleEvent(.finalResult(TranscriptionResult(
            transcript: "much higher",
            confidence: 0.99,
            words: [],
            speechFinal: true
        )))

        try await waitUntil(timeout: .seconds(5)) { !ctx.controller.isProcessingFinal }
        try await waitUntilAsync(timeout: .seconds(5), interval: .milliseconds(20)) {
            let completed = await SessionMetricsStore.shared.recentCompletedSessions(limit: 50)
            return completed.contains(where: { $0.sessionId == sessionId })
        }

        let completed = await SessionMetricsStore.shared.recentCompletedSessions(limit: 50)
        guard let metrics = completed.last(where: { $0.sessionId == sessionId }) else {
            Issue.record("Completed metrics session not found")
            return
        }

        #expect(metrics.wordsProduced == 2, "Trailing final words must be counted before session end")
        #expect(metrics.endReason == RecordingController.StopReason.hotkey.rawValue)
    }

    // MARK: - Stop / Cancel

    @MainActor @Test
    func streamingRecording_stop_setsProcessingFinal() {
        let ctx = makeController()
        ctx.controller.startRecording()
        #expect(ctx.controller.isRecording)

        ctx.controller.stopRecording(reason: .hotkey)
        #expect(!ctx.controller.isRecording, "Should stop recording")
        #expect(ctx.controller.isProcessingFinal, "Should enter processing final state")
    }

    @MainActor @Test
    func streamingRecording_cancel_resetsAllState() {
        let ctx = makeController()
        ctx.controller.startRecording()
        ctx.controller.cancelRecording()

        #expect(!ctx.controller.isRecording, "Should stop recording")
        #expect(!ctx.controller.isProcessingFinal, "Should not be processing final")
        #expect(ctx.controller.fullTranscript.isEmpty, "Transcript should be cleared")
        #expect(ctx.textInserter.cancelCalled, "Text inserter should be cancelled")
        #expect(ctx.keyInterceptor.stopCallCount >= 1, "Key interceptor should be stopped")
    }

    // MARK: - Error Path

    @MainActor @Test
    func streamingRecording_errorEvent_triggersBanner() async throws {
        let ctx = makeController()
        ctx.controller.startRecording()

        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        lsc.handleEvent(.error(DeepgramError.connectionFailed("test error")))
        lsc.onError?(DeepgramError.connectionFailed("test error"))

        try await Task.sleep(for: .milliseconds(100))

        #expect(!ctx.controller.isRecording, "Should stop recording on error")
    }

    // MARK: - Provider Not Configured

    @MainActor @Test
    func streamingRecording_noConfiguredProvider_showsBanner() {
        let ctx = makeController(providerConfigured: false)
        ctx.controller.startRecording()

        #expect(!ctx.controller.isRecording, "Should not start recording")
        #expect(ctx.banner.bannerMessages.count == 1, "Should show error banner")
        #expect(ctx.banner.bannerMessages.first?.1 == .error, "Banner should be error style")
    }
}

// MARK: - Streaming Duration Accounting

/// Streaming dictation must contribute its elapsed time to total transcribed
/// duration. Previously, the streaming final path passed `audioDurationSeconds: 0`
/// to `recordTranscription`, causing `totalSecondsTranscribed`, per-provider
/// seconds, and the dashboard "time saved" calculation to stay at zero for
/// every streaming recording, even while words and recording count increased.
@Suite("RecordingController: Streaming Duration Accounting", .serialized)
struct StreamingDurationAccountingTests {

    @MainActor
    private func makeController() -> StreamingTestContext {
        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let settings = SpySettings()
        settings.streamingTrailingFinalTimeout = 0.0

        let mockSession = MockStreamingSession()
        let mockProvider = MockStreamingProvider()
        mockProvider.isConfigured = true
        mockProvider.mockSession = mockSession
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(mockProvider)

        let (controller, ki, ti, bp) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings
        )
        return StreamingTestContext(
            controller: controller, provider: mockProvider, session: mockSession,
            textInserter: ti, banner: bp, keyInterceptor: ki
        )
    }

    @MainActor @Test
    func streamingFinal_recordsElapsedSegmentDurationNotZero() async throws {
        let stats = Statistics.shared
        let baselineSeconds = stats.totalSecondsTranscribed
        let baselineDeepgramSeconds = stats.providerUsage[ProviderId.deepgram]?.seconds ?? 0

        let ctx = makeController()
        ctx.controller.startRecording()
        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        try await Task.sleep(for: .milliseconds(120))
        lsc.handleEvent(.finalResult(TranscriptionResult(
            transcript: "hello world",
            isFinal: true,
            speechFinal: true
        )))

        let delta = stats.totalSecondsTranscribed - baselineSeconds
        #expect(delta >= 0.1,
                "Streaming final must contribute at least the elapsed segment time (>= 100ms) to totalSecondsTranscribed; got delta=\(delta)")

        let providerDelta = (stats.providerUsage[ProviderId.deepgram]?.seconds ?? 0) - baselineDeepgramSeconds
        #expect(providerDelta >= 0.1,
                "Per-provider seconds must also grow by at least the elapsed segment time; got delta=\(providerDelta)")
    }

    @MainActor @Test
    func streamingFinals_accumulateSegmentDurations() async throws {
        let stats = Statistics.shared
        let baseline = stats.totalSecondsTranscribed

        let ctx = makeController()
        ctx.controller.startRecording()
        guard let lsc = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created"); return
        }

        try await Task.sleep(for: .milliseconds(80))
        lsc.handleEvent(.finalResult(TranscriptionResult(transcript: "hello", isFinal: true, speechFinal: true)))
        let afterFirst = stats.totalSecondsTranscribed - baseline

        try await Task.sleep(for: .milliseconds(80))
        lsc.handleEvent(.finalResult(TranscriptionResult(transcript: "world again", isFinal: true, speechFinal: true)))
        let afterSecond = stats.totalSecondsTranscribed - baseline

        #expect(afterSecond > afterFirst,
                "Second final must add its own segment duration on top of the first; afterFirst=\(afterFirst), afterSecond=\(afterSecond)")
        #expect(afterSecond >= 0.15,
                "Two segments of ~80ms each should sum to >= 150ms; got \(afterSecond)")
    }
}
