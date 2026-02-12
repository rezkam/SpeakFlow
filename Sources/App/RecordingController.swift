import AppKit
import ApplicationServices
import AVFoundation
import OSLog
import os
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

    // UI test support (configured externally by AppDelegate)
    var isUITestMode = false
    var useMockRecordingInUITests = false
    var uiTestToggleCount = 0
    /// Called after recording state changes (used by UI test harness).
    var onStateChanged: (() -> Void)?

    private static let maxFinishRetries = 30

    init(
        keyInterceptor: any KeyIntercepting = KeyInterceptor.shared,
        textInserter: any TextInserting = TextInserter.shared,
        appState: any BannerPresenting = AppState.shared
    ) {
        self.keyInterceptor = keyInterceptor
        self.textInserter = textInserter
        self.appState = appState
        self.keyInterceptor.onEscapePressed = { [weak self] in self?.cancelRecording() }
        self.keyInterceptor.onEnterPressed = { [weak self] in
            guard let self else { return }
            if self.isRecording { self.stopRecordingAndSubmit() }
            else if self.isProcessingFinal { self.shouldPressEnterOnComplete = true }
        }
    }

    // MARK: - Hotkey

    func setupHotkey() {
        if isUITestMode {
            hotkeyListener?.stop()
            hotkeyListener = nil
            Logger.hotkey.info("UI test mode: skipping global hotkey listener")
            return
        }
        let type = HotkeySettings.shared.currentHotkey
        if hotkeyListener == nil {
            hotkeyListener = HotkeyListener()
            hotkeyListener?.onActivate = { [weak self] in self?.toggle() }
        }
        hotkeyListener?.start(type: type)
        Logger.hotkey.info("Using \(type.displayName) activation")
    }

    // MARK: - Transcription Callbacks

    func setupTranscriptionCallbacks() {
        Transcription.shared.queueBridge.onTextReady = { [weak self] text in
            guard let self else { return }
            if !self.fullTranscript.isEmpty { self.fullTranscript += " " }
            self.fullTranscript += text
            if self.isRecording || self.isProcessingFinal {
                self.textInserter.insertText(text + " ")
            }
        }
        Transcription.shared.queueBridge.onAllComplete = { [weak self] in
            self?.finishIfDone()
        }
    }

    // MARK: - Toggle

    @objc func toggle() {
        if isUITestMode { uiTestToggleCount += 1 }
        if isRecording { stopRecording(reason: .hotkey) } else { startRecording() }
        onStateChanged?()
    }

    // MARK: - Start Recording

    func startRecording() {
        guard !isRecording else { return }
        if isProcessingFinal {
            NSSound(named: "Basso")?.play()
            return
        }
        if isUITestMode && useMockRecordingInUITests {
            isRecording = true; isProcessingFinal = false; hasPlayedCompletionSound = false
            shouldPressEnterOnComplete = false; fullTranscript = ""
            onStateChanged?(); return
        }
        if !isUITestMode {
            if !AXIsProcessTrusted() {
                NSSound(named: "Basso")?.play()
                _ = PermissionController.shared.ensureAccessibility()
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    Task { @MainActor in if granted { self?.startRecording() } }
                }
                return
            case .denied, .restricted:
                NSSound(named: "Basso")?.play(); return
            @unknown default: return
            }
        }

        let providerId = ProviderSettings.shared.activeProviderId
        let provider = ProviderRegistry.shared.provider(for: providerId)
        guard let provider, provider.isConfigured else {
            NSSound(named: "Basso")?.play()
            appState.showBanner(
                "Set up a transcription provider in Accounts to start dictating",
                style: .error
            )
            return
        }

        isRecording = true; isProcessingFinal = false; hasPlayedCompletionSound = false
        shouldPressEnterOnComplete = false; fullTranscript = ""

        textInserter.captureTarget()
        NSSound(named: "Blow")?.play()

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
        recorder?.onChunkReady = { chunk in
            Task { @MainActor in
                let ticket = await Transcription.shared.queueBridge.nextSequence()
                Transcription.shared.transcribe(ticket: ticket, chunk: chunk)
            }
        }
        recorder?.onAutoEnd = { [weak self] in
            Task { @MainActor in self?.stopRecording(reason: .autoEnd) }
        }
        keyInterceptor.start()
        Task { @MainActor in
            await Transcription.shared.queueBridge.reset()
            let started = await recorder?.start() ?? false
            if !started {
                isRecording = false; isProcessingFinal = false; recorder = nil
                self.keyInterceptor.stop(); NSSound(named: "Basso")?.play()
            }
        }
    }

    // MARK: - Streaming Recording

    private func startStreamingRecording(provider: any StreamingTranscriptionProvider) {
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
        if Settings.shared.streamingAutoEndEnabled {
            controller.autoEndSilenceDuration = Settings.shared.autoEndSilenceDuration
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

        keyInterceptor.start()
        Task { @MainActor in
            let started = await controller.start(provider: provider, config: config)
            if !started {
                isRecording = false; isProcessingFinal = false
                liveStreamingController = nil; self.keyInterceptor.stop()
                NSSound(named: "Basso")?.play()
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

        if isUITestMode && useMockRecordingInUITests {
            isRecording = false; isProcessingFinal = false; onStateChanged?(); return
        }
        isRecording = false

        if liveStreamingController != nil {
            // Streaming: respond quickly but wait for any pending text insertions.
            isProcessingFinal = true
            NSSound(named: "Pop")?.play()
            hasPlayedCompletionSound = true
            let pendingInsertion = textInserter.pendingTask
            let controller = liveStreamingController
            liveStreamingController = nil
            Task { await controller?.stop() }
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
            isProcessingFinal = true; NSSound(named: "Pop")?.play()
            recorder?.stop(); recorder = nil
            Task { try? await Task.sleep(for: .seconds(1)); await MainActor.run { self.finishIfDone() } }
        }
        onStateChanged?()
    }

    func cancelRecording() {
        guard isRecording || isProcessingFinal else { return }
        keyInterceptor.stop(); isRecording = false; isProcessingFinal = false
        shouldPressEnterOnComplete = false; fullTranscript = ""
        textInserter.cancelAndReset()
        if liveStreamingController != nil {
            Task { await liveStreamingController?.cancel(); await MainActor.run { self.liveStreamingController = nil } }
        } else {
            recorder?.cancel(); recorder = nil; Transcription.shared.cancelAll()
        }
        onStateChanged?(); NSSound(named: "Glass")?.play()
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
            Task { await Transcription.shared.queueBridge.checkCompletion() }
            keyInterceptor.stop(); isProcessingFinal = false
            textInserter.reset(); return
        }
        Task {
            let pending = await Transcription.shared.queueBridge.getPendingCount()
            if pending > 0 {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { self.finishIfDone(attempt: attempt + 1) }
                return
            }
            await self.textInserter.waitForPendingInsertions()
            await MainActor.run {
                self.keyInterceptor.stop(); self.isProcessingFinal = false
                self.textInserter.reset()
                guard !self.fullTranscript.isEmpty, !self.hasPlayedCompletionSound else { return }
                self.hasPlayedCompletionSound = true
                NSSound(named: "Glass")?.play()
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
        Transcription.shared.cancelAll()
        Transcription.shared.queueBridge.stopListening()
        textInserter.cancelAndReset()
    }
}
