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

    // Explicit @MainActor — DateComponentsFormatter is not Sendable; even though the
    // enclosing @MainActor class isolates static members in Swift 6, being explicit
    // makes the intent clear and prevents accidental nonisolated access.
    @MainActor private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 4
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    /// Format duration using locale-aware DateComponentsFormatter.
    var formattedDuration: String {
        let totalSeconds = max(totalSecondsTranscribed, 0)

        if totalSeconds == 0 {
            return String(localized: "0 seconds")
        }

        return Self.durationFormatter.string(from: totalSeconds)
            ?? String(localized: "0 seconds")
    }

    @MainActor private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formatCount(_ value: Int) -> String {
        Self.decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Format character count with thousands separators
    var formattedCharacters: String {
        formatCount(totalCharacters)
    }

    /// Format word count with thousands separators
    var formattedWords: String {
        formatCount(totalWords)
    }

    /// Format API call count with thousands separators
    var formattedApiCalls: String {
        formatCount(totalApiCalls)
    }

#if DEBUG
    static var _testFormatterIdentity: ObjectIdentifier {
        ObjectIdentifier(decimalFormatter)
    }

    static func _testFormatCount(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
#endif

    /// Full statistics summary for display
    public var summary: String {
        """
        📊 \(String(localized: "Transcription Statistics"))

        ⏱ \(String(localized: "Total Duration")): \(formattedDuration)
        📝 \(String(localized: "Characters")): \(formattedCharacters)
        💬 \(String(localized: "Words")): \(formattedWords)
        🌐 \(String(localized: "API Calls")): \(formattedApiCalls)
        """
    }

    /// Raw counters exposed for automation/testing.
    public var apiCallCount: Int { totalApiCalls }
    public var wordCount: Int { totalWords }
}
