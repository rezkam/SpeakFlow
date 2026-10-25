import Foundation
import Observation
import SpeakFlowCore

/// Observable fallback history for the statistics dashboard.
@MainActor @Observable
final class StatisticsSessionHistory {
    private(set) var sessions: [SessionMetrics] = []
    @ObservationIgnored private var generation: UInt64 = 0
    private let load: @MainActor (Date) async -> [SessionMetrics]

    init(load: (@MainActor (Date) async -> [SessionMetrics])? = nil) {
        self.load = load ?? { cutoff in
            await SessionMetricsStore.shared.recentCompletedSessions(after: cutoff, limit: 200)
        }
    }

    func refresh(resetDate: () -> Date) async {
        generation &+= 1
        let request = generation
        let cutoff = resetDate()
        let fetched = await load(cutoff)
        guard generation == request, resetDate() == cutoff, !Task.isCancelled else { return }
        sessions = fetched
    }

    func reset() {
        generation &+= 1
        sessions = []
    }
}
