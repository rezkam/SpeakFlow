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
