import AppKit
import SwiftUI
import Testing
import os
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Models screen", .serialized)
struct ModelsScreenTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func consentCancellationFailureAndStableGeometry() async throws {
        guard NativeUIProbeSupport.isChild(for: "ModelsScreenTests") else {
            try NativeUIProbeSupport.runChild(suite: "ModelsScreenTests", expectedTests: 2)
            return
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let store = root.appendingPathComponent(".agents/test-fixtures/models-ui-\(UUID().uuidString)")
        let installer = ExplicitModelInstaller(root: store, fetch: { _, _, _, _ in throw LocalModelError.transferFailed },
                                               availableBytes: { _ in Int64.max })
        let controller = VADInstallController(root: store, installer: installer)
        let models = try ModelsScreenFixtures.make(root: store, vad: controller)
        let host = NSHostingView(rootView: ScrollView { ModelsSettingsView(vad: controller, models: models).padding(24) }
            .frame(width: 620, height: 620, alignment: .topLeading).background(Theme.background))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
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
        try await snapshot("models-screen-vad-missing", window: window)
        controller.reviewDownload()
        try await waitUntil { window.sheets.first?.contentView != nil }
        #expect(controller.confirmation == LocalVADAssets.manifest)
        let sheet = try #require(window.sheets.first)
        try await snapshot("models-screen-vad-confirmation", window: sheet)
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
        try await snapshot("models-screen-vad-download-error", window: window)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_UI_PROBES"] == "1")) @MainActor
    func asrCardKeepsItsIntrinsicSizeAcrossInstallLoadAndErrorStates() async throws {
        guard NativeUIProbeSupport.isChild(for: "ModelsScreenTests") else {
            try NativeUIProbeSupport.runChild(suite: "ModelsScreenTests", expectedTests: 2)
            return
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/card-layout-\(UUID().uuidString)")
        let ready = OSAllocatedUnfairLock(initialState: false)
        let vad = VADInstallController(root: root, verify: { .success($0) })
        let controller = try ModelsScreenFixtures.make(root: root, vad: vad, available: { ready.withLock { $0 } })
        await controller.refresh()
        let model = try #require(controller.models.first)
        let host = NSHostingView(rootView: LocalSpeechModelCard(model: model, controller: controller).frame(width: 580))
        host.layoutSubtreeIfNeeded()
        let initial = host.fittingSize
        #expect(initial.height > 200)
        controller.reviewDownload(model.id)
        controller.confirmOperation()
        try await waitUntil { controller.entry(model.id).hasError && !controller.isBusy }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == initial)
        ready.withLock { $0 = true }
        await controller.refresh()
        controller.load(model.id)
        try await waitUntil { controller.runtimeState.loaded.contains(model.id) && !controller.isBusy }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == initial)
        controller.unload(model.id)
        try await waitUntil { !controller.runtimeState.loaded.contains(model.id) && !controller.isBusy }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == initial)
    }

}

/// Persistent, isolated host for external accessibility and visual verification.
@MainActor
private enum ModelsVisualProbe {
    static var window: NSWindow?

    static func show() {
        guard ProcessInfo.processInfo.environment["SPEAKFLOW_ISOLATED_STORAGE"] == "1" else { return }
        if CommandLine.arguments.contains("--editor") { showEditor(); return }
        let removalFixture = CommandLine.arguments.contains("--delete-fixture")
        let relativeRoot = removalFixture ? ".agents/test-fixtures/model-delete-verification-20261030"
            : ".agents/test-fixtures/models-visual-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativeRoot)
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, _, _ in throw LocalModelError.transferFailed },
                                               availableBytes: { _ in Int64.max })
        let installed = CommandLine.arguments.contains("--installed")
        let vadState = ModelPreviewVADState()
        let controller = VADInstallController(root: root, installer: installer,
            verify: { installed ? .success($0) : .failure(LocalModelError.missingVAD) },
            runtime: VADRuntimeOperations(load: { await vadState.load() }, unload: { await vadState.unload() },
                snapshot: { await vadState.snapshot() }), remove: { _ in })
        guard let models = try? ModelsScreenFixtures.make(root: root, vad: controller, available: { installed },
                                                        allowFixtureRemoval: removalFixture) else { return }
        if installed {
            for manifest in models.models.map(\.manifest) + [LocalVADAssets.manifest] {
                try? FileManager.default.createDirectory(at: root.appendingPathComponent(manifest.installationName),
                                                         withIntermediateDirectories: true)
            }
        }
        let view = NSHostingView(rootView: ScrollView { ModelsSettingsView(vad: controller, models: models).padding(24) }
            .frame(width: 660, height: 760, alignment: .topLeading).background(Theme.background)
            .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--large-text") ? .accessibility3 : .large))
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 660, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Models UI Probe"
        window.contentView = view
        Self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private static func showEditor() {
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 680, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Local dictation test editor"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 260))
        scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .systemFont(ofSize: 20)
        editor.textContainerInset = NSSize(width: 20, height: 20)
        editor.string = "Fixture prefix. "
        editor.setAccessibilityIdentifier("local-dictation-test-editor")
        scroll.documentView = editor
        window.contentView = scroll
        Self.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    }
}

@_cdecl("show_models_visual_probe")
@MainActor
func showModelsVisualProbe() { ModelsVisualProbe.show() }


private actor ModelPreviewVADState {
    var loaded = false
    func load() { loaded = true }
    func unload() { loaded = false }
    func snapshot() -> VADModelCacheSnapshot { VADModelCacheSnapshot(isLoaded: loaded, isLoading: false) }
}
