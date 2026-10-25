import Foundation
import Testing
@testable import SpeakFlowCore

/// Cancelled audio is discarded, never uploaded: nothing may emit a chunk
/// once cancellation has begun, including speech-end early emission triggered
/// by VAD processing of audio still queued at cancel time.
@Suite("StreamingRecorder — Cancel Discards Audio", .serialized)
struct StreamingRecorderCancelDiscardTests {
    @Test @MainActor
    func cancellationDuringHeldSpeechEndInferenceCannotEmitAudio() async throws {
        let settings = SpySettings()
        settings.chunkDuration = .minute1
        settings.skipSilentChunks = true
        let recorder = StreamingRecorder(settings: settings)
        let buffer = AudioBuffer(sampleRate: 16000)
        let session = SessionController()
        await session.startSession()
        let backend = MockVADBackend(repeating: .speech(), count: 5)
        let gate = AsyncStream<Void>.makeStream()
        await backend.setInferenceGate {
            if await backend.callCount == 6 { for await _ in gate.stream {} }
        }
        defer {
            gate.continuation.finish()
            Task { await backend.setInferenceGate(nil) }
        }
        let vad = VADProcessor()
        await vad._testInjectBackend(backend)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testInjectVADProcessor(vad)
        recorder._testInjectSessionController(session)
        recorder._testSetVADActive(true)
        recorder._testSetIsRecording(true)
        var emissions = 0
        recorder.onChunkReady = { _ in emissions += 1 }
        recorder._testEnqueueSamples([Float](repeating: 0.5, count: 160_000))
        recorder._testScheduleProcessingPass()
        try await waitUntilAsync { await backend.callCount == 6 }
        try #require(await session.hasSpoken)
        recorder.cancel()
        gate.continuation.finish()
        await recorder.waitForStopCompletion()
        #expect(emissions == 0, "A speech-end result returning after cancel cannot upload buffered audio")
    }

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
        // Ordering is under test, not the bound: allow for a loaded scheduler.
        controller.stopDrainTimeout = .seconds(10)
        for byte in UInt8(1)...5 { controller._testEnqueueAudioFrame(Data([byte])) }

        await controller.stop(trailingFinalTimeout: 0)

