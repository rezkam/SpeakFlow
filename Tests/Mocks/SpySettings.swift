import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
final class SpySettings: SettingsProviding {
    var chunkDuration: ChunkDuration = .minute1
    var skipSilentChunks: Bool = true
    var vadEnabled: Bool = true
    var vadThreshold: Float = 0.15
    var autoEndEnabled: Bool = true
    var autoEndSilenceDuration: Double = 5.0
    var minSpeechRatio: Float = 0.01
    var streamingAutoEndEnabled: Bool = false
    var deepgramInterimResults: Bool = true
    var deepgramSmartFormat: Bool = true
    var deepgramEndpointingMs: Int = 300
    var deepgramModel: String = "nova-3"
    var deepgramLanguage: String = "en-US"
    var maxChunkDuration: Double { chunkDuration.rawValue }
    var minChunkDuration: Double { chunkDuration.minDuration }
}
