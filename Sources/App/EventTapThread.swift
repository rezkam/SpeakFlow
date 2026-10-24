import Foundation

/// Services one event tap's run loop source on a dedicated thread.
///
/// The WindowServer waits for an active tap to answer each event and disables
/// the tap when it does not answer in time. A tap serviced by the main run loop
/// cannot answer while the main thread is busy (synchronous Accessibility calls,
/// text insertion, UI work), so its keys would pass through unintercepted.
final class EventTapThread: @unchecked Sendable {
    private let source: CFRunLoopSource
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(source: CFRunLoopSource) {
        self.source = source
    }

    /// Starts the thread and returns once the source is scheduled on it.
    func start(name: String) {
        let scheduled = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            guard let current = CFRunLoopGetCurrent() else {
                scheduled.signal()
                return
            }
            CFRunLoopAddSource(current, source, .commonModes)
            lock.withLock { runLoop = current }
            scheduled.signal()
            // CFRunLoopStop only ends the current pass, so re-check the flag.
            while !lock.withLock({ stopped }) {
                CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }
            CFRunLoopRemoveSource(current, source, .commonModes)
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        scheduled.wait()
    }

    /// Stops servicing the source. The thread exits after its current pass.
    func stop() {
        let current = lock.withLock { () -> CFRunLoop? in
            stopped = true
            return runLoop
        }
        if let current {
            CFRunLoopStop(current)
            CFRunLoopWakeUp(current)
        }
    }
}
