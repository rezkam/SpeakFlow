import AppKit
import ApplicationServices
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("TextInserter Modifier Safety")
struct TextInserterModifierSafetyTests {
    @MainActor
    @Test
    func typingUsesMoreConservativePacingDefaults() {
        #expect(TextInserter._testKeystrokeDelayMicroseconds == 8_500)
        #expect(TextInserter._testTypingBatchSize == 14)
        #expect(TextInserter._testTypingBatchYieldNanoseconds == 8_500_000)
    }

    @MainActor
    @Test
    func hasActiveModifiersDetectsPressedFlags() {
        #expect(!TextInserter._testHasActiveModifiers([]))
        #expect(TextInserter._testHasActiveModifiers(.maskCommand))
        #expect(TextInserter._testHasActiveModifiers(.maskControl))
        #expect(TextInserter._testHasActiveModifiers(.maskAlternate))
        #expect(TextInserter._testHasActiveModifiers(.maskShift))
    }

    @MainActor
    @Test
    func waitForModifiersReleasedSucceedsWhenReleasedBeforeTimeout() async {
        let inserter = TextInserter.shared
        let sequence: [CGEventFlags] = [.maskCommand, .maskCommand, []]
        var index = 0

        let released = await inserter._testWaitForModifiersReleased(maxAttempts: 5) {
            let value = sequence[min(index, sequence.count - 1)]
            index += 1
            return value
        }

        #expect(released)
    }

    @MainActor
    @Test
    func waitForModifiersReleasedFailsWhenStillPressedAtTimeout() async {
        let inserter = TextInserter.shared
        let released = await inserter._testWaitForModifiersReleased(maxAttempts: 2) {
            .maskCommand
        }

        #expect(!released)
    }
}

// MARK: - Contract Coverage: the real posting paths route through the gate

/// Drives the real `insertText`/`deleteChars`/`pressEnterKey` entry points on an
/// isolated instance, with a scripted modifier-flags source and a capture sink
/// standing in for the real `CGEvent.post(tap:)`. This is the coverage that was
/// missing (F-17): none of the tests above ever exercised the posting paths, so
/// deleting the modifier guard from any of them kept the suite green.
@Suite("TextInserter Modifier Safety — Guarded Posting Paths", .serialized)
struct TextInserterGuardedPostingTests {

    /// Minimal description of a posted `CGEvent`, enough to assert identity
    /// (key-down vs key-up, which key / unicode payload) and ordering.
    private struct PostedEvent: CustomStringConvertible {
        let isKeyDown: Bool
        let keyCode: Int64
        let unicode: String

        var description: String {
            "\(isKeyDown ? "down" : "up"):code=\(keyCode):unicode=\(unicode)"
        }
    }

    private func describe(_ event: CGEvent) -> PostedEvent {
        let isKeyDown = event.type == .keyDown
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        let unicode = length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""
        return PostedEvent(isKeyDown: isKeyDown, keyCode: keyCode, unicode: unicode)
    }

