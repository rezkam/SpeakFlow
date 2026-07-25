import AppKit
import AVFoundation
import CoreServices
import OSLog
import SpeakFlowCore

/// Thin application lifecycle coordinator.
///
/// Wires up the three domain controllers (Recording, Auth, Permission)
/// and manages window lifecycle / activation policy. All business logic
/// lives in the controllers — this class only handles app-level concerns.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var uiTestHarness: UITestHarnessController?
    private var windowCloseObserver: Any?
    private var openMainWindowHandler: (() -> Void)?
    private var closeMainWindowHandler: (() -> Void)?
    private let terminationReasonProvider: @MainActor () -> OSType?
    private let terminationRequester: @MainActor () -> Void
    private var explicitTerminationRequested = false
    private let isUITestMode = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MODE"] == "1"
    private let useMockRecordingInUITests = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MOCK_RECORDING"] != "0"
    private let resetUITestState = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_RESET_STATE"] == "1"
    private let uiTestHotkeyCycle: [HotkeyType] = [.controlOptionD, .controlOptionSpace, .commandShiftD]

    override init() {
        terminationReasonProvider = AppDelegate.currentTerminationReason
        terminationRequester = { NSApp.terminate(nil) }
        super.init()
    }

    init(
        terminationReasonProvider: @escaping @MainActor () -> OSType?,
        terminationRequester: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.terminationReasonProvider = terminationReasonProvider
        self.terminationRequester = terminationRequester
        super.init()
    }

    /// Switch to regular activation policy BEFORE SwiftUI creates scenes.
    /// This ensures the Window scene actually shows (LSUIElement apps suppress windows).
    /// We always show the settings window on launch so the user can review their setup.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the Dock icon from the bundled colorful icon
        if let icon = AppResources.pngImage(named: "DockIcon") {
            icon.isTemplate = false
            NSApp.applicationIconImage = icon
        }

        // Register all transcription providers
        let registry = ProviderRegistry.shared
        registry.register(ChatGPTBatchProvider())
        registry.register(DeepgramProvider())
        registry.register(MistralProvider())
        registry.register(MistralBatchProvider())

        let recording = RecordingController.shared
        let permissions = PermissionController.shared
        configureObservabilityForCurrentSettings()

        if isUITestMode {
            Logger.permissions.info("UI test mode enabled; skipping startup permission prompts")
            recording.testMode = useMockRecordingInUITests ? .mock : .live
        } else {
            permissions.checkInitialPermissions()

            if VADProcessor.isAvailable && Settings.shared.vadEnabled {
                Task {
                    let timedOut = await withTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            await VADModelCache.shared.warmUp(threshold: Settings.shared.vadThreshold)
                            return false
                        }
                        group.addTask {
                            try? await Task.sleep(for: .seconds(15))
                            return true
                        }
                        let result = await group.next() ?? false
                        group.cancelAll()
                        return result
                    }
                    if timedOut {
                        Logger.audio.warning("VAD model warm-up timed out after 15s")
                    }
                }
            }
            // Only pre-warm audio if microphone is already granted — accessing
            // AVAudioEngine.inputNode triggers the OS microphone permission dialog.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                Task.detached(priority: .background) {
                    let engine = AVAudioEngine()
                    _ = engine.inputNode.outputFormat(forBus: 0)
                    Logger.audio.info("Audio subsystem pre-warmed")
                }
            }
        }

        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        Logger.app.info("SpeakFlow ready - \(hotkeyName)")

        recording.setupHotkey()
        recording.setupTranscriptionCallbacks()

        if isUITestMode { setupUITestHarness() }

        AppState.shared.refresh()
        setupWindowLifecycleObservers()

        // Bring settings window to front on launch
        NSApp.activate(ignoringOtherApps: true)

        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
    }

    /// Keep the app alive when the settings window is closed — it runs in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Treat ordinary Quit requests, including Dock Quit, as control-panel close requests.
    /// Shutdown, restart, logout, system-wide Quit All, and the explicit menu action terminate normally.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if explicitTerminationRequested {
            return .terminateNow
        }

        if let reason = terminationReasonProvider(), Self.systemTerminationReasons.contains(reason) {
            return .terminateNow
        }

        closeControlPanel()
        return .terminateCancel
    }

    /// Handle Finder reopen events (including when users replace/update the app while it is
    /// already running as a menu bar app). Without this, reopening can look like a no-op.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)

        if !flag {
            var showedWindow = false

            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.makeKeyAndOrderFront(nil)
                showedWindow = true
            }

            if !showedWindow {
                if let openMainWindowHandler {
                    openMainWindowHandler()
                } else {
                    // Fallback path if bridge is not yet registered.
                    let showedSettings = NSApp.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil,
                        from: nil
                    )
                    if !showedSettings {
                        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func registerMainWindowOpener(_ handler: @escaping () -> Void) {
        openMainWindowHandler = handler
    }

    func registerMainWindowCloser(_ handler: @escaping () -> Void) {
        closeMainWindowHandler = handler
    }

    /// Close only the control panel. SpeakFlow remains available from the menu bar.
    func closeControlPanel() {
        closeMainWindowHandler?()
    }

    /// Fully quit after an explicit user selection. Command-Q and Dock Quit remain
    /// control-panel-close actions so a menu-bar-resident session stays available.
    func quitSpeakFlow() {
        explicitTerminationRequested = true
        terminationRequester()
    }

    // MARK: - Window Lifecycle

    private static let systemTerminationReasons: Set<OSType> = [
        OSType(kAEQuitAll),
        OSType(kAEShutDown),
        OSType(kAERestart),
        OSType(kAEReallyLogOut)
    ]

    private static func currentTerminationReason() -> OSType? {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
            .typeCodeValue
    }

    /// Track window open/close to toggle activation policy (Dock icon visibility).
    private func setupWindowLifecycleObservers() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let hasVisibleWindows = NSApp.windows.contains {
                    $0.isVisible && $0.styleMask.contains(.titled)
                }
                if !hasVisibleWindows {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await ObservabilityStore.shared.record(
                component: "App",
                name: "app_terminate",
                level: .info
            )
        }
        RecordingController.shared.shutdown()
        AuthController.shared.shutdown()
        PermissionController.shared.shutdown()
        // Flush any pending statistics before the process exits.
        // The debounce timer won't fire once the run loop stops.
        Statistics.shared.flushIfDirty()
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configureObservabilityForCurrentSettings() {
        let settings = Settings.shared
        let providerId = ProviderSettings.shared.activeProviderId
        let mode = ProviderRegistry.shared.provider(for: providerId)?.mode.rawValue ?? "unknown"
        let hotkey = HotkeySettings.shared.currentHotkey.rawValue
        let captureSettings = settings.observabilityCaptureSettingsSnapshot

        Task {
            await ObservabilityStore.shared.applyConfiguration(
                enabled: settings.observabilityEnabled,
                verbosity: settings.observabilityVerbosity,
                captureSettingsSnapshot: captureSettings,
                captureSystemContext: settings.observabilityCaptureSystemContext,
                captureTextPayloads: settings.observabilityCaptureTextPayloads
            )

            await ObservabilityStore.shared.record(
                component: "App",
                name: "app_launch",
                level: .info,
                metadata: [
                    "activeProviderId": providerId,
                    "activeProviderMode": mode,
                    "hotkey": hotkey,
                    "uiTestMode": isUITestMode ? "true" : "false"
                ]
            )

            guard captureSettings else { return }
            await ObservabilityStore.shared.recordSettingsSnapshot(
                sessionId: nil,
                settings: [
                    "provider.activeId": providerId,
                    "provider.activeMode": mode,
                    "hotkey.current": hotkey,
                    "streaming.autoEndEnabled": settings.streamingAutoEndEnabled ? "true" : "false",
                    "streaming.keepAliveEnabled": settings.streamingKeepAliveEnabled ? "true" : "false",
                    "streaming.keepAliveInterval": String(settings.streamingKeepAliveInterval),
                    "streaming.reconnectEnabled": settings.streamingReconnectEnabled ? "true" : "false",
                    "streaming.minimumFinalWordCount": String(settings.streamingMinimumFinalWordCount),
                    "streaming.trailingFinalTimeout": String(settings.streamingTrailingFinalTimeout),
                    "observability.captureTextPayloads": settings.observabilityCaptureTextPayloads ? "true" : "false",
                    "batch.chunkDuration": String(settings.chunkDuration.rawValue),
                    "batch.skipSilentChunks": settings.skipSilentChunks ? "true" : "false",
                    "batch.finalizationTimeoutBase": String(settings.batchFinalizationTimeoutBase),
                    "batch.finalizationTimeoutPerChunkSecond": String(settings.batchFinalizationTimeoutPerChunkSecond),
                    "batch.finalizationMaxTimeout": String(settings.batchFinalizationMaxTimeout),
                    "vad.enabled": settings.vadEnabled ? "true" : "false",
                    "vad.threshold": String(settings.vadThreshold),
                    "autoEnd.enabled": settings.autoEndEnabled ? "true" : "false",
                    "autoEnd.silenceDuration": String(settings.autoEndSilenceDuration),
                    "behavior.focusWaitTimeout": String(settings.focusWaitTimeout)
                ]
            )
        }
    }

    // MARK: - UI Test Harness

    private func setupUITestHarness() {
        guard isUITestMode, uiTestHarness == nil else { return }
        let recording = RecordingController.shared

        if resetUITestState {
            Statistics.shared.reset()
            recording.uiTestToggleCount = 0
        }
        if resetUITestState || !uiTestHotkeyCycle.contains(HotkeySettings.shared.currentHotkey) {
            HotkeySettings.shared.currentHotkey = .controlOptionD
        }

        let harness = UITestHarnessController()
        harness.onStartClicked = { recording.startRecording() }
        harness.onStopClicked = { recording.stopRecording(reason: .ui) }
        harness.onSeedStatsClicked = { [weak self] in self?.seedUITestStatistics() }
        harness.onResetStatsClicked = { [weak self] in self?.resetUITestStatistics() }
        harness.onNextHotkeyClicked = { [weak self] in
            let current = HotkeySettings.shared.currentHotkey
            guard let self else { return }
            let idx = self.uiTestHotkeyCycle.firstIndex(of: current) ?? 0
            let next = self.uiTestHotkeyCycle[(idx + 1) % self.uiTestHotkeyCycle.count]
            HotkeySettings.shared.currentHotkey = next
            recording.setupHotkey()
            AppState.shared.refresh()
            self.refreshUITestHarness()
        }
        uiTestHarness = harness

        // Wire recording state changes to update the harness display
        recording.onStateChanged = { [weak self] in self?.refreshUITestHarness() }

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

    private func refreshUITestHarness() {
        let recording = RecordingController.shared
        uiTestHarness?.updateState(
            isRecording: recording.isRecording,
            toggleCount: recording.uiTestToggleCount,
            mode: recording.testMode == .mock ? "mock" : "live",
            hotkeyDisplay: HotkeySettings.shared.currentHotkey.displayName,
            statsApiCalls: Statistics.shared.apiCallCount,
            statsWords: Statistics.shared.wordCount
        )
    }
}
