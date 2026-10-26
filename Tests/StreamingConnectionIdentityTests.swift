import Foundation
import Testing
@testable import SpeakFlowCore

private actor DelayedFailingAudioSession: StreamingSession {
    struct SendFailed: Error {}
    nonisolated let events = AsyncStream<TranscriptionEvent> { _ in }
    let gate: AsyncStream<Void>
    private(set) var sendStarted = false

    init(gate: AsyncStream<Void>) { self.gate = gate }
    func sendAudio(_ data: Data) async throws {
        sendStarted = true
        for await _ in gate {}
        throw SendFailed()
    }
    func finalize() async throws {}
    func keepAlive() async throws {}
    func close() async throws {}
}

private actor HeldHandshakeProvider: StreamingTranscriptionProvider {
    nonisolated let id = "synthetic-held-handshake"
    nonisolated let displayName = "Fixture provider"
    nonisolated let mode = ProviderMode.streaming
    nonisolated let isConfigured = true
    nonisolated let authRequirement = ProviderAuthRequirement.none
    let session = MockStreamingSession()
    private var held: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func startSession(config: StreamingSessionConfig) async throws -> any StreamingSession {
        started = true
        await withCheckedContinuation { held = $0 }
        return session
    }
    func release() { held?.resume(); held = nil }
}

@Suite("Streaming connection identity", .serialized)
struct StreamingConnectionIdentityTests {
    @Test @MainActor
    func stoppedReconnectCannotActivateAnUncooperativeHandshake() async throws {
        let provider = HeldHandshakeProvider()
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        controller.isActive = true
        controller.reconnectProvider = provider
        controller.reconnectConfig = .default
        controller.handleEvent(.closed)
        try await waitUntilAsync { await provider.started }
        let reconnect = try #require(controller.reconnectTask)
        await controller.stop(trailingFinalTimeout: 0)

        await provider.release()
        await reconnect.value

        #expect(!controller.isActive, "A handshake returning after stop must not reactivate the controller")
        #expect(await provider.session.closeCalled, "The retired handshake must dispose its returned session")
        #expect(!controller._testAudioSessionRefActive)
        await controller.cancel()
    }

    @Test @MainActor
    func retiredSendFailureCannotDisableTheReplacement() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let retired = DelayedFailingAudioSession(gate: gate.stream)
        let replacement = MockStreamingSession()
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller._testSetAudioSessionRefActive(true, session: retired)
        controller._testEnqueueAudioFrame(Data([1]))
        try await waitUntilAsync { await retired.sendStarted }
        controller._testSetAudioSessionRefActive(true, session: replacement)
        controller._testEnqueueAudioFrame(Data([2]))

        gate.continuation.finish()
        let drained = await controller._testDrainAudio(timeout: .seconds(1))

        #expect(drained, "A retired failure must not strand replacement audio")
        #expect(controller._testAudioSessionRefActive, "Only the current connection may disable audio delivery")
        #expect(await replacement.sentAudioChunks == [Data([2])])
        await controller.cancel()
    }
}
