import AVFoundation
import Foundation
import Testing
@testable import SpeakFlowCore

private actor InstalledSpeechEvents {
    private(set) var partial = false
    private(set) var final = false
    func record(_ event: TranscriptionEvent) {
        switch event {
        case .interim(let value): partial = partial || !value.transcript.isEmpty
        case .finalResult(let value): final = final || (!value.transcript.isEmpty && value.isFinal && value.speechFinal)
        default: break
        }
    }
}

@Suite("Installed local speech engines", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_LOCAL_SPEECH_PROBES"] == "1"))
struct LocalSpeechEngineIntegrationTests {
    @Test func approvedParakeetAcceptsAShortSyntheticTail() async throws {
        let store = try #require(ProcessInfo.processInfo.environment["SPEAKFLOW_LOCAL_MODEL_CACHE_ROOT"])
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == .parakeetV2 })
        let runtime = LocalSpeechRuntime(root: URL(fileURLWithPath: store, isDirectory: true))
        let lease = try await runtime.acquire(model)
        let wav = WavEncoder.encode(samples: Array(repeating: Float(0), count: 800), sampleRate: 16_000)
        _ = try await LocalBatchSpeechProvider(lease: lease).transcribe(audio: wav)
        await lease.release()
        try await runtime.unload(model.id)
        #expect(await runtime.snapshot().loaded.isEmpty)
    }

    @Test(arguments: LocalSpeechModelID.allCases)
    func approvedInstalledModelsProduceTextThroughTheProductionRuntime(id: LocalSpeechModelID) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let store = environment["SPEAKFLOW_LOCAL_MODEL_CACHE_ROOT"],
              let fixture = environment["SPEAKFLOW_PUBLIC_SPEECH_FIXTURE"] else {
            Issue.record("The local speech probe requires explicitly approved isolated model and public fixture paths")
            return
        }
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == id })
        let runtime = LocalSpeechRuntime(root: URL(fileURLWithPath: store, isDirectory: true))
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: fixture))
        guard audio.processingFormat.sampleRate == 16000, audio.processingFormat.channelCount == 1,
              audio.length > 0, audio.length < 16000 * 30,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else {
            Issue.record("The public speech fixture must be a bounded mono 16 kHz clip")
            return
        }
        try audio.read(into: buffer)
        let floats = try #require(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: floats, count: Int(buffer.frameLength)))
        let wav = WavEncoder.encode(samples: samples, sampleRate: 16000)
        let lease = try await runtime.acquire(model)
        if model.mode == .batch {
            let text = try await LocalBatchSpeechProvider(lease: lease).transcribe(audio: wav)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Issue.record("The installed batch engine returned no words for public speech")
            }
        } else {
            let provider = try await LocalStreamingSpeechProvider.prepare(lease: lease)
            let session = try await provider.startSession(config: await provider.buildSessionConfig())
            let recorder = InstalledSpeechEvents()
            let reader = Task { for await event in session.events { await recorder.record(event) } }
            let pcm = Data(wav.dropFirst(44))
            for offset in stride(from: 0, to: pcm.count, by: 3200) {
                try await session.sendAudio(Data(pcm[offset..<min(offset + 3200, pcm.count)]))
            }
            try await waitUntilAsync { await recorder.partial }
            try await session.finalize()
            try await session.close()
            await reader.value
            #expect(await recorder.final)
        }
        await lease.release()
        try await runtime.unload(id)
        let state = await runtime.snapshot()
        #expect(state.selected == id && state.loaded.isEmpty && state.inUse.isEmpty)
    }
}
