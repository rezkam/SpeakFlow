import AppKit
import SwiftUI
import SpeakFlowCore

/// App entry point with a main settings window and minimal menu bar.
///
/// The app runs as an accessory (LSUIElement) — no Dock icon by default.
/// When the settings window opens, it switches to regular (Dock icon visible)
/// so the window can receive focus. When all windows close, it goes back
/// to accessory mode.
@main
struct SpeakFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("SpeakFlow", id: "main") {
            MainSettingsView()
                .environment(\.appState, AppState.shared)
                .environment(\.recordingController, RecordingController.shared)
                .environment(\.permissionController, PermissionController.shared)
                .environment(\.authController, AuthController.shared)
                .environment(\.statistics, Statistics.shared)
        }
        .defaultSize(width: 750, height: 650)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView()
        } label: {
            // Use the custom app icon from the bundle for the menu bar
            if let icon = Self.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Label("SpeakFlow", systemImage: "waveform")
            }
        }
        .menuBarExtraStyle(.menu)
    }

    /// Load MenuBarIcon.png as a template image for automatic light/dark mode tinting.
    /// The image is black-on-transparent at @2x (44px height); macOS uses only the alpha channel.
    private static let menuBarIcon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        // Set the size in points (half the pixel size for @2x Retina)
        image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
        image.isTemplate = true
        return image
    }()
}

/// Minimal menu bar menu: open settings, toggle dictation, quit.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appState) private var state
    @Environment(\.recordingController) private var recordingController

    var body: some View {
        // Read refreshVersion so SwiftUI re-evaluates when provider config changes
        let _ = state.refreshVersion

        Button("Open SpeakFlow...") {
            showSettingsWindow()
        }

        Divider()

        Button(dictationLabel) {
            recordingController.toggle()
        }
        .disabled(!state.isRecording && !state.canStartDictation)

        // Show provider switcher when more than one provider is configured
        let configured = ProviderRegistry.shared.configuredProviders
        if configured.count > 1 {
            Divider()

            ForEach(configured, id: \.id) { provider in
                Button {
                    switchProvider(provider.id)
                } label: {
                    Text(state.activeProviderId == provider.id
                        ? "✓ \(provider.providerDisplayName)"
                        : "   \(provider.providerDisplayName)")
                }
            }
        }

        Divider()

        Button("Quit SpeakFlow") {
            NSApp.terminate(nil)
        }
    }

    private var dictationLabel: String {
        (state.isRecording || state.isProcessingFinal)
            ? "Stop Dictation (\(state.currentHotkey.displayName))"
            : "Start Dictation (\(state.currentHotkey.displayName))"
    }

    private func switchProvider(_ id: String) {
        ProviderSettings.shared.activeProviderId = id
        state.refresh()
    }

    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
