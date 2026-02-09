import AppKit
@preconcurrency import ApplicationServices
import OSLog

/// Possible user responses to the accessibility permission prompt.
public enum PermissionAlertResponse: Sendable {
    case openSettings
    case remindLater
    case quitApp
}

/// Protocol for permission manager delegate callbacks
@MainActor
public protocol AccessibilityPermissionDelegate: AnyObject {
    func updateStatusIcon()
    func setupHotkey()
    /// Show a permission request dialog and return the user's choice.
    func showAccessibilityPermissionAlert() async -> PermissionAlertResponse
    /// Show a success dialog after permission is granted.
    func showAccessibilityGrantedAlert()
}

/// Manages accessibility permission requests and monitoring
@MainActor
public final class AccessibilityPermissionManager {
    private var permissionCheckTask: Task<Void, Never>?
    private var hasShownInitialPrompt = false
    private var lastKnownPermissionState: Bool?  // P3 Security: Track permission state changes
    private var pollAttempts = 0
    static let maxPollAttempts = 60  // 60 * 2s = 2 minutes timeout (internal for testing)
    public weak var delegate: AccessibilityPermissionDelegate?

    public init() {}

    public func checkAndRequestPermission(showAlertIfNeeded: Bool = true, isAppStart: Bool = false) -> Bool {
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
        // Access the accessibility constant - safe on MainActor
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: !hasShownInitialPrompt] as CFDictionary
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
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self.showPermissionAlert()
                self.startPollingForPermission()
            }
        }

        return trusted
    }

    private func showPermissionAlert() {
        Task { @MainActor in
            guard let delegate else { return }
            let response = await delegate.showAccessibilityPermissionAlert()
            switch response {
            case .openSettings:
                self.openAccessibilitySettings()
            case .remindLater:
                Logger.permissions.info("User postponed accessibility permission")
            case .quitApp:
                Logger.app.info("User chose to quit from permission dialog")
                NSApp.terminate(nil)
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
        // Stop any existing polling task and reset counter
        permissionCheckTask?.cancel()
        pollAttempts = 0

        // Poll every 2 seconds using a MainActor Task loop.
        // This avoids Timer's @Sendable closure which cannot safely
        // access @MainActor state in Swift 6.
        permissionCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self = self else { return }

                self.pollAttempts += 1

                // P2 Security: Timeout after max attempts to prevent infinite polling
                if self.pollAttempts >= Self.maxPollAttempts {
                    Logger.permissions.warning("Permission polling timed out after \(Self.maxPollAttempts) attempts")
                    self.permissionCheckTask = nil
                    return
                }

                let trusted = AXIsProcessTrusted()
                if trusted {
                    Logger.permissions.info("Accessibility permission granted")
                    self.permissionCheckTask = nil

                    // Update UI — already on MainActor
                    self.delegate?.updateStatusIcon()
                    self.delegate?.setupHotkey()

                    // Show confirmation
                    self.showPermissionGrantedAlert()
                    return
                }
            }
        }
    }

    private func showPermissionGrantedAlert() {
        delegate?.showAccessibilityGrantedAlert()
    }

    public func stopPolling() {
        permissionCheckTask?.cancel()
        permissionCheckTask = nil
    }
}
