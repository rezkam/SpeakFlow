import Foundation
import OSLog

/// Actor-based rate limiter to prevent API overload
actor RateLimiter {
    /// Last reserved request slot. This is updated *before* any suspension in waitAndRecord()
    /// so concurrent callers cannot reserve the same slot.
    private var lastRequestTime: Date?
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = Config.minTimeBetweenRequests) {
        self.minimumInterval = minimumInterval
    }

    func timeUntilNextAllowed(now: Date = Date()) -> TimeInterval {
        guard let last = lastRequestTime else { return 0 }
        let nextAllowed = last.addingTimeInterval(minimumInterval)
        return max(0, nextAllowed.timeIntervalSince(now))
    }

    /// Atomically reserve the next request slot and wait until that slot is reached.
    ///
    /// Reserving the slot before suspension prevents reentrant callers from bypassing
    /// throttling under concurrent load.
    func waitAndRecord() async throws {
        try Task.checkCancellation()

        let now = Date()
        let scheduledTime: Date

        if let last = lastRequestTime {
            let nextAllowed = last.addingTimeInterval(minimumInterval)
            scheduledTime = max(now, nextAllowed)
        } else {
            scheduledTime = now
        }

        // Reserve this slot before any await to prevent races with reentrant calls.
        lastRequestTime = scheduledTime

        let waitTime = scheduledTime.timeIntervalSince(now)
        if waitTime > 0 {
            Logger.transcription.debug("Rate limit: waiting \(String(format: "%.1f", waitTime))s")
            try await Task.sleep(for: .seconds(waitTime))
        }
    }
}
