import AppKit
import ApplicationServices
import AVFoundation
import OSLog
import os
import SpeakFlowCore

/// Manages the recording pipeline, text insertion, and key interception.
///
/// Extracted from AppDelegate so that business-critical recording logic
/// lives in its own controller, independent of app lifecycle concerns.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    // MARK: - Recording State

    var isRecording = false {
        didSet { AppState.shared.isRecording = isRecording }
    }
    var isProcessingFinal = false {
        didSet { AppState.shared.isProcessingFinal = isProcessingFinal }
    }

    // MARK: - Internal

    var hotkeyListener: HotkeyListener?
    var recorder: StreamingRecorder?
    var liveStreamingController: LiveStreamingController?
    var hasPlayedCompletionSound = false
    var fullTranscript = ""
    var targetElement: AXUIElement?

    private var textInsertionTask: Task<Void, Never>?
    private var queuedInsertionCount = 0
    private var keyMonitor: Any?
    private var shouldPressEnterOnComplete = false
    private let keyListenerActive = OSAllocatedUnfairLock(initialState: false)
    private var recordingEventTap: CFMachPort?
    private var recordingRunLoopSource: CFRunLoopSource?

    // UI test support (configured externally by AppDelegate)
    var isUITestMode = false
    var useMockRecordingInUITests = false
    var uiTestToggleCount = 0
    /// Called after recording state changes (used by UI test harness).
    var onStateChanged: (() -> Void)?

    private static let maxFinishRetries = 30
    private static let maxTextInsertionLength = 100_000
    private static let keystrokeDelayMicroseconds: UInt32 = 5000

    private init() {}

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
                self.insertText(text + " ")
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

        isRecording = true; isProcessingFinal = false; hasPlayedCompletionSound = false
        shouldPressEnterOnComplete = false; fullTranscript = ""

        // Capture focused element for text insertion target
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           let element = focusedElement, CFGetTypeID(element) == AXUIElementGetTypeID() {
            targetElement = (element as! AXUIElement)
        } else {
            targetElement = nil
        }

        NSSound(named: "Blow")?.play()

        if ProviderSettings.shared.activeProviderId == "deepgram" {
            startDeepgramRecording()
        } else {
            startGPTRecording()
        }
        onStateChanged?()
    }

    // MARK: - GPT Recording

    private func startGPTRecording() {
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
        startKeyListener()
        Task { @MainActor in
            await Transcription.shared.queueBridge.reset()
            let started = await recorder?.start() ?? false
            if !started {
                isRecording = false; isProcessingFinal = false; recorder = nil
                self.stopKeyListener(); NSSound(named: "Basso")?.play()
            }
        }
    }

    // MARK: - Deepgram Recording

    private func startDeepgramRecording() {
        guard let apiKey = ProviderSettings.shared.apiKey(for: "deepgram") else {
            isRecording = false; NSSound(named: "Basso")?.play(); return
        }
        let provider = DeepgramProvider()
        ProviderSettings.shared.setApiKey(apiKey, for: "deepgram")

        let config = StreamingSessionConfig(
            language: Settings.shared.deepgramLanguage,
            interimResults: Settings.shared.deepgramInterimResults,
            smartFormat: Settings.shared.deepgramSmartFormat,
            endpointingMs: Settings.shared.deepgramEndpointingMs,
            model: Settings.shared.deepgramModel
        )

        let controller = LiveStreamingController()
        self.liveStreamingController = controller

        controller.onTextUpdate = { [weak self] textToType, replacingChars, isFinal, fullText in
            guard let self, self.isRecording else { return }
            if replacingChars > 0 { self.deleteChars(replacingChars) }
            if !textToType.isEmpty {
                self.insertText(isFinal ? textToType + " " : textToType)
            } else if isFinal && !fullText.isEmpty {
                self.insertText(" ")
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

        startKeyListener()
        Task { @MainActor in
            let started = await controller.start(provider: provider, config: config)
            if !started {
                isRecording = false; isProcessingFinal = false
                liveStreamingController = nil; self.stopKeyListener()
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
            // Set isProcessingFinal so the key handler still acts on Enter/Escape
            // during the wind-down gap (isRecording is false, tap is still active).
            isProcessingFinal = true
            NSSound(named: "Pop")?.play()
            hasPlayedCompletionSound = true
            let pendingInsertion = textInsertionTask
            // Gracefully close WebSocket in the background
            let controller = liveStreamingController
            liveStreamingController = nil
            Task { await controller?.stop() }
            // Wait for pending insertions, then release key listener and press Enter.
            // Read shouldPressEnterOnComplete late so Enter presses during wind-down are captured.
            Task { @MainActor in
                await pendingInsertion?.value
                // If cancel or a new session already cleaned up, don't clobber their state.
                guard self.isProcessingFinal, !self.isRecording else { return }
                let enterRequested = self.shouldPressEnterOnComplete
                self.shouldPressEnterOnComplete = false
                self.stopKeyListener()
                self.isProcessingFinal = false
                self.targetElement = nil
                self.textInsertionTask = nil
                self.queuedInsertionCount = 0
                if enterRequested { self.pressEnterKey() }
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
        stopKeyListener(); isRecording = false; isProcessingFinal = false
        shouldPressEnterOnComplete = false; fullTranscript = ""; targetElement = nil
        textInsertionTask?.cancel(); textInsertionTask = nil; queuedInsertionCount = 0
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
            stopKeyListener(); isProcessingFinal = false; targetElement = nil
            textInsertionTask = nil; queuedInsertionCount = 0; return
        }
        Task {
            let pending = await Transcription.shared.queueBridge.getPendingCount()
            if pending > 0 {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { self.finishIfDone(attempt: attempt + 1) }
                return
            }
            await self.waitForTextInsertion()
            await MainActor.run {
                self.stopKeyListener(); self.isProcessingFinal = false
                self.targetElement = nil; self.textInsertionTask = nil; self.queuedInsertionCount = 0
                guard !self.fullTranscript.isEmpty, !self.hasPlayedCompletionSound else { return }
                self.hasPlayedCompletionSound = true
                NSSound(named: "Glass")?.play()
                if self.shouldPressEnterOnComplete {
                    self.shouldPressEnterOnComplete = false; self.pressEnterKey()
                }
            }
        }
    }

    // MARK: - Escape/Enter Key Interceptor

    private func startKeyListener() {
        guard recordingEventTap == nil else { return }
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        recordingEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, _, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let controller = Unmanaged<RecordingController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.handleRecordingKeyEvent(event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = recordingEventTap else {
            Logger.audio.error("Could not create CGEvent tap. Falling back to passive monitor.")
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 53: Task { @MainActor [weak self] in self?.cancelRecording() }
                case 36: Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.isRecording { self.stopRecordingAndSubmit() }
                    else if self.isProcessingFinal { self.shouldPressEnterOnComplete = true }
                }
                default: break
                }
            }
            return
        }

        recordingRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = recordingRunLoopSource else { recordingEventTap = nil; return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyListenerActive.withLock { $0 = true }
    }

    private nonisolated func handleRecordingKeyEvent(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard keyListenerActive.withLock({ $0 }) else { return Unmanaged.passRetained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch keyCode {
        case 53:
            Task { @MainActor [weak self] in self?.cancelRecording() }
            return nil
        case 36:
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isRecording { self.stopRecordingAndSubmit() }
                else if self.isProcessingFinal { self.shouldPressEnterOnComplete = true }
            }
            return nil
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func stopKeyListener() {
        keyListenerActive.withLock { $0 = false }
        if let tap = recordingEventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = recordingRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        recordingEventTap = nil
        recordingRunLoopSource = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
    }

    // MARK: - Text Insertion

    func deleteChars(_ count: Int) {
        guard count > 0 else { return }
        let previousTask = textInsertionTask
        queuedInsertionCount += 1
        textInsertionTask = Task { [weak self] in
            defer { Task { @MainActor in self?.queuedInsertionCount -= 1 } }
            await previousTask?.value
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
            for _ in 0..<count {
                try? Task.checkCancellation()
                if let kd = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                   let ku = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                    kd.post(tap: .cghidEventTap); ku.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000)
                }
            }
        }
    }

    func insertText(_ text: String) {
        let sanitized = text.filter { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0.isWhitespace || $0 == "\n" || $0 == "\t" }
        let textToInsert = sanitized.count > Self.maxTextInsertionLength ? String(sanitized.prefix(Self.maxTextInsertionLength)) : sanitized
        guard !textToInsert.isEmpty, queuedInsertionCount < Config.maxQueuedTextInsertions else { return }
        queuedInsertionCount += 1
        let previousTask = textInsertionTask
        textInsertionTask = Task { [weak self] in
            defer { Task { @MainActor in self?.queuedInsertionCount -= 1 } }
            await previousTask?.value
            await self?.typeTextAsync(textToInsert)
        }
    }

    func waitForTextInsertion() async { await textInsertionTask?.value }

    private func pressEnterKey() {
        guard verifyInsertionTarget() else { return }
        let keyCode: CGKeyCode = 36
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000)
            if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    private func verifyInsertionTarget() -> Bool {
        guard let target = targetElement else { return true }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(target, focused as! AXUIElement)
    }

    private func typeTextAsync(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        guard await MainActor.run(body: { self.verifyInsertionTarget() }) else { return }
        await waitForModifiersReleased()
        for char in text {
            do { try Task.checkCancellation() } catch { return }
            await waitForModifiersReleased()
            var unichar = Array(String(char).utf16)
            guard let kd = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let ku = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            kd.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)
            kd.post(tap: .cghidEventTap); ku.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000)
        }
    }

    private func waitForModifiersReleased() async {
        var attempts = 0
        while attempts < 100 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.contains(.maskControl) && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate) && !flags.contains(.maskShift) { return }
            attempts += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Cleanup

    func shutdown() {
        hotkeyListener?.stop(); hotkeyListener = nil
        stopKeyListener()
        if isRecording || isProcessingFinal {
            recorder?.cancel(); recorder = nil
            isRecording = false; isProcessingFinal = false
        }
        Transcription.shared.cancelAll()
        Transcription.shared.queueBridge.stopListening()
        textInsertionTask?.cancel(); textInsertionTask = nil
    }
}
