import Foundation

/// Completion gate shared by the executable and offline contract tests.
@MainActor
public enum LiveE2ECompletion {
    public static func wait(
        timeout: Duration,
        isIdle: () async -> Bool,
        cancel: () -> Void
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            if await isIdle() { return true }
            guard ContinuousClock.now < deadline else { break }
            do {
                try await Task.sleep(for: min(.milliseconds(200), ContinuousClock.now.duration(to: deadline)))
            } catch { break }
        }
        cancel()
        return false
    }
}
