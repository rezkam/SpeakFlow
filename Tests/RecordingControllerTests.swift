import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - RecordingController Behavioral Tests

@Suite("RecordingController — Provider Configuration Gate")
struct RecordingControllerProviderGateTests {

    @MainActor @Test
    func autoEndStopReasonIsProviderNeutral() {
        #expect(RecordingController.StopReason.autoEnd.rawValue == "SILENCE_AUTO_END")
    }

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
    func enterDuringProcessingFinalIsOneShot() {
        let (controller, keyInterceptor, _, _) = makeTestRecordingController()
        controller.isProcessingFinal = true
        keyInterceptor.onEnterPressed?()
        #expect(controller.shouldPressEnterOnComplete, "First Enter should arm submit")
        controller.shouldPressEnterOnComplete = false

        // Second Enter in the same processing-final lifecycle must not re-arm.
        keyInterceptor.onEnterPressed?()
        #expect(!controller.shouldPressEnterOnComplete, "Second Enter must be ignored by one-shot guard")
    }
}

@Suite("RecordingController — Cancel & Shutdown")
struct RecordingControllerCleanupTests {

    @MainActor @Test
    func cancelRecordingStopsKeyInterceptor() {
        let (controller, keyInterceptor, _, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.cancelRecording()
        #expect(keyInterceptor.cancelCallCount >= 1, "Cancel must cancel key interception")
        #expect(keyInterceptor.stopCallCount == 0,
                "Cancel must not use stop(), which would deliver swallowed keys")
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
        #expect(keyInterceptor.cancelCallCount >= 1, "Shutdown must cancel key interception")
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

// MARK: - Error banner & batch provider dispatch tests

@Suite("RecordingController — Error Banners & Batch Provider Dispatch")
@MainActor
struct RecordingControllerErrorBannerTests {

    @Test
    func onChunkErrorShowsErrorBanner() {
        let (controller, _, _, banner) = makeTestRecordingController()
        controller.transcription.queueBridge.onChunkError?(
            TranscriptionError.httpError(statusCode: 403, body: "Forbidden")
        )
        #expect(banner.bannerMessages.count == 1, "Error banner must appear on chunk failure")
        #expect(banner.bannerMessages.first?.1 == .error, "Banner style must be .error")
    }

    @Test
    func onChunkErrorBannerMessageContainsActionableText() {
        let providerSettings = SpyProviderSettings()
        providerSettings.activeProviderId = ProviderId.chatGPT
        let (controller, _, _, banner) = makeTestRecordingController(providerSettings: providerSettings)

        controller.transcription.queueBridge.onChunkError?(
            TranscriptionError.httpError(statusCode: 403, body: "Forbidden")
        )

        let message = banner.bannerMessages.first?.0 ?? ""
        #expect(message.localizedCaseInsensitiveContains("ChatGPT"),
                "Auth error for ChatGPT must mention ChatGPT in the banner")
        #expect(message.localizedCaseInsensitiveContains("re-login") ||
                message.localizedCaseInsensitiveContains("expired"),
                "Auth error must suggest re-login or mention expiry")
    }

