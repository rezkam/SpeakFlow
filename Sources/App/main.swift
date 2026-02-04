import AppKit
import SpeakFlowCore

// MARK: - Application Entry Point

// Run on main thread as required by AppKit
DispatchQueue.main.async {
    let appDelegate = AppDelegate()
    NSApplication.shared.delegate = appDelegate
    // P3: Removed duplicate .regular activation policy - AppDelegate sets .accessory
    NSApplication.shared.run()
}

// Keep the main thread alive
dispatchMain()
