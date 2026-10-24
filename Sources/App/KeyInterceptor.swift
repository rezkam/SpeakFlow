import ApplicationServices
import AppKit
import Carbon.HIToolbox
import OSLog
import SpeakFlowCore
import os

/// Intercepts Escape and Enter keys during recording via CGEvent tap.
///
/// Extracted from RecordingController to isolate the low-level CGEvent tap
/// management into a single-responsibility component. Uses callbacks so
/// RecordingController can wire up the appropriate actions without the
/// interceptor knowing about recording state.
@MainActor
final class KeyInterceptor: KeyIntercepting {
    static let shared = KeyInterceptor()

    /// Called when Escape is pressed. Should cancel recording.
    var onEscapePressed: (() -> Void)?

    /// Called when Enter is pressed. Caller decides action based on recording state.
    var onEnterPressed: (() -> Void)?

    private struct EventTapState: @unchecked Sendable {
        var isActive: Bool = false
        var recordingEventTap: CFMachPort?
        var recordingRunLoopSource: CFRunLoopSource?
        /// PID of the target app. When non-zero, keys are only intercepted
        /// if keyboard focus is in this app (prevents swallowing Escape/Enter
        /// when the user is in Spotlight, password dialogs, etc.).
        var targetPid: pid_t = 0
        /// One-shot Enter capture token. Armed at recording start, consumed by the
        /// first intercepted Enter so subsequent Enters pass through normally.
        var enterCaptureArmed: Bool = false
        /// Keys the tap already swallowed whose handler has not run yet. Set in the
        /// same critical section that decides to swallow, so a swallowed key is
        /// always either delivered (async hop or `stop()`) or deliberately
        /// discarded (`cancel()`), never silently lost.
        var pendingKeys = PendingKeys()
    }

    struct PendingKeys: Equatable {
        var escape = false
        var enter = false
        var isEmpty: Bool { !escape && !enter }
    }

    /// Creates and toggles the system event tap. Injected so tests can observe
    /// the tap lifecycle without installing a real WindowServer tap.
    struct EventTapDriver: Sendable {
        /// Creates a keyDown event tap whose callback receives `refcon` as user info.
        let createTap: @Sendable (_ refcon: UnsafeMutableRawPointer) -> CFMachPort?
        let setTapEnabled: @Sendable (_ tap: CFMachPort, _ enabled: Bool) -> Void

        static let system = EventTapDriver(
            createTap: { refcon in
                let eventMask = (1 << CGEventType.keyDown.rawValue)
                return CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap,
                    options: .defaultTap, eventsOfInterest: CGEventMask(eventMask),
                    callback: { (_, eventType, event, refcon) -> Unmanaged<CGEvent>? in
                        guard let refcon else { return Unmanaged.passRetained(event) }
                        let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
                            interceptor.handleEventTapDisabled(eventType: eventType)
                            return Unmanaged.passRetained(event)
                        }
                        return interceptor.handleKeyEvent(event: event)
                    },
                    userInfo: refcon
                )
            },
            setTapEnabled: { tap, enabled in CGEvent.tapEnable(tap: tap, enable: enabled) }
        )
    }

    private let state = OSAllocatedUnfairLock(initialState: EventTapState())
    private let eventTapDriver: EventTapDriver
    private let keyboardFocusSnapshotProvider: @Sendable (pid_t) -> KeyboardFocusSnapshot
    private let secureInputStatusProvider: () -> Bool
    private let secureInputPollingInterval: Duration
    private var secureInputMonitorTask: Task<Void, Never>?
    private var lastSecureInputEnabled: Bool?

    init(
        eventTapDriver: EventTapDriver = .system,
        keyboardFocusSnapshotProvider: @escaping @Sendable (pid_t) -> KeyboardFocusSnapshot = KeyInterceptor.keyboardFocusSnapshot,
        isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        secureInputPollingInterval: Duration = .seconds(1)
    ) {
        self.eventTapDriver = eventTapDriver
        self.keyboardFocusSnapshotProvider = keyboardFocusSnapshotProvider
        secureInputStatusProvider = isSecureInputEnabled
        self.secureInputPollingInterval = secureInputPollingInterval
    }