    @Test
    func successfulTranscriptionDismissesErrorBanner() {
        let (controller, _, _, banner) = makeTestRecordingController()
        // Fire an error first
        controller.transcription.queueBridge.onChunkError?(
            TranscriptionError.httpError(statusCode: 500, body: "err")
        )
        #expect(banner.bannerMessages.count == 1)

        // Now simulate a successful text delivery
        controller.transcription.queueBridge.onTextReady?("hello")
        #expect(banner.dismissCount == 1,
                "Successful transcription must dismiss the previous error banner")
    }

    @Test
    func startBatchRecordingSetsBatchProviderOnTranscription() {
        let providerSettings = SpyProviderSettings()
        providerSettings.activeProviderId = ProviderId.mistralBatch
        let registry = SpyProviderRegistry()
        let mockProvider = MockBatchProvider()
        mockProvider.isConfigured = true
        registry.register(mockProvider)
        let spyTranscription = SpyTranscription()
        let (controller, _, _, _) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: registry,
            transcription: spyTranscription
        )

        controller.startRecording()

        #expect(spyTranscription.activeBatchProvider != nil,
                "startBatchRecording must set activeBatchProvider on the transcription coordinator")
    }

    @Test
    func userFacingMessageAuthChatGPT() {
        let msg = RecordingController.userFacingMessage(
            for: TranscriptionError.httpError(statusCode: 403, body: ""),
            providerId: ProviderId.chatGPT
        )
        #expect(msg.localizedCaseInsensitiveContains("ChatGPT"))
        #expect(msg.localizedCaseInsensitiveContains("re-login") ||
                msg.localizedCaseInsensitiveContains("expired"))
    }

    @Test
    func userFacingMessageAuthMistral() {
        let msg = RecordingController.userFacingMessage(
            for: TranscriptionError.httpError(statusCode: 401, body: ""),
            providerId: ProviderId.mistral
        )
        #expect(msg.localizedCaseInsensitiveContains("Mistral"))
        #expect(msg.localizedCaseInsensitiveContains("API key") ||
                msg.localizedCaseInsensitiveContains("expired"))
    }

    @Test
    func userFacingMessageRateLimited() {
        let msg = RecordingController.userFacingMessage(
            for: TranscriptionError.rateLimited(retryAfter: nil),
            providerId: ProviderId.deepgram
        )
        #expect(msg.localizedCaseInsensitiveContains("rate limit") ||
                msg.localizedCaseInsensitiveContains("wait"))
    }

    @Test
    func userFacingMessageNetwork() {
        let msg = RecordingController.userFacingMessage(
            for: TranscriptionError.networkError(underlying: URLError(.notConnectedToInternet)),
            providerId: ProviderId.mistral
        )
        #expect(msg.localizedCaseInsensitiveContains("network") ||
                msg.localizedCaseInsensitiveContains("internet"))
    }
}

// MARK: - Mock batch provider for tests

private final class MockBatchProvider: BatchTranscriptionProvider, @unchecked Sendable {
    let id = ProviderId.mistralBatch
    let displayName = "Mock Batch"
    let mode: ProviderMode = .batch
    let authRequirement: ProviderAuthRequirement = .apiKey(providerId: ProviderId.mistralBatch)
    var isConfigured = false
    func transcribe(audio: Data) async throws -> String { "" }
    func validateAPIKey(_ key: String) async -> String? { nil }
}

@Suite("RecordingController — Target Capture Fails Closed")
struct RecordingControllerTargetCaptureTests {
    /// Regression guard: a transient Accessibility failure at start used to
    /// leave no destination, which disabled every focus protection for the
    /// session and let dictation follow whichever app was focused later.
    @MainActor @Test
    func recordingDoesNotStartWithoutACapturedTarget() {
        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let provider = MockStreamingProvider()
        provider.isConfigured = true
        provider.mockSession = MockStreamingSession()
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(provider)
        let sounds = SpySoundEffectPlayer()
        let (controller, keyInterceptor, textInserter, banner) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            playSoundEffect: { sounds.play($0) }
        )
        textInserter.captureSucceeds = false

        controller.startRecording()

        #expect(!controller.isRecording, "Recording must not start without a safe destination")
        #expect(controller.liveStreamingController == nil, "No audio capture or provider session may start")
        #expect(keyInterceptor.startCallCount == 0, "Enter/Escape must not be intercepted for a recording that never started")
        #expect(sounds.count(.error) == 1)
        #expect(sounds.count(.start) == 0)
        #expect(banner.bannerMessages.contains { $0.0.contains("text field") },
                "The user must be told why dictation did not start")
    }
}

/// Each recording owns its callbacks and its finalization. Shared
/// isRecording / isProcessingFinal flags cannot tell recordings apart, so late
/// work from a retired recording used to act on the next one.
@Suite("RecordingController — Session Identity", .serialized)
struct RecordingControllerSessionIdentityTests {
    @MainActor
    private func makeStreaming(session: any StreamingSession = MockStreamingSession()) -> (RecordingController, SpyTextInserter, SpyBannerPresenter, SpySoundEffectPlayer) {
        let providerSettings = SpyProviderSettings()
        let registry = SpyProviderRegistry()
        let provider = MockStreamingProvider()
        provider.mockSession = session
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        registry.register(provider)
        let settings = SpySettings()
        settings.streamingTrailingFinalTimeout = 0
        let sounds = SpySoundEffectPlayer()
        let (controller, _, inserter, banner) = makeTestRecordingController(
            providerSettings: providerSettings, providerRegistry: registry, settings: settings,
            playSoundEffect: { sounds.play($0) }
        )
        return (controller, inserter, banner, sounds)
    }

