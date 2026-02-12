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

            #if compiler(>=6.2)
            // Isolated deinit calls stop() on deallocation
            #expect(stopCalls == 1)
            #else
            // Swift 6.1 has no isolated deinit — cleanup via explicit stop() only
            #expect(stopCalls == 0)
            #endif
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

            #if compiler(>=6.2)
            // Manual stop() + isolated deinit stop()
            #expect(stopCalls == 2)
            #else
            // Swift 6.1: only the explicit stop() call
            #expect(stopCalls == 1)
            #endif
        }
    }
}
