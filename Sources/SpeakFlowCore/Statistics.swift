import Foundation
import OSLog

/// Tracks and persists usage statistics as a JSON file in `~/.speakflow/`.
///
/// Uses `Codable` for clean serialization, independent of UserDefaults and
/// bundle identifiers. The file is written atomically on every mutation to
/// avoid data loss.
@MainActor
public final class Statistics {
    public static let shared = Statistics()

    // MARK: - Persisted Data

    public enum Period: String, Codable, CaseIterable, Sendable {
        case day
        case week
        case month
        case year
    }

    public struct UsageEntry: Codable, Hashable, Sendable {
        public var recordings: Int
        public var words: Int
        public var characters: Int
        public var seconds: Double

        public init(recordings: Int = 0, words: Int = 0, characters: Int = 0, seconds: Double = 0) {
            self.recordings = recordings
            self.words = words
            self.characters = characters
            self.seconds = seconds
        }

        private enum CodingKeys: String, CodingKey {
            case recordings
            case words
            case characters
            case seconds
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            recordings = try container.decodeIfPresent(Int.self, forKey: .recordings) ?? 0
            words = try container.decodeIfPresent(Int.self, forKey: .words) ?? 0
            characters = try container.decodeIfPresent(Int.self, forKey: .characters) ?? 0
            seconds = try container.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        }
    }

    public struct LatencySummary: Codable, Hashable, Sendable {
        public var samples: Int
        public var totalMs: Double
        public var minMs: Double
        public var maxMs: Double

        public var averageMs: Double {
            samples == 0 ? 0 : totalMs / Double(samples)
        }

        public init(samples: Int = 0, totalMs: Double = 0, minMs: Double = 0, maxMs: Double = 0) {
            self.samples = samples
            self.totalMs = totalMs
            self.minMs = minMs
            self.maxMs = maxMs
        }

        mutating func record(milliseconds: Double) {
            guard milliseconds.isFinite, milliseconds >= 0 else { return }
            if samples == 0 {
                minMs = milliseconds
                maxMs = milliseconds
            } else {
                minMs = min(minMs, milliseconds)
                maxMs = max(maxMs, milliseconds)
            }
            samples += 1
            totalMs += milliseconds
        }
    }

    public struct DimensionUsage: Codable, Hashable, Sendable {
        public var usage: UsageEntry
        public var latency: LatencySummary

        public init(usage: UsageEntry = UsageEntry(), latency: LatencySummary = LatencySummary()) {
            self.usage = usage
            self.latency = latency
        }
    }

    public struct PeriodUsage: Codable, Hashable, Sendable {
        public var startDate: Date
        public var totals: DimensionUsage
        public var providers: [String: DimensionUsage]
        public var languages: [String: DimensionUsage]

        public init(
            startDate: Date = Date(timeIntervalSince1970: 0),
            totals: DimensionUsage = DimensionUsage(),
            providers: [String: DimensionUsage] = [:],
            languages: [String: DimensionUsage] = [:]
        ) {
            self.startDate = startDate
            self.totals = totals
            self.providers = providers
            self.languages = languages
        }
    }

    public struct PeriodEntry: Identifiable, Hashable, Sendable {
        public let period: Period
        public let key: String
        public let startDate: Date
        public let usage: PeriodUsage

        public var id: String { "\(period.rawValue):\(key)" }

        public init(period: Period, key: String, startDate: Date, usage: PeriodUsage) {
            self.period = period
            self.key = key
            self.startDate = startDate
            self.usage = usage
        }
    }

    public struct DailyRecording: Identifiable, Hashable, Sendable {
        public let date: Date
        public let count: Int

        public var id: Date { date }

        public init(date: Date, count: Int) {
            self.date = date
            self.count = count
        }
    }

    private struct PeriodUsageStore: Codable, Hashable, Sendable {
        var days: [String: PeriodUsage] = [:]
        var weeks: [String: PeriodUsage] = [:]
        var months: [String: PeriodUsage] = [:]
        var years: [String: PeriodUsage] = [:]

        func usage(for period: Period) -> [String: PeriodUsage] {
            switch period {
            case .day: days
            case .week: weeks
            case .month: months
            case .year: years
            }
        }
    }

