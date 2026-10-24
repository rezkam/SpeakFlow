import CoreGraphics
import Foundation
import os
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

/// Records event-tap lifecycle calls made by `KeyInterceptor` without
/// installing a real system tap. Each created tap is a plain CFMachPort so
/// invalidation is observable through `CFMachPortIsValid`.
final class FakeEventTapDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var _createdTaps: [CFMachPort] = []
    private var _enableCalls: [Bool] = []
    var failCreation = false

    var createdTaps: [CFMachPort] { lock.withLock { _createdTaps } }
    var enableCalls: [Bool] { lock.withLock { _enableCalls } }

    var driver: KeyInterceptor.EventTapDriver {
        KeyInterceptor.EventTapDriver(
            createTap: { [self] _ in
                guard !failCreation else { return nil }
                var context = CFMachPortContext()
                var shouldFree: DarwinBoolean = false
                guard let port = CFMachPortCreate(
                    kCFAllocatorDefault,
                    { _, _, _, _ in },
                    &context,
                    &shouldFree
                ) else { return nil }
                lock.withLock { _createdTaps.append(port) }
                return port
            },
            setTapEnabled: { [self] _, enabled in
                lock.withLock { _enableCalls.append(enabled) }
            }
        )
    }
}

@Suite("KeyInterceptor — Event Tap Registration", .serialized)
struct KeyInterceptorRegistrationTests {
    @MainActor @Test
    func stopInvalidatesTheEventTapSoItIsNotLeaked() throws {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(eventTapDriver: fake.driver, isSecureInputEnabled: { false })

        interceptor.start(targetPid: 42)
        let tap = try #require(fake.createdTaps.first)
        #expect(CFMachPortIsValid(tap), "A running interceptor must keep its tap valid")

        interceptor.stop()

        #expect(!CFMachPortIsValid(tap),
                "stop() must invalidate the tap; a disabled-but-valid tap stays registered in the WindowServer")
    }

    @MainActor @Test
    func startWhileStillRegisteredRearmsForTheNewRecording() {
        let fake = FakeEventTapDriver()
        let focusedTargets = OSAllocatedUnfairLock(initialState: [pid_t]())
        let interceptor = KeyInterceptor(
            eventTapDriver: fake.driver,
            keyboardFocusSnapshotProvider: { targetPid in
                focusedTargets.withLock { $0.append(targetPid) }
                return .init(isInTargetApp: true, focusedPid: targetPid, frontmostPid: targetPid, source: "test")
            },
            isSecureInputEnabled: { false }
        )
        defer { interceptor.stop() }

        interceptor.start(targetPid: 41)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36), "First recording captures its Enter")

        // A new recording starts before the previous registration was torn down.
        interceptor.start(targetPid: 42)

        #expect(fake.createdTaps.count == 1, "Re-arming must reuse the registered tap, not stack a second one")
        #expect(interceptor._testIsEnterCaptureArmed, "The new recording must get a fresh one-shot Enter token")
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36), "The new recording's first Enter must be captured")
        #expect(focusedTargets.withLock { $0.last } == 42, "Focus checks must target the new recording's app")
    }
}
