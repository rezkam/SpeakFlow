import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// ============================================================
// MARK: - Streaming Stop-Path Contract Tests
// ============================================================

/// Covers §3.3.2 (hotkey stop streaming), §3.3.3 (Enter stop streaming),
/// and §3.3.1 (Escape cancel) for the streaming (real-time) model.
@Suite("RecordingController — Streaming Stop/Cancel Contract")
struct StreamingStopContractTests {

    // MARK: Helpers

    @MainActor
    private func makeStreamingContext(
        trailingFinalTimeout: Double = 0.0
    ) -> (controller: RecordingController,
          lsc: LiveStreamingController,
          ti: SpyTextInserter,
          ki: SpyKeyInterceptor) {

        let settings = SpySettings()
        settings.streamingTrailingFinalTimeout = trailingFinalTimeout

        let providerSettings = SpyProviderSettings()
        let providerRegistry = SpyProviderRegistry()
        let mockProvider = MockStreamingProvider()
        mockProvider.isConfigured = true
        mockProvider.mockSession = MockStreamingSession()
        providerSettings.activeProviderId = ProviderId.deepgram
        providerSettings.storedKeys[ProviderId.deepgram] = "test-key"
        providerRegistry.register(mockProvider)

        let (controller, ki, ti, _) = makeTestRecordingController(
            providerSettings: providerSettings,
            providerRegistry: providerRegistry,
            settings: settings
        )
        controller.startRecording()

        guard let lsc = controller.liveStreamingController else {
            Issue.record("LiveStreamingController not created in makeStreamingContext")
            fatalError("setup failed")
        }
        return (controller, lsc, ti, ki)
    }

    // MARK: - §3.3.2 Trailing finals accepted during processing-final

