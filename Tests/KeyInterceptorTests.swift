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
    func startArmsEnterCaptureToken() {
        let interceptor = KeyInterceptor.shared
        interceptor.stop()

        interceptor.start(targetPid: 0)
        #expect(interceptor._testIsEnterCaptureArmed,
                "start(targetPid:) must arm Enter one-shot capture")

        interceptor.stop()
    }
}