    @MainActor
    private struct BatchContext {
        let controller: RecordingController
        let inserter: SpyTextInserter
        let transcription: SpyTranscription
        let banner: SpyBannerPresenter
        let sounds: SpySoundEffectPlayer
    }

    @MainActor
    private func makeBatch() -> BatchContext {
        let providerSettings = SpyProviderSettings()
        providerSettings.activeProviderId = ProviderId.mistralBatch
        let registry = SpyProviderRegistry()
        let provider = MockBatchProvider()
        provider.isConfigured = true
        registry.register(provider)
        let transcription = SpyTranscription()
        let sounds = SpySoundEffectPlayer()
        let (controller, _, inserter, banner) = makeTestRecordingController(
            providerSettings: providerSettings, providerRegistry: registry, transcription: transcription,
            playSoundEffect: { sounds.play($0) }
        )
        return BatchContext(
            controller: controller, inserter: inserter, transcription: transcription, banner: banner, sounds: sounds
        )
    }

    @MainActor @Test
    func cancelDuringStreamingStopDiscardsPendingUploads() async throws {
        let session = SuspendedUploadSession()
        let (controller, inserter, _, _) = makeStreaming(session: session)
        controller.startRecording()
        let stream = try #require(controller.liveStreamingController)
        defer { Task { @MainActor in await stream.cancel() } }
        try await waitUntil { stream.isActive }
        try #require(stream.isActive)
        stream.stopDrainTimeout = .seconds(10)
        for byte in UInt8(1)...3 { stream._testEnqueueAudioFrame(Data([byte])) }
        try await waitUntilAsync { await session.sendStarted }
        try #require(await session.sendStarted)
        try #require(stream._testPendingAudioChunkCount == 2)

        controller.stopRecordingAndSubmit()
        await Task.yield()
        controller.cancelRecording()
        try await waitUntil(timeout: .seconds(1)) { stream._testAudioSessionRefIsShutdown }
        #expect(stream._testAudioSessionRefIsShutdown)
        #expect(stream._testPendingAudioChunkCount == 0)
        #expect(await session.uploads == 0)
        #expect(!inserter.operations.contains(.pressEnterKey))
        #expect(!controller.isRecording && !controller.isProcessingFinal)
    }

