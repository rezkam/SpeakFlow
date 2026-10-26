import AppKit
import SwiftUI
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Transcription language control", .serialized)
struct TranscriptionLanguagePickerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func realtimeIsAutomaticWhileBatchRemainsEditable() async throws {
        guard NativeUIProbeSupport.isChild(for: "TranscriptionLanguagePickerTests") else {
            try NativeUIProbeSupport.runChild(suite: "TranscriptionLanguagePickerTests")
            return
        }
        var language = "fr"
        let binding = Binding(get: { language }, set: { language = $0 })
        func control(_ provider: String) -> TranscriptionLanguagePicker {
            TranscriptionLanguagePicker(providerId: provider, deepgramLanguage: .constant("en-US"), mistralLanguage: binding)
        }
        let host = NSHostingView(rootView: control(ProviderId.mistralBatch))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Language control test"
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func pickers(in view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { pickers(in: $0) }
        }
        try await waitUntil { pickers(in: host).count == 1 }
        let batch = try #require(pickers(in: host).first)
        #expect(batch.isEnabled)
        let german = try #require(batch.item(withTitle: "German"))
        let action = try #require(german.action)
        _ = NSApp.sendAction(action, to: german.target, from: german)
        try await waitUntil { language == "de" }

        host.rootView = control(ProviderId.mistral)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(pickers(in: host).isEmpty, "Realtime must not offer an unsupported language picker")
        #expect(language == "de", "Opening automatic detection must preserve the Batch language")
    }
}
