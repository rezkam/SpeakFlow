import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
final class SpySettings: SettingsProviding {
    var chunkDuration: ChunkDuration = .minute1
    var skipSilentChunks: Bool = true
    var vadEnabled: Bool = true
    var vadThreshold: Float = 0.15
    var vadVolumeGateEnabled: Bool = true
    var vadMinVolumeForSpeech: Float = 0.008
    var vadVolumeSmoothingFactor: Float = 0.2
    var vadStateResetInterval: Double = 5.0
    var autoEndEnabled: Bool = true
    var autoEndSilenceDuration: Double = 10.0
    var autoEndMinSessionDuration: Double = 2.0
    var autoEndRequireSpeechFirst: Bool = true
    var autoEndNoSpeechTimeout: Double = 10.0
    var autoEndMaxContinuousSpeechDuration: Double = 180.0
    var thinkingPauseEnabled: Bool = true
    var thinkingPauseExtensionSeconds: Double = 5.0
    var turnClassifierEnabled: Bool = false
    var turnClassifierMinimumSilence: Double = 1.5
    var turnClassifierIncompleteExtensionSeconds: Double = 3.0
    var turnClassifierThreshold: Float = 0.5
    var idleNudgeEnabled: Bool = false
    var idleNudgeInitialDelay: Double = 0.0
    var idleNudgeInterval: Double = 3.0
    var idleNudgeMaxCount: Int = 2
    var audioNoiseGateEnabled: Bool = true
    var audioNoiseGateRmsThreshold: Float = 0.002
    var minSpeechRatio: Float = 0.01
    var streamingAutoEndEnabled: Bool = true
    var streamingKeepAliveEnabled: Bool = true
    var streamingKeepAliveInterval: Double = 8.0
    var streamingReconnectEnabled: Bool = true
    var streamingMinimumFinalWordCount: Int = Config.defaultStreamingMinimumFinalWordCount
    var streamingTrailingFinalTimeout: Double = 2.0
    var batchFinalizationTimeoutBase: Double = 10.0
    var batchFinalizationTimeoutPerChunkSecond: Double = 2.0
    var batchFinalizationMaxTimeout: Double = 120.0
    var deepgramInterimResults: Bool = true
    var deepgramSmartFormat: Bool = true
    var deepgramEndpointingMs: Int = 300
    var deepgramModel: String = "nova-3"
    var deepgramLanguage: String = "en-US"
    var mistralModel: String = "voxtral-mini-transcribe-realtime-2602"
    var mistralBatchModel: String = "voxtral-mini-latest"
    var mistralLanguage: String = "en"
    var mistralTemperature: Float = 0.0
    var mistralDiarize: Bool = false
    var mistralContextBias: String = ""
    var focusWaitTimeout: Double = 60.0
    var hotkeyRestartsRecording: Bool = true
    var observabilityEnabled: Bool = true
    var observabilityVerbosity: ObservabilityVerbosity = .standard
    var observabilityCaptureSettingsSnapshot: Bool = true
    var observabilityCaptureSystemContext: Bool = true
    var observabilityCaptureTextPayloads: Bool = false
    var maxChunkDuration: Double { chunkDuration.rawValue }
    var minChunkDuration: Double { chunkDuration.minDuration }
}
