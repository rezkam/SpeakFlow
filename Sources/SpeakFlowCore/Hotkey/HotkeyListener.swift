import AppKit
import os
import OSLog

// MARK: - Key Codes
private enum KeyCode {
    static let d: UInt16 = 2
    static let space: UInt16 = 49
}

/// Listens for global hotkey events to activate dictation
@MainActor
public final class HotkeyListener {
    private struct DoubleTapState: @unchecked Sendable {
        var lastControlReleaseTime: Date?
        var controlWasDown = false
        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var globalMonitor: Any?
    }

    private let tapState = OSAllocatedUnfairLock(initialState: DoubleTapState())
    private let doubleTapInterval: TimeInterval = 0.4

    public var onActivate: (() -> Void)?

    #if DEBUG
    // swiftlint:disable:next identifier_name
    static var _testStopHook: (() -> Void)?
    /// Synchronous hook fired immediately when a double-tap is detected,
    /// before the async Task dispatch. Enables deterministic testing.
    // swiftlint:disable:next identifier_name
    var _testDoubleTapDetected: (() -> Void)?
    #endif

    public init() {}

    @MainActor deinit {
        stop()
    }

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

        let (tap, source, monitor) = tapState.withLockUnchecked { s -> (CFMachPort?, CFRunLoopSource?, Any?) in
            let result = (s.eventTap, s.runLoopSource, s.globalMonitor)
            s.eventTap = nil
            s.runLoopSource = nil
            s.globalMonitor = nil
            s.lastControlReleaseTime = nil
            s.controlWasDown = false
            return result
        }

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Double-tap Control Detection (using CGEvent tap)

    private func startDoubleTapDetection() {
        let alreadyActive = tapState.withLockUnchecked { $0.eventTap != nil }
        guard !alreadyActive else { return }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, _, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
                listener.handleFlagsChanged(event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            Logger.hotkey.error("Could not create event tap (need Accessibility permission)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source else { return }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapState.withLockUnchecked {
            $0.eventTap = tap
            $0.runLoopSource = source
        }

        Logger.hotkey.info("Double-tap Control listener started")
    }

    func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let controlDown = flags.contains(.maskControl)

        let hasOtherModifiers = flags.contains(.maskCommand) ||
                                flags.contains(.maskAlternate) ||
                                flags.contains(.maskShift)

        let doubleTapDetected = tapState.withLockUnchecked { s -> Bool in
            // Detect Control key RELEASE (was down, now up) with no other modifiers
            if s.controlWasDown && !controlDown && !hasOtherModifiers {
                let now = Date()
                if let lastRelease = s.lastControlReleaseTime,
                   now.timeIntervalSince(lastRelease) < doubleTapInterval {
                    s.lastControlReleaseTime = nil
                    s.controlWasDown = controlDown
                    return true
                } else {
                    s.lastControlReleaseTime = now
                }
            }
            s.controlWasDown = controlDown
            return false
        }

        if doubleTapDetected {
            #if DEBUG
            _testDoubleTapDetected?()
            #endif
            Task { @MainActor [weak self] in
                self?.onActivate?()
            }
        }
    }

    // MARK: - Key Combo Detection (using NSEvent monitor)

    private func startKeyComboDetection(type: HotkeyType) {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event: event, type: type)
        }
        tapState.withLockUnchecked { $0.globalMonitor = monitor }

        if monitor != nil {
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
