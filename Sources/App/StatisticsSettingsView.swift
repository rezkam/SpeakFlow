import SwiftUI
import SpeakFlowCore

/// Dashboard-style transcription usage statistics.
struct StatisticsSettingsView: View {
    @Environment(\.statistics) private var stats
    @State private var showResetConfirm = false
    @State private var recentSessions: [SessionMetrics] = []

    private let historicalProviderId = "historical-unknown-provider"
    private let unknownLanguageId = "unknown"

    private var providerEntries: [BreakdownEntry] {
        effectiveProviderUsage
            .map { providerId, usage in
                BreakdownEntry(
                    id: providerId,
                    title: providerLabel(providerId),
                    subtitle: providerSubtitle(providerId, recordings: usage.recordings),
                    value: formatCount(usage.words),
                    detail: "words",
                    count: usage.recordings
                )
            }
            .sorted { lhs, rhs in
                if lhs.id == historicalProviderId { return false }
                if rhs.id == historicalProviderId { return true }
                if lhs.count == rhs.count { return lhs.title < rhs.title }
                return lhs.count > rhs.count
            }
    }

    private var languageEntries: [BreakdownEntry] {
        effectiveLanguageUsage
            .map { language, count in
                BreakdownEntry(
                    id: language,
                    title: languageLabel(language),
                    subtitle: languageSubtitle(language),
                    value: formatCount(count),
                    detail: "recordings",
                    count: count
                )
            }
            .sorted { lhs, rhs in
                if lhs.id == unknownLanguageId { return false }
                if rhs.id == unknownLanguageId { return true }
                if lhs.count == rhs.count { return lhs.title < rhs.title }
                return lhs.count > rhs.count
            }
    }

    private var dailyRecordings: [Statistics.DailyRecording] {
        mergeDailyRecordings(stats.dailyRecordingsLast30, recentDailyRecordings)
    }

    private var dailyRecordingsArePartial: Bool {
        stats.dailyRecordingsLast30.map(\.count).reduce(0, +) == 0
            && recentDailyRecordings.map(\.count).reduce(0, +) > 0
    }

    var body: some View {
        VStack(spacing: 16) {
            hero
            metricsGrid
            breakdownGrid
            HeatmapCard(days: dailyRecordings, isPartial: dailyRecordingsArePartial)
            footerBar
        }
        .task {
            recentSessions = await SessionMetricsStore.shared.recentCompletedSessions(
                after: stats.lastResetDate,
                limit: 200
            )
        }
    }

