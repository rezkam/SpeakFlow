import AppKit
import SwiftUI
import Testing
@testable import SpeakFlow

@Suite("Provider key editor", .serialized)
struct ProviderKeyEditorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func failedSavePreservesTheVisibleDraftAndAllowsRetry() async throws {
        guard NativeUIProbeSupport.isChild(for: "ProviderKeyEditorTests") else {
            try NativeUIProbeSupport.runChild(suite: "ProviderKeyEditorTests")
            return
        }
        var attempts: [String] = []
        var rejectSave = true
        let account = ProviderAccount(
            id: "synthetic-editor-provider", altId: nil, name: "Fixture Provider", vendor: "Fixture",
            authStyle: .apiKey, blurb: "Synthetic credential editor", models: []
        )
        let card = ProviderCard(
            account: account, isExpanded: true, activeProviderId: "", activeModelId: "",
            onToggle: {}, onActivate: { _ in }, onAuthAction: { action in
                if case .saveKey(let key) = action { attempts.append(key) }
                return rejectSave ? "Synthetic storage failure" : nil
            }
        )
        let host = NSHostingView(rootView: card)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Credential editor test"
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        func fields(in view: NSView) -> [NSSecureTextField] {
            (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        func renderedImage() -> Data? {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        try await waitUntil { !fields(in: host).isEmpty && buttons(in: host).count == 2 }
        let field = try #require(fields(in: host).first)
        // This unconfigured card has Cancel followed by Validate & Save.
        // SwiftUI supplies the labels, so the underlying NSButtons have empty titles.
        let save = try #require(buttons(in: host).last)
        #expect(!save.isEnabled)
        let draft = "synthetic-key-123"
        field.stringValue = draft
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await waitUntil { save.isEnabled }
        let beforeSave = try #require(renderedImage())
        save.performClick(nil)
        try await waitUntil {
            guard attempts.count == 1, let afterSave = renderedImage() else { return false }
            return afterSave != beforeSave
        }
        #expect(field.stringValue == draft, "A storage failure must not erase the visible key draft")
        #expect(attempts == [draft])
        try #require(save.isEnabled, "The failed save must leave a retryable draft")

        rejectSave = false
        save.performClick(nil)
        try await waitUntil { attempts.count == 2 && field.stringValue.isEmpty }
        #expect(attempts == [draft, draft])
        #expect(!save.isEnabled)
    }
}
