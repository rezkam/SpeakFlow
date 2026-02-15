import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - Hotkey Listener Cleanup Tests

struct HotkeyListenerCleanupTests {
    @Test func testStopIsIdempotent() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            let listener = HotkeyListener()
            listener.stop()
            listener.stop()
            #expect(stopCalls == 2)
        }
    }
}

struct HotkeyListenerCleanupRegressionTests {
    @Test func testDeinitInvokesStopCleanup() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            var listener: HotkeyListener? = HotkeyListener()
            #expect(stopCalls == 0)
            _ = listener // Silence "never read" warning
            listener = nil

            #expect(stopCalls == 1)
        }
    }

    @Test func testDeinitAfterManualStopRemainsSafe() async {
        await MainActor.run {
            var stopCalls = 0
            HotkeyListener._testStopHook = { stopCalls += 1 }
            defer { HotkeyListener._testStopHook = nil }

            var listener: HotkeyListener? = HotkeyListener()
            listener?.stop()
            listener = nil

            #expect(stopCalls == 2)
        }
    }
}
