import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import SpeakFlowCore

/// General settings: permissions, hotkey, launch at login.
struct GeneralSettingsView: View {
    private let state = AppState.shared

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
                    action: { PermissionController.shared.checkAccessibility() }
                )

                PermissionCard(
                    title: "Microphone",
                    icon: "mic",
                    granted: state.microphoneGranted,
                    explanation: "SpeakFlow needs microphone access to hear your voice for transcription. Audio is processed in real-time and never stored on disk.",
                    action: { PermissionController.shared.checkMicrophoneAction() }
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
                RecordingController.shared.setupHotkey()
                state.refresh()
            }
        )
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
