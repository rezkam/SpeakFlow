import ApplicationServices
import AppKit
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
        /// Invalidates focus observations made by an earlier registration.
        var registrationGeneration: UInt64 = 0
        var recordingEventTap: CFMachPort?
        var recordingTapThread: EventTapThread?
        /// PID of the captured app. Enter requires focus in this app;
        /// plain Escape cancels from any app while this recording is active.
        var targetPid: pid_t = 0
        /// Bundle identifier of the target app, so focus in its helper processes
        /// or in a relaunched instance still counts as the target.
        var targetApplicationURL: URL?
        /// One-shot Enter capture token. Armed at recording start, consumed by the
        /// first intercepted Enter so subsequent Enters pass through normally.
        var enterCaptureArmed: Bool = false
        /// Pending model loading observes Enter without swallowing it or arming submit.
        var pendingStart = false
        /// Keys the tap already swallowed whose handler has not run yet. Set in the
        /// same critical section that decides to swallow, so a swallowed key is
        /// always either delivered (async hop or `stop()`) or deliberately
        /// discarded (`cancel()`), never silently lost.
        var pendingKeys = PendingKeys()
        /// Hardware key-down events the tap received since registration.
        var tapKeyDowns: UInt32 = 0
        /// Synthetic key-down events (SpeakFlow's own typing) the tap received.
        var tapSyntheticKeyDowns: UInt32 = 0
        /// System key-down counter when the tap was registered; nil when not registered.
        var systemKeyDownsAtStart: UInt32?
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
                    callback: KeyInterceptor.eventTapCallback,
                    userInfo: refcon
                )
            },
            setTapEnabled: { tap, enabled in CGEvent.tapEnable(tap: tap, enable: enabled) }
        )
    }

    nonisolated static let eventTapCallback: CGEventTapCallBack = { @Sendable (_, eventType, event, refcon) in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            interceptor.handleEventTapDisabled(eventType: eventType)
            return Unmanaged.passUnretained(event)
        }
        return interceptor.handleKeyEvent(event: event)
    }

    private let state = OSAllocatedUnfairLock(initialState: EventTapState())
    private let eventTapDriver: EventTapDriver
    private let keyboardFocusSnapshotProvider: @Sendable (_ targetPid: pid_t, _ targetApplicationURL: URL?) -> KeyboardFocusSnapshot
    private let bundleIdentifierLookup: @Sendable (pid_t) -> String?
    private let applicationURLLookup: @Sendable (pid_t) -> URL?
    private let secureInputOwnerProvider: () -> pid_t?
    private let systemKeyDownCounter: @Sendable () -> UInt32
    private let secureInputPollingInterval: Duration
    private var secureInputMonitorTask: Task<Void, Never>?
    /// Secure-input holder last observed while monitoring; nil when not monitoring.
    private var secureInputObservation: SecureInputObservation?

    private struct SecureInputObservation {
        var owner: pid_t?
    }

    init(
        eventTapDriver: EventTapDriver = .system,
        focusQuery: @escaping @Sendable () -> FocusQueryResult = KeyInterceptor.queryKeyboardFocus,
        bundleIdentifierLookup: @escaping @Sendable (pid_t) -> String? = {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        },
        applicationURLLookup: @escaping @Sendable (pid_t) -> URL? = ApplicationOwnership.applicationURL,
        secureInputOwner: @escaping () -> pid_t? = KeyInterceptor.currentSecureInputOwner,
        secureInputPollingInterval: Duration = .seconds(1),
        systemKeyDownCounter: @escaping @Sendable () -> UInt32 = KeyInterceptor.currentSystemKeyDownCount
    ) {
        self.systemKeyDownCounter = systemKeyDownCounter
        self.eventTapDriver = eventTapDriver
        self.bundleIdentifierLookup = bundleIdentifierLookup
        self.applicationURLLookup = applicationURLLookup
        keyboardFocusSnapshotProvider = { targetPid, targetApplicationURL in
            Self.focusSnapshot(
                focusQuery(),
                targetPid: targetPid,
                targetApplicationURL: targetApplicationURL,
                applicationURLLookup: applicationURLLookup
            )
        }
        secureInputOwnerProvider = secureInputOwner
        self.secureInputPollingInterval = secureInputPollingInterval
    }

