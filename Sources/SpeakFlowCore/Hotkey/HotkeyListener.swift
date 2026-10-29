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
        /// The current Control press took part in a shortcut or chord, so its
        /// release is not a tap.
        var controlPressDisqualified = false
        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var globalMonitor: Any?
        var localMonitor: Any?
        var activeHotkeyType: HotkeyType?
    }

    private let tapState = OSAllocatedUnfairLock(initialState: DoubleTapState())
    private var registrationGeneration: UInt64 = 0
    private let doubleTapInterval: TimeInterval = 0.4

    public var onActivate: (() -> Void)?

    /// Creates and toggles the flagsChanged event tap. Injected so tests can
    /// observe the tap lifecycle without installing a real WindowServer tap.
    struct EventTapDriver: Sendable {
        /// Creates a flagsChanged event tap that calls `callback` with `refcon` as user info.
        let createTap: @Sendable (_ refcon: UnsafeMutableRawPointer, _ callback: CGEventTapCallBack) -> CFMachPort?
        let setTapEnabled: @Sendable (_ tap: CFMachPort, _ enabled: Bool) -> Void

        static let system = EventTapDriver(
            createTap: { refcon, callback in
                CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .defaultTap,
                    // keyDown is observed only to tell a Control tap from a Control shortcut.
                    eventsOfInterest: CGEventMask(
                        (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
                    ),
                    callback: callback,
                    userInfo: refcon
                )
            },
            setTapEnabled: { tap, enabled in CGEvent.tapEnable(tap: tap, enable: enabled) }
        )
    }

    static let eventTapCallback: CGEventTapCallBack = { (_, eventType, event, refcon) in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let listener = Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            listener.handleEventTapDisabled(eventType: eventType)
            return Unmanaged.passUnretained(event)
        }
        if eventType == .keyDown {
            listener.handleTapKeyDown(event: event)
        } else {
            listener.handleFlagsChanged(event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    struct EventMonitorDriver: Sendable {
        let addGlobal: @MainActor @Sendable (@escaping (NSEvent) -> Void) -> Any?
        let addLocal: @MainActor @Sendable (@escaping (NSEvent) -> NSEvent?) -> Any?
        let remove: @Sendable (Any) -> Void

        static let system = EventMonitorDriver(
            addGlobal: { NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: $0) },
            addLocal: { NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0) },
            remove: { NSEvent.removeMonitor($0) }
        )
    }

    private let eventTapDriver: EventTapDriver
    private let eventMonitorDriver: EventMonitorDriver

    #if DEBUG
    // swiftlint:disable:next identifier_name
    nonisolated(unsafe) static var _testStopHook: (() -> Void)?
    /// Synchronous hook fired immediately when a double-tap is detected,
    /// before the async Task dispatch. Enables deterministic testing.
    // swiftlint:disable:next identifier_name
    var _testDoubleTapDetected: (() -> Void)?
    #endif

    public init() {
        eventTapDriver = .system
        eventMonitorDriver = .system
    }

    init(eventTapDriver: EventTapDriver, eventMonitorDriver: EventMonitorDriver = .system) {
        self.eventTapDriver = eventTapDriver
        self.eventMonitorDriver = eventMonitorDriver
    }

    deinit {
        #if DEBUG
        Self._testStopHook?()
        #endif

        // Clean up event tap and monitors directly without calling the
        // @MainActor-isolated stop() method.  The lock-protected state
        // is safe to access from any isolation context.
        let (tap, source, monitor, local) = tapState.withLockUnchecked { s -> (CFMachPort?, CFRunLoopSource?, Any?, Any?) in
            let result = (s.eventTap, s.runLoopSource, s.globalMonitor, s.localMonitor)
            s.eventTap = nil
            s.runLoopSource = nil
            s.globalMonitor = nil
            s.localMonitor = nil
            return result
        }
        if let tap { eventTapDriver.setTapEnabled(tap, false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let monitor { eventMonitorDriver.remove(monitor) }
        if let local { eventMonitorDriver.remove(local) }
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
        registrationGeneration &+= 1
        #if DEBUG
        Self._testStopHook?()
        #endif

        let (tap, source, monitor, local) = tapState.withLockUnchecked { s -> (CFMachPort?, CFRunLoopSource?, Any?, Any?) in
            let result = (s.eventTap, s.runLoopSource, s.globalMonitor, s.localMonitor)
            s.eventTap = nil
            s.runLoopSource = nil
            s.globalMonitor = nil
            s.localMonitor = nil
            s.activeHotkeyType = nil
            s.lastControlReleaseTime = nil
            s.controlWasDown = false
            return result
        }

        if let tap { eventTapDriver.setTapEnabled(tap, false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let monitor { eventMonitorDriver.remove(monitor) }
        if let local { eventMonitorDriver.remove(local) }

        let metadata = [
            "hadEventTap": tap == nil ? "false" : "true",
            "hadRunLoopSource": source == nil ? "false" : "true",
            "hadGlobalMonitor": monitor == nil ? "false" : "true",
            "hadLocalMonitor": local == nil ? "false" : "true"
        ]
        if tap != nil || source != nil || monitor != nil || local != nil {
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

        let tap = eventTapDriver.createTap(
            Unmanaged.passUnretained(self).toOpaque(),
            Self.eventTapCallback
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
        eventTapDriver.setTapEnabled(tap, true)
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
                "eventMask": "flagsChanged,keyDown",
                "accessibilityTrusted": accessibilityTrustedValue()
            ]) { _, new in new }
        )
    }

    /// Key-down seen by the double-tap tap, passed through untouched. A key
    /// pressed while Control is held makes that press a shortcut, not a tap.
    func handleTapKeyDown(event: CGEvent) {
        tapState.withLockUnchecked { s in
            if s.controlWasDown { s.controlPressDisqualified = true }
        }
    }

    func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let controlDown = flags.contains(.maskControl)

        let hasOtherModifiers = flags.contains(.maskCommand) ||
                                flags.contains(.maskAlternate) ||
                                flags.contains(.maskShift)

        let doubleTapDetected = tapState.withLockUnchecked { s -> Bool in
            // Any other modifier during the press makes it a chord, even if that
            // modifier is released before Control.
            if controlDown && hasOtherModifiers { s.controlPressDisqualified = true }
            guard s.controlWasDown && !controlDown else {
                if controlDown && !s.controlWasDown { s.controlPressDisqualified = hasOtherModifiers }
                s.controlWasDown = controlDown
                return false
            }
            // Control RELEASE. Only an isolated press counts as a tap; a shortcut
            // or chord also breaks any pending first tap.
            let isolated = !s.controlPressDisqualified && !hasOtherModifiers
            s.controlPressDisqualified = false
            guard isolated else {
                s.lastControlReleaseTime = nil
                s.controlWasDown = controlDown
                return false
            }
            s.controlWasDown = controlDown
            let now = Date()
            if let lastRelease = s.lastControlReleaseTime,
               now.timeIntervalSince(lastRelease) < doubleTapInterval {
                s.lastControlReleaseTime = nil
                return true
            }
            s.lastControlReleaseTime = now
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
            enqueueActivation()
        }
    }

    // MARK: - Key Combo Detection (using NSEvent monitor)

    private func startKeyComboDetection(type: HotkeyType) {
        let generation = registrationGeneration
        let monitor = eventMonitorDriver.addGlobal { [weak self] event in
            guard let self, self.registrationGeneration == generation else { return }
            self.handleKeyDown(event: event, type: type)
        }
        let local = eventMonitorDriver.addLocal { [weak self] event in
            guard let self, self.registrationGeneration == generation else { return event }
            self.handleKeyDown(event: event, type: type)
            return event
        }
        tapState.withLockUnchecked {
            $0.globalMonitor = monitor
            $0.localMonitor = local
            $0.activeHotkeyType = type
        }

        if monitor != nil && local != nil {
            HotkeyDiagnostics.record(
                "hotkey_registration_succeeded",
                metadata: registrationMetadata(for: type).merging([
                    "eventMonitor": "NSEventGlobalAndLocalKeyDown",
                    "exclusiveRegistration": "false",
                    "accessibilityTrusted": accessibilityTrustedValue()
                ]) { _, new in new }
            )
        } else {
            HotkeyDiagnostics.record(
                "hotkey_registration_failed",
                level: .error,
                metadata: registrationMetadata(for: type).merging([
                    "reason": monitor == nil ? "globalMonitorCreateReturnedNil" : "localMonitorCreateReturnedNil",
                    "accessibilityTrusted": accessibilityTrustedValue()
                ]) { _, new in new }
            )
        }
    }

    func handleKeyDown(event: NSEvent, type: HotkeyType) {
        // Holding the combination auto-repeats key-down; only a fresh press
        // toggles, or a held hotkey would start, stop, and restart dictation.
        guard !event.isARepeat, matches(event: event, type: type) else { return }
        HotkeyDiagnostics.record(
            "hotkey_activation_detected",
            metadata: registrationMetadata(for: type).merging([
                "trigger": "keyCombo",
                "keyCode": String(event.keyCode),
                "modifiers": modifierDescription(event.modifierFlags)
            ]) { _, new in new }
        )
        enqueueActivation()
    }

    private func enqueueActivation() {
        let generation = registrationGeneration
        Task { @MainActor [weak self] in
            guard let self, self.registrationGeneration == generation else { return }
            self.onActivate?()
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
        eventTapDriver.setTapEnabled(tap, true)
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