    private var hero: some View {
        let counts = dailyRecordings.map(\.count)
        let last7 = counts.suffix(7).reduce(0, +)
        let prev7 = counts.dropLast(7).suffix(7).reduce(0, +)
        let trendBase = max(prev7, 1)
        let trendPct = Int(((Double(last7) - Double(prev7)) / Double(trendBase)) * 100)
        let trendUp = trendPct >= 0
        let totalLast30 = counts.reduce(0, +)

        return HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("LAST 30 DAYS")
                }
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.accent)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(formatCount(totalLast30))
                        .font(.system(size: 38, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    HStack(spacing: 4) {
                        Image(systemName: trendUp ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(abs(trendPct))%")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                        Text("vs prior 7d")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.text3)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(trendUp ? Theme.greenSoft : Color(light: 0xC8453D, dark: 0xC8453D, lightAlpha: 0.13, darkAlpha: 0.18))
                    )
                    .foregroundStyle(trendUp ? Theme.green : Theme.red)
                }

                Text("Recordings · \(formatCount(totalLast30)) total")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
            }

            Spacer(minLength: 12)

            SparklineView(values: counts)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 260, minHeight: 80, idealHeight: 92, maxHeight: 100)
                .layoutPriority(1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            LinearGradient(
                colors: [Theme.card, Theme.accentSoft.opacity(0.4)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10
        ) {
            MetricCard(
                icon: "clock.fill",
                iconColor: Theme.blue,
                value: stats.formattedDuration,
                label: "Total duration"
            )
            MetricCard(
                icon: "text.alignleft",
                iconColor: Theme.accent,
                value: stats.formattedWords,
                label: "Words transcribed"
            )
            MetricCard(
                icon: "mic.fill",
                iconColor: Theme.green,
                value: stats.formattedApiCalls,
                label: "API calls"
            )
            MetricCard(
                icon: "bolt.fill",
                iconColor: Theme.orange,
                value: timeSavedFormatted,
                label: "Time saved"
            )
        }
    }

    /// Time saved versus typing at 50 WPM, formatted like `6h 14m` / `42m` / `45s`.
    private var timeSavedFormatted: String {
        let typingSeconds = Double(stats.totalWords) / 50.0 * 60.0
        let saved = Int(max(typingSeconds - stats.totalSecondsTranscribed, 0))
        let hours = saved / 3600
        let minutes = (saved % 3600) / 60
        let seconds = saved % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    private var breakdownGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
            spacing: 10
        ) {
            BreakdownCard(
                title: "Provider breakdown",
                icon: "cloud.fill",
                entries: providerEntries,
                emptyMessage: "Provider usage appears after the next recording."
            )
            BreakdownCard(
                title: "Language breakdown",
                icon: "globe",
                entries: languageEntries,
                emptyMessage: "Language usage appears after the next recording."
            )
        }
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            Text("Stored locally in ~/.speakflow/statistics.json. Nothing is sent to any server.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
            Spacer()
            Button("Reset Statistics...", role: .destructive) { showResetConfirm = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .alert("Reset Statistics?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                stats.reset()
                // Drop the recent-sessions fallback immediately so the dashboard
                // does not keep showing pre-reset breakdowns while the view is
                // still on screen. The `.task` re-runs the filtered fetch next
                // time this view appears.
                recentSessions = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently reset all transcription statistics to zero.")
        }
    }

    private var last30Summary: String {
        let count = dailyRecordings.map(\.count).reduce(0, +)
        return dailyRecordingsArePartial
            ? "\(formatCount(count)) known recordings"
            : "\(formatCount(count)) recordings"
    }

    private var recentProviderUsage: [String: Statistics.UsageEntry] {
        var usage: [String: Statistics.UsageEntry] = [:]
        for session in recentSessions {
            var entry = usage[session.providerId] ?? Statistics.UsageEntry()
            entry.recordings += 1
            entry.words += session.wordsProduced
            entry.seconds += session.totalDurationSeconds
            usage[session.providerId] = entry
        }
        return usage
    }

    private var effectiveProviderUsage: [String: Statistics.UsageEntry] {
        // `totalApiCalls` and per-provider recording counts intentionally drift
        // apart now: a batch recording is one recording but N API calls. So we
        // can no longer derive a "missing recordings" historical row from their
        // difference. Pick the richer of the persisted aggregate and the recent
        // session metrics, and show that as-is.
        let persistedCount = stats.providerUsage.values.map(\.recordings).reduce(0, +)
        let recentCount = recentProviderUsage.values.map(\.recordings).reduce(0, +)
        return persistedCount >= recentCount ? stats.providerUsage : recentProviderUsage
    }

    private var effectiveLanguageUsage: [String: Int] {
        // See `effectiveProviderUsage`: deriving an "Unknown language" bucket
        // from `totalApiCalls - knownRecordings` would always be positive in
        // batch mode and inject a bogus row.
        stats.languageUsage
    }

    private var recentDailyRecordings: [Statistics.DailyRecording] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let counts = Dictionary(grouping: recentSessions) { session in
            calendar.startOfDay(for: session.startTime)
        }.mapValues(\.count)

        return (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Statistics.DailyRecording(date: date, count: counts[date] ?? 0)
        }
    }

    private func mergeDailyRecordings(
        _ persisted: [Statistics.DailyRecording],
        _ recent: [Statistics.DailyRecording]
    ) -> [Statistics.DailyRecording] {
        let recentByDay = Dictionary(uniqueKeysWithValues: recent.map { ($0.date, $0.count) })
        return persisted.map { day in
            Statistics.DailyRecording(
                date: day.date,
                count: max(day.count, recentByDay[day.date] ?? 0)
            )
        }
    }

    private func providerLabel(_ providerId: String) -> String {
        switch providerId {
        case ProviderId.chatGPT:
            "ChatGPT"
        case ProviderId.deepgram:
            "Deepgram"
        case ProviderId.mistral:
            "Mistral Realtime"
        case ProviderId.mistralBatch:
            "Mistral Batch"
        case historicalProviderId:
            "Historical data"
        default:
            providerId
        }
    }

    private func providerSubtitle(_ providerId: String, recordings: Int) -> String {
        // Historical aggregate is derived from `totalApiCalls`, which counted
        // each chunk as a separate call in earlier builds. Surfacing that as
        // "recordings" would overstate per-recording counts for upgraders, so
        // we label this row as API calls instead.
        providerId == historicalProviderId
            ? "\(formatCount(recordings)) API calls before provider tracking"
            : "\(formatCount(recordings)) recordings"
    }

    private func languageLabel(_ code: String) -> String {
        switch code.lowercased() {
        case unknownLanguageId: "Unknown language"
        case "auto": "Auto-detect"
        case "en", "en-us": "English (US)"
        case "en-gb": "English (UK)"
        case "es": "Spanish"
        case "fr": "French"
        case "de": "German"
        case "pt": "Portuguese"
        case "it": "Italian"
        case "nl": "Dutch"
        case "hi": "Hindi"
        case "ar": "Arabic"
        case "ja": "Japanese"
        case "ko": "Korean"
        case "zh": "Chinese"
        case "ru": "Russian"
        default: code.uppercased()
        }
    }

    private func languageSubtitle(_ language: String) -> String {
        switch language.lowercased() {
        case unknownLanguageId:
            "Recordings before language tracking"
        case "auto":
            "Provider auto-detect"
        default:
            language.uppercased()
        }
    }

    private func formatCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

private struct BreakdownEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let value: String
    let detail: String
    let count: Int
}

