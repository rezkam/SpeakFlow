import Foundation

public enum SpeechEvent: Sendable {
    case started(at: Double)
    case ended(at: Double)
}

public struct VADResult: Sendable {
    public let probability: Float
    public let isSpeaking: Bool
    public let event: SpeechEvent?
    public let processingTimeMs: Double

    public init(probability: Float, isSpeaking: Bool, event: SpeechEvent?, processingTimeMs: Double) {
        self.probability = probability
        self.isSpeaking = isSpeaking
        self.event = event
        self.processingTimeMs = processingTimeMs
    }
}

public enum VADError: Error, Sendable {
    case notInitialized
    case unsupportedPlatform(String)
    case processingFailed(String)
}
