import AppKit
import ApplicationServices
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

/// Cancellation must stop every queued insertion, not only the newest one.
/// Each operation is its own Task chained after its predecessor, so cancelling
/// the tail task alone leaves earlier operations runnable.
@Suite("TextInserter Cancellation", .serialized)
struct TextInserterCancellationTests {
    @MainActor
    final class PostRecorder {
        private(set) var keyDowns: [String] = []
        private(set) var keyCodes: [Int64] = []
        private(set) var keyUps = 0

        func record(_ event: CGEvent) {
            if event.type == .keyDown {
                keyCodes.append(event.getIntegerValueField(.keyboardEventKeycode))
                var length = 0
                var buffer = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(
                    maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer
                )
                let unicode = length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""
                keyDowns.append(unicode.isEmpty ? "code:\(event.getIntegerValueField(.keyboardEventKeycode))" : unicode)
            } else {
                keyUps += 1
            }
        }
    }

    @MainActor
    private func makeFocusedInstance(recorder: PostRecorder, modifiersHeld: @escaping () -> Bool) -> TextInserter {
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.targetElement = AXUIElementCreateApplication(42_424)
        inserter.targetPid = 42_424
        inserter.testIsTargetFrontmost = true
        inserter._testSetTargetProcessLiveness { $0 == 42_424 }
        inserter._testSetFlagsProvider { modifiersHeld() ? .maskCommand : [] }
        inserter._testSetEventPoster { recorder.record($0) }
        return inserter
    }

    @MainActor @Test
    func cancelStopsEveryQueuedOperationNotOnlyTheLastOne() async throws {
        let recorder = PostRecorder()
        var held = true
        let inserter = makeFocusedInstance(recorder: recorder, modifiersHeld: { held })

        // A blocks on the held modifier; B and C wait behind it.
        inserter.insertText("a")
        inserter.deleteChars(2)
        inserter.insertText("c")
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.keyDowns.isEmpty, "Nothing may post while a modifier is held")

        inserter.cancelAndReset()
        held = false
        try await Task.sleep(for: .milliseconds(1_500))

        #expect(recorder.keyDowns.isEmpty,
                "Operations queued before cancellation must never type or delete afterwards, got \(recorder.keyDowns)")
    }

    @MainActor @Test
    func cancelledOperationsDoNotTypeIntoTheNextRecording() async throws {
        let recorder = PostRecorder()
        var held = true
        let inserter = makeFocusedInstance(recorder: recorder, modifiersHeld: { held })

        inserter.insertText("old")
        inserter.pressEnterKey()
        try await Task.sleep(for: .milliseconds(50))
        inserter.cancelAndReset()

        // A new recording captures its own target and queues its own text.
        inserter.targetElement = AXUIElementCreateApplication(42_424)
        inserter.targetPid = 42_424
        inserter.insertText("new")
        held = false
        try await waitUntil(timeout: .seconds(3)) { recorder.keyDowns.count >= 3 }
        try await Task.sleep(for: .milliseconds(200))

        #expect(recorder.keyDowns == ["n", "e", "w"],
                "Only the new recording's text may be posted, got \(recorder.keyDowns)")
    }

    @MainActor @Test
    func aPostedKeyDownStillGetsItsKeyUpWhenCancelledMidPair() async throws {
        let recorder = PostRecorder()
        let inserter = makeFocusedInstance(recorder: recorder, modifiersHeld: { false })

        inserter.pressEnterKey()
        // Enter holds its key-down for 10 ms before the key-up.
        try await waitUntil(timeout: .seconds(1), interval: .milliseconds(1)) { !recorder.keyDowns.isEmpty }
        inserter.cancelAndReset()
        try await Task.sleep(for: .milliseconds(100))

        #expect(recorder.keyDowns.count == 1)
        #expect(recorder.keyUps == 1, "A key-down already posted must always be released")
    }

    @MainActor @Test
    func nothingIsTypedWithoutACapturedTarget() async throws {
        let recorder = PostRecorder()
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter._testSetFlagsProvider { [] }
        inserter._testSetEventPoster { recorder.record($0) }

        inserter.insertText("hello")
        inserter.deleteChars(1)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()

        #expect(recorder.keyDowns.isEmpty, "Without a destination, synthetic input must fail closed")
        #expect(await inserter.ensureTargetFocused() == false)
        #expect(!inserter.isTargetAppFrontmost())
    }

}

