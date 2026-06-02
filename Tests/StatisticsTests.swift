import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - Statistics Formatter Tests

struct StatisticsFormatterCachingTests {
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

// MARK: - Statistics API Call vs Recording Semantics

/// `totalApiCalls` must reflect actual STT provider requests (per chunk in batch,
/// per session in streaming). `providerUsage[].recordings`, `languageUsage`, and
/// `dailyRecordings` must reflect user-initiated recordings. These two are not
/// the same thing in batch mode: a 4-chunk dictation produces 4 API calls but
/// 1 recording.
struct StatisticsApiCallSemanticsTests {
    @Test func recordApiCallIncrementsOnlyTotalApiCalls() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            for _ in 0..<4 {
                stats.recordApiCall()
            }

            #expect(stats.totalApiCalls == 4,
                    "Four chunks must report four API calls")
            #expect(stats.providerUsage.isEmpty,
                    "API calls alone must not populate per-provider recording rows")
            #expect(stats.languageUsage.isEmpty,
                    "API calls alone must not populate per-language recording rows")
            #expect(stats.dailyRecordingsLast30.map(\.count).reduce(0, +) == 0,
                    "API calls alone must not populate the 30-day recording histogram")
        }
    }

    @Test func recordRecordingIncrementsRecordingDimensionsNotApiCalls() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            stats.recordRecording(providerId: ProviderId.deepgram, language: "en-US")

            #expect(stats.totalApiCalls == 0,
                    "recordRecording must not inflate the API-call counter")
            #expect(stats.providerUsage[ProviderId.deepgram]?.recordings == 1,
                    "recordRecording must increment per-provider recording count")
            #expect(stats.languageUsage["en-us"] == 1,
                    "recordRecording must increment per-language recording count")
            #expect(stats.dailyRecordingsLast30.map(\.count).reduce(0, +) == 1,
                    "recordRecording must increment the 30-day recording histogram")
        }
    }

    @Test func multiChunkRecordingReportsAccurateCounts() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            // Simulate a 4-chunk batch dictation.
            stats.recordRecording(providerId: ProviderId.mistralBatch, language: "en")
            for _ in 0..<4 {
                stats.recordApiCall()
            }

            #expect(stats.totalApiCalls == 4,
                    "Each chunk send is one API call")
            #expect(stats.providerUsage[ProviderId.mistralBatch]?.recordings == 1,
                    "The user made one recording regardless of how many chunks it was split into")
        }
    }
}

// MARK: - Statistics Dashboard Data Tests

struct StatisticsDashboardDataTests {
    @Test func providerLanguageAndDailyUsageTrackRecordings() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            stats.recordRecording(providerId: ProviderId.deepgram, language: "en-US")
            stats.recordTranscription(
                text: "hello world",
                audioDurationSeconds: 2.5,
                providerId: ProviderId.deepgram,
                language: "en-US"
            )
            stats.recordRecording(providerId: ProviderId.mistralBatch, language: "")

