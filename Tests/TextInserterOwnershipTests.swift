import AppKit
import ApplicationServices
import Testing
@testable import SpeakFlow

@Suite("Streaming insertion compatibility and safety", .serialized)
struct TextInserterOwnershipTests {
    @MainActor final class Editor {
        var text = "prefix "
        var selection = NSRange(location: 7, length: 0)
        var readable = true
        var acceptsEvents = true
        var keys: [Int64] = []
        var snapshot: TextInserter.EditorSnapshot? {
            readable ? .init(text: text, selection: selection) : nil
        }
        func post(_ event: CGEvent) {
            guard event.type == .keyDown else { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            keys.append(code)
            guard acceptsEvents else { return }
            if code == 36 { return }
            if code == 51 {
                guard selection.location > 0 else { return }
                let before = String((text as NSString).substring(to: selection.location))
                let length = String(before.last!).utf16.count
                text = (text as NSString).replacingCharacters(in: NSRange(location: selection.location - length, length: length), with: "")
                selection.location -= length
            } else {
                var length = 0
                var buffer = [UniChar](repeating: 0, count: 64)
                event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
                let inserted = String(utf16CodeUnits: buffer, count: length)
                text = (text as NSString).replacingCharacters(in: selection, with: inserted)
                selection = NSRange(location: selection.location + inserted.utf16.count, length: 0)
            }
        }
        func inserter() -> TextInserter {
            let value = TextInserter._testMakeIsolatedInstance()
            value.captureTargetForTesting = { [weak value] in
                value?.targetElement = AXUIElementCreateApplication(42_424)
                value?.targetPid = 42_424
                return true
            }
            value.editorSnapshotForTesting = { self.snapshot }
            value.testIsTargetFrontmost = true
            value._testSetTargetProcessLiveness { _ in true }
            value._testSetFlagsProvider { [] }
            value._testSetEventPoster { self.post($0) }
            _ = value.captureTarget()
            return value
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func opaqueEditorReceivesCompleteUtterancesAndCanBeCleared(unreadable: Bool) async {
        let editor = Editor()
        let inserter = editor.inserter()
        let stale = editor.snapshot
        inserter.editorSnapshotForTesting = { unreadable ? nil : stale }
        #expect(inserter.captureTarget())
        inserter.updateStreamingText("sample phrase", isFinal: true)
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "prefix sample phrase ")
        editor.text = ""
        editor.selection = NSRange(location: 0, length: 0)
        inserter.updateStreamingText("another phrase", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "another phrase ")
        #expect(editor.keys.filter { $0 == 36 }.count == 1)
        #expect(!editor.keys.contains(51))
    }

    @Test @MainActor func clearingCompletedDictationAllowsTheNextUtterance() async {
        let editor = Editor()
        let inserter = editor.inserter()
        inserter.updateStreamingText("first utterance", isFinal: true)
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "prefix first utterance ")
        editor.text = ""
        editor.selection = NSRange(location: 0, length: 0)
        inserter.updateStreamingText("next utterance", isFinal: true)
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "next utterance ")
        #expect(!editor.keys.contains(51), "Cleared text must never authorize Backspace")
    }

    @Test @MainActor func clearingADifferentFieldDoesNotRetargetDictation() async {
        let editor = Editor()
        let inserter = editor.inserter()
        inserter.updateStreamingText("first utterance", isFinal: true)
        await inserter.waitForPendingInsertions()
        let posted = editor.keys.count
        editor.text = ""
        editor.selection = NSRange(location: 0, length: 0)
        inserter.testIsTargetFrontmost = false
        inserter._testSetFocusWaitTimeout(0)
        inserter.updateStreamingText("next utterance", isFinal: true)
        await inserter.waitForPendingInsertions()
        #expect(editor.keys.count == posted)
        #expect(editor.text.isEmpty)
    }

    @Test @MainActor func aNewRecordingCanStartInTheClearedField() async {
        let editor = Editor()
        let inserter = editor.inserter()
        inserter.updateStreamingText("first utterance", isFinal: true)
        await inserter.waitForPendingInsertions()
        inserter.reset()
        editor.text = ""
        editor.selection = NSRange(location: 0, length: 0)
        #expect(inserter.captureTarget())
        inserter.updateStreamingText("next utterance", isFinal: true)
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "next utterance ")
    }

    @Test @MainActor func changingFieldsWhileModifiersAreHeldStopsTyping() async throws {
        let editor = Editor()
        let inserter = editor.inserter()
        var held = true
        inserter._testSetFlagsProvider { held ? .maskCommand : [] }
        inserter._testSetFocusWaitTimeout(0)
        inserter.updateStreamingText("hello", isFinal: true)
        inserter.pressEnterKey()
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.keys.isEmpty)
        inserter.testIsTargetFrontmost = false
        held = false
        await inserter.waitForPendingInsertions()
        #expect(editor.keys.isEmpty)
        #expect(editor.text == "prefix ")
    }

    @Test @MainActor func cancellationRetiresRemainingCharactersAndEnter() async {
        let editor = Editor()
        let inserter = editor.inserter()
        inserter._testSetEventPoster { event in
            editor.post(event)
            if event.type == .keyUp, editor.keys.count == 1 { inserter.cancelAndReset() }
        }
        inserter.updateStreamingText("retired", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "prefix r")
        #expect(editor.keys.count == 1)
    }

    @Test @MainActor func partiallyPostedFinalCannotSubmit() async {
        let editor = Editor()
        let inserter = editor.inserter()
        inserter._testSetFocusWaitTimeout(0)
        inserter._testSetEventPoster { event in
            editor.post(event)
            if event.type == .keyUp, editor.keys.count == 1 { inserter.testIsTargetFrontmost = false }
        }
        inserter.updateStreamingText("final phrase", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "prefix f")
        #expect(!editor.keys.contains(36))
    }

    @Test @MainActor func unicodeCorrectionPreservesSurroundingContent() async {
        let editor = Editor()
        editor.text = "🌲 suffix"
        editor.selection.location = 2
        let inserter = editor.inserter()
        inserter.updateStreamingText("👩🏽‍💻 café", isFinal: false)
        await inserter.waitForPendingInsertions()
        inserter.updateStreamingText("👩🏽‍💻 cake", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "🌲👩🏽‍💻 cake  suffix")
        #expect(editor.keys.filter { $0 == 36 }.count == 1)
    }
}