        let log = await session.log
        #expect(Array(log.prefix(6)) == ["send:1", "send:2", "send:3", "send:4", "send:5", "finalize"],
                "Audio captured before stop must reach the provider before finalize, got \(log)")
    }

    @MainActor @Test
    func providerCloseDuringStopDrainDoesNotBeginReconnect() async throws {
        let session = SuspendedUploadSession()
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        #expect(await controller.start(provider: provider, config: .default))
        controller.stopDrainTimeout = .seconds(10)
        controller._testEnqueueAudioFrame(Data([1]))
        try await waitUntilAsync { await session.sendStarted }
        try #require(await session.sendStarted)
        let stopTask = Task { @MainActor in await controller.stop(trailingFinalTimeout: 0) }
        try await waitUntil { controller.suppressSessionClosedCallback }
        try #require(controller.suppressSessionClosedCallback)
        controller.handleEvent(.closed)
        #expect(controller.isActive, "An explicit stop must stay in its drain, not transition to reconnect")
        // Release the controlled send without sending test data or leaking tasks.
        await controller.cancel()
        await stopTask.value
        #expect(provider.startSessionCallCount == 1)
        #expect(!controller.isActive)
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
    @Test(arguments: [false, true]) @MainActor
    func heldInferenceOwnsTheStopDrain(cancel: Bool) async throws {
        let gate = AsyncStream<Void>.makeStream()
        let backend = MockVADBackend(repeating: .silence(), count: 10)
        await backend.setInferenceGate { for await _ in gate.stream {} }
        let vad = VADProcessor()
        await vad._testInjectBackend(backend)
        let buffer = AudioBuffer(sampleRate: 16000)
        let recorder = StreamingRecorder()
        recorder._testInjectAudioBuffer(buffer)
        recorder._testInjectVADProcessor(vad)
        recorder._testInjectSessionController(SessionController())
        recorder._testSetVADActive(true)
        recorder._testSetIsRecording(true)
        defer { gate.continuation.finish() }
        recorder._testEnqueueSamples([Float](repeating: 0.01, count: 4096))
        recorder._testScheduleProcessingPass()
        try await waitUntilAsync { await backend.callCount == 1 }
        // This batch arrives while the actual processing pass is suspended.
        recorder._testEnqueueSamples([Float](repeating: 0.02, count: 4096))
        if cancel { recorder.cancel() } else { recorder.stop() }
        var stopped = false
        let stop = Task { await recorder.waitForStopCompletion(); stopped = true }
        await #expect(throws: PollingError.self) {
            try await waitUntil(timeout: .milliseconds(50)) { stopped }
        }
        gate.continuation.finish()
        await stop.value
        #expect(await backend.callCount == (cancel ? 1 : 2))
        #expect(await backend.maxConcurrentCalls == 1)
    }

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
/// captured to when that final arrived. Provider offsets count only sent audio;
/// capture-time discontinuities must not inflate measured latency.
@Suite("LiveStreamingController — Final Latency", .serialized)
struct LiveStreamingFinalLatencyTests {
    @MainActor
    private func startedController(
        _ session: MockStreamingSession, sampleRate: Int = 16_000,
        capturedAt: ContinuousClock.Instant = .now
    ) async throws -> LiveStreamingController {
        let provider = MockStreamingProvider()
        provider.mockSession = session
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        _ = await controller.start(provider: provider, config: StreamingSessionConfig(sampleRate: sampleRate))
        controller._testEnqueueAudioFrame(Data(repeating: 0, count: 3200), capturedAt: capturedAt)
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
    func reconnectStartsLatencyClockAtTheReplacementSessionsFirstFrame() async throws {
        let first = MockStreamingSession()
        let second = MockStreamingSession()
        let provider = MultiSessionMockProvider()
        provider.sessions = [first, second]
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller.keepAliveEnabled = false
        controller.reconnectEnabled = true
        defer { Task { await controller.cancel() } }
        #expect(await controller.start(provider: provider, config: .default))
        var samples: [Double] = []
        controller.onFinalLatency = { samples.append($0) }
        let audio = Data(repeating: 0, count: 3200)
        controller._testEnqueueAudioFrame(audio, capturedAt: .now - .seconds(20))
        try await waitUntilAsync { await first.sentAudioChunks.count == 1 }
        await first.emit(.finalResult(TranscriptionResult(
            transcript: "first result", start: 0, duration: 0.1, isFinal: true, speechFinal: true
        )))
        try await waitUntil { samples.count == 1 }
        #expect(try #require(samples.first) > 19)

        await first.emit(.closed)
        try await waitUntil { provider.startSessionCallCount == 2 && controller.isActive }
        controller._testEnqueueAudioFrame(audio, capturedAt: .now - .seconds(2))
        try await waitUntilAsync { await second.sentAudioChunks.count == 1 }
        await second.emit(.finalResult(TranscriptionResult(
            transcript: "second result", start: 0, duration: 0.1, isFinal: true, speechFinal: true
        )))
        try await waitUntil { samples.count == 2 }
        let latency = try #require(samples.last)
        #expect(latency > 1 && latency < 4, "A replacement provider's timestamps start at its own first frame")
        await controller.cancel()
    }

    @MainActor @Test
    func droppedAudioDoesNotInflateLatencyForSurvivingFrames() async throws {
        let session = SuspendedUploadSession()
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        defer { Task { await controller.cancel() } }
        var samples: [Double] = []
        controller.onFinalLatency = { samples.append($0) }
        controller._testSetAudioSessionRefActive(true, session: session)
        let frame = Data(repeating: 0, count: 3200) // 100 ms of mono PCM16 at 16 kHz.
        controller._testEnqueueAudioFrame(frame, capturedAt: .now - .seconds(20))
        try await waitUntilAsync { await session.sendStarted }

        // The first send is held, so overflow deterministically drops only the middle frame.
        controller._testEnqueueAudioFrame(Data(repeating: 1, count: 1_000_000), capturedAt: .now - .seconds(19))
        controller._testEnqueueAudioFrame(frame, capturedAt: .now - .seconds(2))
        #expect(controller._testDroppedAudioChunkCount == 1)
        #expect(controller._testPendingAudioChunkCount == 1)
        await session.resumeUploads()
        try await waitUntilAsync { await session.uploads == 2 }

        // A late final for the first frame still uses its own capture time.
        controller.handleEvent(.finalResult(TranscriptionResult(
            transcript: "first phrase", start: 0, duration: 0.1, isFinal: true, speechFinal: true
        )))
        #expect(try #require(samples.last) > 19)
        // The provider received only 200 ms, not the discarded middle audio.
        controller.handleEvent(.finalResult(TranscriptionResult(
            transcript: "second phrase", start: 0.1, duration: 0.1, isFinal: true, speechFinal: true
        )))
        #expect(samples.count == 2)
        let latency = try #require(samples.last)
        #expect(latency > 1 && latency < 4, "Latency must follow the surviving frame's capture time, got \(latency)")
        await controller.cancel()
    }

    @MainActor @Test
    func latencyUsesTheConfiguredSampleRate() async throws {
        let session = MockStreamingSession()
        let controller = try await startedController(session, sampleRate: 8000, capturedAt: .now - .seconds(2))
        var samples: [Double] = []
        controller.onFinalLatency = { samples.append($0) }
        controller.handleEvent(.finalResult(TranscriptionResult(
            transcript: "sample rate phrase", start: 0, duration: 0.2, isFinal: true, speechFinal: true
        )))
        #expect(samples.count == 1)
        let latency = try #require(samples.first)
        #expect(latency > 1 && latency < 4)
        await controller.cancel()
    }

    @MainActor @Test(arguments: [0.2, Double.infinity, Double.nan, -0.1])
    func unsupportedAudioEndpointsDoNotProduceInventedLatency(duration: Double) async throws {
        let session = MockStreamingSession()
        let controller = try await startedController(session, capturedAt: .now - .seconds(2))
        var samples: [Double] = []
        controller.onFinalLatency = { samples.append($0) }
        controller.handleEvent(.finalResult(TranscriptionResult(
            transcript: "unmapped phrase", start: 0, duration: duration, isFinal: true, speechFinal: true
        )))
        #expect(samples.isEmpty)
        await controller.cancel()
    }

    @MainActor @Test
    func boundedTimingHistoryKeepsRecentFinalsWithoutGuessingEvictedOnes() async throws {
        let session = MockStreamingSession()
        let controller = LiveStreamingController(skipAudioEngineForTesting: true)
        controller._testSetAudioSessionRefActive(true, session: session)
        var samples: [Double] = []
        controller.onFinalLatency = { samples.append($0) }
        for _ in 0..<4097 {
            controller._testEnqueueAudioFrame(Data([0, 0]), capturedAt: .now - .seconds(2))
        }
        try await waitUntilAsync { await session.sentAudioChunks.count == 4097 }
        controller.handleEvent(.finalResult(TranscriptionResult(
            transcript: "evicted phrase", start: 0, duration: 1.0 / 16_000, isFinal: true, speechFinal: true
        )))
        #expect(samples.isEmpty)
        controller.handleEvent(.finalResult(TranscriptionResult(
            transcript: "retained phrase", start: 4096.0 / 16_000, duration: 1.0 / 16_000,
            isFinal: true, speechFinal: true
        )))
        #expect(samples.count == 1)
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
