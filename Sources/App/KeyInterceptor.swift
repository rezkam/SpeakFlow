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
final class KeyInterceptor {
    static let shared = KeyInterceptor()

    /// Called when Escape is pressed. Should cancel recording.
    var onEscapePressed: (() -> Void)?

    /// Called when Enter is pressed. Caller decides action based on recording state.
    var onEnterPressed: (() -> Void)?

    private var keyMonitor: Any?
    private let keyListenerActive = OSAllocatedUnfairLock(initialState: false)
    private var recordingEventTap: CFMachPort?
    private var recordingRunLoopSource: CFRunLoopSource?

    private init() {}

    // MARK: - Start / Stop

    func start() {
        guard recordingEventTap == nil else { return }
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        recordingEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, _, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handleKeyEvent(event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = recordingEventTap else {
            Logger.audio.error("Could not create CGEvent tap. Falling back to passive monitor.")
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 53: Task { @MainActor [weak self] in self?.onEscapePressed?() }
                case 36: Task { @MainActor [weak self] in self?.onEnterPressed?() }
                default: break
                }
            }
            return
        }

        recordingRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = recordingRunLoopSource else { recordingEventTap = nil; return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyListenerActive.withLock { $0 = true }
    }

    func stop() {
        keyListenerActive.withLock { $0 = false }
        if let tap = recordingEventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = recordingRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        recordingEventTap = nil
        recordingRunLoopSource = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
    }

    // MARK: - Event Handler

    private nonisolated func handleKeyEvent(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard keyListenerActive.withLock({ $0 }) else { return Unmanaged.passRetained(event) }
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
