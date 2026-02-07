import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import OSLog
import SpeakFlowCore

/// Main application delegate handling UI and lifecycle
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AccessibilityPermissionDelegate {
    var statusItem: NSStatusItem!
    var hotkeyListener: HotkeyListener?
    var recorder: StreamingRecorder?
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
    private var uiTestHarness: UITestHarnessController?
    private var uiTestToggleCount = 0
    private let isUITestMode = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MODE"] == "1"
    private let useMockRecordingInUITests = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MOCK_RECORDING"] != "0"
    private let resetUITestState = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_RESET_STATE"] == "1"
    private let uiTestHotkeyCycle: [HotkeyType] = [.controlOptionD, .controlOptionSpace, .commandShiftD]

    // Menu bar icon
    private lazy var defaultIcon: NSImage? = loadMenuBarIcon()

    // Microphone permission polling timer
    private var micPermissionTimer: Timer?

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
        menu.addItem(NSMenuItem(title: "Start Dictation (\(hotkeyName))", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(.separator())

        // Add accessibility status menu item
        let accessibilityTitle = trusted ? "✅ Accessibility Enabled" : "⚠️ Enable Accessibility..."
        let accessibilityItem = NSMenuItem(
            title: accessibilityTitle,
            action: #selector(checkAccessibility),
            keyEquivalent: ""
        )
        menu.addItem(accessibilityItem)

        // Add microphone status menu item
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micTitle = micStatus == .authorized ? "✅ Microphone Enabled" : "⚠️ Enable Microphone..."
        let micItem = NSMenuItem(title: micTitle, action: #selector(checkMicrophoneAction), keyEquivalent: "")
        menu.addItem(micItem)
        
        // Add login status menu item
        let isLoggedIn = OpenAICodexAuth.isLoggedIn
        let loginTitle = isLoggedIn ? "✅ Logged in to ChatGPT" : "⚠️ Login to ChatGPT..."
        let loginItem = NSMenuItem(title: loginTitle, action: #selector(handleLoginAction), keyEquivalent: "")
        menu.addItem(loginItem)
        
        if isLoggedIn {
            let logoutItem = NSMenuItem(title: "Logout", action: #selector(handleLogout), keyEquivalent: "")
            menu.addItem(logoutItem)
        }
        menu.addItem(.separator())

        // Hotkey submenu
        let hotkeySubmenu = NSMenu()
        for type in HotkeyType.allCases {
            let item = NSMenuItem(title: type.displayName, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.representedObject = type
            item.state = (type == HotkeySettings.shared.currentHotkey) ? .on : .off
            hotkeySubmenu.addItem(item)
        }

        let hotkeyMenuItem = NSMenuItem(title: "Activation Hotkey", action: nil, keyEquivalent: "")
        hotkeyMenuItem.submenu = hotkeySubmenu
        menu.addItem(hotkeyMenuItem)

        // Chunk duration submenu
        let chunkSubmenu = NSMenu()
        for duration in ChunkDuration.allCases {
            let item = NSMenuItem(title: duration.displayName, action: #selector(changeChunkDuration(_:)), keyEquivalent: "")
            item.representedObject = duration
            item.state = (duration == Settings.shared.chunkDuration) ? .on : .off
            chunkSubmenu.addItem(item)
        }
        let chunkMenuItem = NSMenuItem(title: "Chunk Duration", action: nil, keyEquivalent: "")
        chunkMenuItem.submenu = chunkSubmenu
        menu.addItem(chunkMenuItem)

        // Skip silent chunks toggle
        let skipSilentItem = NSMenuItem(
            title: "Skip Silent Chunks",
            action: #selector(toggleSkipSilentChunks(_:)),
            keyEquivalent: ""
        )
        skipSilentItem.state = Settings.shared.skipSilentChunks ? .on : .off
        menu.addItem(skipSilentItem)
        menu.addItem(.separator())

        // Statistics
        menu.addItem(NSMenuItem(title: "View Statistics...", action: #selector(showStatistics), keyEquivalent: ""))
        menu.addItem(.separator())

        // Launch at Login toggle
        let launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
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
        let alert = NSAlert()
        alert.messageText = "Transcription Statistics"
        alert.informativeText = Statistics.shared.summary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reset...")

        if alert.runModal() == .alertSecondButtonReturn {
            // User clicked Reset - confirm
            let confirmAlert = NSAlert()
            confirmAlert.messageText = "Reset Statistics?"
            confirmAlert.informativeText = "This will permanently reset all transcription statistics to zero."
            confirmAlert.alertStyle = .warning
            confirmAlert.addButton(withTitle: "Reset")
            confirmAlert.addButton(withTitle: "Cancel")

            if confirmAlert.runModal() == .alertFirstButtonReturn {
                Statistics.shared.reset()
            }
        }
    }

    @objc private func handleLoginAction() {
        if OpenAICodexAuth.isLoggedIn {
            // Already logged in - show status
            let alert = NSAlert()
            alert.messageText = "Already Logged In"
            alert.informativeText = "You are already logged in to ChatGPT."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            // Start login flow
            startLoginFlow()
        }
    }

    @objc private func handleLogout() {
        let alert = NSAlert()
        alert.messageText = "Logout from ChatGPT?"
        alert.informativeText = "This will remove your saved login credentials."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Logout")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            OpenAICodexAuth.deleteCredentials()
            
            // Rebuild menu to update login status
            let trusted = AXIsProcessTrusted()
            buildMenu(trusted: trusted)
            
            let confirmAlert = NSAlert()
            confirmAlert.messageText = "Logged Out"
            confirmAlert.informativeText = "You have been logged out from ChatGPT."
            confirmAlert.alertStyle = .informational
            confirmAlert.addButton(withTitle: "OK")
            confirmAlert.runModal()
        }
    }

    private func startLoginFlow() {
        // Create authorization flow
        let flow = OpenAICodexAuth.createAuthorizationFlow()
        
        // Start the callback server
        let server = OAuthCallbackServer(expectedState: flow.state)
        
        // Show instructions
        let alert = NSAlert()
        alert.messageText = "Login to ChatGPT"
        alert.informativeText = """
        A browser window will open for you to log in to ChatGPT.
        
        After logging in, you'll be redirected back automatically.
        
        If the redirect doesn't work, copy the URL from your browser and paste it when prompted.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Browser")
        alert.addButton(withTitle: "Cancel")
        
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        // Open browser
        NSWorkspace.shared.open(flow.url)
        
        // Wait for callback in background
        Task {
            let code = await server.waitForCallback(timeout: 120)
            
            await MainActor.run {
                if let code = code {
                    // Got code from callback server
                    self.exchangeCodeForTokens(code: code, flow: flow)
                } else {
                    // Callback timed out or failed - ask for manual input
                    self.promptForManualCode(flow: flow)
                }
            }
        }
    }

    private func promptForManualCode(flow: OpenAICodexAuth.AuthorizationFlow) {
        let alert = NSAlert()
        alert.messageText = "Paste Authorization Code"
        alert.informativeText = "If the browser didn't redirect automatically, paste the URL or authorization code here:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "Paste URL or code here"
        alert.accessoryView = input
        
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        let inputValue = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputValue.isEmpty else {
            showError("No code provided")
            return
        }
        
        // Parse the input - could be full URL or just the code
        let code: String
        if let url = URL(string: inputValue),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value {
            // P2 Security: Validate state parameter if present to prevent CSRF attacks
            if let stateParam = components.queryItems?.first(where: { $0.name == "state" })?.value {
                guard stateParam == flow.state else {
                    showError("Invalid state parameter. Please try logging in again.")
                    return
                }
            }
            code = codeParam
        } else {
            code = inputValue
        }
        
        exchangeCodeForTokens(code: code, flow: flow)
    }

    private func exchangeCodeForTokens(code: String, flow: OpenAICodexAuth.AuthorizationFlow) {
        Task {
            do {
                _ = try await OpenAICodexAuth.exchangeCodeForTokens(code: code, flow: flow)
                
                await MainActor.run {
                    // Rebuild menu to update login status
                    let trusted = AXIsProcessTrusted()
                    self.buildMenu(trusted: trusted)
                    
                    let alert = NSAlert()
                    alert.messageText = "Login Successful"
                    alert.informativeText = "You are now logged in to ChatGPT. You can start using voice dictation."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                await MainActor.run {
                    self.showError("Login failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Active"
            alert.informativeText = "The app has the necessary permissions to insert dictated text."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func checkMicrophoneAction() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            let alert = NSAlert()
            alert.messageText = "Microphone Permission Active"
            alert.informativeText = "The app has access to your microphone for voice recording."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            checkMicrophonePermission()
        }
    }

    // MARK: - Escape Key Listener (only active during recording)

    private func startKeyListener() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53:  // Escape key
                Task { @MainActor [weak self] in
                    self?.cancelRecording()
                }
            case 36:  // Enter key
                Task { @MainActor [weak self] in
                    self?.stopRecordingAndSubmit()
                }
            default:
                break
            }
        }
        Logger.audio.debug("Key listener started (Escape=cancel, Enter=submit)")
    }

    private func stopKeyListener() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
            Logger.audio.debug("Key listener stopped")
        }
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
            if !started {
                Logger.audio.error("Recorder failed to start — rolling back app state")
                isRecording = false
                isProcessingFinal = false
                recorder = nil
                updateStatusIcon()
                NSSound(named: "Basso")?.play()
            }
        }
        startKeyListener()  // Listen for Escape (cancel) or Enter (submit)
        refreshUITestHarness()
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
        stopKeyListener()
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
        isProcessingFinal = true  // Keep inserting text while waiting for final transcriptions
        updateStatusIcon()
        NSSound(named: "Pop")?.play()
        recorder?.stop()
        recorder = nil
        refreshUITestHarness()

        // Wait a moment for final chunks to process, then check completion
        Task {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run { self.finishIfDone() }
        }
    }

    @MainActor
    func cancelRecording() {
        guard isRecording || isProcessingFinal else { return }
        Logger.audio.error("🔴 STOP RECORDING reason=ESCAPE_CANCEL")
        stopKeyListener()
        isRecording = false
        isProcessingFinal = false
        shouldPressEnterOnComplete = false  // Reset submit flag on cancel
        fullTranscript = ""  // P2 Security: Reset transcript to prevent stale data
        targetElement = nil
        textInsertionTask?.cancel()
        textInsertionTask = nil
        queuedInsertionCount = 0  // P3 Security: Reset queue count on cancel
        recorder?.cancel()  // P2 Security: Use cancel() to skip final chunk emission
        recorder = nil
        Transcription.shared.cancelAll()
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
                // All transcriptions complete, stop processing mode
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
            micPermissionTimer?.invalidate()
            micPermissionTimer = nil
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
        micPermissionTimer?.invalidate()
        micPermissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .authorized {
                Logger.permissions.info("Microphone permission granted (detected via polling)")
                timer.invalidate()
                Task { @MainActor in
                    self?.micPermissionTimer = nil
                    self?.updateStatusIcon()
                    self?.updateMenu(trusted: AXIsProcessTrusted())
                }
            }
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = """
        This app needs microphone permission to record your voice for transcription.

        To enable it:
        1. Open System Settings > Privacy & Security > Microphone
        2. Find this app and enable the toggle
        3. Try recording again

        💡 You may need to restart the app after changing permissions.
        """
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone Denied")

        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open Privacy & Security > Microphone
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
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

        // Cancel all in-flight transcription tasks
        Transcription.shared.cancelAll()

        // Cancel ongoing text insertion
        textInsertionTask?.cancel()
        textInsertionTask = nil

        // Stop microphone permission polling
        micPermissionTimer?.invalidate()
        micPermissionTimer = nil

        // Remove workspace notification observer
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        Logger.app.info("Cleanup complete")
    }
}
