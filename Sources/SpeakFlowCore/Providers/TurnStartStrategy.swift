import Foundation

/// Configurable strategies for detecting the start of a conversational turn.
public enum TurnStartStrategy: Sendable, Equatable {
    /// Start turn on provider `speechStarted` events.
    case providerSpeechStarted
    /// Start turn when first non-empty transcription text arrives.
    case firstTranscription
    /// Start turn once transcription has at least N words.
    case minimumWords(Int)
}

/// Strategy that triggered a turn start.
public enum TurnStartTrigger: Sendable, Equatable {
    case providerSpeechStarted
    case firstTranscription
    case minimumWords(Int)
}
