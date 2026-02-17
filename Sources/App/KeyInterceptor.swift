import AppKit
import ApplicationServices
import OSLog
import os

/// Intercepts Escape and Enter keys during recording via CGEvent tap.
///
/// Uses an **active** (filtering) CGEvent tap so that Escape and Enter are
/// **swallowed** — they never reach the focused app. This is critical for
/// batch transcription: Enter must not be forwarded until all chunks have
/// been transcribed and inserted.
///
/// Enter capture is **one-shot**: the first Enter during a recording session
/// is intercepted (if focus is still on the original text field), and after
/// that Enter passes through normally. Escape is always intercepted while
/// the interceptor is active.
///
/// The event tap runs on a **dedicated background thread** with its own
/// CFRunLoop, completely independent of the main thread. This prevents
/// the system-wide input freeze that occurred when the tap was on the main
/// run-loop and TextInserter was keeping the main thread busy with keystroke
/// synthesis. The background thread's run loop always services the tap
/// callback promptly, regardless of main-thread load.
@MainActor
final class KeyInterceptor: KeyIntercepting {
    static let shared = KeyInterceptor()

    /// Called when Escape is pressed. Should cancel recording.
    var onEscapePressed: (() -> Void)?

    /// Called when Enter is pressed AND focus is on the original target.
    /// Caller decides action based on recording state.
    var onEnterPressed: (() -> Void)?

    /// One-shot flag: once Enter has been captured, subsequent Enters pass
    /// through to the focused app. Reset on start(). Thread-safe for the
    /// background event-tap thread.
    private let enterCaptured = OSAllocatedUnfairLock(initialState: false)

    /// The target AXUIElement captured at recording start. Enter is only
    /// intercepted if the current focus matches this target. Thread-safe
    /// snapshot taken on start() from TextInserter's captured target.
    private let capturedTarget = TargetRef()

    /// Thread-safe wrapper for AXUIElement (not Sendable in Swift 6).
    private final class TargetRef: @unchecked Sendable {
        private let lock = NSLock()
        private var _target: AXUIElement?
        var target: AXUIElement? {
            get { lock.withLock { _target } }
            set { lock.withLock { _target = newValue } }
        }
    }

    // Background thread resources — the event tap and its run-loop source
    // live on a dedicated thread so the tap callback is never blocked by
    // main-thread work. Thread-safe access via NSLock wrapper.
    private var tapThread: Thread?
    private let tapState = TapState()

    /// Thread-safe container for the background event tap's CFRunLoop and
    /// CFMachPort. Uses NSLock because CFRunLoop/CFMachPort are not Sendable.
    private final class TapState: @unchecked Sendable {
        private let lock = NSLock()
        private var _runLoop: CFRunLoop?
        private var _port: CFMachPort?

        var isActive: Bool { lock.withLock { _port != nil } }

        func set(runLoop: CFRunLoop, port: CFMachPort) {
            lock.withLock { _runLoop = runLoop; _port = port }
        }

        func stopAndClear() {
            lock.withLock {
                if let rl = _runLoop { CFRunLoopStop(rl) }
                _runLoop = nil
                _port = nil
            }
        }

        func clear() {
            lock.withLock { _runLoop = nil; _port = nil }
        }
    }

    /// Passive fallback monitor (used when CGEvent tap can't be created).
    private var keyMonitor: Any?

    private init() {}

    // MARK: - Start / Stop

    /// Begin intercepting keys. Takes a snapshot of the current focus target
    /// so Enter is only captured while the user is still in the original field.
    func start(target: AXUIElement? = nil) {
        guard !tapState.isActive, keyMonitor == nil else { return }
        guard tapThread == nil else { return }

        enterCaptured.withLock { $0 = false }
        capturedTarget.target = target

        let active = tapState
        // Store pointer as Int (Sendable) to avoid UnsafeMutableRawPointer Sendable warning.
        // Safe: KeyInterceptor is a singleton — outlives the thread.
        let selfBits = Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())

        let thread = Thread { [selfBits, active] in
            let selfPtr = UnsafeMutableRawPointer(bitPattern: selfBits)!
            let eventMask = (1 << CGEventType.keyDown.rawValue)

            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: CGEventMask(eventMask),
                callback: { (_, _, event, refcon) -> Unmanaged<CGEvent>? in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                    return interceptor.handleKeyEvent(event: event)
                },
                userInfo: selfPtr
            ) else {
                // Tap creation failed (no Accessibility permission) — fall back
                // to passive NSEvent monitor on the main thread.
                Task { @MainActor in
                    KeyInterceptor.shared.startFallbackMonitor()
                }
                return
            }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
            let rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            active.set(runLoop: rl!, port: tap)

            // Block this thread, processing event tap callbacks, until
            // CFRunLoopStop is called from stop().
            CFRunLoopRun()

            // Cleanup after the run loop exits
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(rl, source, .commonModes)
            active.clear()
        }
        thread.name = "SpeakFlow.KeyInterceptor"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.start()
        tapThread = thread
    }

    func stop() {
        tapState.stopAndClear()
        tapThread = nil
        enterCaptured.withLock { $0 = false }
        capturedTarget.target = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
    }

    // MARK: - Fallback

    private func startFallbackMonitor() {
        Logger.audio.error("Could not create CGEvent tap. Falling back to passive monitor.")
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: Task { @MainActor [weak self] in self?.onEscapePressed?() }
            case 36: Task { @MainActor [weak self] in self?.handleEnterOnMainActor() }
            default: break
            }
        }
    }

    // MARK: - Event Handler

    /// Called on the dedicated background thread by the CGEvent tap.
    /// Must be nonisolated — dispatches to MainActor via Task.
    private nonisolated func handleKeyEvent(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard tapState.isActive else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch keyCode {
        case 53: // Escape — always swallow while active
            Task { @MainActor [weak self] in self?.onEscapePressed?() }
            return nil
        case 36: // Enter — one-shot capture
            // Already captured once this session → pass through
            if enterCaptured.withLock({ $0 }) {
                return Unmanaged.passUnretained(event)
            }
            // Check if focus is still on the original target (AX APIs are
            // thread-safe). If focus moved, pass Enter through normally.
            if !isFocusOnTarget() {
                return Unmanaged.passUnretained(event)
            }
            // Swallow Enter and dispatch to MainActor
            enterCaptured.withLock { $0 = true }
            Task { @MainActor [weak self] in self?.onEnterPressed?() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Handle Enter in the fallback NSEvent monitor path (MainActor).
    private func handleEnterOnMainActor() {
        guard !enterCaptured.withLock({ $0 }) else { return }
        guard isFocusOnTarget() else { return }
        enterCaptured.withLock { $0 = true }
        onEnterPressed?()
    }

    // MARK: - Focus Check

    /// Check if the currently focused UI element matches the target captured
    /// at recording start. Safe to call from any thread (AX APIs are IPC).
    private nonisolated func isFocusOnTarget() -> Bool {
        guard let target = capturedTarget.target else { return true }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        // swiftlint:disable:next force_cast
        return CFEqual(target, focused as! AXUIElement)
    }
}