    /// onTextUpdate must remain open while isProcessingFinal is true so server
    /// finals arriving in the trailing-final window are typed.
    @MainActor @Test
    func trailingFinalIsTypedAfterStop() {
        let (controller, lsc, ti, _) = makeStreamingContext()

        controller.stopRecording(reason: .hotkey)

        // isRecording is now false; isProcessingFinal is true.
        #expect(!controller.isRecording)
        #expect(controller.isProcessingFinal)

        // Simulate a trailing final that arrives during the processing-final window.
        let trailing = TranscriptionResult(transcript: "Thursday", isFinal: true, speechFinal: true)
        lsc.handleEvent(.finalResult(trailing))

        // The text must be inserted — the onTextUpdate guard now allows isProcessingFinal.
        #expect(
            ti.insertedTexts.contains(where: { $0.contains("Thursday") }),
            "Trailing final arriving while isProcessingFinal must be typed"
        )
    }

    /// Interim events during the processing-final window must also be accepted.
    /// (The server may send an interim just before the speechFinal.)
    @MainActor @Test
    func trailingInterimIsTypedAfterStop() {
        let (controller, lsc, ti, _) = makeStreamingContext()

        controller.stopRecording(reason: .hotkey)
        #expect(controller.isProcessingFinal)

        let interim = TranscriptionResult(transcript: "in progress", isFinal: false)
        lsc.handleEvent(.interim(interim))

        #expect(
            ti.insertedTexts.contains(where: { $0.contains("in progress") }),
            "Trailing interim arriving while isProcessingFinal must be typed"
        )
    }

    /// Events arriving BEFORE stop must still be typed (regression guard).
    @MainActor @Test
    func finalsBeforeStopAreTyped() {
        let (controller, lsc, ti, _) = makeStreamingContext()

        let result = TranscriptionResult(transcript: "hello world", isFinal: true, speechFinal: true)
        lsc.handleEvent(.finalResult(result))
        #expect(ti.insertedTexts.contains(where: { $0.contains("hello world") }))
    }

    // MARK: - §3.3.3 Enter fires AFTER trailing finals, not before

    /// Enter must not fire synchronously on stop — it must wait for controller.stop()
    /// (which includes the trailing-final window) to complete.
    @MainActor @Test
    func enterDoesNotFireSynchronouslyOnStop() {
        let (controller, _, ti, _) = makeStreamingContext()

        controller.stopRecordingAndSubmit()

        // stopRecordingAndSubmit() sets shouldPressEnterOnComplete = true and calls
        // stopRecording(). The Enter task is async — it must NOT have fired yet.
        #expect(
            !ti.enterKeyPressed,
            "Enter must not fire synchronously — it must wait for controller.stop()"
        )
    }

    /// After stop completes (trailing-final window closed), Enter must be pressed
    /// and text must have been inserted before it.
    @MainActor @Test
    func enterFiresAfterTrailingFinalsAndAfterTextInsertion() async throws {
        let (controller, lsc, ti, _) = makeStreamingContext(trailingFinalTimeout: 0.0)

        controller.stopRecordingAndSubmit()

        // Trailing final arrives during the processing-final window (sync, before Task runs).
        let trailing = TranscriptionResult(transcript: "Thursday", isFinal: true, speechFinal: true)
        lsc.handleEvent(.finalResult(trailing))

        // Let the async stop Task complete (stop() + waitForPendingInsertions + pressEnter).
        try await waitUntil(timeout: .seconds(3)) { ti.enterKeyPressed }

        // 1. Text was inserted.
        #expect(
            ti.insertedTexts.contains(where: { $0.contains("Thursday") }),
            "Trailing final text must be inserted"
        )

        // 2. Insertion happened before Enter in the operations log.
        let insertIdx = ti.operations.firstIndex(where: {
            if case .insertText(let t) = $0 { return t.contains("Thursday") }
            return false
        })
        let enterIdx = ti.operations.firstIndex(of: .pressEnterKey)

        #expect(insertIdx != nil, "insertText(Thursday) must appear in operations")
        #expect(enterIdx != nil, "pressEnterKey must appear in operations")
        if let i = insertIdx, let e = enterIdx {
            #expect(i < e, "Text insertion must precede Enter press")
        }
    }

    /// If no trailing events arrive after finalize, stop must honor the full
    /// configured timeout instead of closing after a fixed short grace window.
    @MainActor @Test
    func stopHonorsConfiguredTimeoutWhenNoTrailingEventsArrive() async throws {
        let (controller, _, _, _) = makeStreamingContext(trailingFinalTimeout: 0.6)
        let startedAt = ContinuousClock.now

        controller.stopRecording(reason: .hotkey)
        try await waitUntil(timeout: .seconds(3)) { !controller.isProcessingFinal }

        let elapsed = startedAt.duration(to: ContinuousClock.now)
        let elapsedSeconds =
            Double(elapsed.components.seconds) +
            (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0)

        #expect(
            elapsedSeconds >= 0.45,
            "Stop should honor the configured trailing-final timeout when no events arrive; elapsed \(elapsedSeconds)s"
        )
    }

    /// Once a real trailing event arrives after finalize, stop may close early
    /// after that activity has gone quiet.
    @MainActor @Test
    func stopReturnsEarlyAfterTrailingEventQuietsDown() async throws {
        let (controller, lsc, _, _) = makeStreamingContext(trailingFinalTimeout: 10.0)
        let startedAt = ContinuousClock.now

        controller.stopRecording(reason: .hotkey)
        try await Task.sleep(for: .milliseconds(100))
        lsc.handleEvent(.finalResult(TranscriptionResult(
            transcript: "finished now",
            confidence: 0.99,
            words: [],
            speechFinal: true
        )))
        try await waitUntil(timeout: .seconds(3)) { !controller.isProcessingFinal }

        let elapsed = startedAt.duration(to: ContinuousClock.now)
        let elapsedSeconds =
            Double(elapsed.components.seconds) +
            (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0)

        #expect(
            elapsedSeconds < 3.0,
            "Stop should close after trailing activity quiets instead of waiting the full timeout; elapsed \(elapsedSeconds)s"
        )
    }

    // MARK: - §3.3.1 Escape cancel discards trailing finals

    /// After cancel, onTextUpdate must be ignored even if fired manually
    /// (e.g. residual events from a race-cancellation scenario).
    @MainActor @Test
    func cancelDiscardsTrailingFinalsAfterCancel() {
        let (controller, lsc, ti, _) = makeStreamingContext()

        // Start, then stop (enters isProcessingFinal), then cancel.
        controller.stopRecording(reason: .hotkey)
        #expect(controller.isProcessingFinal)

        controller.cancelRecording()
        #expect(!controller.isRecording)
        #expect(!controller.isProcessingFinal)
        #expect(ti.cancelCalled)

        let countBefore = ti.insertedTexts.count

        // Any trailing final arriving after cancel must be dropped.
        let trailing = TranscriptionResult(transcript: "should not appear", isFinal: true)
        lsc.handleEvent(.finalResult(trailing))

        #expect(
            ti.insertedTexts.count == countBefore,
            "No text must be inserted after cancel"
        )
    }

    /// Escape during active recording (not yet in processing-final) also discards.
    @MainActor @Test
    func cancelDuringRecordingDiscardsEverything() {
        let (controller, lsc, ti, _) = makeStreamingContext()
        #expect(controller.isRecording)

        controller.cancelRecording()
        #expect(!controller.isRecording)
        #expect(!controller.isProcessingFinal)
        #expect(ti.cancelCalled)

        let trailing = TranscriptionResult(transcript: "dropped", isFinal: true)
        lsc.handleEvent(.finalResult(trailing))
        #expect(!ti.insertedTexts.contains(where: { $0.contains("dropped") }))
    }

    // MARK: - isProcessingFinal clears after stop completes

    @MainActor @Test
    func processingFinalClearsAfterStopCompletes() async throws {
        let (controller, _, _, _) = makeStreamingContext(trailingFinalTimeout: 0.0)
        controller.fullTranscript = "hello"  // ensure hasPlayedCompletionSound triggers

        controller.stopRecording(reason: .hotkey)
        #expect(controller.isProcessingFinal)

        try await waitUntil(timeout: .seconds(3)) { !controller.isProcessingFinal }
        #expect(!controller.isProcessingFinal, "isProcessingFinal must clear after stop completes")
        #expect(!controller.isRecording)
    }

    // MARK: - Configurable timeout is forwarded

    /// Verifies that a non-default trailing-final timeout is correctly forwarded
    /// to stop() by confirming stop completes without hanging (0 s timeout).
    @MainActor @Test
    func zeroTrailingFinalTimeoutCompletesImmediately() async throws {
        let (controller, _, _, _) = makeStreamingContext(trailingFinalTimeout: 0.0)
        controller.fullTranscript = "hi"

        controller.stopRecording(reason: .hotkey)

        // With a 0 s timeout the stop Task should settle quickly.
        // 5 s timeout gives headroom under MainActor congestion from parallel tests.
        try await waitUntil(timeout: .seconds(5)) { !controller.isProcessingFinal }
        #expect(!controller.isProcessingFinal)
    }
}

