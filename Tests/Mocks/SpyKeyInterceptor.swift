import Foundation
import Testing
@testable import SpeakFlow

@MainActor
final class SpyKeyInterceptor: KeyIntercepting {
    var onEscapePressed: (() -> Void)?
    var onEnterPressed: (() -> Void)?
    var startCallCount = 0
    var stopCallCount = 0
    var lastTargetPid: pid_t = 0

    func start(targetPid: pid_t) {
        startCallCount += 1
        lastTargetPid = targetPid
    }
    func stop() { stopCallCount += 1 }
}