/// Dictation must stay in the field it started in, not just the same app.
@Suite("TextInserter Field Identity", .serialized)
struct TextInserterFieldIdentityTests {
    typealias Field = TextInserter.FieldIdentity

    @Test
    func identicalElementIsTheSameField() {
        #expect(TextInserter.fieldIdentity(elementsEqual: true, capturedReportsFocused: nil, windowsMatch: false) == .same)
    }

    @Test
    func capturedElementStillFocusedIsTheSameField() {
        // Some apps hand out a new reference for the same element.
        #expect(TextInserter.fieldIdentity(elementsEqual: false, capturedReportsFocused: .focused, windowsMatch: nil) == .same)
    }

    @Test
    func capturedElementNotFocusedIsADifferentField() {
        // Switched conversation, document, or field within the same app.
        #expect(TextInserter.fieldIdentity(elementsEqual: false, capturedReportsFocused: .notFocused, windowsMatch: true) == .different)
    }

    @Test
    func capturedElementGoneIsADifferentField() {
        #expect(TextInserter.fieldIdentity(elementsEqual: false, capturedReportsFocused: .elementGone, windowsMatch: true) == .different)
    }

    @Test
    func matchingWindowDoesNotProveMatchingField() {
        #expect(TextInserter.fieldIdentity(elementsEqual: false, capturedReportsFocused: .unknown, windowsMatch: false) == .different)
        #expect(TextInserter.fieldIdentity(elementsEqual: false, capturedReportsFocused: .unknown, windowsMatch: true) == .unknown)
        #expect(TextInserter.fieldIdentity(elementsEqual: false, capturedReportsFocused: .unknown, windowsMatch: nil) == .unknown,
                "Missing field evidence must not authorize input based on app or window identity")
    }

    @MainActor @Test
    func typingPausesInAnotherFieldOfTheSameAppAndResumesInTheOriginal() async throws {
        let recorder = TextInserterCancellationTests.PostRecorder()
        var field = Field.different
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.targetElement = AXUIElementCreateApplication(42_424)
        inserter.targetPid = 42_424
        inserter._testSetTargetProcessLiveness { $0 == 42_424 }
        inserter._testSetFlagsProvider { [] }
        inserter._testSetEventPoster { recorder.record($0) }
        inserter._testSetFocusObserver { .init(focusedPid: 42_424, field: field) }

        inserter.insertText("hi")
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.keyDowns.isEmpty, "Same app, different field: typing must pause")

        // The user returns to the original field; nothing forces focus.
        field = .same
        try await waitUntil(timeout: .seconds(2)) { recorder.keyDowns.count == 2 }
        #expect(recorder.keyDowns == ["h", "i"])
    }

    @MainActor @Test(arguments: [Field.unknown, Field.different, nil])
    func uncertainDestinationPausesEveryActionUntilOriginalFieldReturns(initialField: Field?) async throws {
        let recorder = TextInserterCancellationTests.PostRecorder()
        let inserter = TextInserter._testMakeIsolatedInstance()
        defer { inserter.cancelAndReset() }
        var field = initialField
        inserter.targetElement = AXUIElementCreateApplication(42_424)
        inserter.targetPid = 42_424
        inserter._testSetTargetProcessLiveness { $0 == 42_424 }
        inserter._testSetFlagsProvider { [] }
        inserter._testSetEventPoster { recorder.record($0) }
        inserter._testSetFocusObserver { field.map { .init(focusedPid: 42_424, field: $0) } }

        inserter.insertText("ok")
        inserter.deleteChars(1)
        inserter.pressEnterKey()
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.keyDowns.isEmpty, "Unproven destination must pause text, deletion, and Enter")

        // Only the user returning to the captured field authorizes queued input.
        field = .same
        await inserter.waitForPendingInsertions()
        #expect(recorder.keyDowns.count == 4)
        #expect(Array(recorder.keyDowns.prefix(2)) == ["o", "k"])
        #expect(Array(recorder.keyCodes.suffix(2)) == [51, 36])
        #expect(recorder.keyUps == 4)
    }
}
