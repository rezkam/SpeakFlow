import Foundation
import OSLog

/// Actor-based rate limiter to prevent API overload
actor RateLimiter {
    /// Last reserved request slot. Updated *before* any suspension in waitAndRecord()
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
    /// The nonisolated entry point checks cancellation before entering the actor queue,
    /// ensuring pre-cancelled tasks throw immediately without waiting for actor scheduling.
    /// Each concurrent caller gets a distinct slot spaced by minimumInterval.
    nonisolated func waitAndRecord() async throws {
        // Check cancellation *before* entering the actor queue — pre-cancelled
        // tasks throw immediately without waiting for actor scheduling.
        try Task.checkCancellation()
        try await _reserveAndWait()
    }

    /// Actor-isolated core: reserve the next slot then sleep until it is due.
    private func _reserveAndWait() async throws {
        try Task.checkCancellation()

        let now = Date()
        let scheduledTime: Date

        if let last = lastRequestTime {
            // Schedule relative to the last reserved slot for proper spacing
            let nextAllowed = last.addingTimeInterval(minimumInterval)
            scheduledTime = max(now, nextAllowed)
        } else {
            // First call — no wait
            scheduledTime = now
        }

        // Reserve this slot BEFORE any suspension point.
        // This is the critical line that prevents concurrent callers
        // from getting the same slot.
        lastRequestTime = scheduledTime

        let waitTime = scheduledTime.timeIntervalSince(now)
        if waitTime > 0 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            try Task.checkCancellation()
        }
    }
}
