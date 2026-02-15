import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import SpeakFlowCore

/// General settings: permissions, hotkey, launch at login.
struct GeneralSettingsView: View {
    @Environment(\.appState) private var state
    @Environment(\.permissionController) private var permissionController
    @Environment(\.recordingController) private var recordingController

    private var allPermissionsGranted: Bool {
        state.accessibilityGranted && state.microphoneGranted
    }

    var body: some View {
        Form {
            Section {
                PermissionCard(
                    title: "Accessibility",
                    icon: "keyboard",
                    granted: state.accessibilityGranted,
                    explanation: "SpeakFlow needs accessibility permission to type transcribed text directly into any app — your text editor, browser, chat, or notes.",
                    action: { permissionController.checkAccessibility() }
                )

                PermissionCard(
                    title: "Microphone",
                    icon: "mic",
                    granted: state.microphoneGranted,
                    explanation: "SpeakFlow needs microphone access to hear your voice for transcription. Audio is processed in real-time and never stored on disk.",
                    action: { permissionController.checkMicrophoneAction() }
                )
            } header: {
                Label("Permissions", systemImage: allPermissionsGranted ? "checkmark.shield.fill" : "shield.lefthalf.filled")
            } footer: {
                if allPermissionsGranted {
                    Text("All permissions granted — SpeakFlow is ready to use.")
                }
            }

            Section("Activation") {
                Picker("Hotkey", selection: hotkeyBinding) {
                    ForEach(HotkeyType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                Toggle("Hotkey Restarts Recording", isOn: state.binding(for: \.hotkeyRestartsRecording))

                SettingSlider(
                    title: "Focus Wait Timeout",
                    displayValue: formatTimeout(state.focusWaitTimeout),
                    value: state.binding(for: \.focusWaitTimeout),
                    range: 10...300, step: 10,
                    lowLabel: "10s — discard quickly",
                    highLabel: "5m — wait patiently"
                )
            } header: {
                Text("Behavior")
            } footer: {
                Text("""
                When Hotkey Restarts Recording is enabled, pressing the hotkey while \
                transcription is still processing cancels it and starts a new recording. \
                Focus Wait Timeout controls how long SpeakFlow waits for you to return \
                to the original app before discarding pending text.
                """)
            }

            Section("System") {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    // MARK: - Bindings

    private var hotkeyBinding: Binding<HotkeyType> {
        Binding(
            get: { state.currentHotkey },
            set: { newValue in
                HotkeySettings.shared.currentHotkey = newValue
                recordingController.setupHotkey()
                state.refresh()
            }
        )
    }

    private func formatTimeout(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 && secs > 0 { return "\(mins)m \(secs)s" }
        if mins > 0 { return "\(mins)m" }
        return "\(secs)s"
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    AppState.shared.showBanner("Could not update login item — check System Settings", style: .error)
                }
                state.refresh()
            }
        )
    }
}

// MARK: - Permission Card

private struct PermissionCard: View {
    let title: String
    let icon: String
    let granted: Bool
    let explanation: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : icon)
                    .font(.title3)
                    .foregroundStyle(granted ? .green : .orange)

                Text(title)
                    .fontWeight(.medium)

                Spacer()

                if !granted {
                    Button("Grant Access") {
                        action()
                    }
                    .controlSize(.small)
                }
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
