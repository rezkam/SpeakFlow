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
    }

    private let state = OSAllocatedUnfairLock(initialState: EventTapState())

    private init() {}

    // MARK: - Start / Stop

    func start() {
        let alreadyActive = state.withLockUnchecked { $0.recordingEventTap != nil }
        guard !alreadyActive else { return }

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
        guard state.withLockUnchecked({ $0.isActive }) else { return Unmanaged.passRetained(event) }
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
}