    @MainActor @Test
    func streamingTextFromARetiredRecordingIsNotTypedIntoTheNextOne() async throws {
        let (controller, inserter, _, _) = makeStreaming()
        controller.startRecording()
        let first = try #require(controller.liveStreamingController)
        controller.stopRecording(reason: .hotkey)
        try await waitUntil { !controller.isProcessingFinal }

        controller.startRecording()
        #expect(controller.isRecording)
        first.onTextUpdate?("late", 0, true, "late")
        first.onTextUpdate?("", 5, false, "")

        #expect(!inserter.operations.contains(.insertText("late ")),
                "A retired recording's trailing final must not be typed into the new recording")
        #expect(!inserter.operations.contains(.deleteChars(5)),
                "A retired recording's interim deletion must not erase the new recording's text")
    }

    @MainActor @Test
    func deferredStreamingErrorCannotStopReplacementRecording() async throws {
        let (controller, _, _, _) = makeStreaming()
        controller.startRecording()
        let first = try #require(controller.liveStreamingController)
        try await waitUntil { first.isActive }
        try #require(first.isActive)
        first.onError?(DeepgramError.connectionFailed("test failure"))
        // Retire the accepted error before its deferred stop can execute.
        controller.cancelRecording()
        controller.startRecording()
        let replacement = try #require(controller.liveStreamingController)
        defer { controller.cancelRecording() }
        try await waitUntil { replacement.isActive || !controller.isRecording }
        #expect(controller.isRecording, "The old error's deferred stop must not stop its replacement")
        #expect(controller.liveStreamingController === replacement)
    }

    @MainActor @Test
    func streamingTextFromACancelledRecordingIsNotTypedIntoTheNextOne() async throws {
        let (controller, inserter, _, _) = makeStreaming()
        controller.startRecording()
        let first = try #require(controller.liveStreamingController)
        controller.cancelRecording()
        controller.startRecording()

        first.onTextUpdate?("", 4, false, "")
        first.onTextUpdate?("late", 0, true, "late")

        #expect(!inserter.operations.contains(.deleteChars(4)))
        #expect(!inserter.operations.contains(.insertText("late ")))
    }

    @MainActor @Test
    func finalizationOwnsItsEnterAndCleanupAgainstANewRecording() async throws {
        let (controller, inserter, _, _) = makeStreaming()
        let enterGate = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(400)) }
        inserter.pendingTaskAfterEnter = enterGate

        controller.startRecording()
        controller.stopRecordingAndSubmit()
        try await waitUntil { inserter.operations.contains(.pressEnterKey) }

        // A new recording starts while the first one's Enter is still pending.
        controller.startRecording()
        let newCapture = try #require(inserter.operations.lastIndex(of: .captureTarget))
        #expect(inserter.operations[..<newCapture].contains(.cancelAndReset),
                "Starting over a pending submit must retire it, not let it submit into the new field")

        await enterGate.value
        try await Task.sleep(for: .milliseconds(100))

        #expect(!inserter.operations[newCapture...].contains(.reset),
                "The old finalizer's cleanup must not reset the new recording's inserter")
        #expect(controller.isRecording, "The new recording must keep running")
        #expect(!controller.isProcessingFinal, "The old finalizer must not take over the new recording")
    }

    @MainActor @Test
    func lateChunkFromARetiredBatchRecordingIsNotTranscribed() async throws {
        let ctx = makeBatch()
        let (controller, transcription) = (ctx.controller, ctx.transcription)
        controller.startRecording()
        let first = try #require(controller.recorder)
        controller.stopRecording(reason: .hotkey)
        controller.startRecording()
        #expect(controller.isRecording)

        await first.onChunkReady?(AudioChunk(wavData: Data([1, 2, 3]), durationSeconds: 1))
        try await Task.sleep(for: .milliseconds(100))

        #expect(transcription.transcribeCalls.isEmpty,
                "Audio from a retired recording must not get a ticket in the new recording's queue session")
    }

    @MainActor @Test
    func stopDuringBatchStartupIsNotTreatedAsAStartFailure() async throws {
        let ctx = makeBatch()
        let (controller, inserter, banner, sounds) = (ctx.controller, ctx.inserter, ctx.banner, ctx.sounds)
        controller.startRecording()
        // Stopped before the recorder finished starting: start() returns false on purpose.
        controller.stopRecordingAndSubmit()

        try await waitUntil(timeout: .seconds(5)) { inserter.operations.contains(.reset) }

        #expect(sounds.count(.error) == 0, "An intentional stop is not a startup failure")
        #expect(!banner.bannerMessages.contains { $0.0.contains("could not start") })
        #expect(inserter.operations.contains(.pressEnterKey),
                "The Enter captured for this recording must still be delivered")
    }

    @MainActor @Test
    func pollingSurvivesZeroTicketsWhileTextDeliveryIsHeld() async throws {
        let ctx = makeBatch()
        let (controller, inserter) = (ctx.controller, ctx.inserter)
        let bridge = ctx.transcription.queueBridge
        let gate = AsyncStream<Void>.makeStream()
        var deliveryHeld = false
        var finalizationDeferred = false
        bridge.startListening()
        bridge.beforeTextDeliveryForTesting = {
            deliveryHeld = true
            for await _ in gate.stream {}
        }
        // Exercise the fallback poller independently of the completion wakeup.
        bridge.onAllComplete = nil
        controller.batchFinalizationDeferredForTesting = { finalizationDeferred = true }
        defer {
            gate.continuation.finish()
            bridge.stopListening()
            controller.cancelRecording()
        }
        controller.startRecording()
        let recorder = try #require(controller.recorder)
        try await waitUntil { recorder._testIsRecording }
        try #require(recorder._testIsRecording)
        let ticket = await bridge.nextSequence()
        await bridge.submitResult(ticket: ticket, text: "tail")
        try await waitUntil { deliveryHeld }
        try #require(deliveryHeld)
        controller.stopRecordingAndSubmit()
        try await waitUntil { finalizationDeferred }
        try #require(finalizationDeferred)
        #expect(await bridge.getPendingCount() == 0)
        #expect(!inserter.operations.contains(.pressEnterKey))
        gate.continuation.finish()
        try await waitUntil(timeout: .seconds(2)) { inserter.operations.contains(.pressEnterKey) }
        #expect(inserter.operations.contains(.insertText("tail ")))
        #expect(inserter.operations.contains(.pressEnterKey))
        #expect(!controller.isProcessingFinal)
        if let text = inserter.operations.firstIndex(of: .insertText("tail ")),
           let enter = inserter.operations.firstIndex(of: .pressEnterKey) {
            #expect(text < enter)
        }
    }

    @MainActor @Test
    func stopCompletionAcknowledgesFinalChunkTicketAllocation() async throws {
        let ctx = makeBatch()
        let bridge = ctx.transcription.queueBridge
        let gate = AsyncStream<Void>.makeStream()
        var allocationEntered = false
        bridge.beforeSequenceAllocationForTesting = {
            allocationEntered = true
            for await _ in gate.stream {}
        }
        defer {
            gate.continuation.finish()
            ctx.controller.cancelRecording()
        }
        ctx.controller.startRecording()
        let recorder = try #require(ctx.controller.recorder)
        try await waitUntil { recorder._testIsRecording }
        try #require(recorder._testIsRecording)
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.2, count: 32_000))
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetVADActive(false)
        ctx.controller.stopRecordingAndSubmit()
        var stopCompleted = false
        let stopObserver = Task { @MainActor in
            await recorder.waitForStopCompletion()
            stopCompleted = true
        }
        try await waitUntil { allocationEntered }
        try #require(allocationEntered)
        // A bounded negative assertion while the allocation gate remains held.
        await #expect(throws: PollingError.self) {
            try await waitUntil(timeout: .milliseconds(150)) { stopCompleted }
        }
        #expect(!stopCompleted, "Stop must acknowledge final ticket allocation, not callback invocation")
        #expect(ctx.transcription.transcribeCalls.isEmpty)
        gate.continuation.finish()
        await stopObserver.value
        try await waitUntil { ctx.transcription.transcribeCalls.count == 1 }
        #expect(ctx.transcription.transcribeCalls.count == 1)
    }

    @MainActor @Test
    func competingBatchFinalizersCannotResetPendingSubmit() async throws {
        let ctx = makeBatch()
        let (controller, inserter) = (ctx.controller, ctx.inserter)
        let insertionGate = AsyncStream<Void>.makeStream()
        let enterGate = AsyncStream<Void>.makeStream()
        let completions = AsyncStream<Int>.makeStream()
        let insertionTask = Task { for await _ in insertionGate.stream {} }
        let enterTask = Task { for await _ in enterGate.stream {} }
        defer {
            insertionGate.continuation.finish()
            enterGate.continuation.finish()
            completions.continuation.finish()
            controller.cancelRecording()
        }
        inserter.pendingTask = insertionTask
        inserter.pendingTaskAfterEnter = enterTask
        controller.startRecording()
        controller.stopRecordingAndSubmit()
        let first = Task { @MainActor in
            await controller.completeBatchFinalization()
            completions.continuation.yield(1)
        }
        try await waitUntil { inserter.operations.contains(.waitForPendingInsertions) }
        try #require(inserter.operations.contains(.waitForPendingInsertions))
        var secondCompleted = false
        let second = Task { @MainActor in
            await controller.completeBatchFinalization()
            secondCompleted = true
            completions.continuation.yield(2)
        }
        try await waitUntil {
            secondCompleted || inserter.operations.filter { $0 == .waitForPendingInsertions }.count >= 2
        }
        try #require(secondCompleted || inserter.operations.filter { $0 == .waitForPendingInsertions }.count >= 2)
        insertionGate.continuation.finish()
        try await waitUntil { inserter.operations.contains(.pressEnterKey) }
        try #require(inserter.operations.contains(.pressEnterKey))
        var iterator = completions.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!inserter.operations.contains(.reset), "No finalizer may reset while submit is still pending")
        #expect(controller.isProcessingFinal)
        enterGate.continuation.finish()
        await first.value
        await second.value
        #expect(inserter.operations.filter { $0 == .pressEnterKey }.count == 1)
        #expect(inserter.operations.filter { $0 == .reset }.count == 1)
    }

    @MainActor @Test
    func batchCompletionWaitsForOutstandingTickets() async throws {
        let ctx = makeBatch()
        let (controller, inserter, transcription) = (ctx.controller, ctx.inserter, ctx.transcription)
        transcription.queueBridge.startListening()
        defer { transcription.queueBridge.stopListening() }
        controller.startRecording()
        try await Task.sleep(for: .milliseconds(100))
        await controller.recorder?.onChunkReady?(AudioChunk(wavData: Data([1]), durationSeconds: 1))
        try await waitUntil { transcription.transcribeCalls.count == 1 }
        controller.stopRecordingAndSubmit()

        // The queue-empty fast path fires while the final chunk is still out.
        await controller.completeBatchFinalization()
        #expect(controller.isProcessingFinal, "Finalization must wait for the outstanding chunk")
        #expect(!inserter.operations.contains(.pressEnterKey), "Enter must not be sent before the final text")

        let ticket = try #require(transcription.transcribeCalls.first?.0)
        await transcription.queueBridge.submitResult(ticket: ticket, text: "tail")
        try await waitUntil(timeout: .seconds(5)) { inserter.operations.contains(.pressEnterKey) }

        let textIndex = try #require(inserter.operations.firstIndex(of: .insertText("tail ")))
        let enterIndex = try #require(inserter.operations.firstIndex(of: .pressEnterKey))
        #expect(textIndex < enterIndex, "The final chunk's text must be typed before Enter")
    }
}

