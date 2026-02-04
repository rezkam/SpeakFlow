import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import OSLog

/// Main application delegate handling UI and lifecycle
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hotkeyListener: HotkeyListener?
    var recorder: StreamingRecorder?
    var isRecording = false
    var isProcessingFinal = false  // Track if we're waiting for final transcriptions
    var fullTranscript = ""
    var permissionManager: AccessibilityPermissionManager!
    var targetElement: AXUIElement?  // Store focused element when recording starts

    // Menu bar icons
    private lazy var defaultIcon: NSImage? = loadMenuBarIcon()
    private lazy var warningIcon: NSImage? = createWarningIcon()

    // Microphone permission polling timer
    private var micPermissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up permission manager
        permissionManager = AccessibilityPermissionManager()
        permissionManager.delegate = self

        // Check accessibility permission - ALWAYS show alert on app start if not granted
        let trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true, isAppStart: true)
        Logger.permissions.debug("AXIsProcessTrusted: \(trusted)")

        if !trusted {
            Logger.permissions.warning("No Accessibility permission - showing permission request")
        } else {
            Logger.permissions.info("Accessibility permission already granted")
        }

        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        Logger.app.info("SpeakFlow ready - \(hotkeyName)")
        Logger.app.debug("Config: min=\(Config.minChunkDuration)s, max=\(Config.maxChunkDuration)s, rate=\(Config.minTimeBetweenRequests)s")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        buildMenu(trusted: trusted)
        setupHotkey()

        setupTranscriptionCallbacks()

        // Check and request microphone permission on startup
        checkMicrophonePermission()

        NSApp.setActivationPolicy(.accessory)

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
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
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
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let newType = sender.representedObject as? HotkeyType else { return }

        HotkeySettings.shared.currentHotkey = newType
        setupHotkey()

        // Rebuild menu to update checkmarks and hotkey display
        let trusted = AXIsProcessTrusted()
        buildMenu(trusted: trusted)
    }

    func setupHotkey() {
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
        let accessibilityOK = AXIsProcessTrusted()
        let microphoneOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        statusItem.button?.title = ""

        if !accessibilityOK || !microphoneOK {
            statusItem.button?.image = warningIcon
        } else {
            statusItem.button?.image = defaultIcon
        }
    }

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
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

    private func createWarningIcon() -> NSImage? {
        if let icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            let size = NSSize(width: 18, height: 18)
            let resized = NSImage(size: size)
            resized.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: size),
                      from: NSRect(origin: .zero, size: icon.size),
                      operation: .copy,
                      fraction: 1.0)
            resized.unlockFocus()
            return resized
        }
        return nil
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

    // MARK: - Recording

    @objc func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording else { return }

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
                DispatchQueue.main.async {
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

        isRecording = true
        isProcessingFinal = false  // Reset in case of previous session
        fullTranscript = ""
        Task { await Transcription.shared.queueBridge.reset() }

        // Capture the focused element NOW so we can insert text there later
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           let element = focusedElement {
            // Force cast is required because AXUIElementCopyAttributeValue returns AnyObject
            // but kAXFocusedUIElementAttribute is guaranteed to return AXUIElement when successful.
            // The Accessibility API is a C API that predates Swift's type system.
            // swiftlint:disable:next force_cast
            targetElement = (element as! AXUIElement)

            // Log element info for debugging
            if let target = targetElement {
                var role: AnyObject?
                var title: AnyObject?
                AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(target, kAXTitleAttribute as CFString, &title)
                Logger.audio.debug("Captured target element: role=\(String(describing: role)), title=\(String(describing: title))")
            }
        } else {
            targetElement = nil
            Logger.audio.warning("Could not capture focused element")
        }

        updateStatusIcon()
        NSSound(named: "Pop")?.play()

        recorder = StreamingRecorder()
        recorder?.onChunkReady = { data in
            Task { @MainActor in
                let seq = await Transcription.shared.queueBridge.nextSequence()
                Transcription.shared.transcribe(seq: seq, audio: data)
            }
        }
        recorder?.start()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isProcessingFinal = true  // Keep inserting text while waiting for final transcriptions
        updateStatusIcon()
        NSSound(named: "Blow")?.play()
        recorder?.stop()
        recorder = nil

        // Wait a moment for final chunks to process, then check completion
        Task {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run { self.finishIfDone() }
        }
    }

    @MainActor
    func cancelRecording() {
        guard isRecording || isProcessingFinal else { return }
        isRecording = false
        isProcessingFinal = false
        recorder?.stop()
        recorder = nil
        Transcription.shared.cancelAll()
        updateStatusIcon()
        Logger.audio.info("Recording cancelled")
    }

    func finishIfDone() {
        guard !isRecording else { return }

        Task {
            let pending = await Transcription.shared.queueBridge.getPendingCount()
            if pending > 0 {
                Logger.transcription.debug("Waiting for \(pending) pending transcriptions")
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { self.finishIfDone() }
                return
            }

            await MainActor.run {
                // All transcriptions complete, stop processing mode
                self.isProcessingFinal = false
                self.targetElement = nil  // Clear stored element
                self.updateStatusIcon()
                guard !self.fullTranscript.isEmpty else { return }

                Logger.transcription.info("Session complete: \(self.fullTranscript, privacy: .private)")
                NSSound(named: "Glass")?.play()
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
        // Validate text length to prevent DoS
        guard text.count <= Self.maxTextInsertionLength else {
            Logger.app.warning("Text too long to insert (\(text.count) chars > \(Self.maxTextInsertionLength))")
            // Insert truncated text with warning
            let truncated = String(text.prefix(Self.maxTextInsertionLength))
            typeText(truncated)
            return
        }

        Logger.app.debug("Inserting text: \(text, privacy: .private)")
        typeText(text)
        Logger.app.debug("Text typed via CGEvent")
    }

    private func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Logger.app.error("Could not create CGEventSource")
            return
        }

        for char in text {
            var unichar = Array(String(char).utf16)

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                Logger.app.error("Could not create CGEvent for character")
                continue
            }

            keyDown.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            usleep(Self.keystrokeDelayMicroseconds)
        }
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
                DispatchQueue.main.async {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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
        DispatchQueue.main.async {
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
    }

    @objc func quit() { NSApp.terminate(nil) }
}
