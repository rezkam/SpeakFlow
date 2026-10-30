import FluidAudio
import Foundation

public enum LocalSpeechEngines {
    public static func load(_ model: LocalSpeechModel, from directory: URL) async throws -> any LocalSpeechEngine {
        #if arch(arm64)
        ModelNetworkPolicy.initialize()
        let configuration = try LocalSpeechCompute.configuration()
        do {
            switch model.id {
            case .parakeet110M, .parakeetV2:
                let models = try AsrModels.loadLocal(from: directory,
                    version: model.id == .parakeet110M ? .tdtCtc110m : .v2, configuration: configuration)
                let manager = AsrManager()
                try await manager.loadModels(models)
                return LocalParakeetEngine(manager: manager, decoderLayers: models.version.decoderLayers)
            case .nemotron1120:
                let manager = StreamingNemotronMultilingualAsrManager(configuration: configuration)
                try await manager.loadModels(from: directory)
                await manager.setLanguage("en")
                return LocalNemotronEngine(manager: manager)
            }
        } catch {
            try Task.checkCancellation()
            throw LocalSpeechRuntimeError.loadFailed
        }
        #else
        throw LocalSpeechRuntimeError.unsupportedPlatform
        #endif
    }
}

private actor LocalParakeetEngine: LocalBatchSpeechEngine {
    private let manager: AsrManager
    private let decoderLayers: Int

    init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager
        self.decoderLayers = decoderLayers
    }
    func transcribe(samples: [Float]) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        return try await manager.transcribe(samples, decoderState: &state).text
    }
    func cleanup() async {
        await manager.cleanup()
    }
}

private actor LocalNemotronEngine: LocalStreamingSpeechEngine {
    private let manager: StreamingNemotronMultilingualAsrManager

    init(manager: StreamingNemotronMultilingualAsrManager) { self.manager = manager }
    func reset() async throws {
        await manager.reset()
        await manager.setLanguage("en")
    }
    func process(samples: [Float]) async throws -> String {
        _ = try await manager.process(samples: samples)
        return await manager.getPartialTranscript()
    }
    func finish() async throws -> String {
        try await manager.finish()
    }
    func cleanup() async {
        await manager.cleanup()
    }
}