/// Streaming finals must produce STT latency samples like batch chunks do,
/// in the period/provider/language statistics and the session metrics.
@Suite("RecordingController — Streaming Latency", .serialized)
struct RecordingControllerStreamingLatencyTests {
    @MainActor
    private func deepgramLatencySamplesToday() -> Int {
        Statistics.shared.usage(for: .day).values
            .compactMap { $0.providers[ProviderId.deepgram]?.latency.samples }
            .reduce(0, +)
    }

    @MainActor @Test
    func streamingFinalLatencyIsRecorded() async throws {
        let providerSettings = SpyProviderSettings()
        let registry = SpyProviderRegistry()
        let provider = MockStreamingProvider()
        provider.mockSession = MockStreamingSession()
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        registry.register(provider)
        let (controller, _, _, _) = makeTestRecordingController(providerSettings: providerSettings, providerRegistry: registry)
        let before = deepgramLatencySamplesToday()

        controller.startRecording()
        let stream = try #require(controller.liveStreamingController)
        let sessionId = try #require(stream.sessionId)
        stream.onFinalLatency?(0.42)

        #expect(deepgramLatencySamplesToday() == before + 1, "Streaming latency must reach the period statistics")
        try await waitUntilAsync {
            await SessionMetricsStore.shared.activeSession(id: sessionId)?.sttLatenciesMs.contains(420) == true
        }
        #expect(await SessionMetricsStore.shared.activeSession(id: sessionId)?.sttLatenciesMs.contains(420) == true,
                "Streaming latency must reach the session metrics")
        controller.cancelRecording()
    }
}