// ============================================================
// MARK: - Batch Stop-Path Contract Tests
// ============================================================

/// Covers §3.3.4 (hotkey stop batch), §3.3.5 (Enter stop batch), and
/// §3.3.1 (Escape cancel batch).
@Suite("RecordingController — Batch Stop/Cancel Contract")
struct BatchStopContractTests {

    // MARK: - §3.3.4 Adaptive timeout formula

    @MainActor @Test
    func timeoutFormulaBase() {
        let settings = SpySettings()
        settings.batchFinalizationTimeoutBase = 5.0
        settings.batchFinalizationTimeoutPerChunkSecond = 1.0
        settings.batchFinalizationMaxTimeout = 100.0
        settings.chunkDuration = .seconds15  // maxChunkDuration = 15 s

        let (controller, _, _, _) = makeTestRecordingController(settings: settings)
        let timeout = controller.computeBatchFinalizationTimeout()
        // 5 + 15 × 1 = 20
        #expect(timeout == 20.0, "Formula: base + maxChunkDuration × perChunkSecond")
    }

    @MainActor @Test
    func timeoutFormulaClampsToMax() {
        let settings = SpySettings()
        settings.batchFinalizationTimeoutBase = 10.0
        settings.batchFinalizationTimeoutPerChunkSecond = 2.0
        settings.batchFinalizationMaxTimeout = 50.0
        settings.chunkDuration = .minute1  // 60 s → 10 + 60 × 2 = 130 > 50 → clamped

        let (controller, _, _, _) = makeTestRecordingController(settings: settings)
        let timeout = controller.computeBatchFinalizationTimeout()
        #expect(timeout == 50.0, "Timeout must be capped at batchFinalizationMaxTimeout")
    }

    @MainActor @Test
    func timeoutFormulaLargeChunk() {
        let settings = SpySettings()
        settings.batchFinalizationTimeoutBase = 10.0
        settings.batchFinalizationTimeoutPerChunkSecond = 2.0
        settings.batchFinalizationMaxTimeout = 120.0
        settings.chunkDuration = .seconds30  // 10 + 30 × 2 = 70 ≤ 120

        let (controller, _, _, _) = makeTestRecordingController(settings: settings)
        let timeout = controller.computeBatchFinalizationTimeout()
        #expect(timeout == 70.0)
    }

    @MainActor @Test
    func timeoutFormulaZeroPerChunk() {
        // perChunkSecond = 0 → timeout = base regardless of chunk size.
        let settings = SpySettings()
        settings.batchFinalizationTimeoutBase = 8.0
        settings.batchFinalizationTimeoutPerChunkSecond = 0.0
        settings.batchFinalizationMaxTimeout = 120.0
        settings.chunkDuration = .minute5  // 300 s × 0 = 0 → 8.0

        let (controller, _, _, _) = makeTestRecordingController(settings: settings)
        let timeout = controller.computeBatchFinalizationTimeout()
        #expect(timeout == 8.0)
    }

    // MARK: - §3.3.4 Finalization completes when queue is empty

