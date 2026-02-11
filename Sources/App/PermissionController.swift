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

    private init() {
        permissionManager.delegate = self
    }

    // MARK: - Public Actions (called from views)

    func checkAccessibility() {
        let trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true)
        if trusted {
            AppState.shared.showBanner("Accessibility permission is active", style: .success)
        }
        AppState.shared.refresh()
    }

    func checkMicrophoneAction() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            AppState.shared.showBanner("Microphone permission is active", style: .success)
        case .notDetermined:
            checkMicrophonePermission()
        case .denied, .restricted:
            // Previously denied — OS won't re-prompt, open Settings directly
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            AppState.shared.showBanner("Opening System Settings — toggle SpeakFlow under Microphone", style: .info)
        @unknown default:
            break
        }
        AppState.shared.refresh()
    }

    /// Silently check permissions on app startup — only reads current status, never triggers OS dialogs.
    /// The user sees the status in the General tab and grants access when ready via "Grant Access" buttons.
    func checkInitialPermissions() {
        let trusted = AXIsProcessTrusted()
        Logger.permissions.debug("AXIsProcessTrusted: \(trusted)")
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Logger.permissions.debug("Microphone status: \(String(describing: micStatus))")
        AppState.shared.refresh()
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
        AppState.shared.refresh()
    }

    func setupHotkey() {
        RecordingController.shared.setupHotkey()
    }

    func showAccessibilityPermissionAlert() async -> PermissionAlertResponse {
        // Always open Settings directly — the user already chose to grant access
        // by clicking "Grant Access" in the General tab. No intermediate alert needed.
        AppState.shared.showBanner("Accessibility permission required — opening System Settings…", style: .info)
        return .openSettings
    }

    func showAccessibilityGrantedAlert() {
        AppState.shared.refresh()
        AppState.shared.showBanner(
            "Accessibility granted — ready to dictate with \(HotkeySettings.shared.currentHotkey.displayName)",
            style: .success
        )
    }

    // MARK: - Private

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionTask?.cancel(); micPermissionTask = nil
            AppState.shared.refresh()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in AppState.shared.refresh() }
            }
        case .denied, .restricted:
            Logger.permissions.warning("Microphone permission denied/restricted")
            AppState.shared.showBanner("Microphone access required — open System Settings → Privacy & Security → Microphone", style: .error)
        @unknown default: break
        }
    }
}
