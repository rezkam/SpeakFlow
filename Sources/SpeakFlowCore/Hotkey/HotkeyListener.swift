import AppKit
import OSLog

// MARK: - Key Codes
private enum KeyCode {
    static let d: UInt16 = 2
    static let space: UInt16 = 49
}

/// Listens for global hotkey events to activate dictation
@MainActor
public final class HotkeyListener {
    // CGEvent tap for double-tap Control detection
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // NSEvent monitor for key combos
    private var globalMonitor: Any?

    // Double-tap detection state - track RELEASE time (this was the working approach)
    private var lastControlReleaseTime: Date?
    private var controlWasDown = false
    private let doubleTapInterval: TimeInterval = 0.4

    public var onActivate: (() -> Void)?

    #if DEBUG
    static var _testStopHook: (() -> Void)?
    #endif

    public init() {}

    // Isolated deinit requires Swift 6.2+; on 6.1 cleanup happens via explicit stop().
    #if compiler(>=6.2)
    @MainActor deinit {
        stop()
    }
    #endif

    public func start(type: HotkeyType) {
        stop()

        switch type {
        case .doubleTapControl:
            startDoubleTapDetection()

        case .controlOptionD, .controlOptionSpace, .commandShiftD:
            startKeyComboDetection(type: type)
        }
    }

    public func stop() {
        #if DEBUG
        Self._testStopHook?()
        #endif

        // Stop CGEvent tap
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        // Stop NSEvent monitor
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        // Reset state
        lastControlReleaseTime = nil
        controlWasDown = false
    }

    // MARK: - Double-tap Control Detection (using CGEvent tap)

    private func startDoubleTapDetection() {
        guard eventTap == nil else { return }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
                listener.handleFlagsChanged(event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            Logger.hotkey.error("Could not create event tap (need Accessibility permission)")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let source = runLoopSource else { return }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        Logger.hotkey.info("Double-tap Control listener started")
    }

    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let controlDown = flags.contains(.maskControl)

        // Only trigger on Control alone (no other modifiers)
        let hasOtherModifiers = flags.contains(.maskCommand) ||
                                flags.contains(.maskAlternate) ||
                                flags.contains(.maskShift)

        // Detect Control key RELEASE (was down, now up) with no other modifiers
        if controlWasDown && !controlDown && !hasOtherModifiers {
            let now = Date()
            if let lastRelease = lastControlReleaseTime,
               now.timeIntervalSince(lastRelease) < doubleTapInterval {
                // Double-tap detected!
                lastControlReleaseTime = nil
                Task { @MainActor [weak self] in
                    self?.onActivate?()
                }
            } else {
                lastControlReleaseTime = now
            }
        }

        controlWasDown = controlDown
    }

    // MARK: - Key Combo Detection (using NSEvent monitor)

    private func startKeyComboDetection(type: HotkeyType) {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event: event, type: type)
        }

        if globalMonitor != nil {
            Logger.hotkey.info("Key combo listener started for \(type.displayName)")
        } else {
            Logger.hotkey.error("Could not create key monitor (need Accessibility permission)")
        }
    }

    private func handleKeyDown(event: NSEvent, type: HotkeyType) {
        let flags = event.modifierFlags

        switch type {
        case .controlOptionD:
            if flags.contains(.control) && flags.contains(.option) &&
               !flags.contains(.command) && !flags.contains(.shift) &&
               event.keyCode == KeyCode.d {
                Task { @MainActor [weak self] in
                    self?.onActivate?()
                }
            }

        case .controlOptionSpace:
            if flags.contains(.control) && flags.contains(.option) &&
               !flags.contains(.command) && !flags.contains(.shift) &&
               event.keyCode == KeyCode.space {
                Task { @MainActor [weak self] in
                    self?.onActivate?()
                }
            }

        case .commandShiftD:
            if flags.contains(.command) && flags.contains(.shift) &&
               !flags.contains(.control) && !flags.contains(.option) &&
               event.keyCode == KeyCode.d {
                Task { @MainActor [weak self] in
                    self?.onActivate?()
                }
            }

        case .doubleTapControl:
            break // Handled by CGEvent tap
        }
    }

}
