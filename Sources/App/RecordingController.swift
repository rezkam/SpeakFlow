import OSLog
import SpeakFlowCore

/// Manages the recording lifecycle, provider dispatch, and hotkey setup.
///
/// Text insertion is delegated to `TextInserter` and key interception
/// to `KeyInterceptor`, keeping this controller focused on recording
/// state transitions and provider orchestration.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    // MARK: - Recording State

    var isRecording = false {
        didSet { appState.isRecording = isRecording }
    }
    var isProcessingFinal = false {
        didSet { appState.isProcessingFinal = isProcessingFinal }
    }

    // MARK: - Internal

    var hotkeyListener: HotkeyListener?
    var recorder: StreamingRecorder?
    var liveStreamingController: LiveStreamingController?
    private var currentMetricsSessionId: UUID?
    private var pendingMetricsTask: Task<Void, Never>?
    private var presentedRecordingErrorMessage: String?

    /// Everything that belongs to one recording. Starting, cancelling, or
    /// shutting down replaces it wholesale, so no field can leak into the next
    /// recording. Callbacks and finalizers capture `generation` and act only
    /// while it is still current.
    private struct RecordingSession {
        let generation: UInt64
        var fullTranscript = ""
        /// A captured Enter asked for a synthetic Enter after finalization.
        var submitRequested = false
        /// Enter capture is one-shot per recording.
        var submitCaptured = false
        var completionSoundPlayed = false
        /// Recorder whose stop pipeline must finish enqueuing final audio
        /// before batch finalization may complete.
        var stoppingRecorder: StreamingRecorder?
        var finalizationReason = StopReason.unknown.rawValue
        /// Wall-clock anchor for the next streaming segment. Each final
        /// contributes its own elapsed segment duration to the stats time
        /// totals (streaming providers do not emit a server-side duration).
        var streamingSegmentStart: ContinuousClock.Instant?
        var latestStreamingError: Error?
    }

    private var session = RecordingSession(generation: 0)

    /// Retires the current recording and starts a fresh session for the next.
    private func replaceSession() {
        session = RecordingSession(generation: session.generation &+ 1)
    }

    var fullTranscript: String {
        get { session.fullTranscript }
        set { session.fullTranscript = newValue }
    }
    var shouldPressEnterOnComplete: Bool {
        get { session.submitRequested }
        set { session.submitRequested = newValue }
    }
    var hasPlayedCompletionSound: Bool {
        get { session.completionSoundPlayed }
        set { session.completionSoundPlayed = newValue }
    }

    let textInserter: any TextInserting
    let keyInterceptor: any KeyIntercepting
    let appState: any BannerPresenting
    let hotkeySettings: any HotkeySettingsProviding
    let providerSettings: any ProviderSettingsProviding
    let providerRegistry: any ProviderRegistryProviding
    let settings: any SettingsProviding
    let transcription: any TranscriptionCoordinating
    private let playSoundEffect: (SoundEffect) -> Void

    /// Test mode controls how the controller behaves outside production.
    /// - `off`: Normal production behavior with real permissions and recording.
    /// - `live`: Skips permission checks but uses real provider dispatch.
    /// - `mock`: Skips permissions and fakes recording start/stop for UI tests.
    enum TestMode { case off, live, mock }

    // UI test support (configured externally by AppDelegate)
    var testMode: TestMode = .off
    var uiTestToggleCount = 0
    /// Called after recording state changes (used by UI test harness).
    var onStateChanged: (() -> Void)?

    // No longer used — batch finalization uses an adaptive deadline (see startBatchFinalization).

    init(
        keyInterceptor: any KeyIntercepting = KeyInterceptor.shared,
        textInserter: any TextInserting = TextInserter.shared,
        appState: any BannerPresenting = AppState.shared,
        hotkeySettings: any HotkeySettingsProviding = HotkeySettings.shared,
        providerSettings: any ProviderSettingsProviding = ProviderSettings.shared,
        providerRegistry: any ProviderRegistryProviding = ProviderRegistry.shared,
        settings: any SettingsProviding = SpeakFlowCore.Settings.shared,
        transcription: any TranscriptionCoordinating = Transcription.shared,
        playSoundEffect: @escaping (SoundEffect) -> Void = { $0.play() }
    ) {
        self.keyInterceptor = keyInterceptor
        self.textInserter = textInserter
        self.appState = appState
        self.hotkeySettings = hotkeySettings
        self.providerSettings = providerSettings
        self.providerRegistry = providerRegistry
        self.settings = settings
        self.transcription = transcription
        self.playSoundEffect = playSoundEffect
        self.keyInterceptor.onEscapePressed = { [weak self] in self?.cancelRecording() }
        self.keyInterceptor.onEnterPressed = { [weak self] in
            guard let self else { return }
            // Enter submit contract:
            // 1) First Enter while recording requests submit and stops capture.
            // 2) Enter capture is one-shot for the recording lifecycle.
            // 3) Actual synthetic Enter happens once, after pending insertions finish.
            if self.isRecording {
                guard !self.session.submitCaptured else { return }
                self.session.submitCaptured = true
                self.stopRecordingAndSubmit()
                return
            }
            if self.isProcessingFinal {
                guard !self.session.submitCaptured else { return }
                self.session.submitCaptured = true
                self.shouldPressEnterOnComplete = true
            }
        }
    }

    /// Whether work from recording `generation` may still act: it is current
    /// and either recording or finishing.
    private func owns(_ generation: UInt64) -> Bool {
        generation == session.generation && (isRecording || isProcessingFinal)
    }

    /// Whether the finalizer of recording `generation` still owns finalization.
    private func ownsFinalization(_ generation: UInt64) -> Bool {
        generation == session.generation && isProcessingFinal && !isRecording
    }

    // MARK: - Hotkey

    func setupHotkey() {
        if testMode != .off {
            hotkeyListener?.stop()
            hotkeyListener = nil
            HotkeyDiagnostics.record(
                "hotkey_setup_skipped_test_mode",
                metadata: ["testMode": String(describing: testMode)]
            )
            Logger.hotkey.info("UI test mode: skipping global hotkey listener")
            return
        }
        let type = hotkeySettings.currentHotkey
        HotkeyDiagnostics.record(
            "hotkey_setup_requested",
            metadata: [
                "hotkeyType": type.rawValue,
                "displayName": type.displayName
            ]
        )
        if hotkeyListener == nil {
            hotkeyListener = HotkeyListener()
            hotkeyListener?.onActivate = { [weak self] in self?.handleHotkeyActivation() }
        }
        hotkeyListener?.start(type: type)
        Logger.hotkey.info("Using \(type.displayName) activation")
    }

    private func handleHotkeyActivation() {
        let type = hotkeySettings.currentHotkey
        HotkeyDiagnostics.record(
            "hotkey_activation_handler_invoked",
            metadata: [
                "hotkeyType": type.rawValue,
                "displayName": type.displayName,
                "isRecording": isRecording ? "true" : "false",
                "isProcessingFinal": isProcessingFinal ? "true" : "false"
            ]
        )
        toggle()
    }

    // MARK: - Transcription Callbacks

    func setupTranscriptionCallbacks() {
        transcription.queueBridge.onTextReady = { [weak self] text in
            guard let self else { return }
            if !self.fullTranscript.isEmpty { self.fullTranscript += " " }
            self.fullTranscript += text
            self.recordMetricsWords(text)
            self.observabilityEvent(
                "batch_text_ready",
                level: .debug,
                metadata: self.metadataForTextPayload(text)
            )
            if self.isRecording || self.isProcessingFinal {
                self.textInserter.insertText(text + " ")
            }
            // Successful transcription — dismiss any previous error banner
            self.resetRecordingErrorPresentation()
            self.appState.dismissBanner()
            // Update the VAD session controller for thinking-pause detection
            Task { [weak self] in
                await self?.recorder?.updateTranscript(self?.fullTranscript ?? "")
            }
        }
        transcription.queueBridge.onAllComplete = { [weak self] in
            // Queue is empty — fast-path to completion without waiting for the
            // polling deadline. completeBatchFinalization is idempotent via its
            // isProcessingFinal guard, so racing with the deadline task is safe.
            self?.observabilityEvent("batch_queue_all_complete", level: .debug)
            Task { @MainActor in await self?.completeBatchFinalization() }
        }
        transcription.queueBridge.onChunkError = { [weak self] error in
            guard let self else { return }
            self.observabilityEvent(
                "transcription_error_banner_shown",
                level: .warning,
                metadata: [
                    "errorKind": String(describing: TranscriptionErrorKind.classify(error)),
                    "providerId": self.providerSettings.activeProviderId,
                    "error": error.localizedDescription
                ]
            )
            self.presentRecordingError(error, providerId: self.providerSettings.activeProviderId)
        }
    }

    // MARK: - Toggle

    @objc func toggle() {
        if testMode != .off { uiTestToggleCount += 1 }
        if isRecording { stopRecording(reason: .hotkey) } else { startRecording() }
        onStateChanged?()
    }

    // MARK: - Start Recording

    func startRecording() {
        guard !isRecording else { return }
        resetRecordingErrorPresentation()
        session.latestStreamingError = nil
        applyObservabilityConfigurationFromSettings()
        observabilityEvent(
            "recording_start_requested",
            metadata: [
                "testMode": String(describing: testMode),
                "activeProviderId": providerSettings.activeProviderId
            ]
        )
        guard resolveFinalizationBeforeStart() else { return }
        if testMode == .mock {
            replaceSession()
            isRecording = true; isProcessingFinal = false
            observabilityEvent("recording_started_mock")
            onStateChanged?(); return
        }
        if testMode == .off {
            if !PermissionController.shared.isAccessibilityReady() { return }
            if !PermissionController.shared.isMicrophoneReady(onGranted: { [weak self] in self?.startRecording() }) { return }
        }

        let providerId = providerSettings.activeProviderId
        let provider = providerRegistry.provider(for: providerId)
        guard let provider, provider.isConfigured else {
            observabilityEvent(
                "recording_start_failed_provider_not_configured",
                level: .warning,
                metadata: ["providerId": providerId]
            )
            playSoundEffect(.error)
            presentRecordingError(
                message: "Set up a transcription provider in Providers to start dictating"
            )
            return
        }

        guard captureTargetOrRefuseStart() else { return }
        replaceSession()

        beginMetricsSession(providerId: provider.id, mode: provider.mode)
        maybeRecordSettingsSnapshot(
            sessionId: currentMetricsSessionId,
            providerId: provider.id,
            providerMode: provider.mode
        )

        isRecording = true; isProcessingFinal = false

        // Enter and Escape are captured only while this recording's app has focus.
        keyInterceptor.start(targetPid: textInserter.targetPid)
        if let streaming = provider as? any StreamingTranscriptionProvider {
            startStreamingRecording(provider: streaming)
        } else if let batch = provider as? any BatchTranscriptionProvider {
            signalRecordingStarted(provider: provider)
            startBatchRecording(provider: batch)
        }
        onStateChanged?()
    }

    /// A start while the previous recording is still finalizing either replaces
    /// it (when the hotkey restarts recording) or is refused.
    private func resolveFinalizationBeforeStart() -> Bool {
        guard isProcessingFinal else { return true }
        if settings.hotkeyRestartsRecording {
            observabilityEvent("recording_restart_during_processing")
            cancelRecording()
            return true
        }
        observabilityEvent(
            "recording_start_blocked_processing",
            level: .warning,
            metadata: ["hotkeyRestartsRecording": "false"]
        )
        // This is an intentional blocked action, not a recording failure.
        // The error cue is sufficient because the current recording is still finalizing.
        playSoundEffect(.error)
        return false
    }

    /// The focused field at start is the only place a recording may type.
    /// Without it, focus protection has nothing to protect, so do not start.
    private func captureTargetOrRefuseStart() -> Bool {
        guard textInserter.captureTarget() else {
            observabilityEvent("recording_start_failed_no_target", level: .warning)
            playSoundEffect(.error)
            presentRecordingError(
                message: "Click into a text field, then start dictation again. SpeakFlow could not identify where to type."
            )
            return false
        }
        return true
    }

    private func signalRecordingStarted(provider: any TranscriptionProvider) {
        playSoundEffect(.start)
        observabilityEvent(
            "recording_started",
            metadata: [
                "providerId": provider.id,
                "providerMode": provider.mode.rawValue,
                "targetPid": String(textInserter.targetPid)
            ]
        )
    }

    private func signalStreamingCaptureStarted(provider: any StreamingTranscriptionProvider) {
        playSoundEffect(.start)
        observabilityEvent(
            "streaming_audio_capture_started",
            metadata: [
                "providerId": provider.id,
                "providerMode": provider.mode.rawValue,
                "targetPid": String(textInserter.targetPid)
            ]
        )
    }

    // MARK: - Batch Recording

    private func startBatchRecording(provider: any BatchTranscriptionProvider) {
        transcription.setActiveBatchProvider(provider)
        observabilityEvent("batch_recording_starting", metadata: ["providerId": provider.id])
        let generation = session.generation
        let startingRecorder = StreamingRecorder()
        recorder = startingRecorder
        startingRecorder.onChunkReady = { [weak self] chunk in
            Task { @MainActor in
                // Audio from a retired recording must not get a ticket in the
                // current queue session, or it would be typed into the next one.
                guard let self, self.owns(generation) else {
                    self?.observabilityEvent("batch_chunk_dropped_stale", level: .debug)
                    return
                }
                let ticket = await self.transcription.queueBridge.nextSequence()
                guard self.owns(generation) else { return }
                self.observabilityEvent(
                    "batch_chunk_ready",
                    level: .debug,
                    metadata: [
                        "ticketSeq": String(ticket.seq),
                        "ticketSession": String(ticket.session),
                        "durationSeconds": String(format: "%.3f", chunk.durationSeconds),
                        "bytes": String(chunk.wavData.count),
                        "speechProbability": String(format: "%.3f", chunk.speechProbability)
                    ]
                )
                self.transcription.transcribe(ticket: ticket, chunk: chunk)
            }
        }
        startingRecorder.onAutoEnd = { [weak self] in
            self?.observabilityEvent("batch_auto_end_triggered")
            Task { @MainActor in
                guard let self, self.owns(generation), self.isRecording else { return }
                self.stopRecording(reason: .autoEnd)
            }
        }
        Task { @MainActor in
            guard self.isStartingBatch(generation, startingRecorder) else { return }
            await self.transcription.queueBridge.reset()
            guard self.isStartingBatch(generation, startingRecorder) else { return }
            let started = await startingRecorder.start()
            // Stop or cancel during startup makes start() return false on
            // purpose; that recording is finalized or discarded elsewhere.
            guard self.isStartingBatch(generation, startingRecorder) else {
                self.observabilityEvent(
                    "batch_start_result_ignored_stale",
                    level: .debug,
                    metadata: ["started": started ? "true" : "false"]
                )
                return
            }
            if !started {
                isRecording = false; isProcessingFinal = false; recorder = nil
                self.keyInterceptor.cancel()
                self.playSoundEffect(.error)
                self.observabilityEvent("batch_recording_start_failed", level: .error)
                self.presentRecordingError(
                    message: "Transcription failed, audio recording could not start. Please try again."
                )
                self.endMetricsSession(reason: "START_FAILED")
            } else {
                Statistics.shared.recordRecording(
                    providerId: provider.id,
                    language: self.languageForStats(providerId: provider.id)
                )
                self.observabilityEvent("batch_recording_started")
            }
        }
    }

    /// Whether a batch startup step for `startingRecorder` is still wanted.
    private func isStartingBatch(_ generation: UInt64, _ startingRecorder: StreamingRecorder) -> Bool {
        generation == session.generation && isRecording && recorder === startingRecorder
    }

    // MARK: - Stop / Cancel

    enum StopReason: String {
        case hotkey = "HOTKEY_TOGGLE", autoEnd = "SILENCE_AUTO_END", enter = "ENTER_SUBMIT"
        case escape = "ESCAPE_CANCEL", ui = "UI_BUTTON", unknown = "UNKNOWN"
    }

    func stopRecording(reason: StopReason = .unknown) {
        guard isRecording else { return }
        Logger.audio.info("Stop requested reason=\(reason.rawValue, privacy: .public)")
        observabilityEvent(
            "recording_stop_requested",
            metadata: [
                "reason": reason.rawValue,
                "isStreaming": liveStreamingController != nil ? "true" : "false"
            ]
        )

        if testMode == .mock {
            session.submitCaptured = false
            isRecording = false; isProcessingFinal = false; onStateChanged?(); return
        }
        isRecording = false

        if liveStreamingController != nil {
            // Streaming stop: isProcessingFinal stays true throughout the trailing-final
            // window so onTextUpdate keeps accepting server results until stop() returns.
            isProcessingFinal = true
            playSoundEffect(.stop)
            hasPlayedCompletionSound = true
            let controller = liveStreamingController
            liveStreamingController = nil
            let trailingTimeout = settings.streamingTrailingFinalTimeout
            let generation = session.generation
            Task { @MainActor in
                let startedAt = ContinuousClock.now
                // Await stop() so trailing finals can be delivered before we proceed.
                // onTextUpdate remains open (isProcessingFinal == true) throughout.
                await controller?.stop(trailingFinalTimeout: trailingTimeout)
                let elapsed = ContinuousClock.now - startedAt
                let elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                self.observabilityEvent(
                    "streaming_stop_completed",
                    metadata: [
                        "reason": reason.rawValue,
                        "trailingTimeout": String(trailingTimeout),
                        "elapsedSeconds": String(format: "%.3f", elapsedSeconds)
                    ]
                )
                guard self.ownsFinalization(generation) else { return }
                // All trailing finals have now arrived; wait for their insertions too.
                await self.textInserter.waitForPendingInsertions()
                guard self.ownsFinalization(generation) else { return }
                self.endMetricsSession(reason: reason.rawValue)
                // Stopping interception delivers any Enter or Escape the tap already
                // swallowed, so read the submit request only after it returns.
                self.keyInterceptor.stop()
                // A delivered Escape cancels the recording; nothing is left to finish.
                guard self.ownsFinalization(generation) else { return }
                await self.finishFinalization(generation: generation, playCompletion: false)
            }
        } else {
            isProcessingFinal = true; playSoundEffect(.stop)
            session.finalizationReason = reason.rawValue
            let stoppingRecorder = recorder
            stoppingRecorder?.stop()
            recorder = nil
            session.stoppingRecorder = stoppingRecorder
            observabilityEvent(
                "batch_stop_requested",
                metadata: ["reason": reason.rawValue]
            )
            startBatchFinalization(stoppingRecorder: stoppingRecorder)
        }
        onStateChanged?()
    }

    func cancelRecording() {
        guard isRecording || isProcessingFinal else { return }
        observabilityEvent(
            "recording_cancel_requested",
            level: .warning,
            metadata: [
                "wasRecording": isRecording ? "true" : "false",
                "wasProcessingFinal": isProcessingFinal ? "true" : "false"
            ]
        )
        endMetricsSession(reason: StopReason.escape.rawValue)
        // Retire this recording: its callbacks and finalizer must not act again.
        replaceSession()
        keyInterceptor.cancel()
        isRecording = false; isProcessingFinal = false
        textInserter.cancelAndReset()
        textInserter.setObservabilitySessionId(nil)
        if let controller = liveStreamingController {
            liveStreamingController = nil
            Task { @MainActor in await controller.cancel() }
        } else {
            recorder?.cancel(); recorder = nil; transcription.cancelAll()
        }
        onStateChanged?(); playSoundEffect(.complete)
    }

    func stopRecordingAndSubmit() {
        guard isRecording else { return }
        shouldPressEnterOnComplete = true
        stopRecording(reason: .enter)
    }

    // MARK: - Batch Finalization

    /// Computes the deadline for waiting on all batch chunks to be transcribed.
    /// Timeout = clamp(base + maxChunkDuration × perChunkSecond, _, maxTimeout).
    func computeBatchFinalizationTimeout() -> Double {
        let base   = settings.batchFinalizationTimeoutBase
        let perSec = settings.batchFinalizationTimeoutPerChunkSecond
        let maxT   = settings.batchFinalizationMaxTimeout
        return min(base + settings.maxChunkDuration * perSec, maxT)
    }

    /// Launches the adaptive-timeout finalization polling task.
    /// Called immediately after `recorder.stop()` in the batch stop path.
    func startBatchFinalization(stoppingRecorder: StreamingRecorder? = nil) {
        let timeout = computeBatchFinalizationTimeout()
        let generation = session.generation
        observabilityEvent(
            "batch_finalization_started",
            metadata: ["timeoutSeconds": String(format: "%.3f", timeout)]
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(timeout)

            // Wait until recorder.stop() has finished its async drain/flush pipeline.
            // Without this, we can observe a transient pending=0 before the final chunk
            // is even enqueued, which can complete finalization too early.
            await stoppingRecorder?.waitForStopCompletion()

            // Grace period before the first poll.
            //
            // StreamingRecorder.stop() performs final-chunk flush in an async Task
            // (drain sampleQueue → emit WAV → enqueue to TranscriptionQueueBridge).
            // Without this sleep the first getPendingCount() call can fire before that
            // Task runs, sees 0 pending, and fires completeBatchFinalization() early —
            // dropping the tail text because onTextReady only inserts while
            // isRecording || isProcessingFinal.
            //
            // One poll interval (500 ms) is more than enough for the in-process flush;
            // real network latency for the chunk comes later and is covered by the loop.
            try? await Task.sleep(for: .milliseconds(500))

            while ContinuousClock.now < deadline {
                if Task.isCancelled { return }
                guard self.ownsFinalization(generation) else { return } // completed or cancelled
                let pending = await self.transcription.queueBridge.getPendingCount()
                self.observabilityEvent(
                    "batch_finalization_poll",
                    level: .debug,
                    metadata: ["pending": String(pending)]
                )
                if pending == 0 { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // At the deadline, finish with whatever arrived rather than hang.
            let timedOut = ContinuousClock.now >= deadline
            await self.completeBatchFinalization(generation: generation, force: timedOut)
        }
    }

    /// Shared completion path for batch finalization, used by the queue-empty
    /// fast path. Completes only for the recording currently finalizing.
    func completeBatchFinalization() async {
        await completeBatchFinalization(generation: session.generation, force: false)
    }

    /// Completes batch finalization for recording `generation` once its final
    /// audio is enqueued, every ticket is transcribed, and every text delivered
    /// has been typed. `force` skips the transcription wait at the deadline.
    /// Idempotent: ownership is re-checked after every suspension.
    private func completeBatchFinalization(generation: UInt64, force: Bool) async {
        guard ownsFinalization(generation) else { return }

        // Final-audio barrier: the stopping recorder must have enqueued its last chunk.
        await session.stoppingRecorder?.waitForStopCompletion()
        guard ownsFinalization(generation) else { return }
        if !force, await !transcription.queueBridge.isIdle() {
            // A later onAllComplete or the polling deadline finishes the job.
            observabilityEvent("batch_finalization_deferred_pending", level: .debug)
            return
        }
        await textInserter.waitForPendingInsertions()
        guard ownsFinalization(generation) else { return }

        // Stopping interception delivers any Enter or Escape the tap already
        // swallowed. A delivered Escape cancels the recording.
        keyInterceptor.stop()
        guard ownsFinalization(generation) else { return }
        session.stoppingRecorder = nil
        transcription.setActiveBatchProvider(nil)
        let finalizationReason = session.finalizationReason
        session.finalizationReason = StopReason.unknown.rawValue
        observabilityEvent(
            "batch_finalization_completed",
            metadata: ["hadTranscript": fullTranscript.isEmpty ? "false" : "true"]
        )
        endMetricsSession(reason: finalizationReason)
        let playCompletion = !fullTranscript.isEmpty && !hasPlayedCompletionSound
        await finishFinalization(generation: generation, playCompletion: playCompletion)
    }

    /// Final step shared by streaming and batch: sends the requested submit
    /// Enter, then resets the inserter. Finalization stays owned (and
    /// `isProcessingFinal` true) until the Enter and cleanup are done, so a new
    /// recording cannot start in between and have this cleanup reset it.
    private func finishFinalization(generation: UInt64, playCompletion: Bool) async {
        let enterRequested = shouldPressEnterOnComplete
        shouldPressEnterOnComplete = false
        session.submitCaptured = false
        if playCompletion {
            hasPlayedCompletionSound = true
            playSoundEffect(.complete)
        }
        if enterRequested {
            textInserter.pressEnterKey()
            await textInserter.waitForPendingInsertions()
            // A new recording that started over this one retired its Enter.
            guard ownsFinalization(generation) else { return }
        }
        textInserter.reset()
        textInserter.setObservabilitySessionId(nil)
        isProcessingFinal = false
        onStateChanged?()
    }

    // MARK: - Cleanup

    func shutdown() {
        observabilityEvent("recording_controller_shutdown")
        endMetricsSession(reason: "SHUTDOWN")
        hotkeyListener?.stop(); hotkeyListener = nil
        replaceSession()
        keyInterceptor.cancel()
        if isRecording || isProcessingFinal {
            recorder?.cancel(); recorder = nil
            isRecording = false; isProcessingFinal = false
        }
        transcription.cancelAll()
        transcription.queueBridge.stopListening()
        textInserter.cancelAndReset()
        textInserter.setObservabilitySessionId(nil)
    }

    private func beginMetricsSession(providerId: String, mode: ProviderMode) {
        let sessionId = UUID()
        let language = languageForStats(providerId: providerId)
        currentMetricsSessionId = sessionId
        transcription.setMetricsSession(sessionId)
        textInserter.setObservabilitySessionId(sessionId)
        observabilityEvent(
            "metrics_session_started",
            sessionId: sessionId,
            metadata: [
                "providerId": providerId,
                "mode": mode.rawValue,
                "language": language
            ]
        )
        enqueueMetricsOperation {
            await SessionMetricsStore.shared.startSession(
                sessionId: sessionId,
                providerId: providerId,
                mode: mode
            )
        }
    }

    private func languageForStats(providerId: String) -> String {
        switch providerId {
        case ProviderId.deepgram:
            settings.deepgramLanguage
        case ProviderId.mistral, ProviderId.mistralBatch:
            settings.mistralLanguage
        default:
            ""
        }
    }

    /// Streaming counterpart of the batch chunk latency: time from the end of
    /// a final's audio to its arrival.
    private func recordStreamingLatency(seconds: Double, providerId: String) {
        Statistics.shared.recordSTTLatency(
            seconds: seconds,
            providerId: providerId,
            language: languageForStats(providerId: providerId)
        )
        guard let sessionId = currentMetricsSessionId else { return }
        enqueueMetricsOperation {
            await SessionMetricsStore.shared.recordSTTLatency(sessionId: sessionId, milliseconds: seconds * 1000)
        }
    }

    private func endMetricsSession(reason: String) {
        guard let sessionId = currentMetricsSessionId else { return }
        currentMetricsSessionId = nil
        transcription.setMetricsSession(nil)
        observabilityEvent(
            "metrics_session_ended",
            sessionId: sessionId,
            metadata: ["reason": reason]
        )
        enqueueMetricsOperation {
            await SessionMetricsStore.shared.endSession(sessionId: sessionId, reason: reason)
        }
    }

    /// Returns the elapsed wall-clock seconds since the start of the current
    /// streaming segment, and resets the anchor for the next segment. Returns
    /// zero if no anchor is set (defensive; shouldn't happen during a normal
    /// streaming session).
    private func consumeStreamingSegmentSeconds() -> Double {
        let now = ContinuousClock.now
        guard let start = session.streamingSegmentStart else { return 0 }
        let duration = now - start
        session.streamingSegmentStart = now
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        return max(seconds, 0)
    }

    private func recordMetricsWords(_ text: String) {
        guard let sessionId = currentMetricsSessionId else { return }
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return }
        enqueueMetricsOperation {
            await SessionMetricsStore.shared.addWords(sessionId: sessionId, count: words)
        }
    }

    private func enqueueMetricsOperation(_ operation: @escaping @Sendable () async -> Void) {
        let previous = pendingMetricsTask
        let task = Task {
            await previous?.value
            await operation()
        }
        pendingMetricsTask = task
    }

    private func applyObservabilityConfigurationFromSettings() {
        ObservabilityConfigurator.shared.apply(from: settings)
    }

    private func observabilityEvent(
        _ name: String,
        level: ObservabilityEventLevel = .info,
        sessionId: UUID? = nil,
        metadata: @autoclosure () -> [String: String] = [:]
    ) {
        guard settings.observabilityEnabled,
              settings.observabilityVerbosity.includes(level) else { return }
        let activeSessionId = sessionId ?? currentMetricsSessionId
        let payload = metadata()
        Task {
            await ObservabilityStore.shared.record(
                component: "RecordingController",
                name: name,
                level: level,
                sessionId: activeSessionId,
                metadata: payload
            )
        }
    }

    private func maybeRecordSettingsSnapshot(
        sessionId: UUID?,
        providerId: String,
        providerMode: ProviderMode
    ) {
        guard settings.observabilityCaptureSettingsSnapshot else { return }
        let snapshot = SettingsSnapshot.values(settings).merging([
            "provider.id": providerId,
            "provider.mode": providerMode.rawValue,
            "recording.testMode": String(describing: testMode)
        ]) { _, context in context }
        Task {
            await ObservabilityStore.shared.recordSettingsSnapshot(sessionId: sessionId, settings: snapshot)
        }
    }

    private func metadataForTextPayload(_ text: String) -> [String: String] {
        var metadata: [String: String] = [
            "characters": String(text.count),
            "fingerprint": ObservabilityFingerprint.sha256(text)
        ]
        if settings.observabilityCaptureTextPayloads {
            metadata["text"] = text
        }
        return metadata
    }

}