    private struct Data: Codable {
        var totalSecondsTranscribed: Double = 0
        var totalCharacters: Int = 0
        var totalWords: Int = 0
        var totalApiCalls: Int = 0
        var sttLatencyMs: [Double] = []
        var providerUsage: [String: UsageEntry] = [:]
        var languageUsage: [String: Int] = [:]
        var languageUsageDetails: [String: UsageEntry] = [:]
        var lastResetDate: Date = Date()
        var dailyRecordings: [String: Int] = [:]
        var periodUsage: PeriodUsageStore = PeriodUsageStore()

        private enum CodingKeys: String, CodingKey {
            case totalSecondsTranscribed
            case totalCharacters
            case totalWords
            case totalApiCalls
            case sttLatencyMs
            case providerUsage
            case languageUsage
            case languageUsageDetails
            case lastResetDate
            case dailyRecordings
            case periodUsage
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalSecondsTranscribed = try container.decodeIfPresent(Double.self, forKey: .totalSecondsTranscribed) ?? 0
            totalCharacters = try container.decodeIfPresent(Int.self, forKey: .totalCharacters) ?? 0
            totalWords = try container.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
            totalApiCalls = try container.decodeIfPresent(Int.self, forKey: .totalApiCalls) ?? 0
            sttLatencyMs = try container.decodeIfPresent([Double].self, forKey: .sttLatencyMs) ?? []
            providerUsage = try container.decodeIfPresent([String: UsageEntry].self, forKey: .providerUsage) ?? [:]
            languageUsage = try container.decodeIfPresent([String: Int].self, forKey: .languageUsage) ?? [:]
            languageUsageDetails = try container.decodeIfPresent([String: UsageEntry].self, forKey: .languageUsageDetails) ?? [:]
            lastResetDate = try container.decodeIfPresent(Date.self, forKey: .lastResetDate) ?? Date(timeIntervalSince1970: 0)
            dailyRecordings = try container.decodeIfPresent([String: Int].self, forKey: .dailyRecordings) ?? [:]
            periodUsage = try container.decodeIfPresent(PeriodUsageStore.self, forKey: .periodUsage) ?? PeriodUsageStore()
            migrateLegacyLanguageUsage()
            migrateLegacyDailyRecordings()
        }

        private mutating func migrateLegacyLanguageUsage() {
            guard languageUsageDetails.isEmpty else { return }
            languageUsageDetails = languageUsage.mapValues { UsageEntry(recordings: $0) }
        }

        private mutating func migrateLegacyDailyRecordings() {
            guard periodUsage.days.isEmpty,
                  periodUsage.weeks.isEmpty,
                  periodUsage.months.isEmpty,
                  periodUsage.years.isEmpty else { return }

            for (key, count) in dailyRecordings {
                guard let date = Statistics.date(fromDayKey: key) else { continue }
                var usage = PeriodUsage(startDate: Statistics.periodStartDate(for: date, period: .day))
                usage.totals.usage.recordings = count
                periodUsage.days[key] = usage

                for period in [Period.week, .month, .year] {
                    let periodKey = Statistics.periodKey(for: date, period: period)
                    let startDate = Statistics.periodStartDate(for: date, period: period)
                    var bucket = periodUsage.usage(for: period)[periodKey] ?? PeriodUsage(startDate: startDate)
                    bucket.totals.usage.recordings += count
                    switch period {
                    case .day:
                        break
                    case .week:
                        periodUsage.weeks[periodKey] = bucket
                    case .month:
                        periodUsage.months[periodKey] = bucket
                    case .year:
                        periodUsage.years[periodKey] = bucket
                    }
                }
            }
        }
    }

    private var data: Data
    private static let sttLatencySampleCapacity = 100

