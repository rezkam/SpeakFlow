import AppKit
import SwiftUI
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
private final class HeldKeyValidator: TranscriptionProvider, APIKeyValidatable {
    let id = "synthetic-held-validator"
    let displayName = "Fixture provider"
    let mode = ProviderMode.batch
    let isConfigured = true
    let authRequirement = ProviderAuthRequirement.none
    let response = AsyncStream<Void>.makeStream()
    var started = false
    var finished = false

    func validateAPIKey(_ key: String) async -> String? {
        started = true
        for await _ in response.stream {}
        finished = true
        return nil
    }
}

@Suite("Provider validation retirement", .serialized)
struct ProviderKeyValidationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func removingAKeyRetiresItsHeldValidation() async throws {
        guard NativeUIProbeSupport.isChild(for: "ProviderKeyValidationTests") else {
            try NativeUIProbeSupport.runChild(suite: "ProviderKeyValidationTests")
            return
        }
        let validator = HeldKeyValidator()
        ProviderRegistry.shared.register(validator)
        defer { validator.response.continuation.finish() }
        var removed = 0
        var saved: [String] = []
        let account = ProviderAccount(id: validator.id, altId: nil, name: "Fixture provider", vendor: "Fixture",
                                      authStyle: .apiKey, blurb: "Synthetic validation probe", models: [])
        let card = ProviderCard(account: account, isExpanded: true, activeProviderId: "", activeModelId: "",
                                onToggle: {}, onActivate: { _ in }, onAuthAction: { action in
            switch action {
            case .removeKey: removed += 1
            case .saveKey(let key): saved.append(key)
            default: break
            }
            return nil
        })
        let host = NSHostingView(rootView: card)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Validation retirement test"
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        func fields(in view: NSView) -> [NSSecureTextField] {
            (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        try await waitUntil { buttons(in: host).count == 2 }
        buttons(in: host)[0].performClick(nil)
        try await waitUntil { !fields(in: host).isEmpty && buttons(in: host).count == 4 }
        let field = try #require(fields(in: host).first)
        field.stringValue = "synthetic-key-123"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        let save = try #require(buttons(in: host).last)
        try await waitUntil { save.isEnabled }
        save.performClick(nil)
        try await waitUntil { validator.started }
        buttons(in: host)[1].performClick(nil)
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet?.contentView)
        let remove = try #require(buttons(in: sheet).first { $0.title == "Remove" })
        remove.performClick(nil)
        try await waitUntil { removed == 1 }
        validator.response.continuation.finish()
        try await waitUntil { validator.finished }
        try await Task.sleep(for: .milliseconds(100))
        #expect(saved.isEmpty, "A validation that outlives removal must never restore the removed key")
    }
}
