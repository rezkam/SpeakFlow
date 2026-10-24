import Foundation
import Testing
@testable import SpeakFlowCore

/// Cancelled audio is discarded, never uploaded: nothing may emit a chunk
/// once cancellation has begun, including speech-end early emission triggered
/// by VAD processing of audio still queued at cancel time.
@Suite("StreamingRecorder — Cancel Discards Audio", .serialized)
struct StreamingRecorderCancelDiscardTests {
    @Test @MainActor
    func earlyEmissionDuringCancellationDoesNotUpload() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.2, count: 32_000))
        let recorder = StreamingRecorder()
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)
        var uploaded: [AudioChunk] = []
        recorder.onChunkReady = { uploaded.append($0) }

        recorder.cancel()
        // A speech-end event from VAD processing reaches the early-emit path.
        let sent = await recorder._testInvokeSendChunkIfReady(reason: "speechEnd", minimumDuration: 0)
        await recorder.waitForStopCompletion()

        #expect(!sent)
        #expect(uploaded.isEmpty, "Audio from a cancelled recording must never be emitted for upload")
    }
}

/// A session whose sends are slow, recording the order of sends and finalize.
actor SlowRecordingSession: StreamingSession {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private(set) var log: [String] = []
    let sendDelay: Duration

    init(sendDelay: Duration) {
        var cont: AsyncStream<TranscriptionEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
        self.sendDelay = sendDelay
    }

    func sendAudio(_ data: Data) async throws {
        try await Task.sleep(for: sendDelay)
        log.append("send:\(data.first ?? 0)")
    }
    func finalize() async throws { log.append("finalize") }
    func close() async throws {
        log.append("close")
        continuation.finish()
    }
    func keepAlive() async throws {}
}

/// Stopping a stream must deliver the audio already captured, not drop it.
@Suite("LiveStreamingController — Stop Drains Captured Audio", .serialized)
struct LiveStreamingStopDrainTests {
    @MainActor
    private func startController(session: SlowRecordingSession) async -> LiveStreamingController {
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        _ = await controller.start(provider: provider, config: .default)
        return controller
    }

    @MainActor @Test
    func stopSendsQueuedAudioBeforeFinalizing() async {
        let session = SlowRecordingSession(sendDelay: .milliseconds(20))
        let controller = await startController(session: session)
        for byte in UInt8(1)...5 { controller._testEnqueueAudioFrame(Data([byte])) }

        await controller.stop(trailingFinalTimeout: 0)

        let log = await session.log
        #expect(Array(log.prefix(6)) == ["send:1", "send:2", "send:3", "send:4", "send:5", "finalize"],
                "Audio captured before stop must reach the provider before finalize, got \(log)")
    }

    @MainActor @Test
    func drainIsBoundedWhenTheNetworkStalls() async {
        let session = SlowRecordingSession(sendDelay: .seconds(10))
        let controller = await startController(session: session)
        controller._testEnqueueAudioFrame(Data([1]))
        controller._testEnqueueAudioFrame(Data([2]))

        let started = ContinuousClock.now
        await controller.stop(trailingFinalTimeout: 0)
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(3), "A stalled network must not hold stop open, took \(elapsed)")
        #expect(await session.log.contains("finalize"))
    }

    @MainActor @Test
    func cancelStillDiscardsQueuedAudio() async {
        let session = SlowRecordingSession(sendDelay: .milliseconds(20))
        let controller = await startController(session: session)
        for byte in UInt8(1)...5 { controller._testEnqueueAudioFrame(Data([byte])) }

        await controller.cancel()
        try? await Task.sleep(for: .milliseconds(200))

        let sends = await session.log.filter { $0.hasPrefix("send:") }
        #expect(sends.count <= 1, "Cancel discards captured audio; at most the in-flight frame completes, got \(sends)")
    }
}

/// Queued audio is processed by one ordered consumer: a processing pass must
/// finish before the next one, or the stop-time drain, touches VAD state.
@Suite("StreamingRecorder — Ordered Processing", .serialized)
struct StreamingRecorderOrderedProcessingTests {
    @Test @MainActor
    func stopWaitsForTheInFlightProcessingPass() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        let vad = VADProcessor()
        let backend = MockVADBackend(repeating: .silence(), count: 10)
        await backend.setInferenceDelay(.milliseconds(50))
        await vad._testInjectBackend(backend)
        let recorder = StreamingRecorder()
        recorder._testInjectAudioBuffer(buffer)
        recorder._testInjectVADProcessor(vad)
        recorder._testInjectSessionController(SessionController())
        recorder._testSetVADActive(true)
        recorder._testSetIsRecording(true)
        // Two VAD-sized chunks for the in-flight pass.
        recorder._testEnqueueSamples([Float](repeating: 0.01, count: 8_192))

        recorder._testScheduleProcessingPass()
        recorder._testScheduleProcessingPass()
        try? await Task.sleep(for: .milliseconds(10))
        recorder.stop()
        await recorder.waitForStopCompletion()

        let calls = await backend.callCount
        let maxConcurrent = await backend.maxConcurrentCalls
        #expect(calls == 2, "Stop must not complete while a processing pass is still running VAD")
        #expect(maxConcurrent == 1)
    }
}

/// Streaming STT latency: the time from when the end of a final's audio was
/// captured to when that final arrived. The audio clock starts at the first
/// frame sent to the provider session, which is where provider timestamps
/// count from.
@Suite("LiveStreamingController — Final Latency", .serialized)
struct LiveStreamingFinalLatencyTests {
    @MainActor
    private func startedController(_ session: MockStreamingSession) async throws -> LiveStreamingController {
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        _ = await controller.start(provider: provider, config: .default)
        controller._testEnqueueAudioFrame(Data(repeating: 0, count: 320))
        try await waitUntilAsync { await !session.sentAudioChunks.isEmpty }
        return controller
    }

    @MainActor @Test
    func finalLatencyIsMeasuredFromTheEndOfItsAudio() async throws {
        let session = MockStreamingSession()
        let controller = try await startedController(session)
        var samples: [Double] = []
        controller.onFinalLatency = { samples.append($0) }

        try await Task.sleep(for: .milliseconds(250))
        controller.handleEvent(.finalResult(TranscriptionResult(
            transcript: "hello there", start: 0, duration: 0.05, isFinal: true, speechFinal: true
        )))

        #expect(samples.count == 1)
        if let latency = samples.first {
            #expect(latency > 0.15 && latency < 2, "Expected about 0.2 s after the audio ended, got \(latency)")
        }
        await controller.cancel()
    }

    @MainActor @Test
    func finalsWithoutAudioTimingAreNotGuessed() async throws {
        let session = MockStreamingSession()
        let controller = try await startedController(session)
        var samples: [Double] = []
        controller.onFinalLatency = { samples.append($0) }

        controller.handleEvent(.finalResult(TranscriptionResult(transcript: "hello there", isFinal: true, speechFinal: true)))

        #expect(samples.isEmpty)
        await controller.cancel()
    }
}
