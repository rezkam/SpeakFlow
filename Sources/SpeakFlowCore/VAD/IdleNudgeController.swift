import Foundation

/// Progressive idle feedback before triggering auto-end.
///
/// Intended for dictation sessions where immediate auto-end can feel abrupt.
/// The controller can emit one or more nudges, then a final expiration callback.
@MainActor
public final class IdleNudgeController {
    public var onNudge: (() -> Void)?
    public var onFinalWarning: (() -> Void)?
    public var onExpired: (() -> Void)?

    private let nudgeInterval: TimeInterval
    private let maxNudges: Int
    private var nudgeCount = 0
    private var nudgeTask: Task<Void, Never>?
    private var isMonitoring = false

    public init(nudgeInterval: TimeInterval = 5.0, maxNudges: Int = 2) {
        self.nudgeInterval = max(0.01, nudgeInterval)
        self.maxNudges = max(0, maxNudges)
    }

    /// Start monitoring if not already active.
    ///
    /// Repeated calls while active are ignored to avoid restarting the sequence.
    public func startMonitoring(afterDelay initialDelay: TimeInterval) {
        guard !isMonitoring else { return }
        isMonitoring = true
        nudgeCount = 0
        let delay = max(0, initialDelay)
        if delay == 0 {
            Task { [weak self] in
                await self?.tick()
            }
        } else {
            scheduleTick(after: delay)
        }
    }

    public func stopMonitoring() {
        nudgeTask?.cancel()
        nudgeTask = nil
        nudgeCount = 0
        isMonitoring = false
    }

    private func scheduleTick(after delay: TimeInterval) {
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, self.isMonitoring else { return }
            await self.tick()
        }
    }

    private func tick() async {
        guard isMonitoring else { return }

        if nudgeCount < maxNudges {
            nudgeCount += 1
            if nudgeCount == maxNudges {
                onFinalWarning?()
            } else {
                onNudge?()
            }
            scheduleTick(after: nudgeInterval)
            return
        }

        isMonitoring = false
        nudgeTask = nil
        onExpired?()
    }
}
