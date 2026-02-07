import Foundation
import OSLog

/// Tracks and persists usage statistics for the app
@MainActor
public final class Statistics {
    public static let shared = Statistics()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let totalSecondsTranscribed = "stats.totalSecondsTranscribed"
        static let totalCharacters = "stats.totalCharacters"
        static let totalWords = "stats.totalWords"
        static let totalApiCalls = "stats.totalApiCalls"
    }

    // MARK: - Stored Properties

    private(set) var totalSecondsTranscribed: Double {
        get { UserDefaults.standard.double(forKey: Keys.totalSecondsTranscribed) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.totalSecondsTranscribed) }
    }

    private(set) var totalCharacters: Int {
        get { UserDefaults.standard.integer(forKey: Keys.totalCharacters) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.totalCharacters) }
    }

    private(set) var totalWords: Int {
        get { UserDefaults.standard.integer(forKey: Keys.totalWords) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.totalWords) }
    }

    private(set) var totalApiCalls: Int {
        get { UserDefaults.standard.integer(forKey: Keys.totalApiCalls) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.totalApiCalls) }
    }

    private init() {}

    // MARK: - Recording Methods

    /// Record a completed transcription
    public func recordTranscription(text: String, audioDurationSeconds: Double) {
        totalSecondsTranscribed += audioDurationSeconds
        totalCharacters += text.count

        // Count words by splitting on whitespace
        let words = text.split(whereSeparator: { $0.isWhitespace })
        totalWords += words.count

        Logger.app.debug("Stats updated: +\(String(format: "%.1f", audioDurationSeconds))s, +\(text.count) chars, +\(words.count) words")
    }

    /// Record an API call (success or failure)
    public func recordApiCall() {
        totalApiCalls += 1
    }

    /// Reset all statistics
    public func reset() {
        totalSecondsTranscribed = 0
        totalCharacters = 0
        totalWords = 0
        totalApiCalls = 0
        Logger.app.info("Statistics reset")
    }

    // MARK: - Formatting

    /// Format duration as human-readable string (e.g., "2 days, 4 hours, 30 minutes, 2 seconds")
    var formattedDuration: String {
        let totalSeconds = Int(totalSecondsTranscribed)

        if totalSeconds == 0 {
            return "0 seconds"
        }

        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        var parts: [String] = []

        if days > 0 {
            parts.append("\(days) \(days == 1 ? "day" : "days")")
        }
        if hours > 0 {
            parts.append("\(hours) \(hours == 1 ? "hour" : "hours")")
        }
        if minutes > 0 {
            parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")")
        }
        if seconds > 0 || parts.isEmpty {
            parts.append("\(seconds) \(seconds == 1 ? "second" : "seconds")")
        }

        return parts.joined(separator: ", ")
    }

    /// Format character count with thousands separators
    var formattedCharacters: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: totalCharacters)) ?? "\(totalCharacters)"
    }

    /// Format word count with thousands separators
    var formattedWords: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: totalWords)) ?? "\(totalWords)"
    }

    /// Format API call count with thousands separators
    var formattedApiCalls: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: totalApiCalls)) ?? "\(totalApiCalls)"
    }

    /// Full statistics summary for display
    public var summary: String {
        """
        📊 Transcription Statistics

        ⏱ Total Duration: \(formattedDuration)
        📝 Characters: \(formattedCharacters)
        💬 Words: \(formattedWords)
        🌐 API Calls: \(formattedApiCalls)
        """
    }

    /// Raw counters exposed for automation/testing.
    public var apiCallCount: Int { totalApiCalls }
    public var wordCount: Int { totalWords }
}
