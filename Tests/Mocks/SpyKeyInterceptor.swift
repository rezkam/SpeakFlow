import Foundation
import Testing
@testable import SpeakFlow

@MainActor
final class SpyKeyInterceptor: KeyIntercepting {
    var onEscapePressed: (() -> Void)?
    var onEnterPressed: (() -> Void)?
    var startCallCount = 0
    var pendingStartCallCount = 0
    var pendingStartSucceeds = true
    var stopCallCount = 0
    var cancelCallCount = 0
    var lastTargetPid: pid_t = 0
    /// Runs once inside the next `stop()`, standing in for a swallowed key the
    /// real interceptor delivers (exactly once) before `stop()` returns.
    var onStop: (() -> Void)?

    func start(targetPid: pid_t) {
        startCallCount += 1
        lastTargetPid = targetPid
    }
    @discardableResult func startPending(targetPid: pid_t) -> Bool {
        pendingStartCallCount += 1
        lastTargetPid = targetPid
        return pendingStartSucceeds
    }
    func stop() {
        stopCallCount += 1
        let pending = onStop
        onStop = nil
        pending?()
    }
    func cancel() { cancelCallCount += 1 }
}
