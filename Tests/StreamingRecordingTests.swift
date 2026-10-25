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
    let soundPlayer: SpySoundEffectPlayer

    init(
        controller: RecordingController,
        provider: MockStreamingProvider,
        session: MockStreamingSession,
        textInserter: SpyTextInserter,
        banner: SpyBannerPresenter,
        keyInterceptor: SpyKeyInterceptor,
        soundPlayer: SpySoundEffectPlayer = SpySoundEffectPlayer()
    ) {
        self.controller = controller
        self.provider = provider
        self.session = session
        self.textInserter = textInserter
        self.banner = banner
        self.keyInterceptor = keyInterceptor
        self.soundPlayer = soundPlayer
    }
}

/// Streaming session whose close operation is controlled by the test.
/// This makes the cancellation suspension window deterministic.
actor SuspendingCloseStreamingSession: StreamingSession {
    private let eventContinuation: AsyncStream<TranscriptionEvent>.Continuation
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private(set) var closeCallCount = 0

    init() {
        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func sendAudio(_ data: Data) async throws {}
    func finalize() async throws {}

    func close() async throws {
        closeCallCount += 1
        await withCheckedContinuation { closeWaiter = $0 }
        eventContinuation.finish()
    }

    func keepAlive() async throws {}

    func releaseClose() {
        closeWaiter?.resume()
        closeWaiter = nil
    }
}

/// Suspends observability configuration to exercise the second asynchronous
/// startup boundary after the provider handshake has returned a session.
actor SuspendingObservabilityStreamingSession: StreamingSession {
    private let eventContinuation: AsyncStream<TranscriptionEvent>.Continuation
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasEnteredConfiguration = false
    private(set) var closeCallCount = 0

    init() {
        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func sendAudio(_ data: Data) async throws {}
    func finalize() async throws {}
    func keepAlive() async throws {}

    func close() async throws {
        closeCallCount += 1
        eventContinuation.finish()
    }

    func setObservabilitySessionId(_ sessionId: UUID?) async {
        hasEnteredConfiguration = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilObservabilityConfigurationStarts() async {
        guard !hasEnteredConfiguration else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func releaseObservabilityConfiguration() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

// These tests share Statistics.shared, including the nested duration checks.
// Serialize their fixture scope; explicit in-test concurrency remains exercised.
@Suite("RecordingController: Streaming Recording Lifecycle", .serialized)
struct StreamingRecordingTests {
    @Test @MainActor
    func retiredReliabilityCallbacksCannotIncrementReplacementMetrics() async throws {
        let ctx = makeController()
        ctx.controller.startRecording()
        try await waitUntil { ctx.controller.liveStreamingController?.isActive == true }
        let old = try #require(ctx.controller.liveStreamingController)
        let keepAlive = try #require(old.onKeepAliveSent)
        let reconnected = try #require(old.onReconnected)
        ctx.controller.cancelRecording()
        ctx.provider.mockSession = MockStreamingSession()
        ctx.controller.startRecording()
        defer { ctx.controller.cancelRecording() }
        try await waitUntil { ctx.controller.liveStreamingController?.isActive == true }
        let replacement = try #require(ctx.controller.testCurrentMetricsSessionId)
        try await waitUntilAsync { await SessionMetricsStore.shared.activeSession(id: replacement) != nil }
        keepAlive()
        reconnected()
        await #expect(throws: PollingError.self) {
            try await waitUntilAsync(timeout: .milliseconds(150), interval: .milliseconds(10)) {
                guard let metrics = await SessionMetricsStore.shared.activeSession(id: replacement) else { return false }
                return metrics.keepAlivesSent > 0 || metrics.reconnections > 0
            }
        }
        let current = try #require(ctx.controller.liveStreamingController)
        current.onKeepAliveSent?()
        current.onReconnected?()
        try await waitUntilAsync {
            guard let metrics = await SessionMetricsStore.shared.activeSession(id: replacement) else { return false }
            return metrics.keepAlivesSent > 0 && metrics.reconnections > 0
        }
        let metrics = try #require(await SessionMetricsStore.shared.activeSession(id: replacement))
        #expect(metrics.keepAlivesSent == 1 && metrics.reconnections == 1)
    }


    /// Creates a testable RecordingController wired with a MockStreamingProvider.
    /// Builds on the shared `makeTestRecordingController()` and adds streaming-specific mocks.
    @MainActor
    private func makeController(
        providerConfigured: Bool = true,
        providerShouldFail: Bool = false,
        trailingFinalTimeout: Double = 0
    ) -> StreamingTestContext {
        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let settings = SpySettings()

        // Most tests avoid a real trailing-final wait; specific startup-stop
        // regressions override this to prove an inactive session does not wait.
        settings.streamingTrailingFinalTimeout = trailingFinalTimeout

        let mockSession = MockStreamingSession()
        let mockProvider = MockStreamingProvider()
        mockProvider.isConfigured = providerConfigured
        mockProvider.mockSession = mockSession
        mockProvider.shouldFailOnStart = providerShouldFail

        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(mockProvider)

        let soundPlayer = SpySoundEffectPlayer()
        let (controller, ki, ti, bp) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings,
            playSoundEffect: { soundPlayer.play($0) }
        )

        return StreamingTestContext(
            controller: controller, provider: mockProvider, session: mockSession,
            textInserter: ti, banner: bp, keyInterceptor: ki, soundPlayer: soundPlayer
        )
    }

    @MainActor
    private func makeReconnectController(
        sessions: [any StreamingSession]? = nil
    ) -> (RecordingController, MultiSessionMockProvider, SpyTextInserter) {
        let providerSettings = SpyProviderSettings()
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"

        let provider = MultiSessionMockProvider()
        provider.sessions = sessions ?? [MockStreamingSession(), MockStreamingSession()]

        let providerRegistry = SpyProviderRegistry()
        providerRegistry.register(provider)

        let settings = SpySettings()
        settings.streamingKeepAliveEnabled = false
        settings.streamingReconnectEnabled = true
        settings.streamingTrailingFinalTimeout = 0

        let (controller, _, inserter, _) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings
        )
        return (controller, provider, inserter)
    }

    // MARK: - Start

    @MainActor @Test
    func startStreamingRecording_createsLiveController() async throws {
        let ctx = makeController()
        ctx.controller.startRecording()
        try await waitUntil {
            ctx.provider.startSessionCallCount == 1
                && ctx.controller.liveStreamingController?.recording == true
        }
        #expect(ctx.controller.liveStreamingController != nil,
                "Streaming provider should create a LiveStreamingController")
        #expect(ctx.controller.isRecording, "Should be in recording state")
        #expect(ctx.soundPlayer.count(.start) == 1,
                "Start cue must play once when local capture begins")
    }

    /// The microphone capture cue is local, not a proxy for remote provider
    /// readiness. A slow WebSocket handshake must not make the hotkey feel
    /// unresponsive or delay the user until it is safe to begin speaking.
    @MainActor @Test
    func startStreamingRecording_signalsCaptureBeforeProviderHandshakeCompletes() async throws {
        let ctx = makeController()
        ctx.provider.startDelay = 1.0

        ctx.controller.startRecording()
        try await waitUntil { ctx.provider.startSessionCallCount == 1 }

        #expect(ctx.soundPlayer.count(.start) == 1,
                "Capture cue must play before the slow provider handshake completes")
        #expect(ctx.controller.liveStreamingController?.recording == false,
                "Provider session should still be unready at the capture cue")
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

    @MainActor @Test(arguments: [false, true])
    func reconnectPreservesInsertionAndBothStatisticsStores(interimBeforeDrop: Bool) async throws {
        let first = MockStreamingSession()
        let second = MockStreamingSession()
        let (controller, provider, inserter) = makeReconnectController(sessions: [first, second])
        let initialWords = Statistics.shared.totalWords
        let initialCalls = Statistics.shared.totalApiCalls
        controller.startRecording()
        defer { controller.cancelRecording() }
        try await waitUntil { controller.liveStreamingController?.recording == true }
        let sessionId = try #require(controller.testCurrentMetricsSessionId)
        let firstResult = TranscriptionResult(
            transcript: "first phrase", isFinal: !interimBeforeDrop, speechFinal: !interimBeforeDrop
        )
        await first.emit(interimBeforeDrop ? .interim(firstResult) : .finalResult(firstResult))
        try await waitUntil { inserter.insertedTexts.joined() == (interimBeforeDrop ? "first phrase" : "first phrase ") }
        await first.emit(.closed)
        try await waitUntil { provider.startSessionCallCount == 2 && controller.liveStreamingController?.recording == true }
        await second.emit(.finalResult(TranscriptionResult(
            transcript: "second phrase", isFinal: true, speechFinal: true
        )))
        try await waitUntil { inserter.insertedTexts.joined() == "first phrase second phrase " }
        #expect(inserter.deletedCounts.isEmpty, "A reconnect must not replace the previous connection's committed text")
        #expect(Statistics.shared.totalWords == initialWords + 4)
        #expect(Statistics.shared.totalApiCalls == initialCalls + 1, "Reconnect is not a second recording")
        try await waitUntilAsync {
            guard let metrics = await SessionMetricsStore.shared.activeSession(id: sessionId) else { return false }
            return metrics.reconnections == 1 && metrics.wordsProduced == 4
        }
        controller.stopRecording()
        try await waitUntil { !controller.isProcessingFinal }
        let completed = await SessionMetricsStore.shared.recentCompletedSessions(limit: 200)
        let metrics = try #require(completed.first { $0.sessionId == sessionId })
        #expect(metrics.wordsProduced == 4 && metrics.reconnections == 1)
        #expect(metrics.providerId == provider.id && metrics.mode == .streaming)
    }

    @MainActor @Test
    func streamingRecording_closedEventReconnectsWithoutStoppingRecording() async throws {
        let (controller, provider, _) = makeReconnectController()
        controller.startRecording()

        try await waitUntil {
            provider.startSessionCallCount == 1
                && controller.liveStreamingController?.recording == true
        }
        guard let liveController = controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created")
            return
        }

        liveController.handleEvent(.closed)

        try await waitUntil {
            provider.startSessionCallCount == 2 && liveController.recording
        }

        #expect(controller.isRecording,
                "A reconnectable close must not stop the recording lifecycle")
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

    /// Stop before provider readiness has no trailing server audio to flush.
    /// It must finish promptly even when the configured trailing-final timeout
    /// is nonzero, rather than blocking the next recording attempt.
    @MainActor @Test
    func streamingRecording_stopDuringInitialHandshakeSkipsTrailingFinalWait() async throws {
        let ctx = makeController(trailingFinalTimeout: 1.0)
        ctx.provider.startDelay = 0.4

        ctx.controller.startRecording()
        try await waitUntil { ctx.provider.startSessionCallCount == 1 }

        let stopStart = Date()
        ctx.controller.stopRecording(reason: .hotkey)
        try await waitUntil(timeout: .seconds(0.5)) { !ctx.controller.isProcessingFinal }
        let elapsed = Date().timeIntervalSince(stopStart)

        #expect(elapsed < 0.5,
                "Stopping before provider readiness must skip the trailing-final wait, took \(elapsed)s")
        try await waitUntilAsync(timeout: .seconds(2)) { await ctx.session.closeCalled }
    }

    /// A slow initial provider handshake must not reactivate capture after the
    /// user cancels. The returned session must be closed instead of becoming an
    /// orphaned live connection that can still send audio or count a recording.
    @MainActor @Test
    func streamingRecording_cancelDuringInitialHandshakeDoesNotActivateLateSession() async throws {
        let ctx = makeController()
        ctx.provider.startDelay = 0.4

        ctx.controller.startRecording()
        try await waitUntil { ctx.provider.startSessionCallCount == 1 }
        guard let startingController = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created")
            return
        }

        ctx.controller.cancelRecording()

        try await waitUntilAsync(timeout: .seconds(2)) { await ctx.session.closeCalled }
        #expect(!startingController.recording,
                "A cancelled initial handshake must not activate its late session")
        #expect(ctx.controller.liveStreamingController == nil)
        #expect(!ctx.controller.isRecording)
    }

    /// Stop has the same invalidation requirement as cancel, but it retains a
    /// processing-final state while teardown runs. A late initial session must
    /// still be closed rather than activated.
    @MainActor @Test
    func streamingRecording_stopDuringInitialHandshakeDoesNotActivateLateSession() async throws {
        let ctx = makeController()
        ctx.provider.startDelay = 0.4

        ctx.controller.startRecording()
        try await waitUntil { ctx.provider.startSessionCallCount == 1 }
        guard let startingController = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created")
            return
        }

        ctx.controller.stopRecording(reason: .hotkey)

        try await waitUntilAsync(timeout: .seconds(2)) { await ctx.session.closeCalled }
        #expect(!startingController.recording,
                "A stopped initial handshake must not activate its late session")
        #expect(ctx.controller.liveStreamingController == nil)
        #expect(!ctx.controller.isRecording)
    }

    /// The post-handshake observability setup is also asynchronous. Cancelling
    /// in that window must close the returned session before it can activate.
    @MainActor @Test
    func streamingRecording_cancelDuringSessionConfigurationDoesNotActivateLateSession() async throws {
        let ctx = makeController()
        let delayedSession = SuspendingObservabilityStreamingSession()
        ctx.provider.mockSession = delayedSession

        ctx.controller.startRecording()
        try await waitUntil { ctx.provider.startSessionCallCount == 1 }
        guard let startingController = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created")
            return
        }
        await delayedSession.waitUntilObservabilityConfigurationStarts()

        ctx.controller.cancelRecording()
        await delayedSession.releaseObservabilityConfiguration()

        try await waitUntilAsync(timeout: .seconds(2)) { await delayedSession.closeCallCount == 1 }
        #expect(!startingController.recording,
                "Cancellation during session configuration must not activate the late session")
        #expect(ctx.controller.liveStreamingController == nil)
        #expect(!ctx.controller.isRecording)
    }

    /// Stop must invalidate the post-handshake configuration boundary too.
    @MainActor @Test
    func streamingRecording_stopDuringSessionConfigurationDoesNotActivateLateSession() async throws {
        let ctx = makeController()
        let delayedSession = SuspendingObservabilityStreamingSession()
        ctx.provider.mockSession = delayedSession

        ctx.controller.startRecording()
        try await waitUntil { ctx.provider.startSessionCallCount == 1 }
        guard let startingController = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created")
            return
        }
        await delayedSession.waitUntilObservabilityConfigurationStarts()

        ctx.controller.stopRecording(reason: .hotkey)
        await delayedSession.releaseObservabilityConfiguration()

        try await waitUntilAsync(timeout: .seconds(2)) { await delayedSession.closeCallCount == 1 }
        #expect(!startingController.recording,
                "Stop during session configuration must not activate the late session")
        #expect(ctx.controller.liveStreamingController == nil)
        #expect(!ctx.controller.isRecording)
    }

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
        #expect(ctx.keyInterceptor.cancelCallCount >= 1, "Key interception should be cancelled")
    }

    /// Regression guard:
    /// A suspended cancel task must only own the controller captured before it started.
    /// It must not clear or close a replacement controller started during suspension.
    @MainActor @Test
    func streamingRecording_cancelDoesNotOrphanReplacementController() async throws {
        let firstSession = SuspendingCloseStreamingSession()
        let secondSession = MockStreamingSession()
        defer {
            Task { await firstSession.releaseClose() }
        }
        let (controller, provider, _) = makeReconnectController(
            sessions: [firstSession, secondSession]
        )

        controller.startRecording()
        try await waitUntil {
            provider.startSessionCallCount == 1
                && controller.liveStreamingController?.recording == true
        }

        controller.cancelRecording()
        try await waitUntilAsync {
            await firstSession.closeCallCount == 1
        }

        controller.startRecording()
        try await waitUntil {
            provider.startSessionCallCount == 2
                && controller.liveStreamingController?.recording == true
        }
        guard let replacementController = controller.liveStreamingController else {
            Issue.record("Replacement LiveStreamingController not created")
            return
        }

        await firstSession.releaseClose()
        try await Task.sleep(for: .milliseconds(50))

        #expect(
            controller.liveStreamingController === replacementController,
            "Finishing the old cancel must not clear the replacement controller"
        )
        #expect(
            await !secondSession.closeCalled,
            "The replacement session must not be closed by the old cancel task"
        )

        controller.cancelRecording()
        try await waitUntilAsync {
            await secondSession.closeCalled
        }
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

        try await waitUntil {
            !ctx.controller.isRecording && !ctx.banner.bannerMessages.isEmpty
        }

        #expect(!ctx.controller.isRecording, "Should stop recording on error")
        #expect(ctx.banner.bannerMessages.count == 1,
                "A mid-session failure must present exactly one banner")
        #expect(ctx.banner.bannerMessages.contains(where: {
            $0.1 == .error && $0.0.localizedCaseInsensitiveContains("test error")
        }),
                "Mid-session streaming errors must show an error banner")
    }

    @MainActor @Test
    func streamingRecording_rejectedHandshakeShowsAuthBanner() async throws {
        let ctx = makeController()
        ctx.provider.startError = DeepgramError.handshakeRejected(statusCode: 401)

        ctx.controller.startRecording()

        try await waitUntil {
            !ctx.controller.isRecording && !ctx.banner.bannerMessages.isEmpty
        }

        #expect(ctx.banner.bannerMessages.contains(where: {
            $0.1 == .error
                && $0.0.contains("Deepgram API key is invalid or expired")
        }))
        #expect(ctx.banner.bannerMessages.count == 1,
                "The onError and start-failure paths must not double-present the banner")
        #expect(ctx.soundPlayer.count(.start) == 1,
                "A rejected handshake may follow an honest local capture cue")
        #expect(ctx.soundPlayer.count(.error) == 1,
                "A rejected handshake must play one error cue after capture begins")
    }

    @MainActor @Test
    func streamingRecording_closedWithoutTextUsesActiveProviderBanner() async throws {
        let ctx = makeController()
        ctx.provider.displayName = "Deepgram"
        ctx.controller.startRecording()
        try await waitUntil {
            ctx.controller.liveStreamingController?.recording == true
        }
        guard let liveController = ctx.controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created")
            return
        }

        liveController.onSessionClosed?()

        try await waitUntil {
            ctx.banner.bannerMessages.contains(where: { $0.1 == .error })
        }
        let message = ctx.banner.bannerMessages.last?.0 ?? ""
        #expect(message.contains("Deepgram"))
        #expect(!message.contains("Mistral"),
                "A provider-neutral close path must not name another provider")
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

        let soundPlayer = SpySoundEffectPlayer()
        let (controller, ki, ti, bp) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings,
            playSoundEffect: { soundPlayer.play($0) }
        )
        return StreamingTestContext(
            controller: controller, provider: mockProvider, session: mockSession,
            textInserter: ti, banner: bp, keyInterceptor: ki, soundPlayer: soundPlayer
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
}