#if DEBUG
    /// Creates an isolated interceptor with a deterministic keyboard-focus source.
    @MainActor
    init(testKeyboardFocusSnapshotProvider: @escaping @Sendable (pid_t) -> KeyboardFocusSnapshot) {
        eventTapDriver = .system
        keyboardFocusSnapshotProvider = { targetPid, _ in testKeyboardFocusSnapshotProvider(targetPid) }
        bundleIdentifierLookup = { _ in nil }
        applicationURLLookup = { _ in nil }
        secureInputOwnerProvider = Self.currentSecureInputOwner
        systemKeyDownCounter = Self.currentSystemKeyDownCount
        secureInputPollingInterval = .seconds(1)
    }
#endif

    // MARK: - Start / Stop

    func start(targetPid: pid_t) { register(targetPid: targetPid, pendingStart: false) }

    @discardableResult
    func startPending(targetPid: pid_t) -> Bool {
        register(targetPid: targetPid, pendingStart: true)
        return state.withLockUnchecked { $0.isActive }
    }

    private func register(targetPid: pid_t, pendingStart: Bool) {
        let targetApplicationURL = targetPid == 0 ? nil : applicationURLLookup(targetPid)
        // A tap still registered from an earlier recording is reused, but the
        // new recording must own it: its target app and a fresh Enter token.
        let previousTargetPid = state.withLockUnchecked { s -> pid_t? in
            s.registrationGeneration &+= 1
            guard s.recordingEventTap != nil else { return nil }
            let previous = s.targetPid
            s.targetPid = targetPid
            s.targetApplicationURL = targetApplicationURL
            s.enterCaptureArmed = !pendingStart
            s.pendingStart = pendingStart
            s.tapKeyDowns = 0
            s.tapSyntheticKeyDowns = 0
            s.systemKeyDownsAtStart = systemKeyDownCounter()
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
            $0.targetApplicationURL = targetApplicationURL
            $0.enterCaptureArmed = !pendingStart
            $0.pendingStart = pendingStart
        }
        let secureInputOwner = secureInputOwnerProvider()
        HotkeyDiagnostics.record(
            "key_interceptor_registration_started",
            metadata: [
                "targetPid": String(targetPid),
                "accessibilityTrusted": AXIsProcessTrusted() ? "true" : "false",
                "secureInputOwnerPid": secureInputOwner.map(String.init) ?? "none"
            ]
        )
        if let secureInputOwner {
            recordSecureInputDetected(owner: secureInputOwner, targetPid: targetPid, phase: "start")
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
        let tapThread = EventTapThread(source: source)
        // Publish the registration before the tap can deliver its first event
        // on the tap thread.
        let systemKeyDowns = systemKeyDownCounter()
        state.withLockUnchecked {
            $0.recordingEventTap = tap
            $0.recordingTapThread = tapThread
            $0.isActive = true
            $0.tapKeyDowns = 0
            $0.tapSyntheticKeyDowns = 0
            $0.systemKeyDownsAtStart = systemKeyDowns
        }
        tapThread.start(name: "SpeakFlow.KeyInterceptor.EventTap")
        eventTapDriver.setTapEnabled(tap, true)
        startSecureInputMonitoring(targetPid: targetPid, initialOwner: secureInputOwner)
        HotkeyDiagnostics.record(
            "key_interceptor_registration_succeeded",
            metadata: [
                "targetPid": String(targetPid),
                "eventTap": "cgSessionEventTap",
                "tapPlacement": "headInsertEventTap",
                "tapRunLoop": "dedicatedThread",
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
        let systemKeyDownsAtStop = systemKeyDownCounter()
        let registration = state.withLockUnchecked { s -> EndedRegistration in
            let result = EndedRegistration(
                tap: s.recordingEventTap,
                tapThread: s.recordingTapThread,
                targetPid: s.targetPid,
                pending: s.pendingKeys,
                keyCounts: s.systemKeyDownsAtStart.map {
                    KeyDownCounts(
                        system: systemKeyDownsAtStop &- $0,
                        tap: s.tapKeyDowns,
                        tapSynthetic: s.tapSyntheticKeyDowns
                    )
                }
            )
            s.tapKeyDowns = 0
            s.tapSyntheticKeyDowns = 0
            s.systemKeyDownsAtStart = nil
            s.isActive = false
            s.targetPid = 0
            s.targetApplicationURL = nil
            s.enterCaptureArmed = false
            s.pendingKeys = PendingKeys()
            s.recordingEventTap = nil
            s.recordingTapThread = nil
            return result
        }
        let (tap, tapThread, targetPid) = (registration.tap, registration.tapThread, registration.targetPid)
        recordSecureInputTransitionIfNeeded(targetPid: targetPid, phase: "stop")
        stopSecureInputMonitoring()
        if let tap { eventTapDriver.setTapEnabled(tap, false) }
        tapThread?.stop()
        // Disabling alone leaves the tap registered with the WindowServer for the
        // life of the process; invalidating the port removes it.
        if let tap { CFMachPortInvalidate(tap) }
        let metadata = [
            "targetPid": String(targetPid),
            "phase": phase,
            "hadEventTap": tap == nil ? "false" : "true",
            "hadTapThread": tapThread == nil ? "false" : "true"
        ]
        if tap != nil || tapThread != nil {
            HotkeyDiagnostics.record("key_interceptor_registration_stopped", metadata: metadata)
        } else {
            HotkeyDiagnostics.record("key_interceptor_registration_stop_noop", level: .debug, metadata: metadata)
        }
        if let keyCounts = registration.keyCounts {
            recordKeyDownCounts(keyCounts, targetPid: targetPid, phase: phase)
        }
        return registration.pending
    }

    private struct EndedRegistration {
        let tap: CFMachPort?
        let tapThread: EventTapThread?
        let targetPid: pid_t
        let pending: PendingKeys
        let keyCounts: KeyDownCounts?
    }

    private struct KeyDownCounts {
        /// Key-down events the HID system produced while the tap was registered.
        let system: UInt32
        /// Hardware key-down events the tap received in the same window.
        let tap: UInt32
        /// Synthetic key-down events (SpeakFlow's typing) the tap received.
        let tapSynthetic: UInt32
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
            $0.targetApplicationURL = nil
            $0.enterCaptureArmed = false
            $0.pendingStart = false
            $0.pendingKeys = PendingKeys()
            $0.recordingEventTap = nil
            $0.recordingTapThread = nil
        }
    }

    // MARK: - Event Handler

    private nonisolated func handleKeyEvent(event: CGEvent) -> Unmanaged<CGEvent>? {
        countTapKeyDown(event)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard Self.isInterceptedKey(keyCode) else { return Unmanaged.passUnretained(event) }
        guard !isModifiedKey(event, keyCode: keyCode) else { return Unmanaged.passUnretained(event) }

        let (isActive, targetPid, targetApplicationURL, generation) = state.withLockUnchecked {
            ($0.isActive, $0.targetPid, $0.targetApplicationURL, $0.registrationGeneration)
        }
        guard isActive else {
            HotkeyDiagnostics.record(
                "key_interceptor_key_passed_inactive",
                level: .debug,
                metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
            )
            return Unmanaged.passUnretained(event)
        }

        // Cancellation is global during a captured recording. Only submission
        // depends on keyboard focus; an unavailable AX query must not block Escape.
        guard targetPid != 0, !observePendingStartEnter(keyCode, generation: generation) else {
            return Unmanaged.passUnretained(event)
        }
        if keyCode != 53,
           !isFocusInTarget(keyCode: keyCode, targetPid: targetPid, targetApplicationURL: targetApplicationURL) {
            return Unmanaged.passUnretained(event)
        }

        switch keyCode {
        case 53:
            let captured = state.withLockUnchecked { s -> Bool in
                // The registration may have been retired after the event snapshot.
                guard s.isActive, s.registrationGeneration == generation else { return false }
                s.pendingKeys.escape = true
                return true
            }
            guard captured else { return Unmanaged.passUnretained(event) }
            HotkeyDiagnostics.record(
                "key_interceptor_escape_captured",
                metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
            )
            scheduleDelivery()
            return nil
        case 36, 76:
            guard consumeEnterCaptureToken(generation: generation) else {
                // Enter is one-shot: after the first captured Enter, all subsequent
                // Enter presses pass through to the app unmodified.
                HotkeyDiagnostics.record(
                    "key_interceptor_enter_passed_capture_not_armed",
                    metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
                )
                return Unmanaged.passUnretained(event)
            }
            HotkeyDiagnostics.record(
                "key_interceptor_enter_captured",
                metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
            )
            scheduleDelivery()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private nonisolated func observePendingStartEnter(_ keyCode: Int64, generation: UInt64) -> Bool {
        guard keyCode == 36 || keyCode == 76 else { return false }
        let observed = state.withLockUnchecked { value -> Bool in
            guard value.isActive, value.registrationGeneration == generation, value.pendingStart else { return false }
            value.pendingKeys.enter = true
            return true
        }
        if observed { scheduleDelivery() }
        return observed
    }

    /// Only intercept Enter when the target app has keyboard focus.
    /// If the user is in Spotlight, a password dialog, or another app,
    /// the key passes through so it acts on that UI instead.
    private nonisolated func isFocusInTarget(keyCode: Int64, targetPid: pid_t, targetApplicationURL: URL?) -> Bool {
        // No target app: there is no recording field to protect, so the key
        // belongs to whatever has focus.
        guard targetPid != 0 else {
            HotkeyDiagnostics.record(
                "key_interceptor_key_passed_no_target",
                metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
            )
            return false
        }
        let focus = keyboardFocusSnapshotProvider(targetPid, targetApplicationURL)
        guard !focus.isInTargetApp else { return true }
        HotkeyDiagnostics.record(
            "key_interceptor_key_passed_focus_mismatch",
            metadata: Self.keyMetadata(keyCode: keyCode, targetPid: targetPid)
                .merging(focus.metadata) { _, new in new }
        )
        return false
    }

    /// Shift/Option/Command/Control+Enter mean something else to the app
    /// (newline, alternate submit), so they are never turned into a plain
    /// submit and do not consume the one-shot token. Same for Escape.
    private nonisolated func isModifiedKey(_ event: CGEvent, keyCode: Int64) -> Bool {
        guard !event.flags.isDisjoint(with: Self.commandModifiers) else { return false }
        HotkeyDiagnostics.record(
            "key_interceptor_key_passed_modified",
            metadata: Self.keyMetadata(keyCode: keyCode, targetPid: state.withLockUnchecked { $0.targetPid })
                .merging(["flags": String(event.flags.rawValue)]) { _, new in new }
        )
        return true
    }

    /// Hardware input carries the HID system source state; SpeakFlow's own
    /// typing uses a session source and must not count as a seen hardware key.
    private nonisolated func countTapKeyDown(_ event: CGEvent) {
        let isHardware = event.getIntegerValueField(.eventSourceStateID)
            == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        state.withLockUnchecked { s in
            guard s.systemKeyDownsAtStart != nil else { return }
            if isHardware { s.tapKeyDowns &+= 1 } else { s.tapSyntheticKeyDowns &+= 1 }
        }
    }

    private nonisolated func scheduleDelivery() {
        Task { @MainActor [weak self] in self?.deliverPendingKeys() }
    }

    /// Consumes the one-shot Enter token and marks the Enter pending delivery
    /// in one critical section.
    private nonisolated func consumeEnterCaptureToken(generation: UInt64) -> Bool {
        state.withLockUnchecked { state in
            guard state.isActive, state.registrationGeneration == generation,
                  state.enterCaptureArmed else { return false }
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

// MARK: - Secure Input Diagnostics

extension KeyInterceptor {
    private func startSecureInputMonitoring(targetPid: pid_t, initialOwner: pid_t?) {
        stopSecureInputMonitoring()
        secureInputObservation = SecureInputObservation(owner: initialOwner)
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
        secureInputObservation = nil
    }

    private func recordSecureInputTransitionIfNeeded(targetPid: pid_t, phase: String) {
        guard let previous = secureInputObservation else { return }
        let currentOwner = secureInputOwnerProvider()
        guard currentOwner != previous.owner else { return }
        secureInputObservation = SecureInputObservation(owner: currentOwner)

        if let currentOwner {
            recordSecureInputDetected(owner: currentOwner, targetPid: targetPid, phase: phase)
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

    /// Records which process holds Secure Event Input. While the target app
    /// itself holds it, the tap is expected not to see Enter or Escape. A
    /// different holder is recorded as context only: capture was observed to
    /// keep working in other apps while a background app held secure input.
    private func recordSecureInputDetected(owner: pid_t, targetPid: pid_t, phase: String) {
        let targetApplicationURL = state.withLockUnchecked { $0.targetApplicationURL }
        let ownerBundle = bundleIdentifierLookup(owner)
        let ownerIsTargetApp = targetPid != 0 && (
            owner == targetPid
                || ApplicationOwnership.matches(target: targetApplicationURL, candidate: applicationURLLookup(owner))
        )
        HotkeyDiagnostics.record(
            "key_interceptor_secure_input_detected",
            level: ownerIsTargetApp ? .warning : .info,
            metadata: [
                "targetPid": String(targetPid),
                "ownerPid": String(owner),
                "ownerBundleIdentifier": ownerBundle ?? "unknown",
                "ownerIsTargetApp": String(ownerIsTargetApp),
                "phase": phase
            ]
        )
    }
}

// MARK: - Keyboard Focus

extension KeyInterceptor {
    /// Longest a focus query may block the tap thread. The default Accessibility
    /// messaging timeout is several seconds, longer than the WindowServer waits
    /// for an active tap before disabling it.
    private nonisolated static let focusQueryTimeoutSeconds: Float = 0.25

    /// Raw keyboard-focus owners reported by Accessibility.
    struct FocusQueryResult: Sendable {
        /// Owner of the focused UI element. Catches overlays (Spotlight, password
        /// dialogs) that take keyboard focus without changing the focused app.
        let focusedPid: pid_t?
        let focusedAppPid: pid_t?
        let source: String
    }

    /// Runs on the tap thread, so it uses Accessibility only (no AppKit).
    nonisolated static func queryKeyboardFocus() -> FocusQueryResult {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, focusQueryTimeoutSeconds)
        let focusedAppPid = pid(ofAttribute: kAXFocusedApplicationAttribute, of: systemWide)
        if let focusedPid = pid(ofAttribute: kAXFocusedUIElementAttribute, of: systemWide) {
            return FocusQueryResult(
                focusedPid: focusedPid,
                focusedAppPid: focusedAppPid,
                source: "accessibilityFocusedElement"
            )
        }
        // The focused app did not answer in time or exposes no focused element.
        return FocusQueryResult(
            focusedPid: nil,
            focusedAppPid: focusedAppPid,
            source: focusedAppPid == nil ? "none" : "accessibilityFocusedApplication"
        )
    }

    /// Decides whether keyboard focus belongs to the target app.
    nonisolated static func focusSnapshot(
        _ query: FocusQueryResult,
        targetPid: pid_t,
        targetApplicationURL: URL?,
        applicationURLLookup: (pid_t) -> URL?
    ) -> KeyboardFocusSnapshot {
        guard let ownerPid = query.focusedPid ?? query.focusedAppPid else {
            return KeyboardFocusSnapshot(isInTargetApp: false, focusedPid: nil, frontmostPid: nil, source: query.source)
        }
        // Same rule TextInserter uses before typing: the target app's helper
        // processes and a relaunched instance are still the target app.
        let isInTargetApp = ownerPid == targetPid
            || ApplicationOwnership.matches(
                target: targetApplicationURL,
                candidate: applicationURLLookup(ownerPid)
            )
        return KeyboardFocusSnapshot(
            isInTargetApp: isInTargetApp,
            focusedPid: query.focusedPid,
            frontmostPid: query.focusedAppPid,
            source: query.source
        )
    }

    private nonisolated static func pid(ofAttribute attribute: String, of element: AXUIElement) -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid) == .success else { return nil }
        return pid
    }

    /// Process the window server reports as holding Secure Event Input, if any.
    /// Unlike Carbon's `IsSecureEventInputEnabled()`, which is true while any
    /// process holds it, this names the holder so it can be compared with the target.
    nonisolated static func currentSecureInputOwner() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
              pid > 0 else { return nil }
        return pid
    }

    /// Key-down events the HID system has produced since boot. Counts keys the
    /// tap never receives, so the two can be compared.
    nonisolated static func currentSystemKeyDownCount() -> UInt32 {
        CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
    }

    private nonisolated static let commandModifiers: CGEventFlags = [
        .maskShift, .maskAlternate, .maskCommand, .maskControl
    ]
}

// MARK: - Missed-Key Diagnostics

extension KeyInterceptor {
    /// Keys that never reach the tap (secure input held by the target app, a
    /// tap disabled by the system) cannot be logged by the tap itself. Compare
    /// what the tap saw with the system-wide count so they leave a trace.
    private func recordKeyDownCounts(_ counts: KeyDownCounts, targetPid: pid_t, phase: String) {
        HotkeyDiagnostics.record(
            "key_interceptor_session_summary",
            metadata: [
                "targetPid": String(targetPid),
                "phase": phase,
                "systemKeyDowns": String(counts.system),
                "tapKeyDowns": String(counts.tap),
                "tapSyntheticKeyDowns": String(counts.tapSynthetic)
            ]
        )
        // One key pressed exactly at registration or teardown can land on one
        // side only, because the two counts are sampled a moment apart.
        // The HID counter includes SpeakFlow's own synthetic typing, so compare
        // it with everything the tap saw.
        let seen = counts.tap &+ counts.tapSynthetic
        guard counts.system > seen, counts.system - seen > 1 else { return }
        let owner = secureInputOwnerProvider()
        HotkeyDiagnostics.record(
            "key_interceptor_keys_missed_by_tap",
            level: .warning,
            metadata: [
                "targetPid": String(targetPid),
                "phase": phase,
                "missedKeyDowns": String(counts.system - seen),
                "systemKeyDowns": String(counts.system),
                "tapKeyDowns": String(counts.tap),
                "tapSyntheticKeyDowns": String(counts.tapSynthetic),
                "secureInputOwnerPid": owner.map(String.init) ?? "none",
                "secureInputOwnerBundleIdentifier": owner.flatMap(bundleIdentifierLookup) ?? "none"
            ]
        )
    }
}

#if DEBUG
extension KeyInterceptor {
    // Consumes only the token; the Enter is not left pending for delivery.
    // swiftlint:disable:next identifier_name
    nonisolated func _testConsumeEnterCaptureToken() -> Bool {
        let generation = state.withLockUnchecked { $0.registrationGeneration }
        let consumed = consumeEnterCaptureToken(generation: generation)
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
    nonisolated func _testHandleKeyEventForTests(
        keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        sourceState: CGEventSourceStateID = .hidSystemState
    ) -> Bool {
        let source = CGEventSource(stateID: sourceState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            return false
        }
        event.type = .keyDown
        event.flags = flags
        let result = handleKeyEvent(event: event)
        if result != nil {
            // Incoming events are borrowed by the callback, not transferred.
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
    @MainActor func _testStartSecureInputMonitoring(targetPid: pid_t, initialOwner: pid_t?) {
        startSecureInputMonitoring(targetPid: targetPid, initialOwner: initialOwner)
    }
}
#endif
