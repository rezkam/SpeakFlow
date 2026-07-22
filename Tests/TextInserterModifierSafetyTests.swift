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

// MARK: - Contract Coverage: real posting paths use guarded pairs

@Suite("TextInserter Modifier Safety — Guarded Posting Paths", .serialized)
struct TextInserterGuardedPostingTests {
    private struct PostedEvent: CustomStringConvertible, Equatable {
        let isKeyDown: Bool
        let keyCode: Int64
        let unicode: String

        var description: String {
            "\(isKeyDown ? "down" : "up"):code=\(keyCode):unicode=\(unicode)"
        }
    }

    private enum TraceEntry {
        case flagsHeld
        case flagsClear
        case posted(PostedEvent)
    }

    @MainActor
    private final class ModifierPostingTrace {
        private(set) var entries: [TraceEntry] = []

        func recordFlags(_ flags: CGEventFlags) {
            entries.append(TextInserter._testHasActiveModifiers(flags) ? .flagsHeld : .flagsClear)
        }

        func recordPost(_ event: PostedEvent) {
            entries.append(.posted(event))
        }
    }

    private func describe(_ event: CGEvent) -> PostedEvent {
        let isKeyDown = event.type == .keyDown
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        let unicode = length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""
        return PostedEvent(isKeyDown: isKeyDown, keyCode: keyCode, unicode: unicode)
    }

    /// Uses a deterministic PID and liveness seam. Focus remains injected, so
    /// these tests exercise production focus decisions without a GUI app.
    @MainActor
    private func makeFocusedInstance() -> TextInserter {
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.targetElement = AXUIElementCreateApplication(42_424)
        inserter.targetPid = 42_424
        inserter.testIsTargetFrontmost = true
        inserter._testSetTargetProcessLiveness { $0 == 42_424 }
        return inserter
    }

    @MainActor
    private func installHeldThenClearTrace(
        on inserter: TextInserter,
        trace: ModifierPostingTrace
    ) {
        var flagCalls = 0
        inserter._testSetFlagsProvider {
            flagCalls += 1
            let flags: CGEventFlags = flagCalls <= 3 ? .maskCommand : []
            trace.recordFlags(flags)
            return flags
        }
        inserter._testSetEventPoster { trace.recordPost(describe($0)) }
    }

    @MainActor
    private func installHeldClearHeldClearTrace(
        on inserter: TextInserter,
        trace: ModifierPostingTrace
    ) {
        let sequence: [CGEventFlags] = [
            .maskCommand, .maskCommand, [],
            .maskCommand, .maskCommand, []
        ]
        var index = 0
        inserter._testSetFlagsProvider {
            let flags = sequence[min(index, sequence.count - 1)]
            index += 1
            trace.recordFlags(flags)
            return flags
        }
        inserter._testSetEventPoster { trace.recordPost(describe($0)) }
    }

