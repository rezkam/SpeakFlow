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
    /// Signalled from the fake tap's mach-port callout, on whichever thread's
    /// run loop services the tap.
    final class CalloutRecorder: @unchecked Sendable {
        let fired = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _ranOnMainThread: Bool?
        var ranOnMainThread: Bool? { lock.withLock { _ranOnMainThread } }

        func record() {
            lock.withLock { _ranOnMainThread = Thread.isMainThread }
            fired.signal()
        }
    }

    private let lock = NSLock()
    private var _createdTaps: [CFMachPort] = []
    private var _enableCalls: [Bool] = []
    let callouts = CalloutRecorder()
    var failCreation = false

    var createdTaps: [CFMachPort] { lock.withLock { _createdTaps } }
    var enableCalls: [Bool] { lock.withLock { _enableCalls } }

    var driver: KeyInterceptor.EventTapDriver {
        KeyInterceptor.EventTapDriver(
            createTap: { [self] _ in
                guard !failCreation else { return nil }
                var context = CFMachPortContext(
                    version: 0,
                    info: Unmanaged.passUnretained(callouts).toOpaque(),
                    retain: nil,
                    release: nil,
                    copyDescription: nil
                )
                var shouldFree: DarwinBoolean = false
                guard let port = CFMachPortCreate(
                    kCFAllocatorDefault,
                    { _, _, _, info in
                        guard let info else { return }
                        Unmanaged<CalloutRecorder>.fromOpaque(info).takeUnretainedValue().record()
                    },
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

    /// Sends an empty mach message to `tap`, as the WindowServer does for each event.
    static func sendMessage(to tap: CFMachPort) {
        var header = mach_msg_header_t()
        header.msgh_bits = UInt32(MACH_MSG_TYPE_MAKE_SEND)
        header.msgh_size = mach_msg_size_t(MemoryLayout<mach_msg_header_t>.size)
        header.msgh_remote_port = CFMachPortGetPort(tap)
        header.msgh_local_port = mach_port_t(MACH_PORT_NULL)
        _ = mach_msg(
            &header, MACH_SEND_MSG, header.msgh_size, 0,
            mach_port_t(MACH_PORT_NULL), MACH_MSG_TIMEOUT_NONE, mach_port_t(MACH_PORT_NULL)
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

    @MainActor @Test
    func stopDeliversACapturedEnterBeforeReturning() {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(eventTapDriver: fake.driver, isSecureInputEnabled: { false })
        var enterCallbacks = 0
        interceptor.onEnterPressed = { enterCallbacks += 1 }

        interceptor.start(targetPid: 0)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36), "Enter must be swallowed")

        // Finalization stops interception before the handler hop has run.
        interceptor.stop()

        #expect(enterCallbacks == 1,
                "A swallowed Enter must reach the recording before stop() returns, or it is lost")
    }

    @MainActor @Test
    func stopDeliversACapturedEscapeBeforeReturning() {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(eventTapDriver: fake.driver, isSecureInputEnabled: { false })
        var escapeCallbacks = 0
        interceptor.onEscapePressed = { escapeCallbacks += 1 }

        interceptor.start(targetPid: 0)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 53), "Escape must be swallowed")
        interceptor.stop()

        #expect(escapeCallbacks == 1,
                "A swallowed Escape must reach the recording before stop() returns, or it is lost")
    }

    @MainActor @Test
    func capturedKeyIsDeliveredExactlyOnce() async throws {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(eventTapDriver: fake.driver, isSecureInputEnabled: { false })
        var enterCallbacks = 0
        interceptor.onEnterPressed = { enterCallbacks += 1 }

        interceptor.start(targetPid: 0)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36))
        try await waitUntil { enterCallbacks == 1 }
        interceptor.stop()
        try await Task.sleep(for: .milliseconds(50))

        #expect(enterCallbacks == 1, "The async hop and stop() must not both deliver the same Enter")
    }

    @MainActor @Test
    func cancelDiscardsACapturedKeyInsteadOfDeliveringIt() async throws {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(eventTapDriver: fake.driver, isSecureInputEnabled: { false })
        var enterCallbacks = 0
        interceptor.onEnterPressed = { enterCallbacks += 1 }

        interceptor.start(targetPid: 0)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36))
        interceptor.cancel()
        try await Task.sleep(for: .milliseconds(50))

        #expect(enterCallbacks == 0, "A cancelled recording must never turn a captured Enter into a submit")
        #expect(fake.createdTaps.allSatisfy { !CFMachPortIsValid($0) }, "cancel() must tear the tap down too")
    }

    @MainActor @Test
    func tapIsServicedWhileTheMainThreadIsBlocked() throws {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(eventTapDriver: fake.driver, isSecureInputEnabled: { false })
        defer { interceptor.stop() }

        interceptor.start(targetPid: 0)
        let tap = try #require(fake.createdTaps.first)

        FakeEventTapDriver.sendMessage(to: tap)
        // Block the main thread, as per-character Accessibility calls or UI work
        // can. A tap serviced by the main run loop cannot run until this returns,
        // and the WindowServer disables taps that do not answer in time.
        let serviced = fake.callouts.fired.wait(timeout: .now() + .seconds(1)) == .success

        #expect(serviced, "The tap must be serviced while the main thread is blocked")
        #expect(fake.callouts.ranOnMainThread == false, "The tap must run on its own thread")
    }
}
