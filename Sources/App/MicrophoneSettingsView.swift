import SwiftUI
import SpeakFlowCore

/// Compact input selection shared with the menu bar submenu.
struct MicrophoneSettingsView: View {
    @Environment(\.microphoneSelection) private var selection
    let isRecording: Bool
    let permissionGranted: Bool

    var body: some View {
        SectionCard("Audio input", footer: footer) {
            SettingRow("Microphone", description: "Choose an input for SpeakFlow.") {
                Picker("Microphone", selection: selectionBinding) {
                    MicrophoneOptions(selection: selection)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 230)
                .disabled(selection.snapshot.devices.isEmpty)
                .accessibilityIdentifier("microphonePicker")
                .help("Choose the microphone used by SpeakFlow")
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { selection.preferredUID }, set: { selection.select($0) })
    }

    private var footer: String {
        if !permissionGranted {
            return "Microphone access is required to record. Grant access in Permissions below."
        }
        return selection.statusText(isRecording: isRecording)
    }
}

struct MicrophoneOptions: View {
    var selection: MicrophoneSelection

    var body: some View {
        Text("System Default").tag(String?.none)
        if selection.preferenceUnavailable {
            Text("Unavailable microphone").tag(selection.preferredUID).disabled(true)
        }
        ForEach(selection.snapshot.devices) { device in
            Text(selection.label(for: device)).tag(Optional(device.uid))
        }
    }
}

struct MicrophoneMenu: View {
    @Environment(\.microphoneSelection) private var selection
    let isRecording: Bool

    var body: some View {
        Menu("Microphone") {
            Picker("Microphone", selection: Binding(
                get: { selection.preferredUID }, set: { selection.select($0) }
            )) {
                MicrophoneOptions(selection: selection)
            }
            .pickerStyle(.inline)
            .disabled(selection.snapshot.devices.isEmpty)
            Divider()
            Text(selection.menuStatusText)
            if isRecording { Text("Changes apply next recording") }
        }
        .accessibilityIdentifier("microphoneMenu")
    }
}
