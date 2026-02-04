import AppKit

// MARK: - Application Entry Point

// Run on main thread as required by AppKit
DispatchQueue.main.async {
    let appDelegate = AppDelegate()
    NSApplication.shared.delegate = appDelegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}

// Keep the main thread alive
dispatchMain()
