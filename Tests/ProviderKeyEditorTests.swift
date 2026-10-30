import AppKit
import SwiftUI
import Testing
@testable import SpeakFlow

@Suite("Provider key editor", .serialized)
struct ProviderKeyEditorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func failedSavePreservesTheVisibleDraftAndAllowsRetry() async throws {
        guard NativeUIProbeSupport.isChild(for: "ProviderKeyEditorTests") else {
            try NativeUIProbeSupport.runChild(suite: "ProviderKeyEditorTests", expectedTests: 1)
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
        func renderedImage() -> Data? {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        func clickSave() throws {
            window.setContentSize(NSSize(width: host.bounds.width, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            try NativeUIProbeSupport.clickBottomTrailingAction(in: host)
        }
        try await waitUntil { !fields(in: host).isEmpty }
        let field = try #require(fields(in: host).first)
        try clickSave()
        try await Task.sleep(for: .milliseconds(100))
        #expect(attempts.isEmpty, "An empty draft must not trigger save")
        let draft = "synthetic-key-123"
        field.stringValue = draft
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(100))
        let beforeSave = try #require(renderedImage())
        try clickSave()
        do {
            try await waitUntil {
                guard attempts.count == 1, let afterSave = renderedImage() else { return false }
                return afterSave != beforeSave
            }
        } catch {
            try NativeUIProbeSupport.captureView(host, name: "provider-editor-save-timeout")
            Issue.record("First save attempts: \(attempts.count); draft characters: \(field.stringValue.count)")
            throw error
        }
        #expect(field.stringValue == draft, "A storage failure must not erase the visible key draft")
        #expect(attempts == [draft])
        #expect(!field.stringValue.isEmpty, "The failed save must leave a retryable draft")

        rejectSave = false
        try clickSave()
        do { try await waitUntil { attempts.count == 2 && field.stringValue.isEmpty } } catch {
            try NativeUIProbeSupport.captureView(host, name: "provider-editor-retry-timeout")
            Issue.record("Retry save attempts: \(attempts.count); draft characters: \(field.stringValue.count)")
            throw error
        }
        #expect(attempts == [draft, draft])
        try clickSave()
        try await Task.sleep(for: .milliseconds(100))
        #expect(attempts == [draft, draft], "A cleared draft must not trigger another save")
    }
}
