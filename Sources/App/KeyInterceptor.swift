import ApplicationServices
import AppKit
import OSLog
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
        var keyMonitor: Any?
        var isActive: Bool = false
        var recordingEventTap: CFMachPort?
        var recordingRunLoopSource: CFRunLoopSource?
        /// PID of the target app. When non-zero, keys are only intercepted
        /// if keyboard focus is in this app (prevents swallowing Escape/Enter
        /// when the user is in Spotlight, password dialogs, etc.).
        var targetPid: pid_t = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: EventTapState())

    private init() {}

    // MARK: - Start / Stop

    func start(targetPid: pid_t) {
        let alreadyActive = state.withLockUnchecked { $0.recordingEventTap != nil }
        guard !alreadyActive else { return }
        state.withLockUnchecked { $0.targetPid = targetPid }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, _, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handleKeyEvent(event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            Logger.audio.error("Could not create CGEvent tap. Falling back to passive monitor.")
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 53: Task { @MainActor [weak self] in self?.onEscapePressed?() }
                case 36: Task { @MainActor [weak self] in self?.onEnterPressed?() }
                default: break
                }
            }
            state.withLockUnchecked { $0.keyMonitor = monitor }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source else {
            state.withLockUnchecked { $0.recordingEventTap = nil }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state.withLockUnchecked {
            $0.recordingEventTap = tap
            $0.recordingRunLoopSource = source
            $0.isActive = true
        }
    }

    func stop() {
        let (tap, source, monitor) = state.withLockUnchecked { s -> (CFMachPort?, CFRunLoopSource?, Any?) in
            let result = (s.recordingEventTap, s.recordingRunLoopSource, s.keyMonitor)
            s.isActive = false
            s.targetPid = 0
            s.recordingEventTap = nil
            s.recordingRunLoopSource = nil
            s.keyMonitor = nil
            return result
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Event Handler

    private nonisolated func handleKeyEvent(event: CGEvent) -> Unmanaged<CGEvent>? {
        let (isActive, targetPid) = state.withLockUnchecked { ($0.isActive, $0.targetPid) }
        guard isActive else { return Unmanaged.passRetained(event) }

        // Only intercept Escape/Enter when the target app has keyboard focus.
        // If the user is in Spotlight, a password dialog, or another app,
        // let the key pass through so it acts on that UI instead.
        if targetPid != 0, !Self.isKeyboardFocusInApp(pid: targetPid) {
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch keyCode {
        case 53:
            Task { @MainActor [weak self] in self?.onEscapePressed?() }
            return nil
        case 36:
            Task { @MainActor [weak self] in self?.onEnterPressed?() }
            return nil
        default:
            return Unmanaged.passRetained(event)
        }
    }

    /// Checks whether keyboard focus is currently in the specified app.
    /// Uses the system-wide AX focused element to detect focus, catching
    /// system overlays that steal focus without changing the frontmost app.
    private nonisolated static func isKeyboardFocusInApp(pid: pid_t) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
           let element = focusedElement,
           CFGetTypeID(element) == AXUIElementGetTypeID() {
            // Safe: type check guarantees AXUIElement
            // swiftlint:disable:next force_cast
            var focusedPid: pid_t = 0
            if AXUIElementGetPid(element as! AXUIElement, &focusedPid) == .success {
                return focusedPid == pid
            }
        }
        // Fallback: frontmost app check
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.processIdentifier == pid
    }
}