// MARK: - Streaming Recording

extension RecordingController {
    func startStreamingRecording(provider: any StreamingTranscriptionProvider) {
        let config = provider.buildSessionConfig()
        observabilityEvent(
            "streaming_recording_starting",
            metadata: [
                "providerId": provider.id,
                "sampleRate": String(config.sampleRate),
                "encoding": config.encoding.rawValue
            ]
        )

        // Unit tests set testMode = .live to skip permission checks while still
        // exercising the real code paths. Passing skipAudioEngineForTesting = true
        // ensures start() never touches the real microphone, installs audio taps,
        // or consumes mic permissions — no host-OS side-effects from tests.
        let controller = LiveStreamingController(skipAudioEngineForTesting: testMode == .live)
        self.liveStreamingController = controller
        let generation = session.generation
        controller.sessionId = currentMetricsSessionId
        self.session.streamingSegmentStart = ContinuousClock.now
        controller.onAudioCaptureStarted = { [weak self, weak controller] in
            guard let self,
                  self.isRecording,
                  self.liveStreamingController === controller else { return }
            self.signalStreamingCaptureStarted(provider: provider)
        }

        controller.onTextUpdate = { [weak self] textToType, replacingChars, isFinal, fullText in
            // Accept text updates while recording AND while processing final.
            // The processing-final window is when the streaming server delivers
            // trailing finals after the stop-finalize signal — these must be typed.
            // Updates from a retired recording (stopped and replaced, or cancelled)
            // must never touch the current recording's field.
            guard let self, self.owns(generation) else { return }

            let textForInsertion: String
            if !textToType.isEmpty {
                textForInsertion = isFinal ? textToType + " " : textToType
            } else if isFinal && !fullText.isEmpty {
                textForInsertion = " "
            } else {
                textForInsertion = ""
            }
            self.textInserter.replaceTail(replacingChars: replacingChars, with: textForInsertion)
            self.observabilityEvent(
                "streaming_text_update",
                level: .debug,
                metadata: [
                    "isFinal": isFinal ? "true" : "false",
                    "replacingChars": String(replacingChars),
                    "fullTextChars": String(fullText.count),
                    "typedTextFingerprint": ObservabilityFingerprint.sha256(textForInsertion)
                ].merging(
                    self.settings.observabilityCaptureTextPayloads
                        ? ["typedText": textForInsertion, "fullText": fullText]
                        : [:],
                    uniquingKeysWith: { _, new in new }
                )
            )

            if isFinal && !fullText.isEmpty {
                if !self.fullTranscript.isEmpty { self.fullTranscript += " " }
                self.fullTranscript += fullText
                self.recordMetricsWords(fullText)
                let segmentSeconds = self.consumeStreamingSegmentSeconds()
                Statistics.shared.recordTranscription(
                    text: fullText,
                    audioDurationSeconds: segmentSeconds,
                    providerId: provider.id,
                    language: self.languageForStats(providerId: provider.id)
                )
            }
        }

        // Auto-end for streaming mode (user-configurable, enabled by default).
        if settings.streamingAutoEndEnabled {
            controller.autoEndSilenceDuration = settings.autoEndSilenceDuration
        } else {
            controller.autoEndSilenceDuration = 0
        }
        controller.keepAliveEnabled = settings.streamingKeepAliveEnabled
        controller.keepAliveInterval = settings.streamingKeepAliveInterval
        controller.reconnectEnabled = settings.streamingReconnectEnabled
        controller.minimumFinalWordCount = settings.streamingMinimumFinalWordCount
        controller.onFinalLatency = { [weak self] seconds in
            guard let self, self.owns(generation) else { return }
            self.recordStreamingLatency(seconds: seconds, providerId: provider.id)
        }
        controller.onAutoEnd = { [weak self] in
            self?.observabilityEvent("streaming_auto_end_triggered")
            Task { @MainActor in
                guard let self, self.owns(generation), self.isRecording else { return }
                self.stopRecording(reason: .autoEnd)
            }
        }
        controller.onUtteranceEnd = { [weak self] in
            Logger.audio.info("Streaming: utterance end")
            self?.observabilityEvent("streaming_utterance_end", level: .debug)
        }
        controller.onSpeechStarted = { [weak self] in
            Logger.audio.info("Streaming: speech started")
            self?.observabilityEvent("streaming_speech_started", level: .debug)
        }
        controller.onKeepAliveSent = { [weak self] in
            guard let self, let sessionId = self.currentMetricsSessionId else { return }
            Task {
                await SessionMetricsStore.shared.incrementKeepAlive(sessionId: sessionId)
            }
            self.observabilityEvent("streaming_keep_alive_sent", level: .debug, sessionId: sessionId)
        }
        controller.onReconnected = { [weak self] in
            guard let self, let sessionId = self.currentMetricsSessionId else { return }
            Task {
                await SessionMetricsStore.shared.incrementReconnection(sessionId: sessionId)
            }
            self.observabilityEvent("streaming_reconnected", level: .warning, sessionId: sessionId)
        }
        controller.onError = { [weak self, weak controller] error in
            guard let self, let controller,
                  self.liveStreamingController === controller else { return }
            Logger.audio.error("Streaming error: \(error.localizedDescription)")
            self.session.latestStreamingError = error
            self.observabilityEvent(
                "streaming_error",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            self.presentRecordingError(error, providerId: provider.id)
            Task { @MainActor [weak self] in self?.stopRecording(reason: .autoEnd) }
        }
        controller.onSessionClosed = { [weak self] in
            Task { @MainActor in
                guard let self, self.owns(generation), self.isRecording else { return }
                self.observabilityEvent("streaming_session_closed")
                let hadText = !self.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hadText {
                    self.stopRecording(reason: .autoEnd)
                } else {
                    // Early session close with no transcript (observed with Mistral realtime
                    // in some environments) should not silently behave like successful auto-end.
                    // Stop recording and surface explicit guidance.
                    self.stopRecording(reason: .autoEnd)
                    self.presentRecordingError(
                        message: "\(provider.displayName) session ended before audio was transcribed. "
                            + "Please try again or switch provider."
                    )
                    self.observabilityEvent(
                        "streaming_session_closed_without_text",
                        level: .warning
                    )
                }
            }
        }

        Task { @MainActor in
            let started = await controller.start(provider: provider, config: config)

            // Stop/cancel can detach this controller while the initial provider
            // handshake is still in flight. Its late result must not surface an
            // error, alter UI state, or count usage for a finished recording.
            guard self.liveStreamingController === controller, self.isRecording else {
                self.observabilityEvent(
                    "streaming_start_result_ignored_stale",
                    level: .debug,
                    metadata: ["started": started ? "true" : "false"]
                )
                return
            }

            if !started {
                if let error = self.session.latestStreamingError {
                    self.presentRecordingError(error, providerId: provider.id)
                } else {
                    self.presentRecordingError(
                        message: "Transcription failed, \(provider.displayName) streaming could not start. Check your connection and Providers settings."
                    )
                }
                self.session.latestStreamingError = nil
                isRecording = false; isProcessingFinal = false
                liveStreamingController = nil
                self.keyInterceptor.cancel()
                self.playSoundEffect(.error)
                self.observabilityEvent("streaming_recording_start_failed", level: .error)
                self.endMetricsSession(reason: "START_FAILED")
            } else {
                // Provider readiness follows the local capture cue. Startup audio was
                // buffered while the WebSocket connected, so the user can speak as
                // soon as capture starts without losing the first words.
                self.observabilityEvent(
                    "recording_started",
                    metadata: [
                        "providerId": provider.id,
                        "providerMode": provider.mode.rawValue,
                        "targetPid": String(self.textInserter.targetPid)
                    ]
                )

                // Streaming opens exactly one provider WebSocket per recording,
                // so the API-call count grows by one and the recording count
                // by one.
                Statistics.shared.recordApiCall()
                Statistics.shared.recordRecording(
                    providerId: provider.id,
                    language: self.languageForStats(providerId: provider.id)
                )
                self.observabilityEvent(
                    "streaming_recording_started",
                    metadata: ["providerId": provider.id]
                )
            }
        }
    }
}

// MARK: - User-Facing Error Messages

extension RecordingController {
    /// Maps a transcription error to an actionable, user-friendly message.
    static func userFacingMessage(for error: Error, providerId: String) -> String {
        let kind = TranscriptionErrorKind.classify(error)
        switch kind {
        case .authentication:
            if providerId == ProviderId.chatGPT {
                return "Transcription failed, your ChatGPT session has expired. Please re-login in Providers."
            } else {
                let name = providerDisplayName(for: providerId)
                return "Transcription failed, your \(name) API key is invalid or expired. Check Providers settings."
            }
        case .rateLimited:
            return "Transcription rate limited — please wait a moment and try again."
        case .network:
            return "Transcription failed — network error. Check your internet connection."
        case .other:
            return "Transcription failed — \(error.localizedDescription)"
        }
    }

