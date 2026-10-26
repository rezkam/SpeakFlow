import Foundation
import Testing
@testable import SpeakFlowCore

extension StreamingRecorderStopCancelTests {
    @Test(arguments: [false, true]) @MainActor
    func everyBatchWAVFitsTheProviderByteLimit(finalFlush: Bool) async {
        let settings = SpySettings()
        settings.skipSilentChunks = false
        settings.chunkDuration = .minute10
        let recorder = StreamingRecorder(settings: settings)
        let buffer = AudioBuffer(sampleRate: 16000)
        let sampleCount = (Config.maxAudioSizeBytes - 44) / 2 + 12800
        await buffer.append(frames: [Float](repeating: 0.3, count: sampleCount))
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)
        var chunks: [AudioChunk] = []
        recorder.onChunkReady = { chunks.append($0) }

        if finalFlush {
            recorder.stop()
            await recorder.waitForStopCompletion()
        } else {
            #expect(await recorder._testInvokeSendChunkIfReady(reason: "oversized batch"))
            recorder.cancel()
            await recorder.waitForStopCompletion()
        }

        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.wavData.count <= Config.maxAudioSizeBytes },
                "Every WAV must fit the provider limit, including its header")
        #expect(chunks.reduce(0) { $0 + ($1.wavData.count - 44) / 2 } == sampleCount,
                "Splitting must preserve every sample exactly once")
    }

    @Test @MainActor func establishedRecordingPreservesItsShortFinalTail() async {
        let settings = SpySettings()
        settings.skipSilentChunks = false
        let recorder = StreamingRecorder(settings: settings)
        let buffer = AudioBuffer(sampleRate: 16000)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)
        var chunks: [AudioChunk] = []
        recorder.onChunkReady = { chunks.append($0) }
        await buffer.append(frames: [Float](repeating: 0.3, count: 16000))
        #expect(await recorder._testInvokeSendChunkIfReady(reason: "establish session", minimumDuration: 1))
        await buffer.append(frames: [Float](repeating: 0.3, count: 12800))

        recorder.stop()
        await recorder.waitForStopCompletion()

        #expect(chunks.count == 2, "An 800 ms tail is part of an established recording")
        #expect(chunks.last?.durationSeconds == 0.8)
    }

    @Test @MainActor func stopSplitsQueuedSamplesIntoModelSizedFrames() async {
        let recorder = StreamingRecorder()
        let backend = MockVADBackend(repeating: .silence(), count: 4)
        let vad = VADProcessor()
        await vad._testInjectBackend(backend)
        recorder._testInjectVADProcessor(vad)
        let session = SessionController()
        await session.startSession()
        recorder._testInjectSessionController(session)
        recorder._testSetVADActive(true)
        recorder._testInjectAudioBuffer(AudioBuffer(sampleRate: 16000))
        recorder._testSetIsRecording(true)
        recorder._testEnqueueSamples([Float](repeating: 0, count: 16000))

        recorder.stop()
        await recorder.waitForStopCompletion()

        #expect(await backend.callCount == 4,
                "Every queued sample must reach VAD in frames no larger than 4096 samples")
    }

    @Test @MainActor func stopFiltersQueuedSamplesBeforeEncoding() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testInjectAudioFilter(NoiseGateFilter(rmsThreshold: 0.1))
        recorder._testSetIsRecording(true)
        recorder._testEnqueueSamples([Float](repeating: 0.01, count: 16000))
        var received: AudioChunk?
        recorder.onChunkReady = { received = $0 }

        recorder.stop()
        await recorder.waitForStopCompletion()

        #expect(received?.wavData == WavEncoder.encode(
            samples: [Float](repeating: 0, count: 16000), sampleRate: 16000
        ), "Stop-time samples must use the same noise gate as regular samples")
    }
}