    @MainActor
    private func expectGuardedSinglePair(
        _ trace: ModifierPostingTrace,
        keyCode: Int64,
        unicode: String = ""
    ) {
        let entries = trace.entries
        let firstHeldIndex = entries.firstIndex { if case .flagsHeld = $0 { true } else { false } }
        let firstClearIndex = entries.firstIndex { if case .flagsClear = $0 { true } else { false } }
        let firstPostIndex = entries.firstIndex { if case .posted = $0 { true } else { false } }
        let events = entries.compactMap { if case let .posted(event) = $0 { event } else { nil } }

        #expect(firstHeldIndex != nil, "The held-modifier branch must execute")
        #expect(firstClearIndex != nil, "The clear modifier state must be observed")
        #expect(firstPostIndex != nil, "The action must eventually post")
        if let firstClearIndex, let firstPostIndex {
            #expect(firstPostIndex > firstClearIndex, "The first event must post after modifiers first clear")
        }
        #expect(events.count == 2, "Each synthetic action must emit exactly two events")
        guard events.count == 2 else { return }
        #expect(events[0].isKeyDown)
        #expect(!events[1].isKeyDown)
        #expect(events[0].keyCode == keyCode)
        #expect(events[1].keyCode == keyCode)
        #expect(events[0].unicode == events[1].unicode)
        if !unicode.isEmpty { #expect(events[0].unicode == unicode) }
    }

    @MainActor
    private func expectSinglePair(
        _ events: [PostedEvent],
        keyCode: Int64,
        unicode: String = ""
    ) {
        #expect(events.count == 2, "Each synthetic action must emit exactly two events")
        guard events.count == 2 else { return }
        #expect(events[0].isKeyDown)
        #expect(!events[1].isKeyDown)
        #expect(events[0].keyCode == keyCode)
        #expect(events[1].keyCode == keyCode)
        #expect(events[0].unicode == events[1].unicode)
        if !unicode.isEmpty { #expect(events[0].unicode == unicode) }
    }

    @MainActor @Test
    func insertTextWaitsForModifiersAndPostsOrderedPair() async {
        let inserter = makeFocusedInstance()
        let trace = ModifierPostingTrace()
        installHeldThenClearTrace(on: inserter, trace: trace)

        inserter.insertText("a")
        await inserter.waitForPendingInsertions()

        expectGuardedSinglePair(trace, keyCode: 0, unicode: "a")
    }

    @MainActor @Test
    func insertTextRechecksModifiersAfterFocusValidation() async {
        let inserter = makeFocusedInstance()
        let trace = ModifierPostingTrace()
        installHeldClearHeldClearTrace(on: inserter, trace: trace)

        inserter.insertText("a")
        await inserter.waitForPendingInsertions()

        let entries = trace.entries
        let heldIndices = entries.indices.filter {
            if case .flagsHeld = entries[$0] { return true }
            return false
        }
        let clearIndices = entries.indices.filter {
            if case .flagsClear = entries[$0] { return true }
            return false
        }
        let firstPostIndex = entries.firstIndex {
            if case .posted = $0 { return true }
            return false
        }

        #expect(heldIndices.count >= 4, "Modifiers must be observed held again after focus validation")
        #expect(clearIndices.count >= 3, "The final clear state must be observed before posting")
        if let finalClearIndex = clearIndices.last, let firstPostIndex {
            #expect(firstPostIndex > finalClearIndex, "No event may post during the second held-modifier period")
        }
        expectGuardedSinglePair(trace, keyCode: 0, unicode: "a")
    }

    @MainActor @Test
    func deleteCharsWaitsForModifiersAndPostsOrderedPair() async {
        let inserter = makeFocusedInstance()
        let trace = ModifierPostingTrace()
        installHeldThenClearTrace(on: inserter, trace: trace)

        inserter.deleteChars(1)
        await inserter.waitForPendingInsertions()

        expectGuardedSinglePair(trace, keyCode: 51)
    }

    @MainActor @Test
    func pressEnterWaitsForModifiersAndPostsOrderedPair() async {
        let inserter = makeFocusedInstance()
        let trace = ModifierPostingTrace()
        installHeldThenClearTrace(on: inserter, trace: trace)

        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()

        expectGuardedSinglePair(trace, keyCode: 36)
    }

    @MainActor @Test(arguments: ["text", "delete", "enter"])
    func releasePostsAfterFocusAndModifierChangeFollowingKeyDown(_ path: String) async {
        let inserter = makeFocusedInstance()
        var events: [PostedEvent] = []
        inserter._testSetFlagsProvider { [] }
        inserter._testSetEventPoster { event in
            events.append(describe(event))
            if event.type == .keyDown {
                // This state change happens after the safety check. It must not
                // turn a required release into a second guarded action.
                inserter.testIsTargetFrontmost = false
                inserter._testSetFlagsProvider { .maskCommand }
            }
        }

        switch path {
        case "text": inserter.insertText("a")
        case "delete": inserter.deleteChars(1)
        default: inserter.pressEnterKey()
        }
        await inserter.waitForPendingInsertions()

        let code: Int64 = path == "delete" ? 51 : path == "enter" ? 36 : 0
        expectSinglePair(events, keyCode: code, unicode: path == "text" ? "a" : "")
    }

    @MainActor @Test
    func enterReleasePostsWhenCancellationArrivesDuringRegistrationDelay() async {
        let inserter = makeFocusedInstance()
        var events: [PostedEvent] = []
        inserter._testSetFlagsProvider { [] }
        inserter._testSetEventPoster { event in
            events.append(describe(event))
            if event.type == .keyDown {
                inserter.cancelAndReset()
            }
        }

        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()

        expectSinglePair(events, keyCode: 36)
    }

    @MainActor @Test(arguments: ["text", "delete", "enter"])
    func focusLossBeforeKeyDownPostsNothing(_ path: String) async {
        let inserter = makeFocusedInstance()
        var events: [PostedEvent] = []
        var calls = 0
        var targetIsRunning = true
        inserter._testSetTargetProcessLiveness { _ in targetIsRunning }
        inserter._testSetEventPoster { events.append(describe($0)) }
        inserter._testSetFlagsProvider {
            calls += 1
            if calls > 2 {
                inserter.testIsTargetFrontmost = false
                targetIsRunning = false
                return []
            }
            return .maskCommand
        }

        switch path {
        case "text": inserter.insertText("a")
        case "delete": inserter.deleteChars(1)
        default: inserter.pressEnterKey()
        }
        await inserter.waitForPendingInsertions()

        #expect(calls > 2, "The modifier wait must have completed before focus is revalidated")
        #expect(events.isEmpty, "Safety validation failure before key-down must post nothing")
    }
}