    /// Human-readable provider name for error messages.
    private static func providerDisplayName(for providerId: String) -> String {
        switch providerId {
        case ProviderId.deepgram: return "Deepgram"
        case ProviderId.mistral, ProviderId.mistralBatch: return "Mistral"
        case ProviderId.chatGPT: return "ChatGPT"
        default: return providerId
        }
    }

    /// Presents one actionable recording error per session and message. A streaming
    /// startup failure reaches both `onError` and the `start() == false` branch, so
    /// this deduplication prevents the same failure from presenting twice.
    private func presentRecordingError(_ error: Error, providerId: String) {
        presentRecordingError(
            message: Self.userFacingMessage(for: error, providerId: providerId)
        )
    }

    private func presentRecordingError(message: String) {
        guard presentedRecordingErrorMessage != message else { return }
        presentedRecordingErrorMessage = message
        appState.showBanner(message, style: .error, duration: 8)
    }

    private func resetRecordingErrorPresentation() {
        presentedRecordingErrorMessage = nil
    }
}

#if DEBUG
extension RecordingController {
    var testCurrentMetricsSessionId: UUID? {
        currentMetricsSessionId
    }

    func testSetMetricsSession(_ sessionId: UUID?) {
        currentMetricsSessionId = sessionId
        transcription.setMetricsSession(sessionId)
    }
}
#endif
