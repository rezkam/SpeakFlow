import SwiftUI
import AVFoundation
import OSLog
import ServiceManagement
import SpeakFlowCore

/// Pure SwiftUI menu bar dropdown — replaces the entire NSMenu.
struct MenuView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Start / Stop Dictation
        let hotkeyName = state.currentHotkey.displayName
        Button(state.isRecording || state.isProcessingFinal
               ? "Stop Dictation (\(hotkeyName))"
               : "Start Dictation (\(hotkeyName))") {
            AppDelegate.shared.toggle()
        }

        Divider()

        // Permissions
        permissionItem("Accessibility", granted: state.accessibilityGranted) {
            AppDelegate.shared.checkAccessibility()
        }
        permissionItem("Microphone", granted: state.microphoneGranted) {
            AppDelegate.shared.checkMicrophoneAction()
        }

        Divider()

        // Accounts
        Menu("Accounts") {
            // ChatGPT
            Button(state.isLoggedIn ? "ChatGPT — Logged In ✓" : "ChatGPT — Login...") {
                AppDelegate.shared.handleLoginAction()
            }
            if state.isLoggedIn {
                Button("Log Out of ChatGPT") {
                    AppDelegate.shared.handleLogout()
                }
            }

            Divider()

            // Deepgram
            Button(state.hasDeepgramKey ? "Deepgram — API Key Set ✓" : "Deepgram — Set API Key...") {
                WindowHelper.open(id: "deepgram-key")
            }
            if state.hasDeepgramKey {
                Button("Remove API Key") {
                    AppDelegate.shared.handleRemoveDeepgramKey()
                }
            }
        }

        // Provider selection
        Menu("Transcription Provider") {
            Button {
                setProvider("gpt")
            } label: {
                HStack {
                    Text("ChatGPT (GPT-4o) — Batch")
                    if state.activeProviderId == "gpt" { Image(systemName: "checkmark") }
                }
            }
            .disabled(!state.isLoggedIn)

            Button {
                setProvider("deepgram")
            } label: {
                HStack {
                    Text("Deepgram Nova-3 English — Real-time")
                    if state.activeProviderId == "deepgram" { Image(systemName: "checkmark") }
                }
            }
            .disabled(!state.hasDeepgramKey)
        }

        Divider()

        // Hotkey selection
        Menu("Activation Hotkey") {
            ForEach(HotkeyType.allCases, id: \.self) { type in
                Button {
                    HotkeySettings.shared.currentHotkey = type
                    AppDelegate.shared.setupHotkey()
                    state.refresh()
                } label: {
                    HStack {
                        Text(type.displayName)
                        if state.currentHotkey == type { Image(systemName: "checkmark") }
                    }
                }
            }
        }

        // Chunk Duration
        Menu("Chunk Duration") {
            ForEach(ChunkDuration.allCases, id: \.self) { duration in
                Button {
                    Settings.shared.chunkDuration = duration
                    state.refresh()
                } label: {
                    HStack {
                        Text(duration.displayName)
                        if state.chunkDuration == duration { Image(systemName: "checkmark") }
                    }
                }
            }
        }

        // Skip silent chunks
        Toggle("Skip Silent Chunks", isOn: Binding(
            get: { state.skipSilentChunks },
            set: { newValue in
                Settings.shared.skipSilentChunks = newValue
                state.refresh()
            }
        ))

        Divider()

        // Statistics
        Button("View Statistics...") {
            WindowHelper.open(id: "statistics")
        }

        Divider()

        // Launch at login
        Toggle("Launch at Login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    Logger(subsystem: "SpeakFlow", category: "App")
                        .error("Failed to toggle launch at login: \(error.localizedDescription)")
                }
                state.refresh()
            }
        ))

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func permissionItem(_ name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack {
                if !granted {
                    Image(systemName: "exclamationmark.triangle")
                }
                Text(name)
                Spacer()
                if granted {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func setProvider(_ id: String) {
        if id == "deepgram" && !state.hasDeepgramKey {
            WindowHelper.open(id: "deepgram-key")
            return
        }
        ProviderSettings.shared.activeProviderId = id
        state.refresh()
    }
}
