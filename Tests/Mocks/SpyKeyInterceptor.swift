import Testing
@testable import SpeakFlow

@MainActor
final class SpyKeyInterceptor: KeyIntercepting {
    var onEscapePressed: (() -> Void)?
    var onEnterPressed: (() -> Void)?
    var startCallCount = 0
    var stopCallCount = 0

    func start() { startCallCount += 1 }
    func stop() { stopCallCount += 1 }
}