/// Key interception follows the recording directly: it starts for the
/// captured target app, a finished recording stops it (delivering a swallowed
/// key), and only a cancelled one cancels it.
@Suite("RecordingController — Key Interception Lifecycle")
struct RecordingControllerKeyInterceptionLifecycleTests {
    @MainActor @Test
    func interceptionStartsForTheTargetAndStopsWithTheRecording() async throws {
        let providerSettings = SpyProviderSettings()
        let registry = SpyProviderRegistry()
        let provider = MockStreamingProvider()
        provider.mockSession = MockStreamingSession()
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        registry.register(provider)
        let settings = SpySettings()
        settings.streamingTrailingFinalTimeout = 0
        let (controller, keyInterceptor, inserter, _) = makeTestRecordingController(
            providerSettings: providerSettings, providerRegistry: registry, settings: settings
        )
        inserter.targetPid = 4242

        controller.startRecording()
        #expect(keyInterceptor.startCallCount == 1)
        #expect(keyInterceptor.lastTargetPid == 4242)

        controller.stopRecording(reason: .hotkey)
        try await waitUntil { !controller.isProcessingFinal }
        #expect(keyInterceptor.stopCallCount == 1, "A finished recording stops interception")
        #expect(keyInterceptor.cancelCallCount == 0, "Only cancellation discards swallowed keys")
    }
}
