import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
private final class BatchDeliveryStatistics: StatisticsProviding {
    var totalSecondsTranscribed: Double = 0
    var totalCharacters: Int = 0
    var totalWords: Int = 0
    var totalApiCalls: Int = 0
    var recordedLatencies: [TimeInterval] = []
    /// Each entry captures one `recordRecording(providerId:, language:)` call.
    var recordedRecordings: [(providerId: String?, language: String?)] = []
    var apiCallCount: Int { totalApiCalls }
    var wordCount: Int { totalWords }
    var formattedDuration: String { "0s" }
    var formattedCharacters: String { "0" }
    var formattedWords: String { "0" }
    var formattedApiCalls: String { "0" }
    var sttLatencyP50Ms: Double { 0 }
    var sttLatencyP95Ms: Double { 0 }
    var sttLatencyP99Ms: Double { 0 }

    func recordTranscription(text: String, audioDurationSeconds: Double) {
        totalSecondsTranscribed += audioDurationSeconds
        totalCharacters += text.count
        totalWords += text.split(separator: " ").count
    }

    func recordApiCall() {
        totalApiCalls += 1
    }

    func recordRecording(providerId: String?, language: String?) {
        recordedRecordings.append((providerId, language))
    }

    func recordSTTLatency(seconds: TimeInterval) {
        recordedLatencies.append(seconds)
    }

    func reset() {
        totalSecondsTranscribed = 0
        totalCharacters = 0
        totalWords = 0
        totalApiCalls = 0
        recordedRecordings = []
    }
}

private actor BatchDeliveryCloud: TranscriptionServiceProviding {
    func transcribe(audio: Data) async throws -> String {
        Issue.record("Local recording must never call the cloud service")
        throw TranscriptionError.cancelled
    }
}

private actor BatchDeliveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private actor BatchDeliveryEngine: LocalBatchSpeechEngine {
    let gate: BatchDeliveryGate
    private(set) var calls = 0
    init(gate: BatchDeliveryGate) { self.gate = gate }
    func transcribe(samples: [Float]) async throws -> String {
        calls += 1
        let call = calls
        if call == 1 { await gate.wait() }
        return "fixture result \(call)"
    }
    func cleanup() async {}
}

