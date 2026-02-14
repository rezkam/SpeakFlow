import Foundation

// MARK: - Focused Settings Protocols

/// Batch recording settings (chunk size, silence skipping).
@MainActor
public protocol BatchSettingsProviding: AnyObject {
    var chunkDuration: ChunkDuration { get set }
    var skipSilentChunks: Bool { get set }
    var maxChunkDuration: Double { get }
    var minChunkDuration: Double { get }
}

/// Streaming (Deepgram) session settings.
@MainActor
public protocol StreamingSettingsProviding: AnyObject {
    var deepgramInterimResults: Bool { get set }
    var deepgramSmartFormat: Bool { get set }
    var deepgramEndpointingMs: Int { get set }
    var deepgramModel: String { get set }
    var deepgramLanguage: String { get set }
    var streamingAutoEndEnabled: Bool { get set }
}

/// Voice Activity Detection and auto-end settings.
@MainActor
public protocol VADSettingsProviding: AnyObject {
    var vadEnabled: Bool { get set }
    var vadThreshold: Float { get set }
    var autoEndEnabled: Bool { get set }
    var autoEndSilenceDuration: Double { get set }
    var minSpeechRatio: Float { get set }
}

// MARK: - Composite Protocol

/// Full settings surface — existing consumers continue to use this unchanged.
@MainActor
public protocol SettingsProviding: BatchSettingsProviding, StreamingSettingsProviding, VADSettingsProviding {}
