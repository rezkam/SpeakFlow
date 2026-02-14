import AppKit
import AVFoundation
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
    private let isUITestMode = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MODE"] == "1"
    private let useMockRecordingInUITests = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_MOCK_RECORDING"] != "0"
    private let resetUITestState = ProcessInfo.processInfo.environment["SPEAKFLOW_UI_TEST_RESET_STATE"] == "1"
    private let uiTestHotkeyCycle: [HotkeyType] = [.controlOptionD, .controlOptionSpace, .commandShiftD]

    /// Switch to regular activation policy BEFORE SwiftUI creates scenes.
    /// This ensures the Window scene actually shows (LSUIElement apps suppress windows).
    /// We always show the settings window on launch so the user can review their setup.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the Dock icon from the bundled colorful icon
        if let url = Bundle.module.url(forResource: "DockIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.isTemplate = false
            NSApp.applicationIconImage = icon
        }

        // Register all transcription providers
        let registry = ProviderRegistry.shared
        registry.register(ChatGPTBatchProvider())
        registry.register(DeepgramProvider())

        let recording = RecordingController.shared
        let permissions = PermissionController.shared

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

    // MARK: - Window Lifecycle

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
        RecordingController.shared.shutdown()
        AuthController.shared.shutdown()
        PermissionController.shared.shutdown()
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
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
