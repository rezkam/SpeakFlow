import AppKit
import AVFoundation
import OSLog
import SpeakFlowCore

/// Manages accessibility and microphone permission checking and requests.
///
/// Conforms to `AccessibilityPermissionDelegate` so that the permission
/// manager in SpeakFlowCore can call back into the UI layer for feedback
/// (banners, opening System Settings) without knowing about AppKit UI.
@MainActor
final class PermissionController: AccessibilityPermissionDelegate {
    static let shared = PermissionController()

    let permissionManager = AccessibilityPermissionManager()
    private var micPermissionTask: Task<Void, Never>?

    let appState: any BannerPresenting
    let hotkeySettings: any HotkeySettingsProviding
    /// Injected closure to avoid circular dependency with RecordingController.
    let setupHotkeyAction: () -> Void

    init(
        appState: any BannerPresenting = SpeakFlow.AppState.shared,
        hotkeySettings: any HotkeySettingsProviding = SpeakFlowCore.HotkeySettings.shared,
        setupHotkeyAction: @escaping () -> Void = { RecordingController.shared.setupHotkey() }
    ) {
        self.appState = appState
        self.hotkeySettings = hotkeySettings
        self.setupHotkeyAction = setupHotkeyAction
        permissionManager.delegate = self
    }

    // MARK: - Permission Readiness (called from RecordingController)

    /// Returns `true` when accessibility is granted, triggering a request flow if not.
    func isAccessibilityReady() -> Bool {
        if AXIsProcessTrusted() { return true }
        SoundEffect.error.play()
        _ = ensureAccessibility()
        return false
    }

    /// Returns `true` when microphone is authorized. Requests access if undetermined,
    /// calling `onGranted` on the main actor when the user approves.
    func isMicrophoneReady(onGranted: @escaping @MainActor () -> Void) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in if granted { onGranted() } }
            }
            return false
        case .denied, .restricted:
            SoundEffect.error.play()
            return false
        @unknown default: return false
        }
    }

    // MARK: - Public Actions (called from views)

    func checkAccessibility() {
        let trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true)
        if trusted {
            appState.showBanner("Accessibility permission is active", style: .success)
        }
        appState.refresh()
    }

    func checkMicrophoneAction() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            appState.showBanner("Microphone permission is active", style: .success)
        case .notDetermined:
            checkMicrophonePermission()
        case .denied, .restricted:
            // Previously denied — OS won't re-prompt, open Settings directly
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            appState.showBanner("Opening System Settings — toggle SpeakFlow under Microphone", style: .info)
        @unknown default:
            break
        }
        appState.refresh()
    }

    /// Silently check permissions on app startup — only reads current status, never triggers OS dialogs.
    /// The user sees the status in the General tab and grants access when ready via "Grant Access" buttons.
    func checkInitialPermissions() {
        let trusted = AXIsProcessTrusted()
        Logger.permissions.debug("AXIsProcessTrusted: \(trusted)")
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Logger.permissions.debug("Microphone status: \(String(describing: micStatus))")
        appState.refresh()
    }

    /// Returns whether accessibility is currently granted, triggering a request if not.
    func ensureAccessibility(showAlertIfNeeded: Bool = true) -> Bool {
        permissionManager.checkAndRequestPermission(showAlertIfNeeded: showAlertIfNeeded)
    }

    func shutdown() {
        micPermissionTask?.cancel()
        micPermissionTask = nil
        permissionManager.stopPolling()
    }

    // MARK: - AccessibilityPermissionDelegate

    func updateStatusIcon() {
        appState.refresh()
    }

    func setupHotkey() {
        setupHotkeyAction()
    }

    func showAccessibilityPermissionAlert() async -> PermissionAlertResponse {
        // Always open Settings directly — the user already chose to grant access
        // by clicking "Grant Access" in the General tab. No intermediate alert needed.
        appState.showBanner("Accessibility permission required — opening System Settings…", style: .info)
        return .openSettings
    }

    func showAccessibilityGrantedAlert() {
        appState.refresh()
        appState.showBanner(
            "Accessibility granted — ready to dictate with \(hotkeySettings.currentHotkey.displayName)",
            style: .success
        )
    }

    // MARK: - Private

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionTask?.cancel(); micPermissionTask = nil
            appState.refresh()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.appState.refresh() }
            }
        case .denied, .restricted:
            Logger.permissions.warning("Microphone permission denied/restricted")
            appState.showBanner("Microphone access required — open System Settings → Privacy & Security → Microphone", style: .error)
        @unknown default: break
        }
    }
}
