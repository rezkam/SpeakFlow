import AppKit
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("UI harness hotkey routing", .serialized)
struct UITestHarnessTests {
    @Test @MainActor
    func keyboardAndButtonCallbacksReachTheRecordingToggle() throws {
        guard NativeUIProbeSupport.isChild(for: "UITestHarnessTests") else {
            try NativeUIProbeSupport.runChild(suite: "UITestHarnessTests")
            return
        }
        _ = NSApplication.shared
        let hotkeys = SpyHotkeySettings()
        hotkeys.currentHotkey = .controlOptionD
        let (recording, _, _, _) = makeTestRecordingController(hotkeySettings: hotkeys)
        recording.testMode = .mock
        let harness = UITestHarnessController(recording: recording)
        defer { harness.close() }

        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
            ))
        }
        _ = harness.handleLocalHotkey(try event([.command, .shift]))
        #expect(!recording.isRecording, "An inactive combination must not toggle")
        #expect(harness.handleLocalHotkey(try event([.control, .option])) == nil)
        #expect(recording.isRecording, "The active keyboard shortcut starts recording")
        func findButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "ui_test.hotkey_button" {
                return button
            }
            return view.subviews.lazy.compactMap { findButton(in: $0) }.first
        }
        let content = try #require(harness.window?.contentView)
        let button = try #require(findButton(in: content))
        button.performClick(nil)
        #expect(!recording.isRecording, "The hotkey button toggles the active recording")
        #expect(recording.uiTestToggleCount == 2)
    }
}
