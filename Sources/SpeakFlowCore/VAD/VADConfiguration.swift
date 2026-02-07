import Foundation

public struct VADConfiguration: Sendable {
    public var threshold: Float
    public var minSilenceAfterSpeech: TimeInterval
    public var minSpeechDuration: TimeInterval
    public var enabled: Bool

    public init(threshold: Float = 0.5, minSilenceAfterSpeech: TimeInterval = 1.0,
                minSpeechDuration: TimeInterval = 0.25, enabled: Bool = true) {
        self.threshold = threshold
        self.minSilenceAfterSpeech = minSilenceAfterSpeech
        self.minSpeechDuration = minSpeechDuration
        self.enabled = enabled
    }

    public static let `default` = VADConfiguration()
    public static let sensitive = VADConfiguration(threshold: 0.3)
    public static let strict = VADConfiguration(threshold: 0.7)
}
