import AppKit
import ApplicationServices
import Testing
@testable import SpeakFlow

@Suite("Native batch insertion", .serialized)
struct BatchInsertionNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func nativeBulkCommit() async throws {
        let suite = "BatchInsertionNativeTests"
        guard NativeUIProbeSupport.isChild(for: suite) else {
            try NativeUIProbeSupport.runChild(suite: suite)
            return
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic batch insertion test"
        window.orderBack(nil)
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 150))
        editor.string = "prefix old suffix"
        editor.setSelectedRange(NSRange(location: 7, length: 3))
        window.contentView = editor
        let inserter = TextInserter._testMakeIsolatedInstance()
        inserter.targetElement = AXUIElementCreateApplication(42_424)
        inserter.targetPid = 42_424
        inserter.testIsTargetFrontmost = true
        inserter._testSetTargetProcessLiveness { _ in true }
        inserter._testSetFlagsProvider { [] }
        inserter.editorSnapshotForTesting = { .init(text: editor.string, selection: editor.selectedRange()) }
        var events = 0
        var failures = 0
        inserter._testSetEventPoster { event in
            events += 1
            if event.type == .keyDown, let native = NSEvent(cgEvent: event) { editor.keyDown(with: native) }
        }
        inserter.onBulkInsertionFailure = { failures += 1 }
        inserter.insertTextInBulk("hello 🌍\nnext")
        await inserter.waitForPendingInsertions()
        #expect(editor.string == "prefix hello 🌍\nnext suffix")
        #expect(editor.selectedRange() == NSRange(location: 20, length: 0))
        #expect(events == 2)
        #expect(failures == 0)
    }
}
