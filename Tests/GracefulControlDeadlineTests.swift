import Foundation
import Testing
@testable import SpeakFlowCore

private actor HeldControlSession: StreamingSession {
    nonisolated let events = AsyncStream<TranscriptionEvent> { _ in }
    let stallClose: Bool
    private var held: CheckedContinuation<Void, Never>?
    private(set) var closeCalls = 0
    private(set) var finalizeCalls = 0

    init(stallClose: Bool) { self.stallClose = stallClose }
    func sendAudio(_ data: Data) async throws {}
    func keepAlive() async throws {}
    func finalize() async throws {
        finalizeCalls += 1
        if !stallClose { await withCheckedContinuation { held = $0 } }
    }
    func close() async throws {
        closeCalls += 1
        if stallClose { await withCheckedContinuation { held = $0 } }
        else { release() }
    }
    func release() {
        held?.resume()
        held = nil
    }
}

@Suite("Graceful control deadlines", .serialized)
struct GracefulControlDeadlineTests {
    @Test @MainActor
    func cancelIsBoundedWhenCloseIgnoresCancellation() async throws {
        let session = HeldControlSession(stallClose: true)
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        controller.controlMessageTimeout = 0.05
        try #require(await controller.start(provider: provider, config: .default))
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(1))
            await session.release()
        }
        let started = ContinuousClock.now
        await controller.cancel()
        let elapsed = ContinuousClock.now - started
        await session.release()
        watchdog.cancel()
        #expect(elapsed < .milliseconds(500), "Cancellation must not wait for an unresponsive graceful close")
        #expect(await session.finalizeCalls == 0, "Cancellation must never finalize audio")
        #expect(await session.closeCalls == 1)
        #expect(controller._testAudioSessionRefIsShutdown)
    }

    @Test(arguments: [false, true]) @MainActor
    func stopIsBoundedWhenControlMessagesIgnoreCancellation(stallClose: Bool) async throws {
        let session = HeldControlSession(stallClose: stallClose)
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        controller.controlMessageTimeout = 0.05
        try #require(await controller.start(provider: provider, config: .default))
        // Always release the deliberately non-cooperative operation, even on red.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(1))
            await session.release()
        }
        let started = ContinuousClock.now
        await controller.stop(trailingFinalTimeout: 0)
        let elapsed = ContinuousClock.now - started
        await session.release()
        watchdog.cancel()

        #expect(elapsed < .milliseconds(500), "A stalled control send must not hold stop until the watchdog")
        #expect(await session.finalizeCalls == 1)
        #expect(await session.closeCalls == 1, "Finalization timeout must still attempt transport teardown")
        #expect(controller._testAudioSessionRefIsShutdown)
        #expect(!controller.isActive)
    }
}