            #expect(stats.providerUsage[ProviderId.deepgram]?.recordings == 1)
            #expect(stats.providerUsage[ProviderId.deepgram]?.words == 2)
            #expect(stats.providerUsage[ProviderId.deepgram]?.characters == 11)
            #expect(stats.providerUsage[ProviderId.deepgram]?.seconds == 2.5)
            #expect(stats.providerUsage[ProviderId.mistralBatch]?.recordings == 1)
            #expect(stats.languageUsage["en-us"] == 1)
            #expect(stats.languageUsage["auto"] == 1)
            #expect(stats.languageUsageDetails["en-us"]?.words == 2)
            #expect(stats.languageUsageDetails["en-us"]?.characters == 11)
            #expect(stats.dailyRecordingsLast30.map(\.count).reduce(0, +) == 2)
        }
    }

    @Test func periodUsageTracksAllMetricsAndDimensions() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 15))
                ?? Date(timeIntervalSince1970: 1_778_860_800)
            stats.recordRecording(providerId: ProviderId.deepgram, language: "en-US", date: date)
            stats.recordTranscription(
                text: "hello world",
                audioDurationSeconds: 2.5,
                providerId: ProviderId.deepgram,
                language: "en-US",
                date: date
            )
            stats.recordSTTLatency(seconds: 0.2, providerId: ProviderId.deepgram, language: "en-US", date: date)

            for period in Statistics.Period.allCases {
                let entries = stats.periodEntries(for: period)
                #expect(entries.count == 1)

                let usage = entries[0].usage
                #expect(usage.totals.usage.recordings == 1)
                #expect(usage.totals.usage.words == 2)
                #expect(usage.totals.usage.characters == 11)
                #expect(abs(usage.totals.usage.seconds - 2.5) < 0.001)
                #expect(usage.totals.latency.samples == 1)
                #expect(abs(usage.totals.latency.averageMs - 200) < 0.001)

                let provider = usage.providers[ProviderId.deepgram]
                #expect(provider?.usage.recordings == 1)
                #expect(provider?.usage.words == 2)
                #expect(provider?.usage.characters == 11)
                #expect(provider?.latency.samples == 1)

                let language = usage.languages["en-us"]
                #expect(language?.usage.recordings == 1)
                #expect(language?.usage.words == 2)
                #expect(language?.usage.characters == 11)
                #expect(language?.latency.samples == 1)
            }
        }
    }

    @Test func weeklyMonthlyAndYearlyUsageRollsUpDailyBuckets() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            let first = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 12))
                ?? Date(timeIntervalSince1970: 1_778_601_600)
            let second = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 13))
                ?? Date(timeIntervalSince1970: 1_778_688_000)

            stats.recordRecording(providerId: ProviderId.chatGPT, language: "en", date: first)
            stats.recordRecording(providerId: ProviderId.chatGPT, language: "en", date: second)

            #expect(stats.dailyUsage.count == 2)
            #expect(stats.weeklyUsage.count == 1)
            #expect(stats.monthlyUsage.count == 1)
            #expect(stats.yearlyUsage.count == 1)
            #expect(stats.weeklyUsage.values.map { $0.totals.usage.recordings }.reduce(0, +) == 2)
            #expect(stats.monthlyUsage.values.map { $0.totals.usage.recordings }.reduce(0, +) == 2)
            #expect(stats.yearlyUsage.values.map { $0.totals.usage.recordings }.reduce(0, +) == 2)
        }
    }

    @Test func resetClearsDashboardBreakdownData() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()

            stats.recordRecording(providerId: ProviderId.deepgram, language: "en-US")
            stats.recordTranscription(
                text: "hello world",
                audioDurationSeconds: 2.5,
                providerId: ProviderId.deepgram,
                language: "en-US"
            )
            stats.reset()

            #expect(stats.providerUsage.isEmpty)
            #expect(stats.languageUsage.isEmpty)
            #expect(stats.languageUsageDetails.isEmpty)
            #expect(stats.dailyUsage.isEmpty)
            #expect(stats.weeklyUsage.isEmpty)
            #expect(stats.monthlyUsage.isEmpty)
            #expect(stats.yearlyUsage.isEmpty)
            #expect(stats.dailyRecordingsLast30.map(\.count).reduce(0, +) == 0)
        }
    }
}

struct StatisticsFormatterTests {
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

// MARK: - Statistics Duration Tests

struct StatisticsDurationTests {
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

// MARK: - STT Latency Tests

struct StatisticsLatencyTests {
    @Test func testLatencyPercentilesTrackRecordedSamples() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            stats.recordSTTLatency(seconds: 0.10) // 100ms
            stats.recordSTTLatency(seconds: 0.20) // 200ms
            stats.recordSTTLatency(seconds: 0.50) // 500ms
            stats.recordSTTLatency(seconds: 1.00) // 1000ms

            #expect(stats.sttLatencyP50Ms >= 200 && stats.sttLatencyP50Ms <= 500)
            #expect(stats.sttLatencyP95Ms >= 500)
            #expect(stats.sttLatencyP99Ms >= stats.sttLatencyP95Ms)
        }
    }
}

// MARK: - Statistics Formatter Isolation Tests

@Suite("Statistics formatter explicit @MainActor isolation")
struct StatisticsFormatterIsolationTests {

    /// Behavioral: formatters remain stable after explicit @MainActor annotation.
    @Test func testFormattersStillProduceCorrectOutput() async {
        await MainActor.run {
            let stats = Statistics.shared
            stats.reset()
            defer { stats.reset() }

            // Duration formatting — zero case
            #expect(!stats.formattedDuration.isEmpty, "formattedDuration must produce output")

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
