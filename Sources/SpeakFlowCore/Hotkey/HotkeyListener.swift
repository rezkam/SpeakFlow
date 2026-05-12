import ApplicationServices
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
        var activeHotkeyType: HotkeyType?
    }

    private let tapState = OSAllocatedUnfairLock(initialState: DoubleTapState())
    private let doubleTapInterval: TimeInterval = 0.4

    public var onActivate: (() -> Void)?

    #if DEBUG
    // swiftlint:disable:next identifier_name
    nonisolated(unsafe) static var _testStopHook: (() -> Void)?
    /// Synchronous hook fired immediately when a double-tap is detected,
    /// before the async Task dispatch. Enables deterministic testing.
    // swiftlint:disable:next identifier_name
    var _testDoubleTapDetected: (() -> Void)?
    #endif

    public init() {}

    deinit {
        #if DEBUG
        Self._testStopHook?()
        #endif

        // Clean up event tap and monitors directly without calling the
        // @MainActor-isolated stop() method.  The lock-protected state
        // is safe to access from any isolation context.
        let (tap, source, monitor) = tapState.withLockUnchecked { s -> (CFMachPort?, CFRunLoopSource?, Any?) in
            let result = (s.eventTap, s.runLoopSource, s.globalMonitor)
            s.eventTap = nil
            s.runLoopSource = nil
            s.globalMonitor = nil
            return result
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    public func start(type: HotkeyType) {
        stop()

        HotkeyDiagnostics.record(
            "hotkey_registration_started",
            metadata: registrationMetadata(for: type)
        )

        switch type {
        case .doubleTapControl:
            startDoubleTapDetection(type: type)

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
            s.activeHotkeyType = nil
            s.lastControlReleaseTime = nil
            s.controlWasDown = false
            return result
        }

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let monitor { NSEvent.removeMonitor(monitor) }

        let metadata = [
            "hadEventTap": tap == nil ? "false" : "true",
            "hadRunLoopSource": source == nil ? "false" : "true",
            "hadGlobalMonitor": monitor == nil ? "false" : "true"
        ]
        if tap != nil || source != nil || monitor != nil {
            HotkeyDiagnostics.record("hotkey_registration_stopped", metadata: metadata)
        } else {
            HotkeyDiagnostics.record("hotkey_registration_stop_noop", level: .debug, metadata: metadata)
        }
    }

    // MARK: - Double-tap Control Detection (using CGEvent tap)

    private func startDoubleTapDetection(type: HotkeyType) {
        let alreadyActive = tapState.withLockUnchecked { $0.eventTap != nil }
        guard !alreadyActive else {
            HotkeyDiagnostics.record(
                "hotkey_registration_skipped_already_active",
                level: .warning,
                metadata: registrationMetadata(for: type)
            )
            return
        }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, eventType, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
                if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
                    listener.handleEventTapDisabled(eventType: eventType)
                    return Unmanaged.passRetained(event)
                }
                listener.handleFlagsChanged(event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            HotkeyDiagnostics.record(
                "hotkey_registration_failed",
                level: .error,
                metadata: registrationMetadata(for: type).merging([
                    "reason": "eventTapCreateReturnedNil",
                    "accessibilityTrusted": accessibilityTrustedValue()
                ]) { _, new in new }
            )
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source else {
            CFMachPortInvalidate(tap)
            HotkeyDiagnostics.record(
                "hotkey_registration_failed",
                level: .error,
                metadata: registrationMetadata(for: type).merging([
                    "reason": "runLoopSourceCreateReturnedNil",
                    "accessibilityTrusted": accessibilityTrustedValue()
                ]) { _, new in new }
            )
            return
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapState.withLockUnchecked {
            $0.eventTap = tap
            $0.runLoopSource = source
            $0.activeHotkeyType = type
        }

        HotkeyDiagnostics.record(
            "hotkey_registration_succeeded",
            metadata: registrationMetadata(for: type).merging([
                "eventTap": "cgSessionEventTap",
                "tapPlacement": "headInsertEventTap",
                "eventMask": "flagsChanged",
                "accessibilityTrusted": accessibilityTrustedValue()
            ]) { _, new in new }
        )
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
            HotkeyDiagnostics.record(
                "hotkey_activation_detected",
                metadata: registrationMetadata(for: .doubleTapControl).merging([
                    "trigger": "controlDoubleTap"
                ]) { _, new in new }
            )
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
        tapState.withLockUnchecked {
            $0.globalMonitor = monitor
            $0.activeHotkeyType = type
        }

        if monitor != nil {
            HotkeyDiagnostics.record(
                "hotkey_registration_succeeded",
                metadata: registrationMetadata(for: type).merging([
                    "eventMonitor": "NSEventGlobalKeyDown",
                    "exclusiveRegistration": "false",
                    "accessibilityTrusted": accessibilityTrustedValue()
                ]) { _, new in new }
            )
        } else {
            HotkeyDiagnostics.record(
                "hotkey_registration_failed",
                level: .error,
                metadata: registrationMetadata(for: type).merging([
                    "reason": "globalMonitorCreateReturnedNil",
                    "accessibilityTrusted": accessibilityTrustedValue()
                ]) { _, new in new }
            )
        }
    }

    private func handleKeyDown(event: NSEvent, type: HotkeyType) {
        guard matches(event: event, type: type) else { return }
        HotkeyDiagnostics.record(
            "hotkey_activation_detected",
            metadata: registrationMetadata(for: type).merging([
                "trigger": "keyCombo",
                "keyCode": String(event.keyCode),
                "modifiers": modifierDescription(event.modifierFlags)
            ]) { _, new in new }
        )
        Task { @MainActor [weak self] in
            self?.onActivate?()
        }
    }

    private func handleEventTapDisabled(eventType: CGEventType) {
        let (tap, type) = tapState.withLockUnchecked { ($0.eventTap, $0.activeHotkeyType ?? .doubleTapControl) }
        let metadata = registrationMetadata(for: type).merging([
            "eventType": eventTypeName(eventType),
            "willAttemptReenable": tap == nil ? "false" : "true"
        ]) { _, new in new }
        HotkeyDiagnostics.record("hotkey_event_tap_disabled", level: .warning, metadata: metadata)
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        HotkeyDiagnostics.record("hotkey_event_tap_reenabled", metadata: metadata)
    }

    private func registrationMetadata(for type: HotkeyType) -> [String: String] {
        [
            "hotkeyType": type.rawValue,
            "displayName": type.displayName,
            "detectionMode": detectionMode(for: type)
        ]
    }

    private func detectionMode(for type: HotkeyType) -> String {
        switch type {
        case .doubleTapControl:
            return "cgEventTap"
        case .controlOptionD, .controlOptionSpace, .commandShiftD:
            return "globalKeyMonitor"
        }
    }

    private func matches(event: NSEvent, type: HotkeyType) -> Bool {
        let flags = event.modifierFlags
        switch type {
        case .controlOptionD:
            return flags.contains(.control) && flags.contains(.option) &&
                !flags.contains(.command) && !flags.contains(.shift) &&
                event.keyCode == KeyCode.d
        case .controlOptionSpace:
            return flags.contains(.control) && flags.contains(.option) &&
                !flags.contains(.command) && !flags.contains(.shift) &&
                event.keyCode == KeyCode.space
        case .commandShiftD:
            return flags.contains(.command) && flags.contains(.shift) &&
                !flags.contains(.control) && !flags.contains(.option) &&
                event.keyCode == KeyCode.d
        case .doubleTapControl:
            return false
        }
    }

    private func modifierDescription(_ flags: NSEvent.ModifierFlags) -> String {
        var names: [String] = []
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    private func eventTypeName(_ type: CGEventType) -> String {
        switch type {
        case .tapDisabledByTimeout:
            return "tapDisabledByTimeout"
        case .tapDisabledByUserInput:
            return "tapDisabledByUserInput"
        default:
            return String(type.rawValue)
        }
    }

    private func accessibilityTrustedValue() -> String {
        AXIsProcessTrusted() ? "true" : "false"
    }

}
