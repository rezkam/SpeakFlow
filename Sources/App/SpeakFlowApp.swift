import AppKit
import SwiftUI
import SpeakFlowCore

/// App entry point. Uses @main but delegates all work to AppDelegate.
///
/// We do NOT use SwiftUI `MenuBarExtra` — it cannot reliably open windows
/// from accessory (LSUIElement) apps. Instead, AppDelegate owns an
/// `NSStatusItem` with an `NSMenu` built from SwiftUI-powered helpers,
/// and opens SwiftUI dialog content via `NSWindow` + `NSHostingController`
/// (the same proven pattern used by SwiftBar and other menu-bar-only apps).
@main
struct SpeakFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // We need at least one scene for @main, but all UI is managed
        // by AppDelegate via NSStatusItem + NSMenu + NSWindow.
        Settings { EmptyView() }
    }
}
