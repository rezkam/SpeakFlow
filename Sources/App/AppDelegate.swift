import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import OSLog
import os
import SwiftUI
import SpeakFlowCore

/// Application delegate — owns NSStatusItem + NSMenu (menu bar) and
/// opens SwiftUI dialog content via NSWindow + NSHostingController.
/// Also handles system-level concerns:
///   - Hotkey listener
///   - CGEvent tap (Escape/Enter interception)
///   - Recording pipeline (GPT batch + Deepgram streaming)
///   - Text insertion via Accessibility
///   - OAuth login flow
///   - Permission management
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AccessibilityPermissionDelegate {
    /// Singleton so views/helpers can call recording/login actions.
    static var shared: AppDelegate!

    // MARK: - Menu Bar
    var statusItem: NSStatusItem!
    private lazy var defaultIcon: NSImage? = loadMenuBarIcon()

    var hotkeyListener: HotkeyListener?
    var recorder: StreamingRecorder?
    var liveStreamingController: LiveStreamingController?
    var isRecording = false {
        didSet { AppState.shared.isRecording = isRecording; buildMenu() }
    }
    var isProcessingFinal = false {
        didSet { AppState.shared.isProcessingFinal = isProcessingFinal; buildMenu() }
    }
    var hasPlayedCompletionSound = false
    var fullTranscript = ""
    var permissionManager: AccessibilityPermissionManager!
    var targetElement: AXUIElement?
    private var textInsertionTask: Task<Void, Never>?
    private var queuedInsertionCount = 0
    private var keyMonitor: Any?
    private var shouldPressEnterOnComplete = false
    private let keyListenerActive = OSAllocatedUnfairLock(initialState: false)
    private var uiTestHarness: UITestHarnessController?
    private var uiTestToggleCount = 0
    private let isUITestMode = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MODE"] == "1"
    private let useMockRecordingInUITests = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MOCK_RECORDING"] != "0"
    private let resetUITestState = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_RESET_STATE"] == "1"
    private let uiTestHotkeyCycle: [HotkeyType] = [.controlOptionD, .controlOptionSpace, .commandShiftD]
    private var micPermissionTask: Task<Void, Never>?
    private var oauthCallbackServer: OAuthCallbackServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        buildMenu()

        permissionManager = AccessibilityPermissionManager()
        permissionManager.delegate = self

        if isUITestMode {
            Logger.permissions.info("UI test mode enabled; skipping startup permission prompts")
        } else {
            let trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true, isAppStart: true)
            Logger.permissions.debug("AXIsProcessTrusted: \(trusted)")
        }

        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        Logger.app.info("SpeakFlow ready - \(hotkeyName)")

        setupHotkey()
        setupTranscriptionCallbacks()

        if !isUITestMode {
            checkMicrophonePermission()

            if VADProcessor.isAvailable && Settings.shared.vadEnabled {
                Task { await VADModelCache.shared.warmUp(threshold: Settings.shared.vadThreshold) }
            }

            Task.detached(priority: .background) {
                let engine = AVAudioEngine()
                _ = engine.inputNode.outputFormat(forBus: 0)
                Logger.audio.info("Audio subsystem pre-warmed")
            }
        }

        if isUITestMode { setupUITestHarness() }

        AppState.shared.refresh()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    // MARK: - Transcription Callbacks

    private func setupTranscriptionCallbacks() {
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

    // MARK: - UI Test Harness

    private func setupUITestHarness() {
        guard isUITestMode, uiTestHarness == nil else { return }
        if resetUITestState {
            Statistics.shared.reset()
            uiTestToggleCount = 0
        }
        if resetUITestState || !uiTestHotkeyCycle.contains(HotkeySettings.shared.currentHotkey) {
            HotkeySettings.shared.currentHotkey = .controlOptionD
        }
        let harness = UITestHarnessController()
        harness.onStartClicked = { [weak self] in self?.startRecording() }
        harness.onStopClicked = { [weak self] in self?.stopRecording(reason: .ui) }
        harness.onSeedStatsClicked = { [weak self] in self?.seedUITestStatistics() }
        harness.onResetStatsClicked = { [weak self] in self?.resetUITestStatistics() }
        harness.onNextHotkeyClicked = { [weak self] in
            guard let self else { return }
            let current = HotkeySettings.shared.currentHotkey
            let idx = self.uiTestHotkeyCycle.firstIndex(of: current) ?? 0
            let next = self.uiTestHotkeyCycle[(idx + 1) % self.uiTestHotkeyCycle.count]
            HotkeySettings.shared.currentHotkey = next
            self.setupHotkey()
            AppState.shared.refresh()
            self.refreshUITestHarness()
        }
        uiTestHarness = harness
        harness.showWindow(nil)
        refreshUITestHarness()
    }

    private func seedUITestStatistics() {
        Statistics.shared.recordApiCall()
        Statistics.shared.recordTranscription(text: "ui harness seeded stats", audioDurationSeconds: 1.2)
        refreshUITestHarness()
    }

    private func resetUITestStatistics() {
        Statistics.shared.reset()
        refreshUITestHarness()
    }

    func refreshUITestHarness() {
        uiTestHarness?.updateState(
            isRecording: isRecording,
            toggleCount: uiTestToggleCount,
            mode: useMockRecordingInUITests ? "mock" : "live",
            hotkeyDisplay: HotkeySettings.shared.currentHotkey.displayName,
            statsApiCalls: Statistics.shared.apiCallCount,
            statsWords: Statistics.shared.wordCount
        )
    }

    // MARK: - Permission Actions (called from SwiftUI views)

    @objc func applicationDidBecomeActive(_ notification: Notification) {
        guard let app = (notification as NSNotification).userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
        AppState.shared.refresh()
    }

    func checkAccessibility() {
        let trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true)
        if trusted {
            showAlert(title: "Accessibility Permission Active",
                      message: "The app has the necessary permissions to insert dictated text.",
                      style: .success)
        }
    }

    func checkMicrophoneAction() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            showAlert(title: "Microphone Permission Active",
                      message: "The app has access to your microphone for voice recording.",
                      style: .success)
        } else {
            checkMicrophonePermission()
        }
    }

    // MARK: - Alert Helper

    func showAlert(title: String, message: String, style: AppState.AlertStyle) {
        let state = AppState.shared
        state.alertTitle = title
        state.alertMessage = message
        state.alertStyle = style
        WindowHelper.open(id: "alert")
    }

    // MARK: - Status Icon & Menu

    func updateStatusIcon() {
        statusItem.button?.title = ""
        statusItem.button?.image = defaultIcon
        AppState.shared.refresh()
    }

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            Logger.app.warning("Could not load AppIcon.png from bundle")
            return nil
        }
        let menuBarSize = NSSize(width: 18, height: 18)
        let resizedImage = NSImage(size: menuBarSize)
        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: menuBarSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        resizedImage.unlockFocus()
        resizedImage.isTemplate = true
        return resizedImage
    }

    func buildMenu(trusted: Bool? = nil) {
        let isTrusted = trusted ?? AXIsProcessTrusted()
        let state = AppState.shared
        state.refresh()

        let menu = NSMenu()

        // Start / Stop Dictation
        let dictationLabel = (isRecording || isProcessingFinal)
            ? "Stop Dictation (\(state.currentHotkey.displayName))"
            : "Start Dictation (\(state.currentHotkey.displayName))"
        let startItem = NSMenuItem(title: dictationLabel, action: #selector(toggleAction), keyEquivalent: "")
        startItem.target = self
        startItem.setAccessibilityLabel("start_stop_dictation")
        menu.addItem(startItem)

        menu.addItem(.separator())

        // Permissions
        let accessibilityItem = NSMenuItem(title: "Accessibility", action: #selector(checkAccessibilityAction), keyEquivalent: "")
        accessibilityItem.target = self
        accessibilityItem.setAccessibilityLabel("accessibility_permission")
        if isTrusted {
            accessibilityItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        } else {
            accessibilityItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
        menu.addItem(accessibilityItem)

        let micItem = NSMenuItem(title: "Microphone", action: #selector(checkMicrophoneMenuAction), keyEquivalent: "")
        micItem.target = self
        micItem.setAccessibilityLabel("microphone_permission")
        if state.microphoneGranted {
            micItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        } else {
            micItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
        menu.addItem(micItem)

        menu.addItem(.separator())

        // Accounts submenu
        let accountsMenu = NSMenu()
        let accountsItem = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        accountsItem.setAccessibilityLabel("accounts_menu")
        accountsItem.submenu = accountsMenu

        let loginItem = NSMenuItem(
            title: state.isLoggedIn ? "ChatGPT — Logged In ✓" : "ChatGPT — Login...",
            action: #selector(loginAction), keyEquivalent: "")
        loginItem.target = self
        loginItem.setAccessibilityLabel("chatgpt_login")
        accountsMenu.addItem(loginItem)

        if state.isLoggedIn {
            let logoutItem = NSMenuItem(title: "Log Out of ChatGPT", action: #selector(logoutAction), keyEquivalent: "")
            logoutItem.target = self
            logoutItem.setAccessibilityLabel("chatgpt_logout")
            accountsMenu.addItem(logoutItem)
        }

        accountsMenu.addItem(.separator())

        let dgKeyItem = NSMenuItem(
            title: state.hasDeepgramKey ? "Deepgram — API Key Set ✓" : "Deepgram — Set API Key...",
            action: #selector(deepgramKeyAction), keyEquivalent: "")
        dgKeyItem.target = self
        dgKeyItem.setAccessibilityLabel("deepgram_key")
        accountsMenu.addItem(dgKeyItem)

        if state.hasDeepgramKey {
            let removeKeyItem = NSMenuItem(title: "Remove API Key", action: #selector(removeDeepgramKeyAction), keyEquivalent: "")
            removeKeyItem.target = self
            removeKeyItem.setAccessibilityLabel("deepgram_remove_key")
            accountsMenu.addItem(removeKeyItem)
        }

        menu.addItem(accountsItem)

        // Provider submenu
        let providerMenu = NSMenu()
        let providerItem = NSMenuItem(title: "Transcription Provider", action: nil, keyEquivalent: "")
        providerItem.setAccessibilityLabel("provider_menu")
        providerItem.submenu = providerMenu

        let gptItem = NSMenuItem(title: "ChatGPT (GPT-4o) — Batch", action: #selector(selectGPTProvider), keyEquivalent: "")
        gptItem.target = self
        gptItem.setAccessibilityLabel("provider_gpt")
        gptItem.state = state.activeProviderId == "gpt" ? .on : .off
        if !state.isLoggedIn { gptItem.action = nil }
        providerMenu.addItem(gptItem)

        let dgItem = NSMenuItem(title: "Deepgram Nova-3 English — Real-time", action: #selector(selectDeepgramProvider), keyEquivalent: "")
        dgItem.target = self
        dgItem.setAccessibilityLabel("provider_deepgram")
        dgItem.state = state.activeProviderId == "deepgram" ? .on : .off
        if !state.hasDeepgramKey { dgItem.action = nil }
        providerMenu.addItem(dgItem)

        menu.addItem(providerItem)

        menu.addItem(.separator())

        // Hotkey submenu
        let hotkeyMenu = NSMenu()
        let hotkeyItem = NSMenuItem(title: "Activation Hotkey", action: nil, keyEquivalent: "")
        hotkeyItem.setAccessibilityLabel("hotkey_menu")
        hotkeyItem.submenu = hotkeyMenu
        for type in HotkeyType.allCases {
            let item = NSMenuItem(title: type.displayName, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type
            item.state = state.currentHotkey == type ? .on : .off
            hotkeyMenu.addItem(item)
        }
        menu.addItem(hotkeyItem)

        // Chunk Duration submenu
        let chunkMenu = NSMenu()
        let chunkItem = NSMenuItem(title: "Chunk Duration", action: nil, keyEquivalent: "")
        chunkItem.setAccessibilityLabel("chunk_duration_menu")
        chunkItem.submenu = chunkMenu
        for duration in ChunkDuration.allCases {
            let item = NSMenuItem(title: duration.displayName, action: #selector(selectChunkDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = duration
            item.state = state.chunkDuration == duration ? .on : .off
            chunkMenu.addItem(item)
        }
        menu.addItem(chunkItem)

        // Skip Silent Chunks
        let skipItem = NSMenuItem(title: "Skip Silent Chunks", action: #selector(toggleSkipSilent), keyEquivalent: "")
        skipItem.target = self
        skipItem.setAccessibilityLabel("skip_silent_chunks")
        skipItem.state = state.skipSilentChunks ? .on : .off
        menu.addItem(skipItem)

        menu.addItem(.separator())

        // Statistics
        let statsItem = NSMenuItem(title: "View Statistics...", action: #selector(showStatistics), keyEquivalent: "")
        statsItem.target = self
        statsItem.setAccessibilityLabel("view_statistics")
        menu.addItem(statsItem)

        menu.addItem(.separator())

        // Launch at Login
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.setAccessibilityLabel("launch_at_login")
        launchItem.state = state.launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        quitItem.setAccessibilityLabel("quit")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Menu Actions

    @objc private func toggleAction() { toggle() }
    @objc private func checkAccessibilityAction() { checkAccessibility() }
    @objc private func checkMicrophoneMenuAction() { checkMicrophoneAction() }
    @objc private func loginAction() { handleLoginAction() }
    @objc private func logoutAction() { handleLogout() }
    @objc private func deepgramKeyAction() { WindowHelper.open(id: "deepgram-key") }
    @objc private func removeDeepgramKeyAction() { handleRemoveDeepgramKey() }
    @objc private func selectGPTProvider() { setProvider("gpt") }
    @objc private func selectDeepgramProvider() { setProvider("deepgram") }
    @objc private func showStatistics() { WindowHelper.open(id: "statistics") }
    @objc private func quitAction() { NSApplication.shared.terminate(nil) }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? HotkeyType else { return }
        HotkeySettings.shared.currentHotkey = type
        setupHotkey()
        buildMenu()
    }

    @objc private func selectChunkDuration(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? ChunkDuration else { return }
        Settings.shared.chunkDuration = duration
        buildMenu()
    }

    @objc private func toggleSkipSilent() {
        Settings.shared.skipSilentChunks.toggle()
        buildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            let current = (try? SMAppService.mainApp.status == .enabled) ?? false
            if current {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Logger(subsystem: "SpeakFlow", category: "App")
                .error("Failed to toggle launch at login: \(error.localizedDescription)")
        }
        buildMenu()
    }

    private func setProvider(_ id: String) {
        if id == "deepgram" && !AppState.shared.hasDeepgramKey {
            WindowHelper.open(id: "deepgram-key")
            return
        }
        ProviderSettings.shared.activeProviderId = id
        buildMenu()
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

    // MARK: - Escape/Enter Key Interceptor

    private var recordingEventTap: CFMachPort?
    private var recordingRunLoopSource: CFRunLoopSource?

    private func startKeyListener() {
        guard recordingEventTap == nil else { return }
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        recordingEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, _, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return delegate.handleRecordingKeyEvent(event: event)
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

    func stopRecordingAndSubmit() {
        guard isRecording else { return }
        shouldPressEnterOnComplete = true
        stopRecording(reason: .enter)
    }

    // MARK: - Recording

    @objc func toggle() {
        if isUITestMode { uiTestToggleCount += 1 }
        if isRecording { stopRecording(reason: .hotkey) } else { startRecording() }
        refreshUITestHarness()
    }

    func startRecording() {
        guard !isRecording else { return }
        if isProcessingFinal {
            NSSound(named: "Basso")?.play()
            return
        }
        if isUITestMode && useMockRecordingInUITests {
            isRecording = true; isProcessingFinal = false; hasPlayedCompletionSound = false
            shouldPressEnterOnComplete = false; fullTranscript = ""
            refreshUITestHarness(); return
        }
        if !isUITestMode {
            if !AXIsProcessTrusted() {
                NSSound(named: "Basso")?.play()
                _ = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true)
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

        // Capture focused element
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
        refreshUITestHarness()
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
        controller.autoEndSilenceDuration = Settings.shared.autoEndSilenceDuration
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
            let started = await controller.start(provider: provider)
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
            isRecording = false; isProcessingFinal = false; refreshUITestHarness(); return
        }
        isRecording = false

        if liveStreamingController != nil {
            isProcessingFinal = true; NSSound(named: "Pop")?.play()
            Task { @MainActor in
                await liveStreamingController?.stop()
                liveStreamingController = nil; isProcessingFinal = false; stopKeyListener()
                targetElement = nil
                if !hasPlayedCompletionSound { hasPlayedCompletionSound = true; NSSound(named: "Purr")?.play() }
                if shouldPressEnterOnComplete { shouldPressEnterOnComplete = false; pressEnterKey() }
            }
        } else {
            isProcessingFinal = true; NSSound(named: "Pop")?.play()
            recorder?.stop(); recorder = nil
            Task { try? await Task.sleep(for: .seconds(1)); await MainActor.run { self.finishIfDone() } }
        }
        refreshUITestHarness()
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
        refreshUITestHarness(); NSSound(named: "Glass")?.play()
    }

    // MARK: - Finish

    private static let maxFinishRetries = 30

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

    private static let maxTextInsertionLength = 100_000
    private static let keystrokeDelayMicroseconds: UInt32 = 5000

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

    // MARK: - OAuth Login

    func handleLoginAction() {
        if OpenAICodexAuth.isLoggedIn {
            showAlert(title: "Already Logged In", message: "You are already logged in to ChatGPT.", style: .info)
        } else {
            startLoginFlow()
        }
    }

    func handleLogout() {
        OpenAICodexAuth.deleteCredentials()
        AppState.shared.refresh()
        showAlert(title: "Logged Out", message: "You have been logged out from ChatGPT.", style: .success)
    }

    func handleRemoveDeepgramKey() {
        ProviderSettings.shared.removeApiKey(for: "deepgram")
        if ProviderSettings.shared.activeProviderId == "deepgram" {
            ProviderSettings.shared.activeProviderId = "gpt"
        }
        AppState.shared.refresh()
    }

    func startLoginFlow() {
        let flow = OpenAICodexAuth.createAuthorizationFlow()
        let server = OAuthCallbackServer(expectedState: flow.state)
        oauthCallbackServer = server
        NSWorkspace.shared.open(flow.url)
        Task {
            let code = await server.waitForCallback(timeout: 120)
            await MainActor.run {
                self.oauthCallbackServer = nil
                if let code { self.exchangeCodeForTokens(code: code, flow: flow) }
                // TODO: manual code entry fallback
            }
        }
    }

    private func exchangeCodeForTokens(code: String, flow: OpenAICodexAuth.AuthorizationFlow) {
        Task {
            do {
                _ = try await OpenAICodexAuth.exchangeCodeForTokens(code: code, flow: flow)
                await MainActor.run {
                    AppState.shared.refresh()
                    showAlert(title: "Login Successful", message: "You are now logged in to ChatGPT.", style: .success)
                }
            } catch {
                await MainActor.run {
                    showAlert(title: "Error", message: "Login failed: \(error.localizedDescription)", style: .error)
                }
            }
        }
    }

    // MARK: - Accessibility Permission Delegate

    func showAccessibilityPermissionAlert() async -> PermissionAlertResponse {
        // Use SwiftUI-style approach: set state and present via alert window.
        // Since this happens at startup before full SwiftUI readiness, we use
        // a simple continuation with MainActor-isolated NSAlert.
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "SpeakFlow needs Accessibility permission to type transcribed text into other apps.\n\nClick 'Open System Settings' to grant permission."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .openSettings : .remindLater
    }

    func showAccessibilityGrantedAlert() {
        showAlert(title: "Accessibility Permission Granted",
                  message: "You can start using dictation with \(HotkeySettings.shared.currentHotkey.displayName).",
                  style: .success)
    }

    // MARK: - Microphone Permission

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionTask?.cancel(); micPermissionTask = nil
            AppState.shared.refresh()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in AppState.shared.refresh() }
            }
            startMicrophonePermissionPolling()
        case .denied, .restricted:
            startMicrophonePermissionPolling()
        @unknown default: break
        }
    }

    private func startMicrophonePermissionPolling() {
        micPermissionTask?.cancel()
        micPermissionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    self?.micPermissionTask = nil
                    AppState.shared.refresh()
                    return
                }
            }
        }
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyListener?.stop(); hotkeyListener = nil
        stopKeyListener()
        if isRecording || isProcessingFinal { recorder?.cancel(); recorder = nil; isRecording = false; isProcessingFinal = false }
        Transcription.shared.cancelAll(); Transcription.shared.queueBridge.stopListening()
        textInsertionTask?.cancel(); textInsertionTask = nil
        oauthCallbackServer?.stop(); oauthCallbackServer = nil
        micPermissionTask?.cancel(); micPermissionTask = nil
        permissionManager?.stopPolling()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