#if DEBUG
    /// Creates an isolated interceptor with a deterministic keyboard-focus source.
    @MainActor
    init(testKeyboardFocusSnapshotProvider: @escaping @Sendable (pid_t) -> KeyboardFocusSnapshot) {
        eventTapDriver = .system
        keyboardFocusSnapshotProvider = testKeyboardFocusSnapshotProvider
        secureInputStatusProvider = { IsSecureEventInputEnabled() }
        secureInputPollingInterval = .seconds(1)
    }
#endif

    // MARK: - Start / Stop

    func start(targetPid: pid_t) {
        // A tap still registered from an earlier recording is reused, but the
        // new recording must own it: its target app and a fresh Enter token.
        let previousTargetPid = state.withLockUnchecked { s -> pid_t? in
            guard s.recordingEventTap != nil else { return nil }
            let previous = s.targetPid
            s.targetPid = targetPid
            s.enterCaptureArmed = true
            return previous
        }
        if let previousTargetPid {
            HotkeyDiagnostics.record(
                "key_interceptor_registration_rearmed_already_active",
                level: .warning,
                metadata: [
                    "targetPid": String(targetPid),
                    "previousTargetPid": String(previousTargetPid)
                ]
            )
            return
        }
        state.withLockUnchecked {
            $0.targetPid = targetPid
            $0.enterCaptureArmed = true
        }
        let secureInputEnabled = secureInputStatusProvider()
        HotkeyDiagnostics.record(
            "key_interceptor_registration_started",
            metadata: [
                "targetPid": String(targetPid),
                "accessibilityTrusted": AXIsProcessTrusted() ? "true" : "false",
                "secureInputEnabled": secureInputEnabled ? "true" : "false"
            ]
        )
        if secureInputEnabled {
            recordSecureInputDetected(targetPid: targetPid, phase: "start")
        }

        let tap = eventTapDriver.createTap(Unmanaged.passUnretained(self).toOpaque())

        guard let tap else {
            handleEventTapUnavailable(reason: "Could not create CGEvent tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source else {
            CFMachPortInvalidate(tap)
            handleEventTapUnavailable(reason: "Could not create CGEvent tap run loop source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        eventTapDriver.setTapEnabled(tap, true)
        state.withLockUnchecked {
            $0.recordingEventTap = tap
            $0.recordingRunLoopSource = source
            $0.isActive = true
        }
        startSecureInputMonitoring(targetPid: targetPid, initialState: secureInputEnabled)
        HotkeyDiagnostics.record(
            "key_interceptor_registration_succeeded",
            metadata: [
                "targetPid": String(targetPid),
                "eventTap": "cgSessionEventTap",
                "tapPlacement": "headInsertEventTap",
                "eventMask": "keyDown",
                "accessibilityTrusted": AXIsProcessTrusted() ? "true" : "false"
            ]
        )
    }

    func stop() {
        let pending = tearDown(phase: "stop")
        deliver(pending, phase: "stop")
    }

    func cancel() {
        let pending = tearDown(phase: "cancel")
        if !pending.isEmpty {
            HotkeyDiagnostics.record(
                "key_interceptor_pending_keys_discarded",
                metadata: ["escape": String(pending.escape), "enter": String(pending.enter)]
            )
        }
    }

    /// Removes the tap and returns keys that were swallowed but not yet delivered.
    private func tearDown(phase: String) -> PendingKeys {
        let (tap, source, targetPid, pending) = state.withLockUnchecked {
            s -> (CFMachPort?, CFRunLoopSource?, pid_t, PendingKeys) in
            let result = (s.recordingEventTap, s.recordingRunLoopSource, s.targetPid, s.pendingKeys)
            s.isActive = false
            s.targetPid = 0
            s.enterCaptureArmed = false
            s.pendingKeys = PendingKeys()
            s.recordingEventTap = nil
            s.recordingRunLoopSource = nil
            return result
        }
        recordSecureInputTransitionIfNeeded(targetPid: targetPid, phase: "stop")
        stopSecureInputMonitoring()
        if let tap { eventTapDriver.setTapEnabled(tap, false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        // Disabling alone leaves the tap registered with the WindowServer for the
        // life of the process; invalidating the port removes it.
        if let tap { CFMachPortInvalidate(tap) }
        let metadata = [
            "targetPid": String(targetPid),
            "phase": phase,
            "hadEventTap": tap == nil ? "false" : "true",
            "hadRunLoopSource": source == nil ? "false" : "true"
        ]
        if tap != nil || source != nil {
            HotkeyDiagnostics.record("key_interceptor_registration_stopped", metadata: metadata)
        } else {
            HotkeyDiagnostics.record("key_interceptor_registration_stop_noop", level: .debug, metadata: metadata)
        }
        return pending
    }

    /// Runs on the main actor after the tap swallowed a key. Takes whatever is
    /// still pending; if `stop()` or `cancel()` already took it, this is a no-op.
    private func deliverPendingKeys() {
        let pending = state.withLockUnchecked { s -> PendingKeys in
            let pending = s.pendingKeys
            s.pendingKeys = PendingKeys()
            return pending
        }
        deliver(pending, phase: "handler")
    }

    private func deliver(_ pending: PendingKeys, phase: String) {
        if pending.escape {
            HotkeyDiagnostics.record("key_interceptor_escape_handler_invoked", metadata: ["phase": phase])
            onEscapePressed?()
        }
        if pending.enter {
            HotkeyDiagnostics.record("key_interceptor_enter_handler_invoked", metadata: ["phase": phase])
            onEnterPressed?()
        }
    }

    private func startSecureInputMonitoring(targetPid: pid_t, initialState: Bool) {
        stopSecureInputMonitoring()
        lastSecureInputEnabled = initialState
        secureInputMonitorTask = Task { @MainActor [weak self] in
            guard let interval = self?.secureInputPollingInterval else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.recordSecureInputTransitionIfNeeded(targetPid: targetPid, phase: "monitor")
            }
        }
    }

    private func stopSecureInputMonitoring() {
        secureInputMonitorTask?.cancel()
        secureInputMonitorTask = nil
        lastSecureInputEnabled = nil
    }

    private func recordSecureInputTransitionIfNeeded(targetPid: pid_t, phase: String) {
        guard let previousState = lastSecureInputEnabled else { return }
        let currentState = secureInputStatusProvider()
        guard currentState != previousState else { return }
        lastSecureInputEnabled = currentState

        if currentState {
            recordSecureInputDetected(targetPid: targetPid, phase: phase)
        } else {
            HotkeyDiagnostics.record(
                "key_interceptor_secure_input_cleared",
                metadata: [
                    "targetPid": String(targetPid),
                    "phase": phase
                ]
            )
        }
    }

    private func recordSecureInputDetected(targetPid: pid_t, phase: String) {
        HotkeyDiagnostics.record(
            "key_interceptor_secure_input_detected",
            level: .warning,
            metadata: [
                "targetPid": String(targetPid),
                "enterCaptureAvailable": "false",
                "escapeCaptureAvailable": "false",
                "phase": phase
            ]
        )
    }

    private func handleEventTapUnavailable(reason: String) {
        stopSecureInputMonitoring()
        let targetPid = state.withLockUnchecked { $0.targetPid }
        HotkeyDiagnostics.record(
            "key_interceptor_registration_failed",
            level: .error,
            metadata: [
                "targetPid": String(targetPid),
                "reason": reason,
                "accessibilityTrusted": AXIsProcessTrusted() ? "true" : "false",
                "fallback": "none",
                "failureMode": "failClosedBecausePassiveMonitorsCannotSuppressEnter"
            ]
        )
        state.withLockUnchecked {
            $0.isActive = false
            $0.targetPid = 0
            $0.enterCaptureArmed = false
            $0.pendingKeys = PendingKeys()
            $0.recordingEventTap = nil
            $0.recordingRunLoopSource = nil
        }
    }

    // MARK: - Event Handler

    private nonisolated func handleKeyEvent(event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard Self.isInterceptedKey(keyCode) else { return Unmanaged.passRetained(event) }

        let (isActive, targetPid) = state.withLockUnchecked { ($0.isActive, $0.targetPid) }
        guard isActive else {
            HotkeyDiagnostics.record(
                "key_interceptor_key_passed_inactive",
                level: .debug,
                metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
            )
            return Unmanaged.passRetained(event)
        }

        // Only intercept Escape/Enter when the target app has keyboard focus.
        // If the user is in Spotlight, a password dialog, or another app,
        // let the key pass through so it acts on that UI instead.
        if targetPid != 0 {
            let focus = keyboardFocusSnapshotProvider(targetPid)
            if !focus.isInTargetApp {
                HotkeyDiagnostics.record(
                    "key_interceptor_key_passed_focus_mismatch",
                    metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
                        .merging(focus.metadata) { _, new in new }
                )
                return Unmanaged.passRetained(event)
            }
        }

        switch keyCode {
        case 53:
            let captured = state.withLockUnchecked { s -> Bool in
                // Interception may have stopped while focus was being checked.
                guard s.isActive else { return false }
                s.pendingKeys.escape = true
                return true
            }
            guard captured else { return Unmanaged.passRetained(event) }
            HotkeyDiagnostics.record(
                "key_interceptor_escape_captured",
                metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
            )
            scheduleDelivery()
            return nil
        case 36, 76:
            guard consumeEnterCaptureToken() else {
                // Enter is one-shot: after the first captured Enter, all subsequent
                // Enter presses pass through to the app unmodified.
                HotkeyDiagnostics.record(
                    "key_interceptor_enter_passed_capture_not_armed",
                    metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
                )
                return Unmanaged.passRetained(event)
            }
            HotkeyDiagnostics.record(
                "key_interceptor_enter_captured",
                metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
            )
            scheduleDelivery()
            return nil
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private nonisolated func scheduleDelivery() {
        Task { @MainActor [weak self] in self?.deliverPendingKeys() }
    }

    /// Consumes the one-shot Enter token and marks the Enter pending delivery
    /// in one critical section.
    private nonisolated func consumeEnterCaptureToken() -> Bool {
        state.withLockUnchecked { state in
            guard state.isActive, state.enterCaptureArmed else { return false }
            state.enterCaptureArmed = false
            state.pendingKeys.enter = true
            return true
        }
    }

    private nonisolated func handleEventTapDisabled(eventType: CGEventType) {
        let (tap, targetPid) = state.withLockUnchecked { ($0.recordingEventTap, $0.targetPid) }
        let metadata = [
            "targetPid": String(targetPid),
            "eventType": Self.eventTypeName(eventType),
            "willAttemptReenable": tap == nil ? "false" : "true"
        ]
        HotkeyDiagnostics.record("key_interceptor_event_tap_disabled", level: .warning, metadata: metadata)
        guard let tap else { return }
        eventTapDriver.setTapEnabled(tap, true)
        HotkeyDiagnostics.record("key_interceptor_event_tap_reenabled", metadata: metadata)
    }

    /// Checks whether keyboard focus is currently in the specified app.
    /// Uses the system-wide AX focused element to detect focus, catching
    /// system overlays that steal focus without changing the frontmost app.
    struct KeyboardFocusSnapshot: Sendable {
        let isInTargetApp: Bool
        let focusedPid: pid_t?
        let frontmostPid: pid_t?
        let source: String

        var metadata: [String: String] {
            [
                "focusSource": source,
                "focusedPid": focusedPid.map(String.init) ?? "nil",
                "frontmostPid": frontmostPid.map(String.init) ?? "nil"
            ]
        }
    }

    private nonisolated static func keyboardFocusSnapshot(targetPid: pid_t) -> KeyboardFocusSnapshot {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
           let element = focusedElement,
           CFGetTypeID(element) == AXUIElementGetTypeID() {
            let focusedElementAX = unsafeDowncast(element, to: AXUIElement.self)
            var focusedPid: pid_t = 0
            if AXUIElementGetPid(focusedElementAX, &focusedPid) == .success {
                return KeyboardFocusSnapshot(
                    isInTargetApp: focusedPid == targetPid,
                    focusedPid: focusedPid,
                    frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    source: "accessibilityFocusedElement"
                )
            }
        }
        // Fallback: frontmost app check
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return KeyboardFocusSnapshot(
                isInTargetApp: false,
                focusedPid: nil,
                frontmostPid: nil,
                source: "none"
            )
        }
        return KeyboardFocusSnapshot(
            isInTargetApp: frontmost.processIdentifier == targetPid,
            focusedPid: nil,
            frontmostPid: frontmost.processIdentifier,
            source: "frontmostApplication"
        )
    }

    private nonisolated static func isInterceptedKey(_ keyCode: Int64) -> Bool {
        keyCode == 53 || keyCode == 36 || keyCode == 76
    }

    private nonisolated static func keyMetadata(keyCode: Int64, targetPid: pid_t) -> [String: String] {
        [
            "keyCode": String(keyCode),
            "keyName": keyName(for: keyCode),
            "targetPid": String(targetPid)
        ]
    }

    private nonisolated static func keyName(for keyCode: Int64) -> String {
        switch keyCode {
        case 53:
            return "escape"
        case 36, 76:
            return "enter"
        default:
            return "unknown"
        }
    }

    private nonisolated static func eventTypeName(_ type: CGEventType) -> String {
        switch type {
        case .tapDisabledByTimeout:
            return "tapDisabledByTimeout"
        case .tapDisabledByUserInput:
            return "tapDisabledByUserInput"
        default:
            return String(type.rawValue)
        }
    }
}

#if DEBUG
extension KeyInterceptor {
    // swiftlint:disable:next identifier_name
    /// Consumes only the token; the Enter is not left pending for delivery.
    nonisolated func _testConsumeEnterCaptureToken() -> Bool {
        let consumed = consumeEnterCaptureToken()
        state.withLockUnchecked { $0.pendingKeys.enter = false }
        return consumed
    }

    // swiftlint:disable:next identifier_name
    @MainActor func _testArmEnterCaptureForTests(active: Bool = true, targetPid: pid_t = 0) {
        state.withLockUnchecked {
            $0.isActive = active
            $0.targetPid = targetPid
            $0.enterCaptureArmed = true
        }
    }

    // swiftlint:disable:next identifier_name
    nonisolated func _testHandleKeyEventForTests(keyCode: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            return false
        }
        event.type = .keyDown
        let result = handleKeyEvent(event: event)
        if let result {
            result.release()
            return false
        }
        return true
    }

    // swiftlint:disable:next identifier_name
    @MainActor var _testIsEnterCaptureArmed: Bool {
        state.withLockUnchecked { $0.enterCaptureArmed }
    }

    // swiftlint:disable:next identifier_name
    @MainActor var _testIsActive: Bool {
        state.withLockUnchecked { $0.isActive }
    }

    // swiftlint:disable:next identifier_name
    @MainActor func _testHandleEventTapUnavailableForTests() {
        handleEventTapUnavailable(reason: "Test event tap failure")
    }

    // swiftlint:disable:next identifier_name
    @MainActor func _testStartSecureInputMonitoring(targetPid: pid_t, initialState: Bool) {
        startSecureInputMonitoring(targetPid: targetPid, initialState: initialState)
    }
}
#endif
