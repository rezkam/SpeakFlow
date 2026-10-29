import AppKit
import ApplicationServices
import Testing
@testable import SpeakFlow

@Suite("Streaming insertion ownership", .serialized)
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

    @Test @MainActor func movedCaretCannotDeleteExistingContentOrSubmit() async {
        let editor = Editor()
        let inserter = editor.inserter()
        inserter.updateStreamingText("hello", isFinal: false)
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "prefix hello")
        editor.selection.location = 3
        inserter.updateStreamingText("help", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "prefix hello")
        #expect(!editor.keys.contains(51))
        #expect(!editor.keys.contains(36))
    }

    @Test @MainActor func unreadableEditorDoesNotReceiveStreamingOrEnter() async {
        let editor = Editor()
        editor.readable = false
        let inserter = editor.inserter()
        inserter.updateStreamingText("hello", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.keys.isEmpty)
    }

    @Test @MainActor func unacknowledgedKeyStopsFurtherTypingAndEnter() async {
        let editor = Editor()
        editor.acceptsEvents = false
        let inserter = editor.inserter()
        inserter.updateStreamingText("hello", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.keys.count == 1)
        #expect(!editor.keys.contains(36))
    }

    @Test(arguments: [false, true]) @MainActor
    func changedContentOrSelectionCannotAuthorizeCorrection(select: Bool) async {
        let editor = Editor()
        let inserter = editor.inserter()
        inserter.updateStreamingText("hello", isFinal: false)
        await inserter.waitForPendingInsertions()
        if select { editor.selection.length = 1; editor.selection.location -= 1 }
        else { editor.text = "edited hello" }
        let untouched = editor.text
        let count = editor.keys.count
        inserter.updateStreamingText("help", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.text == untouched)
        #expect(editor.keys.count == count)
    }

    @Test @MainActor func delayedAcknowledgementIsAwaitedBeforeSubmit() async throws {
        let editor = Editor()
        let inserter = editor.inserter()
        editor.acceptsEvents = false
        inserter._testSetEventPoster { event in
            guard event.type == .keyDown else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(25))
                editor.acceptsEvents = true
                editor.post(event)
                editor.acceptsEvents = false
            }
        }
        inserter.updateStreamingText("ok", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.text == "prefix ok ")
        try await waitUntil { editor.keys.contains(36) }
    }

    @Test @MainActor func movingCaretWhileModifiersAreHeldCannotRedirectTyping() async throws {
        let editor = Editor()
        let inserter = editor.inserter()
        var held = true
        inserter._testSetFlagsProvider { held ? .maskCommand : [] }
        inserter.updateStreamingText("hello", isFinal: true)
        inserter.pressEnterKey()
        try await Task.sleep(for: .milliseconds(30))
        editor.selection.location = 2
        held = false
        await inserter.waitForPendingInsertions()
        #expect(editor.keys.isEmpty)
        #expect(editor.text == "prefix ")
    }

    @Test @MainActor func cancellationRetiresAnAcknowledgementWait() async throws {
        let editor = Editor()
        editor.acceptsEvents = false
        let inserter = editor.inserter()
        inserter.updateStreamingText("old", isFinal: true)
        inserter.pressEnterKey()
        let old = inserter.pendingTask
        try await waitUntil { editor.keys.count == 1 }
        inserter.cancelAndReset()
        await old?.value
        #expect(editor.keys.count == 1)
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