@Suite("Local batch delivery", .serialized)
struct LocalBatchDeliveryTests {
    @MainActor @Test(arguments: [false, true])
    func producerWaitsForInferenceBeforeDeliveringTheFinalTail(cancel: Bool) async throws {
        let previousVAD = Settings.shared.vadEnabled
        Settings.shared.vadEnabled = false
        defer { Settings.shared.vadEnabled = previousVAD }
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == .parakeetV2 })
        let gate = BatchDeliveryGate(), engine = BatchDeliveryEngine(gate: gate)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/batch-delivery-\(UUID().uuidString)")
        let runtime = LocalSpeechRuntime(root: root, verify: { _, root in root }, load: { _, _ in engine })
        let availability = LocalSpeechAvailability()
        availability.setReady(true)
        let provider = LocalRecordingProvider(model: model, runtime: runtime, availability: availability)
        let registry = SpyProviderRegistry(), providers = SpyProviderSettings(), settings = SpySettings()
        settings.vadEnabled = false
        registry.register(provider)
        providers.activeProviderId = provider.id
        let text = SpyTextInserter(), banner = SpyBannerPresenter()
        let coordinator = Transcription(statistics: BatchDeliveryStatistics(), service: BatchDeliveryCloud())
        defer { coordinator.queueBridge.stopListening() }
        let controller = RecordingController(keyInterceptor: SpyKeyInterceptor(), textInserter: text,
            appState: banner, hotkeySettings: SpyHotkeySettings(), providerSettings: providers,
            providerRegistry: registry, settings: settings, transcription: coordinator, playSoundEffect: { _ in })
        controller.testMode = .live
        text.targetPid = 42
        controller.setupTranscriptionCallbacks()
        controller.startRecording()
        try await waitUntil { controller.recorder?._testIsRecording == true }
        let deliver = try #require(controller.recorder?.onChunkReady)
        var firstReturned = false
        let sending = Task { @MainActor in
            let first = WavEncoder.encode(samples: Array(repeating: Float(0.1), count: 48_000), sampleRate: 16_000)
            let tail = WavEncoder.encode(samples: Array(repeating: Float(0.1), count: 800), sampleRate: 16_000)
            await deliver(AudioChunk(wavData: first, durationSeconds: 3))
            firstReturned = true
            await deliver(AudioChunk(wavData: tail, durationSeconds: 0.05))
        }
        try await waitUntilAsync { await gate.started }
        #expect(!firstReturned, "Local acceptance must apply backpressure until native inference completes")
        if cancel { controller.cancelRecording() }
        await gate.open()
        await sending.value
        #expect(await engine.calls == (cancel ? 1 : 2))
        #expect(!banner.bannerMessages.contains { $0.1 == .error })
        if cancel { #expect(text.operations.allSatisfy { operation in
            switch operation {
            case .insertText, .insertTextInBulk: false
            default: true
            }
        }) }
        if !cancel {
            try await waitUntil { text.bulkInsertedTexts.count + text.insertedTexts.count == 2 }
            #expect(text.bulkInsertedTexts + text.insertedTexts == ["fixture result 1 ", "fixture result 2 "])
        }
        #expect(!text.enterKeyPressed)
        controller.cancelRecording()
    }

    @MainActor @Test func deadlineCancelsWhileTheStopDrainWaitsForNativeInference() async throws {
        let previousVAD = Settings.shared.vadEnabled
        Settings.shared.vadEnabled = false
        defer { Settings.shared.vadEnabled = previousVAD }
        let model = try #require(LocalSpeechCatalog.models().first { $0.id == .parakeetV2 })
        let gate = BatchDeliveryGate(), engine = BatchDeliveryEngine(gate: gate)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/batch-delivery-\(UUID().uuidString)")
        let runtime = LocalSpeechRuntime(root: root, verify: { _, root in root }, load: { _, _ in engine })
        let availability = LocalSpeechAvailability()
        availability.setReady(true)
        let provider = LocalRecordingProvider(model: model, runtime: runtime, availability: availability)
        let registry = SpyProviderRegistry(), providers = SpyProviderSettings(), settings = SpySettings()
        settings.vadEnabled = false
        registry.register(provider)
        providers.activeProviderId = provider.id
        let text = SpyTextInserter(), banner = SpyBannerPresenter()
        let coordinator = Transcription(statistics: BatchDeliveryStatistics(), service: BatchDeliveryCloud())
        defer { coordinator.queueBridge.stopListening() }
        let controller = RecordingController(keyInterceptor: SpyKeyInterceptor(), textInserter: text,
            appState: banner, hotkeySettings: SpyHotkeySettings(), providerSettings: providers,
            providerRegistry: registry, settings: settings, transcription: coordinator, playSoundEffect: { _ in })
        controller.testMode = .live
        text.targetPid = 42
        controller.setupTranscriptionCallbacks()
        controller.startRecording()
        try await waitUntil { controller.recorder?._testIsRecording == true }
        settings.batchFinalizationTimeoutBase = 0.03
        settings.batchFinalizationTimeoutPerChunkSecond = 0
        settings.batchFinalizationMaxTimeout = 0.03
        let recorder = try #require(controller.recorder)
        let buffer = AudioBuffer(sampleRate: 16_000)
        await buffer.append(frames: Array(repeating: Float(0.1), count: 32_000))
        recorder._testInjectAudioBuffer(buffer)
        controller.stopRecordingAndSubmit()
        try await waitUntilAsync { await gate.started }
        do {
            try await waitUntil { !controller.isProcessingFinal }
        } catch {
            Issue.record("Finalization deadline must run while native inference is still held")
        }
        #expect(banner.bannerMessages.last?.0 == LocalSpeechRuntimeError.finalizationTimedOut.localizedDescription)
        #expect(!text.enterKeyPressed)
        controller.cancelRecording()
        await gate.open()
        await recorder.waitForStopCompletion()
        #expect(text.bulkInsertedTexts.isEmpty && text.insertedTexts.isEmpty)
    }

    @Test func shortNativeInputPreservesCapturedSamplesAndPadsOnlyToTheSDKMinimum() throws {
        let short: [Float] = [0.25, -0.25]
        let prepared = try LocalSpeechEngines.parakeetInput(short)
        #expect(prepared.count == 4_800)
        #expect(Array(prepared.prefix(short.count)) == short)
        #expect(prepared.dropFirst(short.count).allSatisfy { $0 == 0 })
        let full = Array(repeating: Float(0.1), count: 8_000)
        #expect(try LocalSpeechEngines.parakeetInput(full) == full)
        #expect(throws: LocalSpeechAudioError.invalidAudio) { try LocalSpeechEngines.parakeetInput([]) }
    }

    @MainActor @Test func stopWaitsForPeriodicEmissionAndRetainsItsTail() async throws {
        let recorder = StreamingRecorder()
        recorder.requiresLosslessAudio = true
        let buffer = AudioBuffer(sampleRate: 16_000)
        await buffer.append(frames: Array(repeating: Float(0.1), count: 32_000))
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)
        let gate = BatchDeliveryGate()
        var chunks: [AudioChunk] = []
        recorder.onChunkReady = { chunk in
            chunks.append(chunk)
            if chunks.count == 1 { await gate.wait() }
        }
        let first = Task { await recorder._testInvokeSendChunkIfReady(reason: "periodic fixture", minimumDuration: 0) }
        try await waitUntilAsync { await gate.started }
        await buffer.append(frames: Array(repeating: Float(0.2), count: 800))
        let overlapping = await recorder._testInvokeSendChunkIfReady(reason: "speech fixture", minimumDuration: 0)
        #expect(!overlapping)
        recorder.stop()
        #expect(chunks.count == 1)
        await gate.open()
        _ = await first.value
        await recorder.waitForStopCompletion()
        #expect(chunks.count == 2)
        #expect(chunks.last?.wavData.count == 44 + 800 * 2)
    }

    @MainActor @Test func localStopDrainKeepsBufferedAudioForOneFinalChunk() async throws {
        let recorder = StreamingRecorder()
        recorder.requiresLosslessAudio = true
        let buffer = AudioBuffer(sampleRate: 16_000)
        await buffer.append(frames: Array(repeating: Float(0.1), count: 32_000))
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(false)
        var chunks: [AudioChunk] = []
        recorder.onChunkReady = { chunks.append($0) }
        let sentEarly = await recorder._testInvokeSendChunkIfReady(reason: "synthetic stop-time speech end", minimumDuration: 0)
        #expect(!sentEarly)
        #expect(await buffer.count == 32_000)
        recorder.stop()
        await recorder.waitForStopCompletion()
        #expect(chunks.count == 1)
        #expect(chunks.first?.wavData.count == 44 + 32_000 * 2)
    }
}
