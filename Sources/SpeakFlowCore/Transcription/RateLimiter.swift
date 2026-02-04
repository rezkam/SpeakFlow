import Foundation
import OSLog

/// Actor-based rate limiter to prevent API overload
actor RateLimiter {
    private var lastRequestTime: Date?

    func canMakeRequest() -> Bool {
        guard let last = lastRequestTime else { return true }
        return Date().timeIntervalSince(last) >= Config.minTimeBetweenRequests
    }

    func recordRequest() {
        lastRequestTime = Date()
    }

    func timeUntilNextAllowed() -> TimeInterval {
        guard let last = lastRequestTime else { return 0 }
        let elapsed = Date().timeIntervalSince(last)
        return max(0, Config.minTimeBetweenRequests - elapsed)
    }

    func waitIfNeeded() async {
        let waitTime = timeUntilNextAllowed()
        if waitTime > 0 {
            Logger.transcription.debug("Rate limit: waiting \(String(format: "%.1f", waitTime))s")
            try? await Task.sleep(for: .seconds(waitTime))
        }
    }
}
