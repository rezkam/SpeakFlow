import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - HotkeyListener Double-Tap State Machine Tests

@Suite("HotkeyListener — Double-Tap Detection", .serialized)
struct HotkeyListenerDoubleTapTests {

    /// Create a synthetic flagsChanged CGEvent with specified flags.
    /// Uses `CGEvent(source: nil)` for minimal overhead — we only need the flags.
    private func makeFlagsEvent(controlDown: Bool) -> CGEvent {
        // CGEvent(source: nil) is guaranteed to succeed for flag-only events.
        // If this ever fails, return a fallback via keyboardEvent constructor.
        if let event = CGEvent(source: nil) {
            event.type = .flagsChanged
            if controlDown {
                event.flags = [.maskControl, .maskNonCoalesced]
            } else {
                event.flags = [.maskNonCoalesced]
            }
            return event
        }
        // Fallback: try keyboard event constructor
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: 0x3B, keyDown: controlDown)!
        event.type = .flagsChanged
        if controlDown {
            event.flags = [.maskControl, .maskNonCoalesced]
        } else {
            event.flags = [.maskNonCoalesced]
        }
        return event
    }

    /// Create a synthetic event with specific modifier flags (for non-Control keys).
    private func makeModifierEvent(flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = .flagsChanged
        event.flags = flags
        return event
    }

    /// Simulate a full Control press+release cycle.
    @MainActor
    private func tapControl(on listener: HotkeyListener) {
        listener.handleFlagsChanged(event: makeFlagsEvent(controlDown: true))
        listener.handleFlagsChanged(event: makeFlagsEvent(controlDown: false))
    }

    @MainActor @Test
    func doubleTapControl_withinInterval_triggersCallback() {
        let listener = HotkeyListener()
        var detected = false
        // Synchronous test hook fires immediately on double-tap detection,
        // before the async Task dispatch. No sleeps needed — both taps
        // execute in microseconds, well within the 0.4s window.
        listener._testDoubleTapDetected = { detected = true }

        // First tap (press + release)
        tapControl(on: listener)
        // Second tap — triggers double-tap detection synchronously
        tapControl(on: listener)

        #expect(detected, "Double-tap within interval should trigger detection")
    }

    @MainActor @Test
    func doubleTapControl_recordsActivationDiagnostic() {
        let listener = HotkeyListener()
        var events: [HotkeyDiagnosticEvent] = []
        HotkeyDiagnostics._testEventHook = { events.append($0) }
        defer { HotkeyDiagnostics._testEventHook = nil }

        tapControl(on: listener)
        tapControl(on: listener)

        #expect(events.contains { event in
            event.name == "hotkey_activation_detected" &&
                event.metadata["hotkeyType"] == HotkeyType.doubleTapControl.rawValue &&
                event.metadata["trigger"] == "controlDoubleTap"
        })
    }

    @MainActor @Test
    func doubleTapControl_tooSlow_doesNotTrigger() async throws {
        let listener = HotkeyListener()
        var activated = false
        listener.onActivate = { activated = true }

        tapControl(on: listener)
        // Wait longer than the 0.4s double-tap interval
        try await Task.sleep(for: .milliseconds(500))
        tapControl(on: listener)
        // Give any potential async Task time to fire
        try await Task.sleep(for: .milliseconds(200))

        #expect(!activated, "Taps separated by > 0.4s should NOT trigger onActivate")
    }

    @MainActor @Test
    func singleTap_doesNotTrigger() async throws {
        let listener = HotkeyListener()
        var activated = false
        listener.onActivate = { activated = true }

        tapControl(on: listener)
        try await Task.sleep(for: .milliseconds(500))

        #expect(!activated, "Single tap should NOT trigger onActivate")
    }

    @MainActor @Test
    func otherModifier_ignored() async throws {
        let listener = HotkeyListener()
        var activated = false
        listener.onActivate = { activated = true }

        // Simulate Shift double-tap (not Control — should be ignored)
        listener.handleFlagsChanged(event: makeModifierEvent(flags: [.maskShift, .maskNonCoalesced]))
        listener.handleFlagsChanged(event: makeModifierEvent(flags: [.maskNonCoalesced]))
        try await Task.sleep(for: .milliseconds(100))
        listener.handleFlagsChanged(event: makeModifierEvent(flags: [.maskShift, .maskNonCoalesced]))
        listener.handleFlagsChanged(event: makeModifierEvent(flags: [.maskNonCoalesced]))
        try await Task.sleep(for: .milliseconds(200))

        #expect(!activated, "Double-tap Shift should NOT trigger (only Control triggers)")
    }

    @MainActor @Test
    func controlWithOtherModifier_ignored() async throws {
        let listener = HotkeyListener()
        var activated = false
        listener.onActivate = { activated = true }

        // Control+Command held (both modifiers present)
        listener.handleFlagsChanged(event: makeModifierEvent(flags: [.maskControl, .maskCommand, .maskNonCoalesced]))
        // Release with Command still held
        listener.handleFlagsChanged(event: makeModifierEvent(flags: [.maskCommand, .maskNonCoalesced]))
        try await Task.sleep(for: .milliseconds(100))
        // Repeat
        listener.handleFlagsChanged(event: makeModifierEvent(flags: [.maskControl, .maskCommand, .maskNonCoalesced]))
        listener.handleFlagsChanged(event: makeModifierEvent(flags: [.maskCommand, .maskNonCoalesced]))
        try await Task.sleep(for: .milliseconds(200))

        #expect(!activated, "Control+Command should NOT count as a control-only double-tap")
    }
}

