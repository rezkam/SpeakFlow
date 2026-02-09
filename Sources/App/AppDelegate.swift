import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import OSLog
import os
import SpeakFlowCore

/// Main application delegate handling UI and lifecycle
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AccessibilityPermissionDelegate {
    var statusItem: NSStatusItem!
    var hotkeyListener: HotkeyListener?
    var recorder: StreamingRecorder?
    var liveStreamingController: LiveStreamingController?
    var isRecording = false
    var isProcessingFinal = false  // Track if we're waiting for final transcriptions
    var hasPlayedCompletionSound = false  // Guard against playing completion sound twice
    var fullTranscript = ""
    var permissionManager: AccessibilityPermissionManager!
    var targetElement: AXUIElement?  // Store focused element when recording starts
    private var textInsertionTask: Task<Void, Never>?  // Track ongoing text insertion
    private var queuedInsertionCount = 0  // P3 Security: Track queue depth to enforce limit
    private var keyMonitor: Any?  // Monitor for Escape/Enter keys during recording
    private var shouldPressEnterOnComplete = false  // Press Enter after transcription completes
    /// Thread-safe flag checked by the nonisolated CGEvent tap callback.
    /// Set to true when key listener starts, false when it stops.
    /// Prevents consuming Enter/Escape when no recording phase is active
    /// (e.g. after recorder start failure where the tap hasn't been removed yet).
    private let keyListenerActive = OSAllocatedUnfairLock(initialState: false)
    private var uiTestHarness: UITestHarnessController?
    private var uiTestToggleCount = 0
    private let isUITestMode = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MODE"] == "1"
    private let useMockRecordingInUITests = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MOCK_RECORDING"] != "0"
    private let resetUITestState = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_RESET_STATE"] == "1"
    private let uiTestHotkeyCycle: [HotkeyType] = [.controlOptionD, .controlOptionSpace, .commandShiftD]

    // Menu bar icon
    private lazy var defaultIcon: NSImage? = loadMenuBarIcon()

    // Microphone permission polling task
    private var micPermissionTask: Task<Void, Never>?

    // OAuth callback server — retained so it can be stopped on app termination
    private var oauthCallbackServer: OAuthCallbackServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up permission manager
        permissionManager = AccessibilityPermissionManager()
        permissionManager.delegate = self

        let trusted: Bool
        if isUITestMode {
            trusted = true
            Logger.permissions.info("UI test mode enabled; skipping startup permission prompts")
        } else {
            // Check accessibility permission - ALWAYS show alert on app start if not granted
            trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true, isAppStart: true)
            Logger.permissions.debug("AXIsProcessTrusted: \(trusted)")

            if !trusted {
                Logger.permissions.warning("No Accessibility permission - showing permission request")
            } else {
                Logger.permissions.info("Accessibility permission already granted")
            }
        }

        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        Logger.app.info("SpeakFlow ready - \(hotkeyName)")
        let settings = Settings.shared
        Logger.app.debug("Config: min=\(settings.minChunkDuration)s, max=\(settings.maxChunkDuration)s, rate=\(Config.minTimeBetweenRequests)s")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        buildMenu(trusted: trusted)
        setupHotkey()

        setupTranscriptionCallbacks()

        if !isUITestMode {
            // Check and request microphone permission on startup
            checkMicrophonePermission()

            // Pre-load the Silero VAD model in the background so the first
            // recording session starts instantly instead of waiting ~1-2s for
            // CoreML model compilation / HuggingFace download.
            if VADProcessor.isAvailable && Settings.shared.vadEnabled {
                Task {
                    await VADModelCache.shared.warmUp(threshold: Settings.shared.vadThreshold)
                }
            }
        }

        NSApp.setActivationPolicy(isUITestMode ? .regular : .accessory)
        if isUITestMode {
            setupUITestHarness()
        }

        // Check permission when app becomes active
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func setupTranscriptionCallbacks() {
        Transcription.shared.queueBridge.onTextReady = { [weak self] text in
            guard let self = self else { return }
            if !self.fullTranscript.isEmpty { self.fullTranscript += " " }
            self.fullTranscript += text
            // Insert text during recording AND while processing final chunks
            if self.isRecording || self.isProcessingFinal {
                self.insertText(text + " ")
            }
        }

        Transcription.shared.queueBridge.onAllComplete = { [weak self] in
            self?.finishIfDone()
        }
    }

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
        harness.onStartClicked = { [weak self] in
            self?.startRecording()
        }
        harness.onStopClicked = { [weak self] in
            self?.stopRecording(reason: .ui)
        }
        harness.onHotkeyTriggered = { [weak self] pressedHotkey in
            self?.handleUITestHotkey(pressedHotkey)
        }
        harness.onNextHotkeyClicked = { [weak self] in
            self?.cycleUITestHotkey()
        }
        harness.onSeedStatsClicked = { [weak self] in
            self?.seedUITestStatistics()
        }
        harness.onResetStatsClicked = { [weak self] in
            self?.resetUITestStatistics()
        }

        uiTestHarness = harness
        refreshUITestHarness()
        harness.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleUITestHotkey(_ pressedHotkey: HotkeyType?) {
        if let pressedHotkey, pressedHotkey != HotkeySettings.shared.currentHotkey {
            return
        }
        toggle()
    }

    private func cycleUITestHotkey() {
        guard isUITestMode else { return }

        let current = HotkeySettings.shared.currentHotkey
        guard let currentIndex = uiTestHotkeyCycle.firstIndex(of: current) else {
            HotkeySettings.shared.currentHotkey = uiTestHotkeyCycle[0]
            refreshUITestHarness()
            return
        }

        let nextIndex = (currentIndex + 1) % uiTestHotkeyCycle.count
        HotkeySettings.shared.currentHotkey = uiTestHotkeyCycle[nextIndex]
        refreshUITestHarness()
    }

    private func seedUITestStatistics() {
        guard isUITestMode else { return }
        Statistics.shared.recordApiCall()
        Statistics.shared.recordTranscription(text: "ui harness seeded stats", audioDurationSeconds: 1.2)
        refreshUITestHarness()
    }

    private func resetUITestStatistics() {
        guard isUITestMode else { return }
        Statistics.shared.reset()
        refreshUITestHarness()
    }

    private func refreshUITestHarness() {
        guard isUITestMode else { return }
        uiTestHarness?.updateState(
            isRecording: isRecording,
            toggleCount: uiTestToggleCount,
            mode: useMockRecordingInUITests ? "mock" : "live",
            hotkeyDisplay: HotkeySettings.shared.currentHotkey.displayName,
            statsApiCalls: Statistics.shared.apiCallCount,
            statsWords: Statistics.shared.wordCount
        )
    }

    @objc func applicationDidBecomeActive(_ notification: Notification) {
        // Check if we're the activated app
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return
        }

        // Re-check accessibility permission (without showing alert)
        let trusted = AXIsProcessTrusted()
        updateStatusIcon()
        updateMenu(trusted: trusted)
    }

    // MARK: - Menu

    private func buildMenu(trusted: Bool) {
        let menu = NSMenu()

        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        let dictationLabel: String
        if isRecording || isProcessingFinal {
            dictationLabel = String(localized: "Stop Dictation")
        } else {
            dictationLabel = String(localized: "Start Dictation")
        }
        let startTitle = "\(dictationLabel) (\(hotkeyName))"
        let startItem = NSMenuItem(title: startTitle, action: #selector(toggle), keyEquivalent: "")
        startItem.setAccessibilityLabel(String(localized: "Start or stop dictation"))
        menu.addItem(startItem)
        menu.addItem(.separator())

        // Permissions section
        let accessibilityItem = NSMenuItem(
            title: String(localized: "Accessibility"),
            action: #selector(checkAccessibility),
            keyEquivalent: ""
        )
        accessibilityItem.state = trusted ? .on : .off
        if !trusted {
            accessibilityItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
        accessibilityItem.setAccessibilityLabel(String(localized: "Accessibility permission status and action"))
        menu.addItem(accessibilityItem)

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micItem = NSMenuItem(
            title: String(localized: "Microphone"),
            action: #selector(checkMicrophoneAction),
            keyEquivalent: ""
        )
        micItem.state = micStatus == .authorized ? .on : .off
        if micStatus != .authorized {
            micItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
        micItem.setAccessibilityLabel(String(localized: "Microphone permission status and action"))
        menu.addItem(micItem)

        menu.addItem(.separator())

        // Accounts section
        let isLoggedIn = OpenAICodexAuth.isLoggedIn
        let hasDeepgramKey = ProviderSettings.shared.hasApiKey(for: "deepgram")

        let accountsSubmenu = NSMenu()

        let chatgptItem = NSMenuItem(
            title: isLoggedIn
                ? String(localized: "ChatGPT — Logged In")
                : String(localized: "ChatGPT — Login..."),
            action: #selector(handleLoginAction),
            keyEquivalent: ""
        )
        chatgptItem.state = isLoggedIn ? .on : .off
        chatgptItem.setAccessibilityLabel(String(localized: "ChatGPT login status and action"))
        accountsSubmenu.addItem(chatgptItem)

        if isLoggedIn {
            let logoutItem = NSMenuItem(title: String(localized: "Log Out of ChatGPT"), action: #selector(handleLogout), keyEquivalent: "")
            logoutItem.indentationLevel = 1
            logoutItem.setAccessibilityLabel(String(localized: "Log out of ChatGPT"))
            accountsSubmenu.addItem(logoutItem)
        }

        accountsSubmenu.addItem(.separator())

        let deepgramItem = NSMenuItem(
            title: hasDeepgramKey
                ? String(localized: "Deepgram — API Key Set")
                : String(localized: "Deepgram — Set API Key..."),
            action: #selector(handleDeepgramApiKey),
            keyEquivalent: ""
        )
        deepgramItem.state = hasDeepgramKey ? .on : .off
        deepgramItem.setAccessibilityLabel(String(localized: "Deepgram API key status and action"))
        accountsSubmenu.addItem(deepgramItem)

        if hasDeepgramKey {
            let removeKeyItem = NSMenuItem(title: String(localized: "Remove API Key"), action: #selector(handleRemoveDeepgramKey), keyEquivalent: "")
            removeKeyItem.indentationLevel = 1
            removeKeyItem.setAccessibilityLabel(String(localized: "Remove Deepgram API key"))
            accountsSubmenu.addItem(removeKeyItem)
        }

        let accountsMenuItem = NSMenuItem(title: String(localized: "Accounts"), action: nil, keyEquivalent: "")
        accountsMenuItem.setAccessibilityLabel(String(localized: "Manage service accounts"))
        accountsMenuItem.submenu = accountsSubmenu
        menu.addItem(accountsMenuItem)

        // Provider selection submenu
        let providerSubmenu = NSMenu()
        let activeProvider = ProviderSettings.shared.activeProviderId

        let gptItem = NSMenuItem(title: "ChatGPT (GPT-4o)", action: #selector(selectProvider(_:)), keyEquivalent: "")
        gptItem.representedObject = "gpt" as NSString
        gptItem.state = activeProvider == "gpt" ? .on : .off
        gptItem.isEnabled = isLoggedIn
        providerSubmenu.addItem(gptItem)

        let deepgramProviderItem = NSMenuItem(title: "Deepgram Nova-3", action: #selector(selectProvider(_:)), keyEquivalent: "")
        deepgramProviderItem.representedObject = "deepgram" as NSString
        deepgramProviderItem.state = activeProvider == "deepgram" ? .on : .off
        deepgramProviderItem.isEnabled = hasDeepgramKey
        providerSubmenu.addItem(deepgramProviderItem)

        let providerMenuItem = NSMenuItem(title: String(localized: "Transcription Provider"), action: nil, keyEquivalent: "")
        providerMenuItem.setAccessibilityLabel(String(localized: "Choose the transcription provider"))
        providerMenuItem.submenu = providerSubmenu
        menu.addItem(providerMenuItem)

        menu.addItem(.separator())

        // Hotkey submenu
        let hotkeySubmenu = NSMenu()
        for type in HotkeyType.allCases {
            let item = NSMenuItem(title: type.displayName, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.representedObject = type
            item.state = (type == HotkeySettings.shared.currentHotkey) ? .on : .off
            let hotkeyOptionLabel = String(localized: "Activation hotkey option")
            item.setAccessibilityLabel("\(hotkeyOptionLabel): \(type.displayName)")
            hotkeySubmenu.addItem(item)
        }

        let hotkeyMenuItem = NSMenuItem(title: String(localized: "Activation Hotkey"), action: nil, keyEquivalent: "")
        hotkeyMenuItem.setAccessibilityLabel(String(localized: "Choose the activation hotkey"))
        hotkeyMenuItem.submenu = hotkeySubmenu
        menu.addItem(hotkeyMenuItem)

        // Chunk duration submenu
        let chunkSubmenu = NSMenu()
        for duration in ChunkDuration.allCases {
            let item = NSMenuItem(title: duration.displayName, action: #selector(changeChunkDuration(_:)), keyEquivalent: "")
            item.representedObject = duration
            item.state = (duration == Settings.shared.chunkDuration) ? .on : .off
            let chunkOptionLabel = String(localized: "Chunk duration option")
            item.setAccessibilityLabel("\(chunkOptionLabel): \(duration.displayName)")
            chunkSubmenu.addItem(item)
        }
        let chunkMenuItem = NSMenuItem(title: String(localized: "Chunk Duration"), action: nil, keyEquivalent: "")
        chunkMenuItem.setAccessibilityLabel(String(localized: "Choose dictation chunk duration"))
        chunkMenuItem.submenu = chunkSubmenu
        menu.addItem(chunkMenuItem)

        // Skip silent chunks toggle
        let skipSilentItem = NSMenuItem(
            title: String(localized: "Skip Silent Chunks"),
            action: #selector(toggleSkipSilentChunks(_:)),
            keyEquivalent: ""
        )
        skipSilentItem.state = Settings.shared.skipSilentChunks ? .on : .off
        skipSilentItem.setAccessibilityLabel(String(localized: "Toggle skipping low-speech chunks"))
        menu.addItem(skipSilentItem)
        menu.addItem(.separator())

        // Statistics
        let statsItem = NSMenuItem(title: String(localized: "View Statistics..."), action: #selector(showStatistics), keyEquivalent: "")
        statsItem.setAccessibilityLabel(String(localized: "View transcription statistics"))
        menu.addItem(statsItem)
        menu.addItem(.separator())

        // Launch at Login toggle
        let launchAtLoginItem = NSMenuItem(
            title: String(localized: "Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        launchAtLoginItem.setAccessibilityLabel(String(localized: "Toggle launch at login"))
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.setAccessibilityLabel(String(localized: "Quit SpeakFlow"))
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
                Logger.app.info("Disabled launch at login")
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
                Logger.app.info("Enabled launch at login")
            }
        } catch {
            Logger.app.error("Failed to toggle launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let newType = sender.representedObject as? HotkeyType else { return }

        HotkeySettings.shared.currentHotkey = newType
        setupHotkey()

        // Rebuild menu to update checkmarks and hotkey display
        let trusted = AXIsProcessTrusted()
        buildMenu(trusted: trusted)
        refreshUITestHarness()
    }

    @objc private func changeChunkDuration(_ sender: NSMenuItem) {
        guard let newDuration = sender.representedObject as? ChunkDuration else { return }

        Settings.shared.chunkDuration = newDuration
        Logger.app.info("Chunk duration changed to \(newDuration.displayName)")

        // Rebuild menu to update checkmarks
        let trusted = AXIsProcessTrusted()
        buildMenu(trusted: trusted)
    }

    @objc private func toggleSkipSilentChunks(_ sender: NSMenuItem) {
        Settings.shared.skipSilentChunks.toggle()
        sender.state = Settings.shared.skipSilentChunks ? .on : .off
        Logger.app.info("Skip silent chunks: \(Settings.shared.skipSilentChunks)")
    }

    @objc private func showStatistics() {
        // Statistics needs a Reset option — use a custom SwiftUI view
        DialogPresenter.showStatistics(
            summary: Statistics.shared.summary,
            onReset: {
                Statistics.shared.reset()
            }
        )
    }

    @objc private func handleLoginAction() {
        if OpenAICodexAuth.isLoggedIn {
            DialogPresenter.showAlert(
                title: "Already Logged In",
                message: "You are already logged in to ChatGPT.",
                style: .info
            )
        } else {
            startLoginFlow()
        }
    }

    @objc private func handleLogout() {
        DialogPresenter.showConfirmation(
            title: "Logout from ChatGPT?",
            message: "This will remove your saved login credentials.",
            confirmTitle: "Logout",
            isDestructive: true
        ) { [weak self] confirmed in
            guard confirmed else { return }
            OpenAICodexAuth.deleteCredentials()
            let trusted = AXIsProcessTrusted()
            self?.buildMenu(trusted: trusted)
            DialogPresenter.showAlert(
                title: "Logged Out",
                message: "You have been logged out from ChatGPT.",
                style: .success
            )
        }
    }

    @objc private func handleDeepgramApiKey() {
        let hasKey = ProviderSettings.shared.hasApiKey(for: "deepgram")
        DialogPresenter.showDeepgramApiKey(isUpdate: hasKey) { [weak self] key in
            guard let key else { return }
            ProviderSettings.shared.setApiKey(key, for: "deepgram")
            let trusted = AXIsProcessTrusted()
            self?.buildMenu(trusted: trusted)
        }
    }

    @objc private func handleRemoveDeepgramKey() {
        DialogPresenter.showConfirmation(
            title: "Remove Deepgram API Key?",
            message: "This will remove your saved Deepgram API key.",
            confirmTitle: "Remove",
            isDestructive: true
        ) { [weak self] confirmed in
            guard confirmed else { return }
            ProviderSettings.shared.removeApiKey(for: "deepgram")
            if ProviderSettings.shared.activeProviderId == "deepgram" {
                ProviderSettings.shared.activeProviderId = "gpt"
            }
            let trusted = AXIsProcessTrusted()
            self?.buildMenu(trusted: trusted)
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let providerId = sender.representedObject as? NSString else { return }
        let id = providerId as String

        if id == "deepgram" && !ProviderSettings.shared.hasApiKey(for: "deepgram") {
            handleDeepgramApiKey()
            return
        }

        ProviderSettings.shared.activeProviderId = id
        Logger.app.info("Transcription provider changed to \(id)")
        let trusted = AXIsProcessTrusted()
        buildMenu(trusted: trusted)
    }

    private func startLoginFlow() {
        // Create authorization flow
        let flow = OpenAICodexAuth.createAuthorizationFlow()

        // Start the callback server (retained for cleanup on app termination)
        let server = OAuthCallbackServer(expectedState: flow.state)
        oauthCallbackServer = server

        // Show instructions and open browser
        DialogPresenter.showConfirmation(
            title: "Login to ChatGPT",
            message: "A browser window will open for you to log in.\n\nAfter logging in, you'll be redirected back automatically.\n\nIf the redirect doesn't work, copy the URL and paste it when prompted.",
            confirmTitle: "Open Browser"
        ) { [weak self] confirmed in
            guard confirmed, let self else { return }

            // Open browser
            NSWorkspace.shared.open(flow.url)
        
        // Wait for callback in background
        Task {
            let code = await server.waitForCallback(timeout: 120)
            
            await MainActor.run {
                self.oauthCallbackServer = nil  // Server done, release
                if let code = code {
                    // Got code from callback server
                    self.exchangeCodeForTokens(code: code, flow: flow)
                } else {
                    // Callback timed out or failed - ask for manual input
                    self.promptForManualCode(flow: flow)
                }
            }
        }
        } // showConfirmation
    }

    private func promptForManualCode(flow: OpenAICodexAuth.AuthorizationFlow) {
        DialogPresenter.showTextInput(
            title: "Paste Authorization Code",
            message: "If the browser didn't redirect automatically, paste the URL or authorization code here:",
            placeholder: "Paste URL or code here",
            submitTitle: "Submit"
        ) { [weak self] inputValue in
            guard let self, let inputValue else { return }

            // Parse the input - could be full URL or just the code
            let code: String
            if let url = URL(string: inputValue),
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value {
                // P2 Security: Validate state parameter if present to prevent CSRF attacks
                if let stateParam = components.queryItems?.first(where: { $0.name == "state" })?.value {
                    guard stateParam == flow.state else {
                        self.showError("Invalid state parameter. Please try logging in again.")
                        return
                    }
                }
                code = codeParam
            } else {
                code = inputValue
            }

            self.exchangeCodeForTokens(code: code, flow: flow)
        }
    }

    private func exchangeCodeForTokens(code: String, flow: OpenAICodexAuth.AuthorizationFlow) {
        Task {
            do {
                _ = try await OpenAICodexAuth.exchangeCodeForTokens(code: code, flow: flow)
                
                await MainActor.run {
                    // Rebuild menu to update login status
                    let trusted = AXIsProcessTrusted()
                    self.buildMenu(trusted: trusted)
                    
                    DialogPresenter.showAlert(
                        title: "Login Successful",
                        message: "You are now logged in to ChatGPT. You can start using voice dictation.",
                        style: .success
                    )
                }
            } catch {
                await MainActor.run {
                    self.showError("Login failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showError(_ message: String) {
        DialogPresenter.showAlert(title: "Error", message: message, style: .error)
    }

    func showAccessibilityPermissionAlert() async -> PermissionAlertResponse {
        await withCheckedContinuation { continuation in
            DialogPresenter.showAccessibilityPermission { response in
                continuation.resume(returning: response)
            }
        }
    }

    func showAccessibilityGrantedAlert() {
        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        DialogPresenter.showAlert(
            title: "Accessibility Permission Granted",
            message: "The app now has permission to insert dictated text.\n\nYou can start using dictation with \(hotkeyName).",
            style: .success
        )
    }

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

    // MARK: - Status Icon

    func updateStatusIcon() {
        statusItem.button?.title = ""
        statusItem.button?.image = defaultIcon
        // Rebuild menu so the Start/Stop Dictation label stays in sync
        buildMenu(trusted: AXIsProcessTrusted())
    }

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            Logger.app.warning("Could not load AppIcon.png from bundle")
            return nil
        }

        // Menu bar icons should be 18x18 to match system icons
        let menuBarSize = NSSize(width: 18, height: 18)
        let resizedImage = NSImage(size: menuBarSize)
        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: menuBarSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resizedImage.unlockFocus()

        // Template mode makes icon white in dark mode, black in light mode
        resizedImage.isTemplate = true
        return resizedImage
    }

    private func updateMenu(trusted: Bool) {
        // Rebuild entire menu to ensure proper state
        buildMenu(trusted: trusted)
    }

    // MARK: - Permission Actions

    @objc func checkAccessibility() {
        let trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true)
        if trusted {
            DialogPresenter.showAlert(
                title: "Accessibility Permission Active",
                message: "The app has the necessary permissions to insert dictated text.",
                style: .success
            )
        }
    }

    @objc func checkMicrophoneAction() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            DialogPresenter.showAlert(
                title: "Microphone Permission Active",
                message: "The app has access to your microphone for voice recording.",
                style: .success
            )
        } else {
            checkMicrophonePermission()
        }
    }

    // MARK: - Escape/Enter Key Interceptor (only active during recording)
    //
    // Uses a CGEvent tap (not NSEvent.addGlobalMonitorForEvents) so that
    // Enter and Escape are CONSUMED during recording — they never reach the
    // target app. Enter triggers stop-and-submit; Escape cancels. All other
    // keys pass through unmodified.

    private var recordingEventTap: CFMachPort?
    private var recordingRunLoopSource: CFRunLoopSource?

    private func startKeyListener() {
        guard recordingEventTap == nil else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        recordingEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // .defaultTap can suppress events
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return delegate.handleRecordingKeyEvent(event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = recordingEventTap else {
            Logger.audio.error("Could not create recording key event tap (need Accessibility permission). Falling back to passive monitor.")
            // Fallback: passive monitor (Enter won't be consumed but at least the feature works)
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 53: Task { @MainActor [weak self] in self?.cancelRecording() }
                case 36: Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.isRecording {
                        self.stopRecordingAndSubmit()
                    } else if self.isProcessingFinal {
                        self.shouldPressEnterOnComplete = true
                        Logger.audio.info("Enter pressed during processing — will submit after completion")
                    }
                }
                default: break
                }
            }
            Logger.audio.debug("Key listener started (PASSIVE fallback — Enter will pass through)")
            return
        }

        recordingRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = recordingRunLoopSource else {
            recordingEventTap = nil
            return
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyListenerActive.withLock { $0 = true }
        Logger.audio.debug("Key listener started (CGEvent tap — Enter/Escape will be intercepted)")
    }

    /// Handle key events during recording / processing-final phase.
    /// Returns nil to consume, or the event to pass through.
    private nonisolated func handleRecordingKeyEvent(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Thread-safe check: only consume keys when a recording phase is actually active.
        // Without this guard, a stale tap (e.g. from a failed recorder start that didn't
        // clean up) would swallow Enter/Escape system-wide.
        guard keyListenerActive.withLock({ $0 }) else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch keyCode {
        case 53:  // Escape — cancel recording (or processing), consume the event
            Task { @MainActor [weak self] in
                self?.cancelRecording()
            }
            return nil  // Consumed: Escape does not reach the target app

        case 36:  // Enter/Return — stop and submit, consume the event
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isRecording {
                    // Still recording — stop and queue Enter for after completion
                    self.stopRecordingAndSubmit()
                } else if self.isProcessingFinal {
                    // Already stopped, waiting for final chunks — just flag Enter
                    self.shouldPressEnterOnComplete = true
                    Logger.audio.info("Enter pressed during processing — will submit after completion")
                }
            }
            return nil  // Consumed: Enter does not reach the target app

        default:
            return Unmanaged.passRetained(event)  // All other keys pass through
        }
    }

    private func stopKeyListener() {
        keyListenerActive.withLock { $0 = false }

        // Stop CGEvent tap
        if let tap = recordingEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = recordingRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        recordingEventTap = nil
        recordingRunLoopSource = nil

        // Stop fallback NSEvent monitor (if CGEvent tap failed)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        Logger.audio.debug("Key listener stopped")
    }
    
    /// Stop recording and press Enter after transcription completes (for chat submit)
    func stopRecordingAndSubmit() {
        guard isRecording else { return }
        Logger.audio.info("Stopping recording with Enter submit")
        shouldPressEnterOnComplete = true
        stopRecording(reason: .enter)
    }

    // MARK: - Recording

    @objc func toggle() {
        if isUITestMode {
            uiTestToggleCount += 1
        }

        if isRecording { stopRecording(reason: .hotkey) } else { startRecording() }
        refreshUITestHarness()
    }

    func startRecording() {
        guard !isRecording else { return }

        // Block restart while previous session is still finalizing transcriptions
        if isProcessingFinal {
            Logger.audio.warning("Cannot start recording — previous session still finalizing")
            NSSound(named: "Basso")?.play()
            return
        }

        if isUITestMode && useMockRecordingInUITests {
            isRecording = true
            isProcessingFinal = false
            hasPlayedCompletionSound = false
            shouldPressEnterOnComplete = false
            fullTranscript = ""
            updateStatusIcon()
            refreshUITestHarness()
            return
        }

        if !isUITestMode {
            // Check accessibility permission before starting
            if !AXIsProcessTrusted() {
                Logger.permissions.warning("Cannot start recording - accessibility permission required")
                NSSound(named: "Basso")?.play()
                _ = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true)
                return
            }

            // Check microphone permission before starting
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break // Permission granted, continue
            case .notDetermined:
                Logger.permissions.info("Microphone permission not yet requested")
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    Task { @MainActor [weak self] in
                        if granted {
                            self?.startRecording() // Retry after permission granted
                        } else {
                            self?.showMicrophonePermissionAlert()
                        }
                    }
                }
                return
            case .denied, .restricted:
                Logger.permissions.warning("Microphone permission denied")
                NSSound(named: "Basso")?.play()
                showMicrophonePermissionAlert()
                return
            @unknown default:
                Logger.permissions.warning("Unknown microphone permission status")
                return
            }
        }

        isRecording = true
        isProcessingFinal = false  // Reset in case of previous session
        hasPlayedCompletionSound = false  // Reset completion sound guard
        shouldPressEnterOnComplete = false  // Reset submit flag
        fullTranscript = ""
        // NOTE: queueBridge.reset() is awaited below in the same Task as recorder.start()
        // to guarantee reset completes before any new transcription activity begins.

        // Capture the focused element NOW so we can insert text there later
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           let element = focusedElement {
            // P1 Security: Validate type before using
            // AXUIElementCopyAttributeValue returns CFTypeRef, verify it's an AXUIElement
            if CFGetTypeID(element) == AXUIElementGetTypeID() {
                // Safe to use - we verified the type above
                let axElement = element as! AXUIElement  // swiftlint:disable:this force_cast
                targetElement = axElement

                // Log element info for debugging
                var role: CFTypeRef?
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &title)
                Logger.audio.debug("Captured target element: role=\(String(describing: role)), title=\(String(describing: title))")
            } else {
                targetElement = nil
                Logger.audio.warning("Focused element is not an AXUIElement (unexpected type)")
            }
        } else {
            targetElement = nil
            Logger.audio.warning("Could not capture focused element")
        }

        updateStatusIcon()
        NSSound(named: "Blow")?.play()

        if ProviderSettings.shared.activeProviderId == "deepgram" {
            startDeepgramRecording()
        } else {
            startGPTRecording()
        }
        refreshUITestHarness()
    }

    /// Start recording with the GPT-4o (ChatGPT) batch transcription pipeline.
    /// Local VAD + chunking → send WAV chunks to ChatGPT API → type text.
    private func startGPTRecording() {
        recorder = StreamingRecorder()
        recorder?.onChunkReady = { chunk in
            Task { @MainActor in
                let ticket = await Transcription.shared.queueBridge.nextSequence()
                Transcription.shared.transcribe(ticket: ticket, chunk: chunk)
            }
        }
        recorder?.onAutoEnd = { [weak self] in
            Task { @MainActor in
                Logger.audio.warning("Auto-end triggered by VAD silence detection (autoEndSilenceDuration=\(Settings.shared.autoEndSilenceDuration)s, vadMinSilenceAfterSpeech=\(Config.vadMinSilenceAfterSpeech)s)")
                self?.stopRecording(reason: .autoEnd)
            }
        }
        Task { @MainActor in
            await Transcription.shared.queueBridge.reset()
            let started = await recorder?.start() ?? false
            if started {
                self.startKeyListener()
            } else {
                Logger.audio.error("Recorder failed to start — rolling back app state")
                isRecording = false
                isProcessingFinal = false
                recorder = nil
                self.stopKeyListener()
                updateStatusIcon()
                NSSound(named: "Basso")?.play()
            }
        }
    }

    /// Start recording with the Deepgram streaming transcription pipeline.
    /// NO local VAD, NO chunking, NO silence detection.
    /// Raw mic audio → Deepgram WebSocket → live interim/final results → type text.
    private func startDeepgramRecording() {
        guard let apiKey = ProviderSettings.shared.apiKey(for: "deepgram") else {
            Logger.audio.error("Deepgram API key not set")
            isRecording = false
            NSSound(named: "Basso")?.play()
            updateStatusIcon()
            return
        }

        let provider = DeepgramProvider()
        ProviderSettings.shared.setApiKey(apiKey, for: "deepgram")

        let controller = LiveStreamingController()
        self.liveStreamingController = controller

        controller.onTextUpdate = { [weak self] textToType, replacingChars, isFinal, fullText in
            guard let self, self.isRecording else { return }
            if replacingChars > 0 {
                self.deleteChars(replacingChars)
            }
            if !textToType.isEmpty {
                self.insertText(isFinal ? textToType + " " : textToType)
            } else if isFinal && !fullText.isEmpty {
                // Text was identical to interim — just add trailing space
                self.insertText(" ")
            }
            if isFinal && !fullText.isEmpty {
                if !self.fullTranscript.isEmpty { self.fullTranscript += " " }
                self.fullTranscript += fullText
            }
        }

        // Auto-end after silence (server-side detection, no local VAD)
        controller.autoEndSilenceDuration = Settings.shared.autoEndSilenceDuration

        controller.onAutoEnd = { [weak self] in
            Logger.audio.warning("Deepgram: auto-end after \(Settings.shared.autoEndSilenceDuration)s silence")
            Task { @MainActor in
                self?.stopRecording(reason: .autoEnd)
            }
        }

        controller.onUtteranceEnd = {
            Logger.audio.info("Deepgram: utterance end detected")
        }

        controller.onSpeechStarted = {
            Logger.audio.info("Deepgram: speech started")
        }

        controller.onError = { [weak self] error in
            Logger.audio.error("Deepgram error: \(error.localizedDescription)")
            Task { @MainActor in
                self?.stopRecording(reason: .autoEnd)
            }
        }

        controller.onSessionClosed = { [weak self] in
            Logger.audio.warning("Deepgram session closed unexpectedly")
            Task { @MainActor in
                if self?.isRecording == true {
                    self?.stopRecording(reason: .autoEnd)
                }
            }
        }

        Task { @MainActor in
            let started = await controller.start(provider: provider)
            if started {
                self.startKeyListener()
                Logger.audio.info("🟢 Deepgram streaming started")
            } else {
                Logger.audio.error("Deepgram streaming failed to start")
                isRecording = false
                isProcessingFinal = false
                liveStreamingController = nil
                self.stopKeyListener()
                updateStatusIcon()
                NSSound(named: "Basso")?.play()
            }
        }
    }

    /// Why the recording stopped — logged for debugging P0 auto-end bug
    enum StopReason: String {
        case hotkey    = "HOTKEY_TOGGLE"
        case autoEnd   = "VAD_AUTO_END"
        case enter     = "ENTER_SUBMIT"
        case escape    = "ESCAPE_CANCEL"
        case ui        = "UI_BUTTON"
        case unknown   = "UNKNOWN"
    }

    func stopRecording(reason: StopReason = .unknown) {
        // NOTE: Key listener stays active through the processing-final phase
        // so Enter/Escape are still intercepted while waiting for final chunks.
        // It is stopped in finishIfDone() or cancelRecording().
        guard isRecording else { return }

        Logger.audio.error("🔴 STOP RECORDING reason=\(reason.rawValue) sessionDur=\(String(format: "%.1f", Date().timeIntervalSince(self.recorder?.sessionStartDate ?? Date())))s transcript=\"\(self.fullTranscript.prefix(80))\"")

        if isUITestMode && useMockRecordingInUITests {
            isRecording = false
            isProcessingFinal = false
            updateStatusIcon()
            refreshUITestHarness()
            return
        }

        isRecording = false

        if liveStreamingController != nil {
            // Deepgram streaming mode
            isProcessingFinal = true
            updateStatusIcon()
            NSSound(named: "Pop")?.play()
            Task { @MainActor in
                await liveStreamingController?.stop()
                liveStreamingController = nil
                isProcessingFinal = false
                stopKeyListener()
                targetElement = nil
                updateStatusIcon()
                if !hasPlayedCompletionSound {
                    hasPlayedCompletionSound = true
                    NSSound(named: "Purr")?.play()
                }
                if shouldPressEnterOnComplete {
                    shouldPressEnterOnComplete = false
                    pressEnterKey()
                }
                Logger.audio.info("Deepgram streaming finished. Transcript: \(self.fullTranscript.prefix(80))")
            }
        } else {
            // GPT batch mode
            isProcessingFinal = true
            updateStatusIcon()
            NSSound(named: "Pop")?.play()
            recorder?.stop()
            recorder = nil
            Task {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { self.finishIfDone() }
            }
        }
        refreshUITestHarness()
    }

    @MainActor
    func cancelRecording() {
        guard isRecording || isProcessingFinal else { return }
        Logger.audio.error("🔴 STOP RECORDING reason=ESCAPE_CANCEL")
        stopKeyListener()
        isRecording = false
        isProcessingFinal = false
        shouldPressEnterOnComplete = false
        fullTranscript = ""
        targetElement = nil
        textInsertionTask?.cancel()
        textInsertionTask = nil
        queuedInsertionCount = 0

        if liveStreamingController != nil {
            Task {
                await liveStreamingController?.cancel()
                await MainActor.run { self.liveStreamingController = nil }
            }
        } else {
            recorder?.cancel()
            recorder = nil
            Transcription.shared.cancelAll()
        }

        updateStatusIcon()
        refreshUITestHarness()
        Logger.audio.debug("Playing cancel sound (Glass)")
        NSSound(named: "Glass")?.play()
        Logger.audio.info("Recording cancelled")
    }

    /// Maximum retry attempts for finishIfDone to prevent infinite task chains
    private static let maxFinishRetries = 30  // 30 * 2s = 60s max wait

    func finishIfDone(attempt: Int = 0) {
        guard !isRecording else { return }

        // P1 Security: Prevent infinite task chain with retry limit
        guard attempt < Self.maxFinishRetries else {
            Logger.transcription.warning("Exceeded max retries (\(Self.maxFinishRetries)) waiting for transcriptions")
            // P1 Fix: Clean up queue state to prevent orphaned pending items
            Task {
                await Transcription.shared.queueBridge.checkCompletion()
            }
            stopKeyListener()
            isProcessingFinal = false
            targetElement = nil
            textInsertionTask = nil
            queuedInsertionCount = 0  // P3 Security: Reset queue count on timeout
            updateStatusIcon()
            return
        }

        Task {
            let pending = await Transcription.shared.queueBridge.getPendingCount()
            if pending > 0 {
                Logger.transcription.debug("Waiting for \(pending) pending transcriptions (attempt \(attempt + 1))")
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { self.finishIfDone(attempt: attempt + 1) }
                return
            }

            // Wait for all text insertion to complete before playing the completion sound
            await self.waitForTextInsertion()

            await MainActor.run {
                // All transcriptions complete — release key interceptor and stop processing mode
                self.stopKeyListener()
                self.isProcessingFinal = false
                self.targetElement = nil  // Clear stored element
                self.textInsertionTask = nil  // Clear completed task
                self.queuedInsertionCount = 0  // P3 Security: Reset queue count on completion
                self.updateStatusIcon()
                guard !self.fullTranscript.isEmpty else { return }
                
                // Guard against playing completion sound twice
                guard !self.hasPlayedCompletionSound else { return }
                self.hasPlayedCompletionSound = true

                Logger.transcription.info("Session complete: \(self.fullTranscript, privacy: .private)")
                Logger.audio.debug("Playing completion sound (Glass)")
                NSSound(named: "Glass")?.play()
                
                // Press Enter if user stopped with Enter key (for chat submit)
                if self.shouldPressEnterOnComplete {
                    self.shouldPressEnterOnComplete = false
                    self.pressEnterKey()
                }
            }
        }
    }
    
    /// Simulate pressing the Enter key (for chat submit after transcription)
    private func pressEnterKey() {
        // P1 Security: Verify focus hasn't changed before pressing Enter
        guard verifyInsertionTarget() else {
            Logger.app.warning("Enter key press aborted — target element no longer focused")
            return
        }

        Logger.audio.debug("Pressing Enter key for submit")
        
        let keyCode: CGKeyCode = 36  // Enter key
        
        // Key down
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }
        
        // Use async sleep to avoid blocking the main actor
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            // Key up
            if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Text Insertion

    /// Maximum text length to prevent DoS from malicious transcriptions
    /// At 5ms per character, 100k chars = ~8 minutes of typing
    /// Delete N characters by sending backspace keystrokes.
    /// Used by Deepgram streaming mode to replace interim text.
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
                if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                   let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                    keyDown.post(tap: .cghidEventTap)
                    keyUp.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000)
                }
            }
        }
    }

    private static let maxTextInsertionLength = 100_000

    /// Delay between keystrokes in microseconds (5ms = smooth typing without overwhelming the system)
    private static let keystrokeDelayMicroseconds: UInt32 = 5000

    func insertText(_ text: String) {
        // P2 Security: Filter out control characters that could cause issues with CGEvent
        // Allow: printable characters, spaces, tabs, and newlines
        let sanitized = text.filter { char in
            char.isLetter || char.isNumber || char.isPunctuation ||
            char.isSymbol || char.isWhitespace || char == "\n" || char == "\t"
        }

        // Validate text length to prevent DoS
        let textToInsert: String
        if sanitized.count > Self.maxTextInsertionLength {
            Logger.app.warning("Text too long to insert (\(sanitized.count) chars > \(Self.maxTextInsertionLength))")
            textToInsert = String(sanitized.prefix(Self.maxTextInsertionLength))
        } else {
            textToInsert = sanitized
        }

        guard !textToInsert.isEmpty else { return }

        // P3 Security: Enforce queue depth limit to prevent unbounded task chains
        guard queuedInsertionCount < Config.maxQueuedTextInsertions else {
            Logger.app.warning("Text insertion queue full (\(Config.maxQueuedTextInsertions) pending), dropping text")
            return
        }

        Logger.app.debug("Inserting text: \(textToInsert, privacy: .private)")

        // Chain text insertion tasks to ensure they complete in order
        queuedInsertionCount += 1
        let previousTask = textInsertionTask
        textInsertionTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.queuedInsertionCount -= 1
                }
            }
            // Wait for any previous insertion to complete
            await previousTask?.value
            await self?.typeTextAsync(textToInsert)
            Logger.app.debug("Text typed via CGEvent")
        }
    }

    /// Wait for all pending text insertions to complete
    func waitForTextInsertion() async {
        await textInsertionTask?.value
    }

    /// Check that the currently focused UI element matches our stored target.
    /// Returns true if we should proceed with typing, false if focus has changed.
    private func verifyInsertionTarget() -> Bool {
        guard let target = targetElement else {
            // No target captured — allow typing (best-effort)
            return true
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            Logger.app.warning("Could not read current focused element for target verification")
            return false
        }

        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            Logger.app.warning("Focused element is not an AXUIElement during target verification")
            return false
        }

        // Compare AXUIElements — CFEqual checks if they refer to the same element
        let currentElement = focused as! AXUIElement  // swiftlint:disable:this force_cast
        if CFEqual(target, currentElement) {
            return true
        }

        // Elements don't match — focus changed
        Logger.app.warning("Focus changed since recording started — dropping text insertion to prevent privacy leak")
        return false
    }

    private func typeTextAsync(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Logger.app.error("Could not create CGEventSource")
            return
        }

        // P1 Security: Verify insertion target before typing
        // Focus may have changed since recording started; typing into wrong app is a privacy leak
        let targetValid = await MainActor.run { self.verifyInsertionTarget() }
        guard targetValid else {
            Logger.app.warning("Text insertion aborted — target element no longer focused")
            return
        }

        // Wait for any modifier keys to be released before typing
        // This prevents Control key from double-tap hotkey interfering with text insertion
        await waitForModifiersReleased()

        for char in text {
            // P1 Security: Check for cancellation to stop typing when recording is cancelled
            // Without this, cancelled tasks continue typing for up to 50s (10k chars × 5ms)
            do {
                try Task.checkCancellation()
            } catch {
                Logger.app.debug("Text insertion cancelled")
                return
            }

            // If modifiers are held mid-typing, wait for release
            // This handles cases where user taps Control during text insertion
            await waitForModifiersReleased()

            var unichar = Array(String(char).utf16)

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                Logger.app.error("Could not create CGEvent for character")
                continue
            }

            keyDown.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            // Use Task.sleep instead of usleep for proper async behavior
            try? await Task.sleep(nanoseconds: UInt64(Self.keystrokeDelayMicroseconds) * 1000)
        }
    }

    /// Wait until no modifier keys (Control, Command, Option, Shift) are pressed
    private func waitForModifiersReleased() async {
        var attempts = 0
        let maxAttempts = 100  // 1 second max wait (100 * 10ms)

        while attempts < maxAttempts {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let hasModifiers = flags.contains(.maskControl) ||
                               flags.contains(.maskCommand) ||
                               flags.contains(.maskAlternate) ||
                               flags.contains(.maskShift)

            if !hasModifiers {
                return
            }

            attempts += 1
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        Logger.app.warning("Timed out waiting for modifier keys to be released")
    }

    // MARK: - Microphone Permission

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Logger.permissions.info("Microphone permission granted")
            micPermissionTask?.cancel()
            micPermissionTask = nil
            updateStatusIcon()
            updateMenu(trusted: AXIsProcessTrusted())
        case .notDetermined:
            Logger.permissions.info("Requesting microphone permission...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        Logger.permissions.info("Microphone permission granted")
                        self?.updateStatusIcon()
                        self?.updateMenu(trusted: AXIsProcessTrusted())
                    } else {
                        Logger.permissions.warning("Microphone permission denied by user")
                        self?.showMicrophonePermissionAlert()
                        self?.startMicrophonePermissionPolling()
                    }
                }
            }
            // Also start polling in case callback doesn't fire
            startMicrophonePermissionPolling()
        case .denied, .restricted:
            Logger.permissions.warning("Microphone permission denied - showing alert")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.showMicrophonePermissionAlert()
            }
            startMicrophonePermissionPolling()
        @unknown default:
            Logger.permissions.warning("Unknown microphone permission status")
        }
    }

    private func startMicrophonePermissionPolling() {
        micPermissionTask?.cancel()
        // Use a MainActor Task loop instead of Timer to avoid @Sendable closure
        // accessing @MainActor state, which violates Swift 6 strict concurrency.
        micPermissionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self = self else { return }

                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .authorized {
                    Logger.permissions.info("Microphone permission granted (detected via polling)")
                    self.micPermissionTask = nil
                    self.updateStatusIcon()
                    self.updateMenu(trusted: AXIsProcessTrusted())
                    return
                }
            }
        }
    }

    private func showMicrophonePermissionAlert() {
        DialogPresenter.showConfirmation(
            title: "Microphone Access Required",
            message: "This app needs microphone permission to record your voice.\n\nOpen System Settings → Privacy & Security → Microphone, find this app and enable the toggle.\n\nYou may need to restart the app after changing permissions.",
            confirmTitle: "Open System Settings"
        ) { confirmed in
            if confirmed,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - Graceful Termination

    func applicationWillTerminate(_ notification: Notification) {
        Logger.app.info("Application terminating — cleaning up")

        // Stop hotkey listener
        hotkeyListener?.stop()
        hotkeyListener = nil

        // Stop key monitor (Escape/Enter)
        stopKeyListener()

        // Stop/cancel any active recording
        if isRecording || isProcessingFinal {
            recorder?.cancel()
            recorder = nil
            isRecording = false
            isProcessingFinal = false
        }

        // Cancel all in-flight transcription tasks and stop the queue stream
        Transcription.shared.cancelAll()
        Transcription.shared.queueBridge.stopListening()

        // Cancel ongoing text insertion
        textInsertionTask?.cancel()
        textInsertionTask = nil

        // Stop OAuth callback server if a login flow is in progress
        oauthCallbackServer?.stop()
        oauthCallbackServer = nil

        // Stop microphone/accessibility permission polling
        micPermissionTask?.cancel()
        micPermissionTask = nil
        permissionManager?.stopPolling()

        // Remove workspace notification observer
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        Logger.app.info("Cleanup complete")
    }
}
