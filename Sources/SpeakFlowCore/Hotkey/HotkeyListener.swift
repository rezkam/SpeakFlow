import AppKit
import OSLog

// MARK: - Key Codes
private enum KeyCode {
    static let d: UInt16 = 2
    static let space: UInt16 = 49
}

/// Listens for global hotkey events to activate dictation
/// All state is accessed on the main thread to prevent race conditions
@MainActor
public final class HotkeyListener {
    // Event monitors are typed as Any? because NSEvent.addGlobalMonitorForEvents returns Any?
    // This is Apple's API design, not a type erasure choice
    private var globalMonitor: Any?
    private var flagsMonitor: Any?

    // Double-tap detection state (protected by @MainActor)
    private var lastControlReleaseTime: Date?
    private var controlWasDown = false

    // Configuration constants
    private static let doubleTapInterval: TimeInterval = 0.4

    // Current hotkey configuration
    private var currentType: HotkeyType = .doubleTapControl

    public var onActivate: (() -> Void)?

    public init() {}

    public func start(type: HotkeyType) {
        stop()
        currentType = type

        switch type {
        case .doubleTapControl:
            startDoubleTapDetection()

        case .controlOptionD, .controlOptionSpace, .commandShiftD:
            startKeyComboDetection(type: type)
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        // Reset state
        lastControlReleaseTime = nil
        controlWasDown = false
    }

    // MARK: - Double-tap Control Detection

    private func startDoubleTapDetection() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Dispatch to main actor to protect shared state
            Task { @MainActor in
                self?.handleFlagsChanged(event: event)
            }
        }

        if flagsMonitor != nil {
            Logger.hotkey.info("Double-tap Control listener started")
        } else {
            Logger.hotkey.error("Could not create flags monitor (need Accessibility permission)")
        }
    }

    private func handleFlagsChanged(event: NSEvent) {
        let flags = event.modifierFlags
        let controlDown = flags.contains(.control)

        // Only trigger on Control alone (no other modifiers except capsLock/numericPad)
        let significantModifiers: NSEvent.ModifierFlags = [.command, .option, .shift]
        let hasOtherModifiers = !flags.isDisjoint(with: significantModifiers)

        // Detect Control key release (was down, now up) with no other significant modifiers
        if controlWasDown && !controlDown && !hasOtherModifiers {
            let now = Date()
            if let lastRelease = lastControlReleaseTime,
               now.timeIntervalSince(lastRelease) < Self.doubleTapInterval {
                // Double-tap detected!
                lastControlReleaseTime = nil
                onActivate?()
            } else {
                lastControlReleaseTime = now
            }
        }

        controlWasDown = controlDown
    }

    // MARK: - Key Combo Detection

    private func startKeyComboDetection(type: HotkeyType) {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event: event, type: type)
            }
        }

        if globalMonitor != nil {
            Logger.hotkey.info("Key combo listener started for \(type.displayName)")
        } else {
            Logger.hotkey.error("Could not create key monitor (need Accessibility permission)")
        }
    }

    private func handleKeyDown(event: NSEvent, type: HotkeyType) {
        // Get only the significant modifier flags, ignoring capsLock, numericPad, function, etc.
        let significantFlags: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let activeFlags = event.modifierFlags.intersection(significantFlags)

        switch type {
        case .controlOptionD:
            // ⌃⌥D - check that control and option are present (ignoring capsLock etc.)
            let required: NSEvent.ModifierFlags = [.control, .option]
            if activeFlags == required && event.keyCode == KeyCode.d {
                onActivate?()
            }

        case .controlOptionSpace:
            // ⌃⌥Space
            let required: NSEvent.ModifierFlags = [.control, .option]
            if activeFlags == required && event.keyCode == KeyCode.space {
                onActivate?()
            }

        case .commandShiftD:
            // ⇧⌘D
            let required: NSEvent.ModifierFlags = [.command, .shift]
            if activeFlags == required && event.keyCode == KeyCode.d {
                onActivate?()
            }

        case .doubleTapControl:
            break // Handled by flagsChanged
        }
    }

    deinit {
        // Note: deinit cannot be @MainActor, but stop() will be called
        // from main thread in practice since HotkeyListener is @MainActor
    }
}
