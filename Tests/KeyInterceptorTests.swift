import Testing
@testable import SpeakFlow

@Suite("KeyInterceptor — Enter One-Shot Capture", .serialized)
struct KeyInterceptorEnterCaptureTests {
    @MainActor @Test
    func enterCaptureTokenConsumesOnlyOncePerArm() {
        let interceptor = KeyInterceptor.shared
        interceptor.stop()
        interceptor._testArmEnterCaptureForTests(active: true)

        #expect(interceptor._testConsumeEnterCaptureToken(),
                "First Enter token consumption should succeed")
        #expect(!interceptor._testConsumeEnterCaptureToken(),
                "Second Enter token consumption should fail until re-armed")

        interceptor.stop()
    }

    @MainActor @Test
    func startOnlyLeavesEnterCaptureArmedWhenInterceptionIsActive() {
        let interceptor = KeyInterceptor.shared
        interceptor.stop()

        interceptor.start(targetPid: 0)
        if interceptor._testIsActive {
            #expect(interceptor._testIsEnterCaptureArmed,
                    "active interception must arm Enter one-shot capture")
        } else {
            #expect(!interceptor._testIsEnterCaptureArmed,
                    "failed interception must not leave passive Enter capture armed")
        }

        interceptor.stop()
    }

    @MainActor @Test
    func eventTapFailureDisarmsEnterCaptureInsteadOfUsingPassiveMonitor() {
        let interceptor = KeyInterceptor.shared
        interceptor.stop()
        interceptor._testArmEnterCaptureForTests(active: true)

        interceptor._testHandleEventTapUnavailableForTests()

        #expect(!interceptor._testIsActive)
        #expect(!interceptor._testIsEnterCaptureArmed)
        #expect(!interceptor._testConsumeEnterCaptureToken())

        interceptor.stop()
    }
}