private struct MetricCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.18))
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 28, height: 28)

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }
}

private struct BreakdownCard: View {
    let title: String
    let icon: String
    let entries: [BreakdownEntry]
    let emptyMessage: String

    private var maxCount: Int {
        max(entries.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.text3)
                Spacer()
            }

            if entries.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    ForEach(entries.prefix(4)) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    Text(entry.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.text3)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(entry.value)
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.text)
                                    Text(entry.detail)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.text3)
                                }
                            }

                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.line.opacity(0.6))
                                    Capsule()
                                        .fill(Theme.accent)
                                        .frame(width: proxy.size.width * CGFloat(entry.count) / CGFloat(maxCount))
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .padding(16)
        .background(Theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }
}

private struct SparklineView: View {
    let values: [Int]

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(values.max() ?? 0, 1)
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: values.count <= 1 ? 0 : proxy.size.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: proxy.size.height - (proxy.size.height * CGFloat(value) / CGFloat(maxValue))
                )
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surface.opacity(0.7))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                    path.addLine(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                    if let last = points.last {
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                    }
                    path.closeSubpath()
                }
                .fill(Theme.accentSoft)
            }
        }
    }
}

private struct HeatmapCard: View {
    let days: [Statistics.DailyRecording]
    let isPartial: Bool

    private var maxCount: Int {
        max(days.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("30-DAY ACTIVITY")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text(isPartial ? "Known recent sessions" : "Each square is one day")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 15), spacing: 6) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color(for: day.count))
                        .frame(height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Theme.line, lineWidth: 1)
                        )
                        .help("\(day.count) recording\(day.count == 1 ? "" : "s")")
                }
            }

            HStack(spacing: 6) {
                Text("Less")
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: index))
                        .frame(width: 14, height: 10)
                }
                Text("More")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.text3)
        }
        .padding(16)
        .background(Theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private func color(for count: Int) -> Color {
        guard count > 0 else { return Theme.surface }
        let opacity = 0.18 + 0.62 * Double(count) / Double(maxCount)
        return Theme.accent.opacity(opacity)
    }
}