    @MainActor @Test
    func finalizationCompletesWithEmptyQueue() async throws {
        let settings = SpySettings()
        settings.batchFinalizationTimeoutBase = 5.0
        settings.batchFinalizationTimeoutPerChunkSecond = 0.0
        settings.batchFinalizationMaxTimeout = 30.0

        let (controller, _, ti, _) = makeTestRecordingController(settings: settings)
        controller.isRecording = true
        controller.fullTranscript = "hello world"

        // stopRecording (batch path: liveStreamingController is nil)
        controller.stopRecording(reason: .hotkey)
        #expect(controller.isProcessingFinal, "Must enter processing-final")

        // Queue bridge reports 0 pending → after the initial grace period the
        // polling loop exits on its first check and calls completeBatchFinalization().
        // Timeout is 5 s to give the MainActor headroom under parallel test load
        // (the 500 ms grace period alone means minimum ~600 ms elapsed).
        try await waitUntil(timeout: .seconds(5)) { !controller.isProcessingFinal }

        #expect(!controller.isProcessingFinal, "Finalization must complete")
        #expect(ti.resetCalled, "TextInserter must be reset after finalization")
    }

    // MARK: - §3.3.5 Enter fires after finalization

    @MainActor @Test
    func enterFiresAfterBatchFinalization() async throws {
        let settings = SpySettings()
        settings.batchFinalizationTimeoutBase = 5.0
        settings.batchFinalizationTimeoutPerChunkSecond = 0.0
        settings.batchFinalizationMaxTimeout = 30.0

        let (controller, _, ti, _) = makeTestRecordingController(settings: settings)
        controller.isRecording = true
        controller.fullTranscript = "some text"

        controller.stopRecordingAndSubmit()
        #expect(controller.isProcessingFinal)

        try await waitUntil(timeout: .seconds(5)) { ti.enterKeyPressed }
        #expect(ti.enterKeyPressed, "Enter must be pressed after batch finalization")
        #expect(!controller.isProcessingFinal, "isProcessingFinal must be cleared")
    }

    // MARK: - §3.3.1 Escape cancel — batch

    @MainActor @Test
    func batchCancelResetsAllState() {
        let (controller, _, ti, _) = makeTestRecordingController()
        controller.isRecording = true
        controller.fullTranscript = "discarded text"

        controller.cancelRecording()

        #expect(!controller.isRecording)
        #expect(!controller.isProcessingFinal)
        #expect(controller.fullTranscript.isEmpty, "Transcript must be cleared on cancel")
        #expect(ti.cancelCalled, "TextInserter must be cancelled (clears inserted text)")
    }

    @MainActor @Test
    func batchCancelDuringProcessingFinalStopsFinalization() async throws {
        let settings = SpySettings()
        settings.batchFinalizationTimeoutBase = 60.0  // long timeout
        settings.batchFinalizationTimeoutPerChunkSecond = 0.0
        settings.batchFinalizationMaxTimeout = 120.0

        let (controller, _, ti, _) = makeTestRecordingController(settings: settings)
        controller.isRecording = true
        controller.fullTranscript = "pending text"

        controller.stopRecording(reason: .hotkey)
        #expect(controller.isProcessingFinal)

        // Cancel while waiting for finalization.
        controller.cancelRecording()
        #expect(!controller.isProcessingFinal)
        #expect(!controller.isRecording)
        #expect(ti.cancelCalled)

        // Wait briefly; finalization task must not complete (isProcessingFinal stays false).
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ti.enterKeyPressed, "Enter must not be pressed after cancel")
    }

    // MARK: - onAllComplete fast path

    @MainActor @Test
    func onAllCompleteTriggersCompletionWithoutWaitingForPolling() async throws {
        let settings = SpySettings()
        settings.batchFinalizationTimeoutBase = 30.0  // long polling timeout
        settings.batchFinalizationTimeoutPerChunkSecond = 0.0
        settings.batchFinalizationMaxTimeout = 120.0

        let spy = SpyTranscription()
        let (controller, _, _, _) = makeTestRecordingController(
            settings: settings,
            transcription: spy
        )
        controller.isRecording = true
        controller.fullTranscript = "hello"

        controller.stopRecording(reason: .hotkey)
        #expect(controller.isProcessingFinal)

        // Fire onAllComplete directly — simulates the queue bridge signalling completion.
        // setupTranscriptionCallbacks() wires onAllComplete in makeTestRecordingController,
        // so this call dispatches a MainActor Task for completeBatchFinalization().
        spy.queueBridge.onAllComplete?()

        // Fast path should complete well under 1 s; 5 s gives headroom under heavy load.
        try await waitUntil(timeout: .seconds(5)) { !controller.isProcessingFinal }
        #expect(!controller.isProcessingFinal, "onAllComplete fast path must complete finalization")
    }
}
