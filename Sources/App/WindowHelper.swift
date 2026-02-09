import AppKit
import SwiftUI

/// Opens SwiftUI dialog views in standalone windows.
///
/// Uses NSWindow + NSHostingController — the proven pattern from SwiftBar
/// and other menu-bar-only (accessory) apps where SwiftUI `openWindow`
/// is unreliable.
@MainActor
enum WindowHelper {
    private static var windows: [String: NSWindow] = [:]

    static func open(id: String) {
        // If window already exists, just bring it forward
        if let existing = windows[id], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Build the SwiftUI content with a close callback
        let closeAction = { close(id: id) }
        let content: AnyView
        let title: String

        switch id {
        case "statistics":
            title = "Statistics"
            content = AnyView(StatisticsWindowView(onDismiss: closeAction))
        case "deepgram-key":
            title = "Deepgram API Key"
            content = AnyView(DeepgramApiKeyWindowView(onDismiss: closeAction))
        case "login":
            title = "Login"
            content = AnyView(LoginWindowView(onDismiss: closeAction))
        case "alert":
            title = "SpeakFlow"
            content = AnyView(AlertWindowView(onDismiss: closeAction))
        default:
            return
        }

        // Create NSHostingController and size to fit
        let hostingController = NSHostingController(rootView: content)
        let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 500, height: 800))
        hostingController.view.frame.size = fittingSize

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating

        windows[id] = window

        // Become regular app so the window can receive focus
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Watch for close to restore accessory mode
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            windows.removeValue(forKey: id)
            restoreAccessoryPolicyIfNeeded()
        }
    }

    static func close(id: String) {
        windows[id]?.close()
        windows.removeValue(forKey: id)
        restoreAccessoryPolicyIfNeeded()
    }

    private static func restoreAccessoryPolicyIfNeeded() {
        // Go back to accessory if no dialog windows remain open
        let hasDialogWindows = !windows.isEmpty
        if !hasDialogWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
