import AppKit
import SwiftUI
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Models screen", .serialized)
struct ModelsScreenTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func consentCancellationFailureAndStableGeometry() async throws {
        guard NativeUIProbeSupport.isChild(for: "ModelsScreenTests") else {
            try NativeUIProbeSupport.runChild(suite: "ModelsScreenTests")
            return
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let store = root.appendingPathComponent(".agents/test-fixtures/models-ui-\(UUID().uuidString)")
        let installer = ExplicitModelInstaller(root: store, fetch: { _, _, _, _ in throw LocalModelError.transferFailed },
                                               availableBytes: { _ in Int64.max })
        let controller = VADInstallController(root: store, installer: installer)
        let host = NSHostingView(rootView: ModelsSettingsView(vad: controller).padding(24)
            .frame(width: 620, height: 430, alignment: .topLeading).background(Theme.background))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Models interaction test"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func snapshot(_ name: String, window: NSWindow) async throws {
            try await Task.sleep(for: .milliseconds(250))
            window.displayIfNeeded()
            let directory = root.appendingPathComponent(".agents/screenshots")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let view = try #require(window.contentView)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }

        try await waitUntil { controller.message != "Checking local files..." }
        #expect(!FileManager.default.fileExists(atPath: store.path), "Browsing must not create or download model assets")
        host.layoutSubtreeIfNeeded()
        let initialSize = host.fittingSize
        #expect(controller.canDownload)
        try await snapshot("models-vad-missing", window: window)
        controller.reviewDownload()
        try await waitUntil { window.sheets.first?.contentView != nil }
        #expect(controller.confirmation == LocalVADAssets.manifest)
        let sheet = try #require(window.sheets.first)
        try await snapshot("models-vad-confirmation", window: sheet)
        #expect(host.fittingSize == initialSize, "Confirmation must not expand the model card")
        controller.confirmation = nil
        try await waitUntil { controller.confirmation == nil && window.sheets.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: store.path), "Cancelling consent must not access the network or store")
        controller.reviewDownload()
        try await waitUntil { window.sheets.first?.contentView != nil }
        controller.confirmDownload()
        try await waitUntil { controller.hasError && !controller.isBusy && window.sheets.isEmpty }
        #expect(!controller.isInstalled)
        #expect(controller.canDownload, "A failed transfer must leave a retry action")
        #expect(host.fittingSize == initialSize, "Errors must use the reserved status area")
        try await snapshot("models-vad-download-error", window: window)
    }
}

/// Persistent, isolated host for external accessibility and visual verification.
@MainActor
private enum ModelsVisualProbe {
    static var window: NSWindow?

    static func show() {
        guard ProcessInfo.processInfo.environment["SPEAKFLOW_ISOLATED_STORAGE"] == "1" else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/models-visual-\(UUID().uuidString)")
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, _, _ in throw LocalModelError.transferFailed },
                                               availableBytes: { _ in Int64.max })
        let controller = VADInstallController(root: root, installer: installer)
        let view = NSHostingView(rootView: ModelsSettingsView(vad: controller).padding(24)
            .frame(width: 620, height: 430, alignment: .topLeading).background(Theme.background))
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 620, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Models UI Probe"
        window.contentView = view
        Self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

@_cdecl("show_models_visual_probe")
@MainActor
func showModelsVisualProbe() { ModelsVisualProbe.show() }