    private static let storageURL: URL = {
        let base: URL
        // Detect test runner: main bundle path contains .xctest, or xctest is in args
        let isTestRun = Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })
        if isTestRun {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("speakflow-test-\(ProcessInfo.processInfo.processIdentifier)")
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".speakflow")
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("statistics.json")
    }()

    private init() {
        if let fileData = try? Foundation.Data(contentsOf: Self.storageURL),
           let decoded = try? JSONDecoder().decode(Data.self, from: fileData) {
            data = decoded
        } else {
            data = Data()
        }
    }

    // MARK: - Public Counters

    public var totalSecondsTranscribed: Double { data.totalSecondsTranscribed }
    public var totalCharacters: Int { data.totalCharacters }
    public var totalWords: Int { data.totalWords }
    public var totalApiCalls: Int { data.totalApiCalls }
    public var sttLatencyP50Ms: Double { percentile(data.sttLatencyMs, 0.50) }
    public var sttLatencyP95Ms: Double { percentile(data.sttLatencyMs, 0.95) }
    public var sttLatencyP99Ms: Double { percentile(data.sttLatencyMs, 0.99) }
    public var providerUsage: [String: UsageEntry] { data.providerUsage }
    public var languageUsage: [String: Int] { data.languageUsage }
    public var languageUsageDetails: [String: UsageEntry] { data.languageUsageDetails }
    public var lastResetDate: Date { data.lastResetDate }
    public var dailyUsage: [String: PeriodUsage] { data.periodUsage.days }
    public var weeklyUsage: [String: PeriodUsage] { data.periodUsage.weeks }
    public var monthlyUsage: [String: PeriodUsage] { data.periodUsage.months }
    public var yearlyUsage: [String: PeriodUsage] { data.periodUsage.years }
    public var dailyRecordingsLast30: [DailyRecording] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = Self.dayKey(for: date, calendar: calendar)
            let count = data.periodUsage.days[key]?.totals.usage.recordings ?? data.dailyRecordings[key] ?? 0
            return DailyRecording(date: date, count: count)
        }
    }

    /// Convenience aliases for automation/testing.
    public var apiCallCount: Int { data.totalApiCalls }
    public var wordCount: Int { data.totalWords }

    public func usage(for period: Period) -> [String: PeriodUsage] {
        data.periodUsage.usage(for: period)
    }

    public func periodEntries(for period: Period) -> [PeriodEntry] {
        data.periodUsage.usage(for: period)
            .map { key, usage in
                PeriodEntry(period: period, key: key, startDate: usage.startDate, usage: usage)
            }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate { return lhs.key < rhs.key }
                return lhs.startDate < rhs.startDate
            }
    }

    // MARK: - Dirty-flag debounce
    //
    // Previous: every mutation called `save()` immediately, performing a
    //   `JSONEncoder().encode()` + atomic `Data.write()` (two syscalls) per call.
    //   `Transcription.transcribe()` calls `recordApiCall()` then
    //   `recordTranscription()` on every chunk — so two disk flushes per chunk.
    //
    // Now: mutations mark the data dirty and schedule a 5-second flush Task.
    // Concurrent mutations within the same 5s window share one flush.
    // `save()` is called immediately only from `reset()` (to preserve the
    // zero-state on disk) and from `flushIfDirty()` on app background/terminate.
    //
    // Safety: `@MainActor` isolation means no race between `markDirty`,
    //   `scheduleFlush`, and `flushIfDirty`. The flush Task captures `[weak self]`
    //   so it doesn't prevent deallocation in tests.

    private var isDirty = false
    private var flushTask: Task<Void, Never>?

    /// Mark data as needing a flush and arm the debounce timer if not already armed.
    private func markDirty() {
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                self?.flushIfDirty()
                self?.flushTask = nil
            }
        }
    }

    /// Write to disk if dirty. Called by the debounce timer and at app lifecycle events.
    public func flushIfDirty() {
        guard isDirty else { return }
        isDirty = false
        save()
    }

    // MARK: - Recording

    public func recordTranscription(text: String, audioDurationSeconds: Double) {
        recordTranscription(
            text: text,
            audioDurationSeconds: audioDurationSeconds,
            providerId: nil,
            language: nil
        )
    }

    public func recordTranscription(
        text: String,
        audioDurationSeconds: Double,
        providerId: String?,
        language: String?
    ) {
        recordTranscription(
            text: text,
            audioDurationSeconds: audioDurationSeconds,
            providerId: providerId,
            language: language,
            date: Date()
        )
    }

    public func recordTranscription(
        text: String,
        audioDurationSeconds: Double,
        providerId: String?,
        language: String?,
        date: Date
    ) {
        data.totalSecondsTranscribed += audioDurationSeconds
        data.totalCharacters += text.count

        let words = text.split(whereSeparator: { $0.isWhitespace })
        let wordCount = words.count
        data.totalWords += words.count
        let normalizedProvider = normalizedProviderId(providerId)
        let normalizedLanguage = normalizedLanguage(language)

        if let providerId = normalizedProvider {
            var entry = data.providerUsage[providerId] ?? UsageEntry()
            entry.words += wordCount
            entry.characters += text.count
            entry.seconds += audioDurationSeconds
            data.providerUsage[providerId] = entry
        }

        if let language = normalizedLanguage {
            var entry = data.languageUsageDetails[language] ?? UsageEntry(recordings: data.languageUsage[language] ?? 0)
            entry.words += wordCount
            entry.characters += text.count
            entry.seconds += audioDurationSeconds
            data.languageUsageDetails[language] = entry
        }

        updatePeriodUsage(date: date, providerId: normalizedProvider, language: normalizedLanguage) { usage in
            usage.usage.words += wordCount
            usage.usage.characters += text.count
            usage.usage.seconds += audioDurationSeconds
        }

        markDirty()

        Logger.app.debug("Stats updated: +\(String(format: "%.1f", audioDurationSeconds))s, +\(text.count) chars, +\(words.count) words")
    }

    /// Record a single STT API request to the active provider. In batch mode
    /// this fires once per chunk; in streaming mode it fires once per WebSocket
    /// session. It increments `totalApiCalls` only. Per-recording counters live
    /// in `recordRecording(...)` so a 4-chunk batch dictation reports 4 API
    /// calls and 1 recording.
    public func recordApiCall() {
        data.totalApiCalls += 1
        markDirty()
    }

    /// Backwards-compat overload. Provider and language are no longer needed
    /// for the API-call counter (they describe a recording, not a request),
    /// but callers passing them stay working.
    public func recordApiCall(providerId: String?, language: String?) {
        recordApiCall()
        _ = providerId
        _ = language
    }

    /// Record one user-initiated recording. Increments per-provider,
    /// per-language, daily, and period recording counters. Decoupled from
    /// `recordApiCall()` so the API-call statistic stays accurate per request.
    public func recordRecording(providerId: String?, language: String?) {
        recordRecording(providerId: providerId, language: language, date: Date())
    }

    public func recordRecording(providerId: String?, language: String?, date: Date) {
        let normalizedProvider = normalizedProviderId(providerId)
        let normalizedLanguage = normalizedLanguage(language)

        if let providerId = normalizedProvider {
            var entry = data.providerUsage[providerId] ?? UsageEntry()
            entry.recordings += 1
            data.providerUsage[providerId] = entry
        }

        if let language = normalizedLanguage {
            data.languageUsage[language, default: 0] += 1
            var entry = data.languageUsageDetails[language] ?? UsageEntry()
            entry.recordings += 1
            data.languageUsageDetails[language] = entry
        }

        let key = Self.dayKey(for: date)
        data.dailyRecordings[key, default: 0] += 1
        updatePeriodUsage(date: date, providerId: normalizedProvider, language: normalizedLanguage) { usage in
            usage.usage.recordings += 1
        }
        markDirty()
    }

    /// Record STT request latency in seconds (stored internally as milliseconds).
    public func recordSTTLatency(seconds: TimeInterval) {
        recordSTTLatency(seconds: seconds, providerId: nil, language: nil, date: Date())
    }

    public func recordSTTLatency(seconds: TimeInterval, providerId: String?, language: String?) {
        recordSTTLatency(seconds: seconds, providerId: providerId, language: language, date: Date())
    }

    public func recordSTTLatency(seconds: TimeInterval, providerId: String?, language: String?, date: Date) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let milliseconds = seconds * 1000

        if data.sttLatencyMs.count >= Self.sttLatencySampleCapacity {
            data.sttLatencyMs.removeFirst()
        }
        data.sttLatencyMs.append(milliseconds)
        updatePeriodUsage(
            date: date,
            providerId: normalizedProviderId(providerId),
            language: normalizedLanguage(language)
        ) { usage in
            usage.latency.record(milliseconds: milliseconds)
        }
        markDirty()
    }

    public func reset() {
        flushTask?.cancel()
        flushTask = nil
        isDirty = false
        data = Data()
        data.lastResetDate = Date()
        save()
        Logger.app.info("Statistics reset")
    }

    // MARK: - Formatting

    @MainActor private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 3
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    @MainActor private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formatCount(_ value: Int) -> String {
        Self.decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public var formattedDuration: String {
        let seconds = max(data.totalSecondsTranscribed, 0)
        if seconds == 0 { return String(localized: "0s") }
        return Self.durationFormatter.string(from: seconds) ?? String(localized: "0s")
    }

    public var formattedCharacters: String { formatCount(data.totalCharacters) }
    public var formattedWords: String { formatCount(data.totalWords) }
    public var formattedApiCalls: String { formatCount(data.totalApiCalls) }

#if DEBUG
    // swiftlint:disable:next identifier_name
    static var _testFormatterIdentity: ObjectIdentifier {
        ObjectIdentifier(decimalFormatter)
    }

    // swiftlint:disable:next identifier_name
    static func _testFormatCount(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
#endif

    // MARK: - Persistence

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = Int(Double(sorted.count - 1) * clamped)
        return sorted[index]
    }

    private func normalizedProviderId(_ providerId: String?) -> String? {
        guard let providerId = providerId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerId.isEmpty else { return nil }
        return providerId
    }

    private func normalizedLanguage(_ language: String?) -> String? {
        guard let rawLanguage = language else { return nil }
        let language = rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty ? "auto" : language.lowercased()
    }

    private func updatePeriodUsage(
        date: Date,
        providerId: String?,
        language: String?,
        update: (inout DimensionUsage) -> Void
    ) {
        for period in Period.allCases {
            let key = Self.periodKey(for: date, period: period)
            let startDate = Self.periodStartDate(for: date, period: period)
            switch period {
            case .day:
                updatePeriodBucket(&data.periodUsage.days, key: key, startDate: startDate, providerId: providerId, language: language, update: update)
            case .week:
                updatePeriodBucket(&data.periodUsage.weeks, key: key, startDate: startDate, providerId: providerId, language: language, update: update)
            case .month:
                updatePeriodBucket(&data.periodUsage.months, key: key, startDate: startDate, providerId: providerId, language: language, update: update)
            case .year:
                updatePeriodBucket(&data.periodUsage.years, key: key, startDate: startDate, providerId: providerId, language: language, update: update)
            }
        }
    }

    private func updatePeriodBucket(
        _ buckets: inout [String: PeriodUsage],
        key: String,
        startDate: Date,
        providerId: String?,
        language: String?,
        update: (inout DimensionUsage) -> Void
    ) {
        var bucket = buckets[key] ?? PeriodUsage(startDate: startDate)
        bucket.startDate = startDate
        update(&bucket.totals)
        if let providerId {
            var providerUsage = bucket.providers[providerId] ?? DimensionUsage()
            update(&providerUsage)
            bucket.providers[providerId] = providerUsage
        }
        if let language {
            var languageUsage = bucket.languages[language] ?? DimensionUsage()
            update(&languageUsage)
            bucket.languages[language] = languageUsage
        }
        buckets[key] = bucket
    }

    nonisolated private static func periodKey(for date: Date, period: Period) -> String {
        switch period {
        case .day:
            return dayKey(for: date)
        case .week:
            let calendar = isoCalendar()
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(
                format: "%04d-W%02d",
                components.yearForWeekOfYear ?? 0,
                components.weekOfYear ?? 0
            )
        case .month:
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        case .year:
            let components = Calendar.current.dateComponents([.year], from: date)
            return String(format: "%04d", components.year ?? 0)
        }
    }

    nonisolated private static func periodStartDate(for date: Date, period: Period) -> Date {
        switch period {
        case .day:
            return Calendar.current.startOfDay(for: date)
        case .week:
            return isoCalendar().dateInterval(of: .weekOfYear, for: date)?.start ?? Calendar.current.startOfDay(for: date)
        case .month:
            return Calendar.current.dateInterval(of: .month, for: date)?.start ?? Calendar.current.startOfDay(for: date)
        case .year:
            return Calendar.current.dateInterval(of: .year, for: date)?.start ?? Calendar.current.startOfDay(for: date)
        }
    }

    nonisolated private static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    nonisolated private static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    nonisolated private static func isoCalendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = Calendar.current.timeZone
        return calendar
    }

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: Self.storageURL, options: .atomic)
        } catch {
            Logger.app.error("Failed to save statistics: \(error.localizedDescription)")
        }
    }
}

extension Statistics: StatisticsProviding {}
