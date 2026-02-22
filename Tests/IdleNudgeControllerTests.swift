import Foundation
import Testing
@testable import SpeakFlowCore

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
