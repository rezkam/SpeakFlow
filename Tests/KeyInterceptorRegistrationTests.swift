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

extension KeyInterceptor {
    nonisolated static let testTargetPid: pid_t = 42

    /// Interceptor whose keyboard focus is always in `testTargetPid`.
    @MainActor
    static func focusedForTests(_ driver: EventTapDriver) -> KeyInterceptor {
        KeyInterceptor(
            eventTapDriver: driver,
            focusQuery: { .init(focusedPid: testTargetPid, focusedAppPid: testTargetPid, source: "test") },
            bundleIdentifierLookup: { _ in nil },
            secureInputOwner: { nil }
        )
    }
}

@Suite("KeyInterceptor — Event Tap Registration", .serialized)
struct KeyInterceptorRegistrationTests {
    @MainActor @Test
    func stopInvalidatesTheEventTapSoItIsNotLeaked() throws {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(eventTapDriver: fake.driver, secureInputOwner: { nil })

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
        let focusedPid = OSAllocatedUnfairLock<pid_t>(initialState: 41)
        let interceptor = KeyInterceptor(
            eventTapDriver: fake.driver,
            focusQuery: {
                let pid = focusedPid.withLock { $0 }
                return .init(focusedPid: pid, focusedAppPid: pid, source: "test")
            },
            bundleIdentifierLookup: { _ in nil },
            secureInputOwner: { nil }
        )
        defer { interceptor.stop() }

        interceptor.start(targetPid: 41)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36), "First recording captures its Enter")

        // A new recording in another app starts before the previous
        // registration was torn down.
        focusedPid.withLock { $0 = 42 }
        interceptor.start(targetPid: 42)

        #expect(fake.createdTaps.count == 1, "Re-arming must reuse the registered tap, not stack a second one")
        #expect(interceptor._testIsEnterCaptureArmed, "The new recording must get a fresh one-shot Enter token")
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36),
                "The new recording's first Enter must be captured in the new target app")
    }

    @MainActor @Test
    func stopDeliversACapturedEnterBeforeReturning() {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        var enterCallbacks = 0
        interceptor.onEnterPressed = { enterCallbacks += 1 }

        interceptor.start(targetPid: KeyInterceptor.testTargetPid)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36), "Enter must be swallowed")

        // Finalization stops interception before the handler hop has run.
        interceptor.stop()

        #expect(enterCallbacks == 1,
                "A swallowed Enter must reach the recording before stop() returns, or it is lost")
    }

    @MainActor @Test
    func stopDeliversACapturedEscapeBeforeReturning() {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        var escapeCallbacks = 0
        interceptor.onEscapePressed = { escapeCallbacks += 1 }

        interceptor.start(targetPid: KeyInterceptor.testTargetPid)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 53), "Escape must be swallowed")
        interceptor.stop()

        #expect(escapeCallbacks == 1,
                "A swallowed Escape must reach the recording before stop() returns, or it is lost")
    }

    @MainActor @Test
    func capturedKeyIsDeliveredExactlyOnce() async throws {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        var enterCallbacks = 0
        interceptor.onEnterPressed = { enterCallbacks += 1 }

        interceptor.start(targetPid: KeyInterceptor.testTargetPid)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36))
        try await waitUntil { enterCallbacks == 1 }
        interceptor.stop()
        try await Task.sleep(for: .milliseconds(50))

        #expect(enterCallbacks == 1, "The async hop and stop() must not both deliver the same Enter")
    }

    @MainActor @Test
    func cancelDiscardsACapturedKeyInsteadOfDeliveringIt() async throws {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        var enterCallbacks = 0
        interceptor.onEnterPressed = { enterCallbacks += 1 }

        interceptor.start(targetPid: KeyInterceptor.testTargetPid)
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36))
        interceptor.cancel()
        try await Task.sleep(for: .milliseconds(50))

        #expect(enterCallbacks == 0, "A cancelled recording must never turn a captured Enter into a submit")
        #expect(fake.createdTaps.allSatisfy { !CFMachPortIsValid($0) }, "cancel() must tear the tap down too")
    }

    @MainActor @Test
    func tapIsServicedWhileTheMainThreadIsBlocked() throws {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        defer { interceptor.stop() }

        interceptor.start(targetPid: KeyInterceptor.testTargetPid)
        let tap = try #require(fake.createdTaps.first)

        FakeEventTapDriver.sendMessage(to: tap)
        // Block the main thread, as per-character Accessibility calls or UI work
        // can. A tap serviced by the main run loop cannot run until this returns,
        // and the WindowServer disables taps that do not answer in time.
        let serviced = fake.callouts.fired.wait(timeout: .now() + .seconds(1)) == .success

        #expect(serviced, "The tap must be serviced while the main thread is blocked")
        #expect(fake.callouts.ranOnMainThread == false, "The tap must run on its own thread")
    }

    @MainActor
    private func makeFocusInterceptor(
        focusedPid: pid_t,
        bundles: [pid_t: String]
    ) -> (KeyInterceptor, FakeEventTapDriver) {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor(
            eventTapDriver: fake.driver,
            focusQuery: { .init(focusedPid: focusedPid, focusedAppPid: focusedPid, source: "test") },
            bundleIdentifierLookup: { bundles[$0] },
            secureInputOwner: { nil }
        )
        return (interceptor, fake)
    }

    @MainActor @Test
    func focusInAHelperProcessOfTheTargetAppIsTheTarget() {
        // Same rule TextInserter uses to keep typing: a helper process of the
        // target app is still the target app.
        let (interceptor, _) = makeFocusInterceptor(
            focusedPid: 99,
            bundles: [42: "com.vendor.Editor", 99: "com.vendor.Editor.helper"]
        )
        defer { interceptor.stop() }
        interceptor.start(targetPid: 42)

        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36),
                "Enter must be captured when focus is in the target app's helper process")
    }

    @MainActor @Test
    func focusInARelaunchedTargetAppIsTheTarget() {
        let (interceptor, _) = makeFocusInterceptor(
            focusedPid: 77,
            bundles: [42: "com.vendor.Editor", 77: "com.vendor.Editor"]
        )
        defer { interceptor.stop() }
        interceptor.start(targetPid: 42)

        #expect(interceptor._testHandleKeyEventForTests(keyCode: 53),
                "Escape must be captured when the target app relaunched under a new PID")
    }

    @MainActor @Test
    func focusInAnUnrelatedAppPassesEnterThrough() {
        let (interceptor, _) = makeFocusInterceptor(
            focusedPid: 99,
            bundles: [42: "com.vendor.Editor", 99: "com.other.Chat"]
        )
        defer { interceptor.stop() }
        interceptor.start(targetPid: 42)

        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 36), "Enter in another app must pass through")
        #expect(interceptor._testIsEnterCaptureArmed, "A passed-through Enter must not consume the token")
    }

    /// Every non-empty combination of Shift, Option, Command, and Control.
    nonisolated static let modifierCombinations: [CGEventFlags] = {
        let single: [CGEventFlags] = [.maskShift, .maskAlternate, .maskCommand, .maskControl]
        return (1..<(1 << single.count)).map { mask in
            single.enumerated().reduce(into: CGEventFlags()) { flags, entry in
                if mask & (1 << entry.offset) != 0 { flags.insert(entry.element) }
            }
        }
    }()

    @MainActor @Test(arguments: modifierCombinations)
    func modifiedEnterAndEscapePassThroughUntouched(modifier: CGEventFlags) {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        defer { interceptor.stop() }
        interceptor.start(targetPid: KeyInterceptor.testTargetPid)

        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 36, flags: modifier),
                "Modified Enter is a different command (newline, alternate submit) and must reach the app")
        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 76, flags: [modifier, .maskNumericPad]),
                "Modified keypad Enter must reach the app")
        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 53, flags: modifier),
                "Modified Escape must reach the app")
        #expect(interceptor._testIsEnterCaptureArmed, "A modified Enter must not consume the submit token")
    }

    @MainActor @Test
    func plainEnterIsStillCapturedWithNonCommandFlags() {
        let fake = FakeEventTapDriver()
        let interceptor = KeyInterceptor.focusedForTests(fake.driver)
        defer { interceptor.stop() }
        interceptor.start(targetPid: KeyInterceptor.testTargetPid)

        // Caps Lock and the keypad/fn flags do not change what Enter means.
        #expect(interceptor._testHandleKeyEventForTests(
            keyCode: 76, flags: [.maskAlphaShift, .maskNumericPad, .maskSecondaryFn]
        ), "Keypad Enter with only non-command flags must still submit")
    }

    @MainActor
    private func makeCountingInterceptor(
        systemKeyDowns: OSAllocatedUnfairLock<UInt32>,
        secureInputOwner: pid_t? = nil,
        bundles: [pid_t: String] = [:]
    ) -> KeyInterceptor {
        KeyInterceptor(
            eventTapDriver: FakeEventTapDriver().driver,
            bundleIdentifierLookup: { bundles[$0] },
            secureInputOwner: { secureInputOwner },
            systemKeyDownCounter: { systemKeyDowns.withLock { $0 } }
        )
    }

    /// Regression guard: keys that never reached the tap (secure input in the
    /// target app, a disabled tap) used to leave no trace at all.
    @MainActor @Test
    func keysTheSystemSawButTheTapDidNotAreRecordedAtStop() {
        let systemKeyDowns = OSAllocatedUnfairLock<UInt32>(initialState: 1_000)
        let interceptor = makeCountingInterceptor(
            systemKeyDowns: systemKeyDowns,
            secureInputOwner: 42,
            bundles: [42: "com.mitchellh.ghostty"]
        )
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer { HotkeyDiagnostics._testEventHook = nil }

        interceptor.start(targetPid: 42)
        // The user typed 5 keys; the tap saw only one of them.
        systemKeyDowns.withLock { $0 += 5 }
        _ = interceptor._testHandleKeyEventForTests(keyCode: 0)
        interceptor.stop()

        let summary = events.first { $0.name == "key_interceptor_session_summary" }
        #expect(summary?.metadata["systemKeyDowns"] == "5")
        #expect(summary?.metadata["tapKeyDowns"] == "1")
        let missed = events.first { $0.name == "key_interceptor_keys_missed_by_tap" }
        #expect(missed?.level == .warning, "Keys the tap never saw must leave a warning")
        #expect(missed?.metadata["missedKeyDowns"] == "4")
        #expect(missed?.metadata["secureInputOwnerPid"] == "42")
        #expect(missed?.metadata["secureInputOwnerBundleIdentifier"] == "com.mitchellh.ghostty")
        #expect(missed?.metadata["phase"] == "stop")
    }

    @MainActor @Test
    func cancelAlsoRecordsKeysTheTapMissed() {
        let systemKeyDowns = OSAllocatedUnfairLock<UInt32>(initialState: 10)
        let interceptor = makeCountingInterceptor(systemKeyDowns: systemKeyDowns)
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer { HotkeyDiagnostics._testEventHook = nil }

        interceptor.start(targetPid: 42)
        systemKeyDowns.withLock { $0 += 3 }
        interceptor.cancel()

        let missed = events.first { $0.name == "key_interceptor_keys_missed_by_tap" }
        #expect(missed?.metadata["missedKeyDowns"] == "3")
        #expect(missed?.metadata["secureInputOwnerPid"] == "none")
        #expect(missed?.metadata["phase"] == "cancel")
    }

    @MainActor @Test
    func noMissedKeyWarningWhenTheTapSawEveryKey() {
        let systemKeyDowns = OSAllocatedUnfairLock<UInt32>(initialState: 0)
        let interceptor = makeCountingInterceptor(systemKeyDowns: systemKeyDowns)
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer { HotkeyDiagnostics._testEventHook = nil }

        interceptor.start(targetPid: 0)
        systemKeyDowns.withLock { $0 += 3 }
        // Ordinary keys, a captured Enter, and a passed-through second Enter all count.
        _ = interceptor._testHandleKeyEventForTests(keyCode: 0)
        _ = interceptor._testHandleKeyEventForTests(keyCode: 36)
        _ = interceptor._testHandleKeyEventForTests(keyCode: 36)
        interceptor.stop()

        #expect(events.contains { $0.name == "key_interceptor_session_summary" && $0.metadata["tapKeyDowns"] == "3" })
        #expect(!events.contains { $0.name == "key_interceptor_keys_missed_by_tap" })
    }

    @MainActor @Test
    func aSingleKeyInFlightAtStartOrStopIsNotReportedAsMissed() {
        // The system counter and the tap are sampled a moment apart, so one key
        // pressed exactly at registration or teardown can appear on one side only.
        let systemKeyDowns = OSAllocatedUnfairLock<UInt32>(initialState: 0)
        let interceptor = makeCountingInterceptor(systemKeyDowns: systemKeyDowns)
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer { HotkeyDiagnostics._testEventHook = nil }

        interceptor.start(targetPid: 0)
        systemKeyDowns.withLock { $0 += 1 }
        interceptor.stop()

        #expect(!events.contains { $0.name == "key_interceptor_keys_missed_by_tap" })
    }

    /// Observed in the running app: the HID system key-down counter includes
    /// SpeakFlow's own synthetic typing (system = hardware seen + synthetic
    /// seen, exactly). Missed keys are what the system counted beyond
    /// everything the tap saw, or every dictation looks like missed keys.
    @MainActor @Test
    func syntheticTypingCountsOnBothSidesOfTheComparison() {
        let systemKeyDowns = OSAllocatedUnfairLock<UInt32>(initialState: 0)
        let interceptor = makeCountingInterceptor(systemKeyDowns: systemKeyDowns)
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer { HotkeyDiagnostics._testEventHook = nil }

        interceptor.start(targetPid: 0)
        // 20 synthetic keys and 1 hardware key, all seen by the tap.
        systemKeyDowns.withLock { $0 += 21 }
        for _ in 0..<20 {
            _ = interceptor._testHandleKeyEventForTests(keyCode: 0, sourceState: .combinedSessionState)
        }
        _ = interceptor._testHandleKeyEventForTests(keyCode: 0)
        interceptor.stop()

        let summary = events.first { $0.name == "key_interceptor_session_summary" }
        #expect(summary?.metadata["tapKeyDowns"] == "1")
        #expect(summary?.metadata["tapSyntheticKeyDowns"] == "20")
        #expect(!events.contains { $0.name == "key_interceptor_keys_missed_by_tap" },
                "Synthetic typing seen by the tap is not a missed key")
    }

    @MainActor @Test
    func hardwareKeysMissedDuringSyntheticTypingAreStillReported() {
        let systemKeyDowns = OSAllocatedUnfairLock<UInt32>(initialState: 0)
        let interceptor = makeCountingInterceptor(systemKeyDowns: systemKeyDowns)
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer { HotkeyDiagnostics._testEventHook = nil }

        interceptor.start(targetPid: 0)
        // 20 synthetic keys seen, plus 4 hardware keys the tap never received.
        systemKeyDowns.withLock { $0 += 24 }
        for _ in 0..<20 {
            _ = interceptor._testHandleKeyEventForTests(keyCode: 0, sourceState: .combinedSessionState)
        }
        interceptor.stop()

        #expect(events.contains {
            $0.name == "key_interceptor_keys_missed_by_tap" && $0.metadata["missedKeyDowns"] == "4"
        })
    }

    @MainActor @Test
    func noTargetAppMeansEnterIsNotIntercepted() {
        let interceptor = KeyInterceptor(eventTapDriver: FakeEventTapDriver().driver, secureInputOwner: { nil })
        defer { interceptor.stop() }
        interceptor.start(targetPid: 0)

        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 36),
                "Without a target app, Enter must reach whatever app has focus")
        // Escape still cancels: it never needs a destination.
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 53))
    }

    /// Escape cancels the active recording from whichever app has focus:
    /// the user may have switched apps and still wants to stop dictation.
    /// Enter keeps the focus rule, because submitting into another app is harmful.
    @MainActor @Test
    func escapeCancelsFromAnyAppWhileEnterKeepsTheFocusRule() async throws {
        let interceptor = KeyInterceptor(
            eventTapDriver: FakeEventTapDriver().driver,
            focusQuery: { .init(focusedPid: 938, focusedAppPid: 938, source: "test") },
            bundleIdentifierLookup: { [42: "com.mitchellh.ghostty", 938: "com.google.Chrome"][$0] },
            secureInputOwner: { nil }
        )
        var escapes = 0
        var enters = 0
        interceptor.onEscapePressed = { escapes += 1 }
        interceptor.onEnterPressed = { enters += 1 }
        defer { interceptor.stop() }
        interceptor.start(targetPid: 42)

        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 36), "Enter in another app still reaches that app")
        #expect(interceptor._testHandleKeyEventForTests(keyCode: 53), "Escape in another app cancels the recording")
        try await waitUntil { escapes == 1 }

        #expect(escapes == 1)
        #expect(enters == 0)
        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 53, flags: .maskCommand),
                "Modified Escape still passes through")
    }
}
