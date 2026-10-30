import CoreGraphics
import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Pending local start keyboard policy", .serialized)
struct KeyInterceptorPendingTests {
    @MainActor @Test(arguments: [CGKeyCode(36), 76, 53])
    func pendingEnterPassesThroughAndEscapeIsConsumed(key: CGKeyCode) {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        var enters = 0, escapes = 0
        interceptor.onEnterPressed = { enters += 1 }
        interceptor.onEscapePressed = { escapes += 1 }
        interceptor.startPending(targetPid: KeyInterceptor.testTargetPid)
        #expect(!interceptor._testIsEnterCaptureArmed)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: key) == (key == 53))
        interceptor.stop()
        #expect(enters == (key == 53 ? 0 : 1))
        #expect(escapes == (key == 53 ? 1 : 0))
    }

    @MainActor @Test func pendingEnterCancelsEvenAfterFocusChangesWithoutSwallowingTheKey() {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(eventTapDriver: fake.driver,
            focusQuery: { .init(focusedPid: 43, focusedAppPid: 43, source: "test") },
            bundleIdentifierLookup: { _ in nil }, secureInputOwner: { nil })
        var cancelled = 0
        interceptor.onEnterPressed = { cancelled += 1 }
        interceptor.startPending(targetPid: KeyInterceptor.testTargetPid)
        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 36))
        interceptor.stop()
        #expect(cancelled == 1)
    }

    @MainActor @Test(arguments: [CGEventFlags.maskShift, .maskAlternate, .maskCommand, .maskControl])
    func modifiedPendingKeysNeverCancel(flags: CGEventFlags) {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        var callbacks = 0
        interceptor.onEnterPressed = { callbacks += 1 }
        interceptor.onEscapePressed = { callbacks += 1 }
        interceptor.startPending(targetPid: KeyInterceptor.testTargetPid)
        for key in [CGKeyCode(36), 76, 53] {
            #expect(!interceptor._testHandleKeyEventForTests(keyCode: key, flags: flags))
        }
        interceptor.stop()
        #expect(callbacks == 0)
    }
}
