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
    var hasPlayedCompletionSound = false
    var fullTranscript = ""
    var shouldPressEnterOnComplete = false
    private var hasCapturedSubmitEnter = false
    private var currentMetricsSessionId: UUID?
    private var pendingMetricsTask: Task<Void, Never>?
    private let lifecycleCoordinator = RecordingLifecycleCoordinator()

    let textInserter: any TextInserting
    let keyInterceptor: any KeyIntercepting
    let appState: any BannerPresenting
    let hotkeySettings: any HotkeySettingsProviding
    let providerSettings: any ProviderSettingsProviding
    let providerRegistry: any ProviderRegistryProviding
    let settings: any SettingsProviding
    let transcription: any TranscriptionCoordinating

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
        transcription: any TranscriptionCoordinating = Transcription.shared
    ) {
        self.keyInterceptor = keyInterceptor
        self.textInserter = textInserter
        self.appState = appState
        self.hotkeySettings = hotkeySettings
        self.providerSettings = providerSettings
        self.providerRegistry = providerRegistry
        self.settings = settings
        self.transcription = transcription
        self.keyInterceptor.onEscapePressed = { [weak self] in self?.cancelRecording() }
        self.keyInterceptor.onEnterPressed = { [weak self] in
            guard let self else { return }
            // Enter submit contract:
            // 1) First Enter while recording requests submit and stops capture.
            // 2) Enter capture is one-shot for the recording lifecycle.
            // 3) Actual synthetic Enter happens once, after pending insertions finish.
            if self.isRecording {
                guard !self.hasCapturedSubmitEnter else { return }
                self.hasCapturedSubmitEnter = true
                self.stopRecordingAndSubmit()
                return
            }
            if self.isProcessingFinal {
                guard !self.hasCapturedSubmitEnter else { return }
                self.hasCapturedSubmitEnter = true
                self.shouldPressEnterOnComplete = true
            }
        }
        configureRecordingComponents()
    }

    // MARK: - Hotkey

    func setupHotkey() {
        if testMode != .off {
            hotkeyListener?.stop()
            hotkeyListener = nil
            Logger.hotkey.info("UI test mode: skipping global hotkey listener")
            return
        }
        let type = hotkeySettings.currentHotkey
        if hotkeyListener == nil {
            hotkeyListener = HotkeyListener()
            hotkeyListener?.onActivate = { [weak self] in self?.toggle() }
        }
        hotkeyListener?.start(type: type)
        Logger.hotkey.info("Using \(type.displayName) activation")
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
        applyObservabilityConfigurationFromSettings()
        observabilityEvent(
            "recording_start_requested",
            metadata: [
                "testMode": String(describing: testMode),
                "activeProviderId": providerSettings.activeProviderId
            ]
        )
        if isProcessingFinal {
            if settings.hotkeyRestartsRecording {
                observabilityEvent("recording_restart_during_processing")
                cancelRecording()
            } else {
                observabilityEvent(
                    "recording_start_blocked_processing",
                    level: .warning,
                    metadata: ["hotkeyRestartsRecording": "false"]
                )
                SoundEffect.error.play()
                return
            }
        }
        if testMode == .mock {
            isRecording = true; isProcessingFinal = false; hasPlayedCompletionSound = false
            shouldPressEnterOnComplete = false
            hasCapturedSubmitEnter = false
            fullTranscript = ""
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
            SoundEffect.error.play()
            appState.showBanner(
                "Set up a transcription provider in Accounts to start dictating",
                style: .error
            )
            return
        }

        beginMetricsSession(providerId: provider.id, mode: provider.mode)
        maybeRecordSettingsSnapshot(
            sessionId: currentMetricsSessionId,
            providerId: provider.id,
            providerMode: provider.mode
        )

        isRecording = true; isProcessingFinal = false; hasPlayedCompletionSound = false
        shouldPressEnterOnComplete = false
        hasCapturedSubmitEnter = false
        fullTranscript = ""

        textInserter.captureTarget()
        configureRecordingComponents()
        do {
            try lifecycleCoordinator.prepareAndStart()
        } catch {
            isRecording = false
            isProcessingFinal = false
            observabilityEvent(
                "recording_start_failed_component",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            endMetricsSession(reason: "START_FAILED_COMPONENT")
            SoundEffect.error.play()
            appState.showBanner("Failed to initialize recording components", style: .error)
            return
        }
        SoundEffect.start.play()
        observabilityEvent(
            "recording_started",
            metadata: [
                "providerId": provider.id,
                "providerMode": provider.mode.rawValue,
                "targetPid": String(textInserter.targetPid)
            ]
        )

        if let streaming = provider as? any StreamingTranscriptionProvider {
            startStreamingRecording(provider: streaming)
        } else if provider is any BatchTranscriptionProvider {
            startBatchRecording()
        }
        onStateChanged?()
    }

    // MARK: - Batch Recording

    private func startBatchRecording() {
        observabilityEvent("batch_recording_starting")
        recorder = StreamingRecorder()
        recorder?.onChunkReady = { [weak self] chunk in
            Task { @MainActor in
                guard let self else { return }
                let ticket = await self.transcription.queueBridge.nextSequence()
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
        recorder?.onAutoEnd = { [weak self] in
            self?.observabilityEvent("batch_auto_end_triggered")
            Task { @MainActor in self?.stopRecording(reason: .autoEnd) }
        }
        Task { @MainActor in
            await self.transcription.queueBridge.reset()
            let started = await recorder?.start() ?? false
            if !started {
                isRecording = false; isProcessingFinal = false; recorder = nil
                self.lifecycleCoordinator.cancel()
                SoundEffect.error.play()
                self.observabilityEvent("batch_recording_start_failed", level: .error)
                self.endMetricsSession(reason: "START_FAILED")
            } else {
                self.observabilityEvent("batch_recording_started")
            }
        }
    }

    // MARK: - Streaming Recording

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
        controller.sessionId = currentMetricsSessionId

        controller.onTextUpdate = { [weak self] textToType, replacingChars, isFinal, fullText in
            // Accept text updates while recording AND while processing final.
            // The processing-final window is when the streaming server delivers
            // trailing finals after the stop-finalize signal — these must be typed.
            guard let self, self.isRecording || self.isProcessingFinal else { return }

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
        controller.onAutoEnd = { [weak self] in
            self?.observabilityEvent("streaming_auto_end_triggered")
            Task { @MainActor in self?.stopRecording(reason: .autoEnd) }
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
        controller.onError = { [weak self] error in
            Logger.audio.error("Streaming error: \(error.localizedDescription)")
            self?.observabilityEvent(
                "streaming_error",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            Task { @MainActor in self?.stopRecording(reason: .autoEnd) }
        }
        controller.onSessionClosed = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.observabilityEvent("streaming_session_closed")
                let hadText = !self.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hadText {
                    self.stopRecording(reason: .autoEnd)
                } else {
                    // Early session close with no transcript (observed with Mistral realtime
                    // in some environments) should not silently behave like successful auto-end.
                    // Stop recording and surface explicit guidance.
                    self.stopRecording(reason: .autoEnd)
                    self.appState.showBanner(
                        "Mistral realtime session ended before audio was transcribed. Please try again or switch provider.",
                        style: .error
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
            if !started {
                isRecording = false; isProcessingFinal = false
                liveStreamingController = nil
                self.lifecycleCoordinator.cancel()
                SoundEffect.error.play()
                self.observabilityEvent("streaming_recording_start_failed", level: .error)
                self.endMetricsSession(reason: "START_FAILED")
            } else {
                self.observabilityEvent(
                    "streaming_recording_started",
                    metadata: ["providerId": provider.id]
                )
            }
        }
    }

    // MARK: - Stop / Cancel

    enum StopReason: String {
        case hotkey = "HOTKEY_TOGGLE", autoEnd = "VAD_AUTO_END", enter = "ENTER_SUBMIT"
        case escape = "ESCAPE_CANCEL", ui = "UI_BUTTON", unknown = "UNKNOWN"
    }

    func stopRecording(reason: StopReason = .unknown) {
        guard isRecording else { return }
        Logger.audio.error("🔴 STOP reason=\(reason.rawValue)")
        observabilityEvent(
            "recording_stop_requested",
            metadata: [
                "reason": reason.rawValue,
                "isStreaming": liveStreamingController != nil ? "true" : "false"
            ]
        )

        if testMode == .mock {
            hasCapturedSubmitEnter = false
            isRecording = false; isProcessingFinal = false; onStateChanged?(); return
        }
        isRecording = false

        if liveStreamingController != nil {
            // Streaming stop: isProcessingFinal stays true throughout the trailing-final
            // window so onTextUpdate keeps accepting server results until stop() returns.
            isProcessingFinal = true
            SoundEffect.stop.play()
            hasPlayedCompletionSound = true
            let controller = liveStreamingController
            liveStreamingController = nil
            let trailingTimeout = settings.streamingTrailingFinalTimeout
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
                guard self.isProcessingFinal, !self.isRecording else { return }
                // All trailing finals have now arrived; wait for their insertions too.
                await self.textInserter.waitForPendingInsertions()
                self.endMetricsSession(reason: reason.rawValue)
                guard self.isProcessingFinal, !self.isRecording else { return }
                let enterRequested = self.shouldPressEnterOnComplete
                self.shouldPressEnterOnComplete = false
                self.lifecycleCoordinator.stop()
                self.isProcessingFinal = false
                self.hasCapturedSubmitEnter = false
                if enterRequested {
                    self.textInserter.pressEnterKey()
                    await self.textInserter.waitForPendingInsertions()
                }
                self.textInserter.reset()
                self.textInserter.setObservabilitySessionId(nil)
            }
        } else {
            isProcessingFinal = true; SoundEffect.stop.play()
            endMetricsSession(reason: reason.rawValue)
            let stoppingRecorder = recorder
            stoppingRecorder?.stop()
            recorder = nil
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
        lifecycleCoordinator.cancel()
        isRecording = false; isProcessingFinal = false
        shouldPressEnterOnComplete = false
        hasCapturedSubmitEnter = false
        fullTranscript = ""
        textInserter.cancelAndReset()
        textInserter.setObservabilitySessionId(nil)
        if liveStreamingController != nil {
            Task { @MainActor in await self.liveStreamingController?.cancel(); self.liveStreamingController = nil }
        } else {
            recorder?.cancel(); recorder = nil; transcription.cancelAll()
        }
        onStateChanged?(); SoundEffect.complete.play()
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
                guard self.isProcessingFinal else { return } // already completed or cancelled
                let pending = await self.transcription.queueBridge.getPendingCount()
                self.observabilityEvent(
                    "batch_finalization_poll",
                    level: .debug,
                    metadata: ["pending": String(pending)]
                )
                if pending == 0 { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            await self.completeBatchFinalization()
        }
    }

    /// Shared completion path for batch finalization.
    /// Called by both the `onAllComplete` fast path and the deadline polling task.
    /// Idempotent: the `isProcessingFinal` guard prevents double-execution.
    func completeBatchFinalization() async {
        guard isProcessingFinal, !isRecording else { return }

        // Brief pause to let the queue actor deliver any text whose onTextReady
        // callback has been queued but not yet fired.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        await textInserter.waitForPendingInsertions()

        // Re-check: another task may have completed finalization during the sleeps.
        guard isProcessingFinal, !isRecording else { return }

        lifecycleCoordinator.stop()
        isProcessingFinal = false
        hasCapturedSubmitEnter = false
        observabilityEvent(
            "batch_finalization_completed",
            metadata: ["hadTranscript": fullTranscript.isEmpty ? "false" : "true"]
        )

        guard !fullTranscript.isEmpty, !hasPlayedCompletionSound else {
            textInserter.reset()
            textInserter.setObservabilitySessionId(nil)
            return
        }

        hasPlayedCompletionSound = true
        SoundEffect.complete.play()
        if shouldPressEnterOnComplete {
            shouldPressEnterOnComplete = false
            textInserter.pressEnterKey()
            await textInserter.waitForPendingInsertions()
        }
        textInserter.reset()
        textInserter.setObservabilitySessionId(nil)
    }

    // MARK: - Cleanup

    func shutdown() {
        observabilityEvent("recording_controller_shutdown")
        endMetricsSession(reason: "SHUTDOWN")
        hotkeyListener?.stop(); hotkeyListener = nil
        lifecycleCoordinator.cancel()
        if isRecording || isProcessingFinal {
            recorder?.cancel(); recorder = nil
            isRecording = false; isProcessingFinal = false
        }
        hasCapturedSubmitEnter = false
        transcription.cancelAll()
        transcription.queueBridge.stopListening()
        textInserter.cancelAndReset()
        textInserter.setObservabilitySessionId(nil)
    }

    private func beginMetricsSession(providerId: String, mode: ProviderMode) {
        let sessionId = UUID()
        currentMetricsSessionId = sessionId
        transcription.setMetricsSession(sessionId)
        textInserter.setObservabilitySessionId(sessionId)
        observabilityEvent(
            "metrics_session_started",
            sessionId: sessionId,
            metadata: [
                "providerId": providerId,
                "mode": mode.rawValue
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
        let settings = self.settings
        Task {
            await ObservabilityStore.shared.applyConfiguration(
                enabled: settings.observabilityEnabled,
                verbosity: settings.observabilityVerbosity,
                captureSettingsSnapshot: settings.observabilityCaptureSettingsSnapshot,
                captureSystemContext: settings.observabilityCaptureSystemContext,
                captureTextPayloads: settings.observabilityCaptureTextPayloads
            )
        }
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
        let snapshot: [String: String] = [
            "provider.id": providerId,
            "provider.mode": providerMode.rawValue,
            "recording.testMode": String(describing: testMode),
            "batch.chunkDuration": String(settings.chunkDuration.rawValue),
            "batch.skipSilentChunks": settings.skipSilentChunks ? "true" : "false",
            "batch.finalizationTimeoutBase": String(settings.batchFinalizationTimeoutBase),
            "batch.finalizationTimeoutPerChunkSecond": String(settings.batchFinalizationTimeoutPerChunkSecond),
            "batch.finalizationMaxTimeout": String(settings.batchFinalizationMaxTimeout),
            "streaming.autoEndEnabled": settings.streamingAutoEndEnabled ? "true" : "false",
            "streaming.keepAliveEnabled": settings.streamingKeepAliveEnabled ? "true" : "false",
            "streaming.keepAliveInterval": String(settings.streamingKeepAliveInterval),
            "streaming.reconnectEnabled": settings.streamingReconnectEnabled ? "true" : "false",
            "streaming.minimumFinalWordCount": String(settings.streamingMinimumFinalWordCount),
            "streaming.trailingFinalTimeout": String(settings.streamingTrailingFinalTimeout),
            "vad.enabled": settings.vadEnabled ? "true" : "false",
            "vad.threshold": String(settings.vadThreshold),
            "vad.volumeGateEnabled": settings.vadVolumeGateEnabled ? "true" : "false",
            "vad.minVolumeForSpeech": String(settings.vadMinVolumeForSpeech),
            "autoEnd.enabled": settings.autoEndEnabled ? "true" : "false",
            "autoEnd.silenceDuration": String(settings.autoEndSilenceDuration),
            "autoEnd.minSessionDuration": String(settings.autoEndMinSessionDuration),
            "behavior.focusWaitTimeout": String(settings.focusWaitTimeout),
            "behavior.hotkeyRestartsRecording": settings.hotkeyRestartsRecording ? "true" : "false",
            "observability.captureTextPayloads": settings.observabilityCaptureTextPayloads ? "true" : "false"
        ]
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

    private func configureRecordingComponents() {
        let keyComponent = KeyInterceptorRecordingComponent(
            interceptor: keyInterceptor,
            targetPidProvider: { [weak self] in self?.textInserter.targetPid ?? 0 }
        )
        lifecycleCoordinator.setComponents([keyComponent])
    }
}

#if DEBUG
extension RecordingController {
    var _testCurrentMetricsSessionId: UUID? {
        currentMetricsSessionId
    }
}
#endif
