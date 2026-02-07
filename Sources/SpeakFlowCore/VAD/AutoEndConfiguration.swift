import Foundation

public struct AutoEndConfiguration: Sendable {
    public var enabled: Bool
    public var silenceDuration: TimeInterval
    public var minSessionDuration: TimeInterval
    public var requireSpeechFirst: Bool
    /// Maximum time to wait for any speech before auto-ending session.
    /// Prevents sessions from hanging forever when only non-vocal audio
    /// (tones, silence, noise) is detected. Set to 0 to disable.
    public var noSpeechTimeout: TimeInterval

    public init(enabled: Bool = true, silenceDuration: TimeInterval = 5.0,
                minSessionDuration: TimeInterval = 2.0, requireSpeechFirst: Bool = true,
                noSpeechTimeout: TimeInterval = 10.0) {
        self.enabled = enabled
        self.silenceDuration = silenceDuration
        self.minSessionDuration = minSessionDuration
        self.requireSpeechFirst = requireSpeechFirst
        self.noSpeechTimeout = noSpeechTimeout
    }

    public static let `default` = AutoEndConfiguration()
    public static let quick = AutoEndConfiguration(silenceDuration: 3.0)
    public static let relaxed = AutoEndConfiguration(silenceDuration: 10.0)
    public static let disabled = AutoEndConfiguration(enabled: false)
}
