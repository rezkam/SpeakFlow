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
    var sttLatencyP50Ms: Double { get }
    var sttLatencyP95Ms: Double { get }
    var sttLatencyP99Ms: Double { get }
    var providerUsage: [String: Statistics.UsageEntry] { get }
    var languageUsage: [String: Int] { get }
    var languageUsageDetails: [String: Statistics.UsageEntry] { get }
    var lastResetDate: Date { get }
    var dailyUsage: [String: Statistics.PeriodUsage] { get }
    var weeklyUsage: [String: Statistics.PeriodUsage] { get }
    var monthlyUsage: [String: Statistics.PeriodUsage] { get }
    var yearlyUsage: [String: Statistics.PeriodUsage] { get }
    var dailyRecordingsLast30: [Statistics.DailyRecording] { get }
    func usage(for period: Statistics.Period) -> [String: Statistics.PeriodUsage]
    func periodEntries(for period: Statistics.Period) -> [Statistics.PeriodEntry]
    func recordTranscription(text: String, audioDurationSeconds: Double)
    func recordTranscription(text: String, audioDurationSeconds: Double, providerId: String?, language: String?)
    func recordApiCall()
    func recordApiCall(providerId: String?, language: String?)
    func recordRecording(providerId: String?, language: String?)
    func recordSTTLatency(seconds: TimeInterval)
    func recordSTTLatency(seconds: TimeInterval, providerId: String?, language: String?)
    func reset()
}

public extension StatisticsProviding {
    var providerUsage: [String: Statistics.UsageEntry] { [:] }
    var languageUsage: [String: Int] { [:] }
    var languageUsageDetails: [String: Statistics.UsageEntry] { [:] }
    var lastResetDate: Date { Date(timeIntervalSince1970: 0) }
    var dailyUsage: [String: Statistics.PeriodUsage] { [:] }
    var weeklyUsage: [String: Statistics.PeriodUsage] { [:] }
    var monthlyUsage: [String: Statistics.PeriodUsage] { [:] }
    var yearlyUsage: [String: Statistics.PeriodUsage] { [:] }
    var dailyRecordingsLast30: [Statistics.DailyRecording] { [] }

    func usage(for period: Statistics.Period) -> [String: Statistics.PeriodUsage] { [:] }

    func periodEntries(for period: Statistics.Period) -> [Statistics.PeriodEntry] { [] }

    func recordTranscription(text: String, audioDurationSeconds: Double, providerId: String?, language: String?) {
        recordTranscription(text: text, audioDurationSeconds: audioDurationSeconds)
    }

    func recordApiCall(providerId: String?, language: String?) {
        recordApiCall()
    }

    func recordRecording(providerId: String?, language: String?) {
        // Default: do nothing. Conformers that care about per-recording stats
        // should override this.
    }

    func recordSTTLatency(seconds: TimeInterval, providerId: String?, language: String?) {
        recordSTTLatency(seconds: seconds)
    }
}
