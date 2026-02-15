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

    private static let maxFinishRetries = 30

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
            if self.isRecording { self.stopRecordingAndSubmit() }
            else if self.isProcessingFinal { self.shouldPressEnterOnComplete = true }
        }
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
            if self.isRecording || self.isProcessingFinal {
                self.textInserter.insertText(text + " ")
            }
        }
        transcription.queueBridge.onAllComplete = { [weak self] in
            self?.finishIfDone()
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
        if isProcessingFinal {
            if settings.hotkeyRestartsRecording {
                cancelRecording()
            } else {
                SoundEffect.error.play()
                return
            }
        }
        if testMode == .mock {
            isRecording = true; isProcessingFinal = false; hasPlayedCompletionSound = false
            shouldPressEnterOnComplete = false; fullTranscript = ""
            onStateChanged?(); return
        }
        if testMode == .off {
            if !PermissionController.shared.isAccessibilityReady() { return }
            if !PermissionController.shared.isMicrophoneReady(onGranted: { [weak self] in self?.startRecording() }) { return }
        }

        let providerId = providerSettings.activeProviderId
        let provider = providerRegistry.provider(for: providerId)
        guard let provider, provider.isConfigured else {
            SoundEffect.error.play()
            appState.showBanner(
                "Set up a transcription provider in Accounts to start dictating",
                style: .error
            )
            return
        }

        isRecording = true; isProcessingFinal = false; hasPlayedCompletionSound = false
        shouldPressEnterOnComplete = false; fullTranscript = ""

        textInserter.captureTarget()
        SoundEffect.start.play()

        if let streaming = provider as? any StreamingTranscriptionProvider {
            startStreamingRecording(provider: streaming)
        } else if provider is any BatchTranscriptionProvider {
            startBatchRecording()
        }
        onStateChanged?()
    }

    // MARK: - Batch Recording

    private func startBatchRecording() {
        recorder = StreamingRecorder()
        recorder?.onChunkReady = { [weak self] chunk in
            Task { @MainActor in
                guard let self else { return }
                let ticket = await self.transcription.queueBridge.nextSequence()
                self.transcription.transcribe(ticket: ticket, chunk: chunk)
            }
        }
        recorder?.onAutoEnd = { [weak self] in
            Task { @MainActor in self?.stopRecording(reason: .autoEnd) }
        }
        keyInterceptor.start(targetPid: textInserter.targetPid)
        Task { @MainActor in
            await self.transcription.queueBridge.reset()
            let started = await recorder?.start() ?? false
            if !started {
                isRecording = false; isProcessingFinal = false; recorder = nil
                self.keyInterceptor.stop(); SoundEffect.error.play()
            }
        }
    }

    // MARK: - Streaming Recording

    func startStreamingRecording(provider: any StreamingTranscriptionProvider) {
        let config = provider.buildSessionConfig()

        let controller = LiveStreamingController()
        self.liveStreamingController = controller

        controller.onTextUpdate = { [weak self] textToType, replacingChars, isFinal, fullText in
            guard let self, self.isRecording else { return }
            if replacingChars > 0 { self.textInserter.deleteChars(replacingChars) }
            if !textToType.isEmpty {
                self.textInserter.insertText(isFinal ? textToType + " " : textToType)
            } else if isFinal && !fullText.isEmpty {
                self.textInserter.insertText(" ")
            }
            if isFinal && !fullText.isEmpty {
                if !self.fullTranscript.isEmpty { self.fullTranscript += " " }
                self.fullTranscript += fullText
            }
        }

        // Auto-end: disabled by default for streaming (user must opt in)
        if settings.streamingAutoEndEnabled {
            controller.autoEndSilenceDuration = settings.autoEndSilenceDuration
        } else {
            controller.autoEndSilenceDuration = 0
        }
        controller.onAutoEnd = { [weak self] in
            Task { @MainActor in self?.stopRecording(reason: .autoEnd) }
        }
        controller.onUtteranceEnd = { Logger.audio.info("Deepgram: utterance end") }
        controller.onSpeechStarted = { Logger.audio.info("Deepgram: speech started") }
        controller.onError = { [weak self] error in
            Logger.audio.error("Deepgram error: \(error.localizedDescription)")
            Task { @MainActor in self?.stopRecording(reason: .autoEnd) }
        }
        controller.onSessionClosed = { [weak self] in
            Task { @MainActor in if self?.isRecording == true { self?.stopRecording(reason: .autoEnd) } }
        }

        keyInterceptor.start(targetPid: textInserter.targetPid)
        Task { @MainActor in
            let started = await controller.start(provider: provider, config: config)
            if !started {
                isRecording = false; isProcessingFinal = false
                liveStreamingController = nil; self.keyInterceptor.stop()
                SoundEffect.error.play()
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

        if testMode == .mock {
            isRecording = false; isProcessingFinal = false; onStateChanged?(); return
        }
        isRecording = false

        if liveStreamingController != nil {
            // Streaming: respond quickly but wait for any pending text insertions.
            isProcessingFinal = true
            SoundEffect.stop.play()
            hasPlayedCompletionSound = true
            let pendingInsertion = textInserter.pendingTask
            let controller = liveStreamingController
            liveStreamingController = nil
            Task { @MainActor in await controller?.stop() }
            // Wait for pending insertions, then release key interceptor and press Enter.
            Task { @MainActor in
                await pendingInsertion?.value
                guard self.isProcessingFinal, !self.isRecording else { return }
                let enterRequested = self.shouldPressEnterOnComplete
                self.shouldPressEnterOnComplete = false
                self.keyInterceptor.stop()
                self.isProcessingFinal = false
                self.textInserter.reset()
                if enterRequested { self.textInserter.pressEnterKey() }
            }
        } else {
            isProcessingFinal = true; SoundEffect.stop.play()
            recorder?.stop(); recorder = nil
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); self.finishIfDone() }
        }
        onStateChanged?()
    }

    func cancelRecording() {
        guard isRecording || isProcessingFinal else { return }
        keyInterceptor.stop(); isRecording = false; isProcessingFinal = false
        shouldPressEnterOnComplete = false; fullTranscript = ""
        textInserter.cancelAndReset()
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

    // MARK: - Finish

    func finishIfDone(attempt: Int = 0) {
        guard !isRecording else { return }
        guard attempt < Self.maxFinishRetries else {
            Task { @MainActor in await self.transcription.queueBridge.checkCompletion() }
            keyInterceptor.stop(); isProcessingFinal = false
            textInserter.reset(); return
        }
        Task {
            let pending = await self.transcription.queueBridge.getPendingCount()
            if pending > 0 {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { self.finishIfDone(attempt: attempt + 1) }
                return
            }
            // Brief pause to let the stream consumer deliver any remaining text
            // that was just flushed from the queue actor. Without this, the stream
            // consumer's onTextReady callback may not have fired yet, so
            // waitForPendingInsertions would return before all text is queued.
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await self.textInserter.waitForPendingInsertions()
            await MainActor.run {
                self.keyInterceptor.stop(); self.isProcessingFinal = false
                self.textInserter.reset()
                guard !self.fullTranscript.isEmpty, !self.hasPlayedCompletionSound else { return }
                self.hasPlayedCompletionSound = true
                SoundEffect.complete.play()
                if self.shouldPressEnterOnComplete {
                    self.shouldPressEnterOnComplete = false; self.textInserter.pressEnterKey()
                }
            }
        }
    }

    // MARK: - Cleanup

    func shutdown() {
        hotkeyListener?.stop(); hotkeyListener = nil
        keyInterceptor.stop()
        if isRecording || isProcessingFinal {
            recorder?.cancel(); recorder = nil
            isRecording = false; isProcessingFinal = false
        }
        transcription.cancelAll()
        transcription.queueBridge.stopListening()
        textInserter.cancelAndReset()
    }
}
