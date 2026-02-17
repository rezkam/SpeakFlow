import ApplicationServices
import Testing
@testable import SpeakFlow

@MainActor
final class SpyKeyInterceptor: KeyIntercepting {
    var onEscapePressed: (() -> Void)?
    var onEnterPressed: (() -> Void)?
    var startCallCount = 0
    var stopCallCount = 0
    var lastTarget: AXUIElement?

    func start(target: AXUIElement? = nil) { startCallCount += 1; lastTarget = target }
    func stop() { stopCallCount += 1 }
}
