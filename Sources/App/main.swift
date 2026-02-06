import AppKit
import SpeakFlowCore

// MARK: - Application Entry Point

// AppDelegate is @MainActor, so we use assumeIsolated since we're on main thread
let appDelegate = MainActor.assumeIsolated {
    AppDelegate()
}
NSApplication.shared.delegate = appDelegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
