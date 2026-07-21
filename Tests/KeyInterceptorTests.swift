import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

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
    func keypadEnterUsesTheSameOneShotCaptureContract() {
        let interceptor = KeyInterceptor.shared
        interceptor.stop()
        defer { interceptor.stop() }

        interceptor._testArmEnterCaptureForTests(active: true)

        #expect(interceptor._testHandleKeyEventForTests(keyCode: 76),
                "Keypad Enter should be captured and suppressed")
        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 76),
                "Second keypad Enter should pass through after one-shot capture")
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

    @MainActor @Test
    func enterCaptureRespectsTargetAppFocusBeforeConsumingToken() async {
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer { HotkeyDiagnostics._testEventHook = nil }

        var mismatchedEnterCallbacks = 0
        let mismatchedInterceptor = KeyInterceptor(testKeyboardFocusSnapshotProvider: { _ in
            .init(
                isInTargetApp: false,
                focusedPid: 99,
                frontmostPid: 99,
                source: "testMismatch"
            )
        })
        mismatchedInterceptor.onEnterPressed = { mismatchedEnterCallbacks += 1 }
        mismatchedInterceptor._testArmEnterCaptureForTests(targetPid: 42)

        #expect(!mismatchedInterceptor._testHandleKeyEventForTests(keyCode: 36),
                "Enter must pass through when keyboard focus belongs to another PID")
        await Task.yield()
        #expect(mismatchedEnterCallbacks == 0,
                "A focus-mismatched Enter must not invoke the recording callback")
        #expect(mismatchedInterceptor._testIsEnterCaptureArmed,
                "A focus-mismatched Enter must not consume the one-shot token")
        #expect(events.contains { event in
            event.name == "key_interceptor_key_passed_focus_mismatch" &&
                event.metadata["targetPid"] == "42" &&
                event.metadata["focusedPid"] == "99" &&
                event.metadata["focusSource"] == "testMismatch"
        }, "The nonzero-PID focus branch must reject the event")

        var matchedEnterCallbacks = 0
        let matchedInterceptor = KeyInterceptor(testKeyboardFocusSnapshotProvider: { _ in
            .init(
                isInTargetApp: true,
                focusedPid: 42,
                frontmostPid: 42,
                source: "testMatch"
            )
        })
        matchedInterceptor.onEnterPressed = { matchedEnterCallbacks += 1 }
        matchedInterceptor._testArmEnterCaptureForTests(targetPid: 42)

        #expect(matchedInterceptor._testHandleKeyEventForTests(keyCode: 36),
                "Enter must be captured when keyboard focus belongs to the target PID")
        await Task.yield()
        #expect(!matchedInterceptor._testHandleKeyEventForTests(keyCode: 36),
                "Only the first matching Enter may be captured")
        await Task.yield()
        #expect(matchedEnterCallbacks == 1,
                "Exactly one matching Enter must invoke the recording callback")
    }

    @MainActor @Test
    func enterCaptureRecordsDiagnostics() {
        let interceptor = KeyInterceptor.shared
        interceptor.stop()
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer {
            HotkeyDiagnostics._testEventHook = nil
            interceptor.stop()
        }

        interceptor._testArmEnterCaptureForTests(active: true)

        #expect(interceptor._testHandleKeyEventForTests(keyCode: 36),
                "Armed Enter should be captured and suppressed")
        #expect(events.contains { event in
            event.name == "key_interceptor_enter_captured" &&
                event.metadata["keyName"] == "enter"
        })

        #expect(!interceptor._testHandleKeyEventForTests(keyCode: 36),
                "Second Enter should pass through after the one-shot token is consumed")
        #expect(events.contains { event in
            event.name == "key_interceptor_enter_passed_capture_not_armed" &&
                event.metadata["keyName"] == "enter"
        })
    }

    @MainActor @Test
    func secureInputAtStartRecordsBlockedKeyDiagnostics() {
        let interceptor = KeyInterceptor(isSecureInputEnabled: { true })
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer {
            HotkeyDiagnostics._testEventHook = nil
            interceptor.stop()
        }

        interceptor.start(targetPid: 42)

        #expect(events.contains { event in
            event.name == "key_interceptor_secure_input_detected" &&
                event.level == .warning &&
                event.metadata["targetPid"] == "42" &&
                event.metadata["enterCaptureAvailable"] == "false" &&
                event.metadata["escapeCaptureAvailable"] == "false"
        })
    }

    @MainActor @Test
    func secureInputTransitionsDuringRecordingAreRecorded() async throws {
        var secureInputEnabled = false
        let interceptor = KeyInterceptor(
            isSecureInputEnabled: { secureInputEnabled },
            secureInputPollingInterval: .milliseconds(10)
        )
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer {
            HotkeyDiagnostics._testEventHook = nil
            interceptor.stop()
        }

        interceptor._testStartSecureInputMonitoring(targetPid: 43, initialState: false)
        secureInputEnabled = true
        try await waitUntil(interval: .milliseconds(10)) {
            events.contains { $0.name == "key_interceptor_secure_input_detected" }
        }

        #expect(events.contains { event in
            event.name == "key_interceptor_secure_input_detected" &&
                event.metadata["targetPid"] == "43" &&
                event.metadata["phase"] == "monitor"
        })

        secureInputEnabled = false
        try await waitUntil(interval: .milliseconds(10)) {
            events.contains { $0.name == "key_interceptor_secure_input_cleared" }
        }

        #expect(events.contains { event in
            event.name == "key_interceptor_secure_input_cleared" &&
                event.metadata["targetPid"] == "43"
        })
    }
}
