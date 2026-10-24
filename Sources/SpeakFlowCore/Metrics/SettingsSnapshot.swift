import Foundation

/// The recording-relevant settings written to diagnostics. Launch and
/// recording-start snapshots share it and add only their own context keys.
public enum SettingsSnapshot {
    @MainActor
    public static func values(_ settings: any SettingsProviding) -> [String: String] {
        func flag(_ value: Bool) -> String { value ? "true" : "false" }
        return [
            "batch.chunkDuration": String(settings.chunkDuration.rawValue),
            "batch.skipSilentChunks": flag(settings.skipSilentChunks),
            "batch.finalizationTimeoutBase": String(settings.batchFinalizationTimeoutBase),
            "batch.finalizationTimeoutPerChunkSecond": String(settings.batchFinalizationTimeoutPerChunkSecond),
            "batch.finalizationMaxTimeout": String(settings.batchFinalizationMaxTimeout),
            "streaming.autoEndEnabled": flag(settings.streamingAutoEndEnabled),
            "streaming.keepAliveEnabled": flag(settings.streamingKeepAliveEnabled),
            "streaming.keepAliveInterval": String(settings.streamingKeepAliveInterval),
            "streaming.reconnectEnabled": flag(settings.streamingReconnectEnabled),
            "streaming.minimumFinalWordCount": String(settings.streamingMinimumFinalWordCount),
            "streaming.trailingFinalTimeout": String(settings.streamingTrailingFinalTimeout),
            "vad.enabled": flag(settings.vadEnabled),
            "vad.threshold": String(settings.vadThreshold),
            "vad.volumeGateEnabled": flag(settings.vadVolumeGateEnabled),
            "vad.minVolumeForSpeech": String(settings.vadMinVolumeForSpeech),
            "autoEnd.enabled": flag(settings.autoEndEnabled),
            "autoEnd.silenceDuration": String(settings.autoEndSilenceDuration),
            "autoEnd.minSessionDuration": String(settings.autoEndMinSessionDuration),
            "behavior.focusWaitTimeout": String(settings.focusWaitTimeout),
            "behavior.hotkeyRestartsRecording": flag(settings.hotkeyRestartsRecording),
            "observability.captureTextPayloads": flag(settings.observabilityCaptureTextPayloads)
        ]
    }
}
