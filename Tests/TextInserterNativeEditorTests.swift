import AppKit
import ApplicationServices
import Testing
@testable import SpeakFlow

@Suite("Native editor streaming ownership", .serialized)
struct TextInserterNativeEditorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func nativeEditorAcknowledgesCorrectionsAndRejectsMovedCaret() async throws {
        guard NativeUIProbeSupport.isChild(for: "TextInserterNativeEditorTests") else {
            try NativeUIProbeSupport.runChild(suite: "TextInserterNativeEditorTests")
            return
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic editor test"
        let content = try #require(window.contentView)
        let editor = NSTextView(frame: content.bounds)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.string = "prefix "
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        window.contentView = editor
        window.orderBack(nil)
        defer { window.close() }
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.captureTargetForTesting = {
            inserter.targetElement = AXUIElementCreateApplication(42_424)
            inserter.targetPid = 42_424
            return true
        }
        inserter.editorSnapshotForTesting = {
            .init(text: editor.string, selection: editor.selectedRange())
        }
        inserter.testIsTargetFrontmost = true
        inserter._testSetTargetProcessLiveness { _ in true }
        inserter._testSetFlagsProvider { [] }
        var enters = 0
        var notices = 0
        inserter.onDeliveryFailure = { notices += 1 }
        inserter._testSetEventPoster { event in
            guard event.type == .keyDown else { return }
            if event.getIntegerValueField(.keyboardEventKeycode) == 36 { enters += 1; return }
            // Direct AppKit dispatch bypasses WindowServer virtual-key translation.
            if event.getIntegerValueField(.keyboardEventKeycode) == 51 {
                if let native = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
                    editor.keyDown(with: native)
                }
            } else if let native = NSEvent(cgEvent: event) { editor.keyDown(with: native) }
        }
        #expect(inserter.captureTarget())
        inserter.updateStreamingText("hello", isFinal: false)
        await inserter.waitForPendingInsertions()
        #expect(editor.string == "prefix hello")
        inserter.updateStreamingText("help", isFinal: false)
        await inserter.waitForPendingInsertions()
        #expect(editor.string == "prefix help")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        inserter.updateStreamingText("held", isFinal: true)
        inserter.pressEnterKey()
        await inserter.waitForPendingInsertions()
        #expect(editor.string == "prefix help")
        #expect(enters == 0)
        #expect(notices == 1)
    }
}
