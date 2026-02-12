import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - Statistics Formatter Tests

struct StatisticsFormatterTests {
    @Test func testFormattedCountsMatchDecimalFormatterOutput() async {
        await MainActor.run {
            let expected = NumberFormatter.localizedString(from: NSNumber(value: 1_234_567), number: .decimal)
            let actual = Statistics._testFormatCount(1_234_567)
            #expect(actual == expected)
        }
    }

    @Test func testFormatterIdentityIsStableAcrossCalls() async {
        await MainActor.run {
            let first = Statistics._testFormatterIdentity
            _ = Statistics._testFormatCount(1)
            _ = Statistics._testFormatCount(2)
            _ = Statistics._testFormatCount(3)
            let second = Statistics._testFormatterIdentity
            #expect(first == second)
        }
    }
}

struct StatisticsFormatterRegressionTests {
    @Test func testCachedFormatterProducesConsistentResultsAfterRepeatedUse() async {
        await MainActor.run {
            let baselineId = Statistics._testFormatterIdentity

            for value in [10, 100, 1000, 10_000, 100_000] {
                let expected = NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
                let actual = Statistics._testFormatCount(value)
                #expect(actual == expected)
            }

            let endId = Statistics._testFormatterIdentity
            #expect(baselineId == endId)
        }
    }

    @Test func testFormattedPropertiesReuseSameCachedFormatter() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            stats.recordTranscription(text: "one two three", audioDurationSeconds: 12.3)
            stats.recordApiCall()

            let before = Statistics._testFormatterIdentity
            _ = stats.formattedCharacters
            _ = stats.formattedWords
            _ = stats.formattedApiCalls
            let after = Statistics._testFormatterIdentity

            #expect(before == after)
        }
    }
}

// MARK: - Statistics Duration Regression Tests

struct StatisticsDurationRegressionTests {
    @Test func testFormattedDurationMatchesDateComponentsFormatter() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            let duration: Double = 90_061 // 1 day, 1 hour, 1 minute, 1 second
            stats.recordTranscription(text: "duration", audioDurationSeconds: duration)

            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 3
            formatter.zeroFormattingBehavior = .dropAll

            let expected = formatter.string(from: duration) ?? String(localized: "0s")
            #expect(stats.formattedDuration == expected)
        }
    }

    @Test func testFormattedDurationZeroUsesLocalizedFallback() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            #expect(stats.formattedDuration == String(localized: "0s"))
        }
    }
}

// MARK: - Statistics Formatter Isolation Tests

@Suite("P2 — Statistics formatter explicit @MainActor isolation")
struct StatisticsFormatterIsolationTests {

    /// Behavioral: formatters remain stable after explicit @MainActor annotation.
    @Test func testFormattersStillProduceCorrectOutput() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            // Duration formatting — zero case
            #expect(stats.formattedDuration.count > 0, "formattedDuration must produce output")

            // Duration formatting — non-zero case
            stats.recordTranscription(text: "test", audioDurationSeconds: 60.0)
            #expect(stats.formattedDuration.contains("1"), "1 minute should appear in formatted duration")

            // Decimal formatting
            let count = Statistics._testFormatCount(42)
            #expect(count == "42" || count.contains("42"),
                    "Decimal formatter must still produce correct output")
        }
    }
}
