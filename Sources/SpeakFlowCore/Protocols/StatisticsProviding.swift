import Foundation

/// Abstracts Statistics for dependency injection.
@MainActor
public protocol StatisticsProviding: AnyObject {
    var totalSecondsTranscribed: Double { get }
    var totalCharacters: Int { get }
    var totalWords: Int { get }
    var totalApiCalls: Int { get }
    var apiCallCount: Int { get }
    var wordCount: Int { get }
    var formattedDuration: String { get }
    var formattedCharacters: String { get }
    var formattedWords: String { get }
    var formattedApiCalls: String { get }
    func recordTranscription(text: String, audioDurationSeconds: Double)
    func recordApiCall()
    func reset()
}