@Suite("HotkeyListener — Event Tap Registration", .serialized)
struct HotkeyListenerRegistrationTests {
    @MainActor @Test
    func stopInvalidatesTheDoubleTapEventTap() throws {
        let fake = FakeHotkeyEventTapDriver()
        let listener = HotkeyListener(eventTapDriver: fake.driver)

        listener.start(type: .doubleTapControl)
        let tap = try #require(fake.createdTaps.first)
        #expect(CFMachPortIsValid(tap), "A running listener must keep its tap valid")

        listener.stop()

        #expect(!CFMachPortIsValid(tap),
                "stop() must invalidate the tap; a disabled-but-valid tap stays registered in the WindowServer")
    }
}

final class FakeHotkeyEventTapDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var _createdTaps: [CFMachPort] = []

    var createdTaps: [CFMachPort] { lock.withLock { _createdTaps } }

    var driver: HotkeyListener.EventTapDriver {
        HotkeyListener.EventTapDriver(
            createTap: { [self] _, _ in
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
            setTapEnabled: { _, _ in }
        )
    }
}

/// Holding a combination hotkey must not toggle dictation again on key repeat.
@Suite("HotkeyListener — Combination Key Repeat", .serialized)
struct HotkeyListenerKeyRepeatTests {
    private func comboEvent(isRepeat: Bool) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "d", charactersIgnoringModifiers: "d", isARepeat: isRepeat, keyCode: 2
        )
    }

    @MainActor @Test
    func autoRepeatedKeyDownDoesNotActivate() throws {
        let listener = HotkeyListener()
        var activations = 0
        HotkeyDiagnostics._testEventHook = { if $0.name == "hotkey_activation_detected" { activations += 1 } }
        defer { HotkeyDiagnostics._testEventHook = nil }

        listener.handleKeyDown(event: try #require(comboEvent(isRepeat: false)), type: .controlOptionD)
        for _ in 0..<5 {
            listener.handleKeyDown(event: try #require(comboEvent(isRepeat: true)), type: .controlOptionD)
        }

        #expect(activations == 1, "Only the fresh press toggles dictation; repeats while held must not")
    }
}

/// Double-tap Control must mean two isolated Control taps, not two shortcuts.
@Suite("HotkeyListener — Double-Tap Excludes Shortcuts", .serialized)
struct HotkeyListenerDoubleTapShortcutTests {
    private func flags(_ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = .flagsChanged
        event.flags = flags
        return event
    }

    private func keyDown(_ keyCode: CGKeyCode, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        return event
    }

    @MainActor
    private func detections(_ steps: (HotkeyListener) -> Void) -> Int {
        let listener = HotkeyListener()
        var count = 0
        listener._testDoubleTapDetected = { count += 1 }
        steps(listener)
        return count
    }

    @MainActor @Test
    func twoControlShortcutsInQuickSuccessionDoNotToggle() {
        let count = detections { listener in
            for key: CGKeyCode in [8, 9] { // Control+C, then Control+V
                listener.handleFlagsChanged(event: flags([.maskControl]))
                listener.handleTapKeyDown(event: keyDown(key, flags: [.maskControl]))
                listener.handleFlagsChanged(event: flags([]))
            }
        }
        #expect(count == 0, "Control used for shortcuts is not a tap")
    }

    @MainActor @Test
    func controlCommandChordReleasedCommandFirstDoesNotCount() {
        let count = detections { listener in
            for _ in 0..<2 {
                listener.handleFlagsChanged(event: flags([.maskControl]))
                listener.handleFlagsChanged(event: flags([.maskControl, .maskCommand]))
                listener.handleFlagsChanged(event: flags([.maskControl]))
                listener.handleFlagsChanged(event: flags([]))
            }
        }
        #expect(count == 0, "A Control press that took part in a chord is not a tap")
    }

    @MainActor @Test
    func shortcutThenTapThenTapStillToggles() {
        let count = detections { listener in
            listener.handleFlagsChanged(event: flags([.maskControl]))
            listener.handleTapKeyDown(event: keyDown(8, flags: [.maskControl]))
            listener.handleFlagsChanged(event: flags([]))
            for _ in 0..<2 {
                listener.handleFlagsChanged(event: flags([.maskControl]))
                listener.handleFlagsChanged(event: flags([]))
            }
        }
        #expect(count == 1, "Two isolated taps after a shortcut still toggle once")
    }
}