    /// Creates an isolated instance with a valid, currently-frontmost target
    /// already captured, so focus checks pass until a test deliberately flips
    /// `testIsTargetFrontmost`.
    ///
    /// The target must be a real running GUI application (not this test
    /// process's own PID): `ensureTargetFocused()` verifies liveness via
    /// `NSRunningApplication(processIdentifier:)`, which does not track
    /// command-line test-runner processes, only bundled applications. Using
    /// our own PID would make `ensureTargetFocused()` fail before the gate is
    /// ever reached, for reasons unrelated to modifiers or focus overrides —
    /// the same pitfall the existing focus tests in `TextInserterFocusTests`
    /// route around by picking a real background app.
    @MainActor
    private func makeFocusedInstance() -> TextInserter? {
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular
        }) else { return nil }

        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.targetElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        inserter.targetPid = runningApp.processIdentifier
        inserter.testIsTargetFrontmost = true
        return inserter
    }

    // MARK: insertText / typeTextAsync

    @MainActor @Test
    func insertTextPostsNothingUntilModifiersReleaseThenPosts() async {
        guard let inserter = makeFocusedInstance() else { return }

        var trace: [String] = []
        inserter._testSetEventPoster { event in
            trace.append("posted:\(self.describe(event))")
        }
        var flagCalls = 0
        inserter._testSetFlagsProvider {
            flagCalls += 1
            let held = flagCalls <= 3
            trace.append(held ? "flags:held" : "flags:clear")
            return held ? .maskCommand : []
        }

        inserter.insertText("a")
        await inserter.waitForPendingInsertions()

        let firstPostedIndex = trace.firstIndex { $0.hasPrefix("posted:") }
        let lastHeldIndex = trace.lastIndex(of: "flags:held")

        #expect(!trace.isEmpty, "Test should have exercised the flags provider and posting sink")
        #expect(lastHeldIndex != nil, "Test must actually exercise the held-modifier branch")
        #expect(firstPostedIndex != nil, "insertText should eventually post once modifiers clear")
        if let firstPostedIndex, let lastHeldIndex {
            #expect(firstPostedIndex > lastHeldIndex,
                    "No key event may be posted while modifiers are still reported held")
        }
    }

    @MainActor @Test
    func insertTextAbortsIfFocusLostDuringModifierWait() async {
        guard let inserter = makeFocusedInstance() else { return }

        // Write a sub-second timeout directly to the test UserDefaults suite.
        // The setter clamps to 10s minimum, but the getter trusts stored
        // values, so writing directly to defaults enables fast test execution
        // (see the identical technique in TextInserterFocusTests.swift).
        let suiteName = "nu.rez.speakflow.tests.\(ProcessInfo.processInfo.processIdentifier)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else { return }
        testDefaults.set(0.05, forKey: "settings.focusWaitTimeout")
        defer {
            testDefaults.removeObject(forKey: "settings.focusWaitTimeout")
            inserter.testIsTargetFrontmost = nil
        }

        var posted: [String] = []
        inserter._testSetEventPoster { _ in posted.append("posted") }

        var flagCalls = 0
        inserter._testSetFlagsProvider { [weak inserter] in
            flagCalls += 1
            if flagCalls > 3 {
                // Modifiers just cleared — simulate the user having switched
                // away from the target app while we were waiting.
                inserter?.testIsTargetFrontmost = false
                return []
            }
            return .maskCommand
        }

        inserter.insertText("a")
        await inserter.waitForPendingInsertions()

        #expect(posted.isEmpty,
                "No event should post when the target app lost focus during the modifier-release wait")
    }

    // MARK: deleteChars / deleteCharsAsync

    @MainActor @Test
    func deleteCharsPostsNothingUntilModifiersReleaseThenPosts() async {
        guard let inserter = makeFocusedInstance() else { return }

        var trace: [String] = []
        inserter._testSetEventPoster { event in
            trace.append("posted:\(self.describe(event))")
        }
        var flagCalls = 0
        inserter._testSetFlagsProvider {
            flagCalls += 1
            let held = flagCalls <= 3
            trace.append(held ? "flags:held" : "flags:clear")
            return held ? .maskCommand : []
        }

        inserter.deleteChars(1)
        await inserter.waitForPendingInsertions()

        let firstPostedIndex = trace.firstIndex { $0.hasPrefix("posted:") }
        let lastHeldIndex = trace.lastIndex(of: "flags:held")

        #expect(lastHeldIndex != nil, "Test must actually exercise the held-modifier branch")
        #expect(firstPostedIndex != nil, "deleteChars should eventually post once modifiers clear")
        if let firstPostedIndex, let lastHeldIndex {
            #expect(firstPostedIndex > lastHeldIndex,
                    "No Delete key event may be posted while modifiers are still reported held")
        }
    }

    @MainActor @Test
    func deleteCharsAbortsIfFocusLostDuringModifierWait() async {
        guard let inserter = makeFocusedInstance() else { return }

        // Write a sub-second timeout directly to the test UserDefaults suite.
        // The setter clamps to 10s minimum, but the getter trusts stored
        // values, so writing directly to defaults enables fast test execution
        // (see the identical technique in TextInserterFocusTests.swift).
        let suiteName = "nu.rez.speakflow.tests.\(ProcessInfo.processInfo.processIdentifier)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else { return }
        testDefaults.set(0.05, forKey: "settings.focusWaitTimeout")
        defer {
            testDefaults.removeObject(forKey: "settings.focusWaitTimeout")
            inserter.testIsTargetFrontmost = nil
        }

        var posted: [String] = []
        inserter._testSetEventPoster { _ in posted.append("posted") }

        var flagCalls = 0
        inserter._testSetFlagsProvider { [weak inserter] in
            flagCalls += 1
            if flagCalls > 3 {
                inserter?.testIsTargetFrontmost = false
                return []
            }
            return .maskCommand
        }

        inserter.deleteChars(1)
        await inserter.waitForPendingInsertions()

        #expect(posted.isEmpty,
                "No Delete key event should post when focus was lost during the modifier-release wait")
    }

    // MARK: pressEnterKey

    @MainActor @Test
    func pressEnterKeyPostsNothingUntilModifiersReleaseThenPosts() async throws {
        guard let inserter = makeFocusedInstance() else { return }

        var trace: [String] = []
        inserter._testSetEventPoster { event in
            trace.append("posted:\(self.describe(event))")
        }
        var flagCalls = 0
        inserter._testSetFlagsProvider {
            flagCalls += 1
            let held = flagCalls <= 3
            trace.append(held ? "flags:held" : "flags:clear")
            return held ? .maskCommand : []
        }

        inserter.pressEnterKey()
        try await waitUntil(timeout: .seconds(3)) {
            trace.contains { $0.hasPrefix("posted:") }
        }

        let firstPostedIndex = trace.firstIndex { $0.hasPrefix("posted:") }
        let lastHeldIndex = trace.lastIndex(of: "flags:held")

        #expect(lastHeldIndex != nil, "Test must actually exercise the held-modifier branch")
        #expect(firstPostedIndex != nil, "pressEnterKey should eventually post once modifiers clear")
        if let firstPostedIndex, let lastHeldIndex {
            #expect(firstPostedIndex > lastHeldIndex,
                    "No Enter key event may be posted while modifiers are still reported held")
        }
    }

    @MainActor @Test
    func pressEnterKeyAbortsIfFocusLostDuringModifierWait() async throws {
        guard let inserter = makeFocusedInstance() else { return }

        // Write a sub-second timeout directly to the test UserDefaults suite.
        // The setter clamps to 10s minimum, but the getter trusts stored
        // values, so writing directly to defaults enables fast test execution
        // (see the identical technique in TextInserterFocusTests.swift).
        let suiteName = "nu.rez.speakflow.tests.\(ProcessInfo.processInfo.processIdentifier)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else { return }
        testDefaults.set(0.05, forKey: "settings.focusWaitTimeout")
        defer {
            testDefaults.removeObject(forKey: "settings.focusWaitTimeout")
            inserter.testIsTargetFrontmost = nil
        }

        var posted: [String] = []
        inserter._testSetEventPoster { _ in posted.append("posted") }

        var flagCalls = 0
        inserter._testSetFlagsProvider { [weak inserter] in
            flagCalls += 1
            if flagCalls > 3 {
                inserter?.testIsTargetFrontmost = false
                return []
            }
            return .maskCommand
        }

        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()

        #expect(posted.isEmpty,
                "No Enter key event should post when focus was lost during the modifier-release wait")
    }
}
