import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Recorder idle feedback", .serialized)
struct RecorderIdleFeedbackTests {
    @Test @MainActor
    func recorderPlaysNudgeAndWarningBeforeAutoEnd() async throws {
        let settings = SpySettings()
        settings.idleNudgeEnabled = true
        settings.idleNudgeInterval = 0.01
        settings.idleNudgeMaxCount = 2
        let sounds = SpySoundEffectPlayer()
        let recorder = StreamingRecorder(settings: settings, playSoundEffect: { sounds.play($0) })
        var expired = false
        recorder.onAutoEnd = { expired = true }
        defer { recorder._testStopIdleMonitoring() }

        recorder._testBeginIdleMonitoring()
        try await waitUntil { expired }

        #expect(sounds.effects == [.nudge, .warning],
                "Idle feedback must be audible through the mute-aware sound policy before auto-end")
    }
}

@Suite("IdleNudgeController")
struct IdleNudgeControllerTests {
    @MainActor
    @Test
    func emitsNudgesThenExpires() async {
        let controller = IdleNudgeController(nudgeInterval: 0.05, maxNudges: 2)
        var nudgeCount = 0
        var warningCount = 0
        var expiredCount = 0

        controller.onNudge = { nudgeCount += 1 }
        controller.onFinalWarning = { warningCount += 1 }
        controller.onExpired = { expiredCount += 1 }

        controller.startMonitoring(afterDelay: 0)

        let deadline = Date().addingTimeInterval(10.0)
        while expiredCount == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(nudgeCount == 1)
        #expect(warningCount == 1)
        #expect(expiredCount == 1)
    }

    @MainActor
    @Test
    func stopMonitoringPreventsExpiration() async {
        let controller = IdleNudgeController(nudgeInterval: 0.05, maxNudges: 1)
        var expiredCount = 0
        controller.onExpired = { expiredCount += 1 }

        controller.startMonitoring(afterDelay: 0.1)
        controller.stopMonitoring()

        try? await Task.sleep(for: .milliseconds(180))
        #expect(expiredCount == 0)
    }
}
