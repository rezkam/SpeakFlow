import AppKit
import ApplicationServices
import OSLog

/// Manages accessibility permission requests and monitoring
final class AccessibilityPermissionManager {
    private var permissionCheckTimer: Timer?
    private var hasShownInitialPrompt = false
    private var lastKnownPermissionState: Bool?  // P3 Security: Track permission state changes
    private var pollAttempts = 0
    private static let maxPollAttempts = 60  // 60 * 2s = 2 minutes timeout
    weak var delegate: AppDelegate?

    func checkAndRequestPermission(showAlertIfNeeded: Bool = true, isAppStart: Bool = false) -> Bool {
        // P3 Security: Reset prompt flag if permission was revoked since last check
        // This allows re-prompting users who removed the app from the Accessibility list
        let currentState = AXIsProcessTrusted()
        if let lastState = lastKnownPermissionState, lastState && !currentState {
            hasShownInitialPrompt = false
            Logger.permissions.info("Permission was revoked, resetting prompt state")
        }
        lastKnownPermissionState = currentState

        // Use AXIsProcessTrustedWithOptions to automatically add app to the list
        // and trigger system prompt on first call
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !hasShownInitialPrompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !hasShownInitialPrompt {
            hasShownInitialPrompt = true
            if !trusted {
                Logger.permissions.info("App added to Accessibility list, system prompt shown")
            }
        }

        // On app start, ALWAYS show alert if permission is not granted
        // On other calls, only show if showAlertIfNeeded is true
        let shouldShowAlert = !trusted && (isAppStart || showAlertIfNeeded)

        if shouldShowAlert {
            // Show our detailed alert after a brief delay to let system prompt appear/dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showPermissionAlert()
                self?.startPollingForPermission()
            }
        }

        return trusted
    }

    private func showPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Enable Accessibility Access"
            alert.informativeText = """
            This app needs Accessibility permission to type dictated text into other applications.

            We've already added this app to your Accessibility settings.

            To enable it:
            1. Click "Open System Settings" below
            2. Find this app in the Accessibility list (already added for you)
            3. Click the toggle switch to turn it ON
            4. Return to this app — we'll automatically detect when you enable it

            💡 You may need to unlock the settings with your password first.
            """
            alert.alertStyle = .informational
            alert.icon = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Permission")

            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Remind Me Later")
            alert.addButton(withTitle: "Quit App")

            let response = alert.runModal()

            switch response {
            case .alertFirstButtonReturn: // Open System Settings
                self.openAccessibilitySettings()

            case .alertSecondButtonReturn: // Remind Me Later
                Logger.permissions.info("User postponed accessibility permission")

            case .alertThirdButtonReturn: // Quit
                Logger.app.info("User chose to quit from permission dialog")
                NSApp.terminate(nil)

            default:
                break
            }
        }
    }

    private func openAccessibilitySettings() {
        // System URL scheme - always valid
        // swiftlint:disable:next force_unwrapping
        let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(accessibilityURL)
        Logger.permissions.debug("Opened System Settings > Privacy & Security > Accessibility")
    }

    private func startPollingForPermission() {
        // Stop any existing timer and reset counter
        permissionCheckTimer?.invalidate()
        pollAttempts = 0

        // Check every 2 seconds if permission has been granted
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            self.pollAttempts += 1

            // P2 Security: Timeout after max attempts to prevent infinite polling
            if self.pollAttempts >= Self.maxPollAttempts {
                Logger.permissions.warning("Permission polling timed out after \(Self.maxPollAttempts) attempts")
                timer.invalidate()
                self.permissionCheckTimer = nil
                return
            }

            let trusted = AXIsProcessTrusted()
            if trusted {
                Logger.permissions.info("Accessibility permission granted")
                timer.invalidate()
                self.permissionCheckTimer = nil

                // Update UI on main actor
                Task { @MainActor in
                    self.delegate?.updateStatusIcon()
                    self.delegate?.setupHotkey()
                }

                // Show confirmation
                self.showPermissionGrantedAlert()
            }
        }
    }

    private func showPermissionGrantedAlert() {
        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Granted"
            alert.informativeText = """
            The app now has permission to insert dictated text into other applications.

            You can start using the dictation feature with \(hotkeyName).
            """
            alert.alertStyle = .informational
            alert.icon = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "Success")

            alert.addButton(withTitle: "OK")

            alert.runModal()
        }
    }

    func stopPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    deinit {
        stopPolling()
    }
}
