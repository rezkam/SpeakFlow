import SwiftUI

/// Shared by every batch model. Streaming models never display this control.
struct BatchInsertionSetting: View {
    @Binding var typeText: Bool

    var body: some View {
        SettingRow(
            "Type batch results",
            description: "Off: insert each result all at once without using the clipboard. Turn on for editors that need simulated typing."
        ) {
            Toggle("Type batch results", isOn: $typeText)
                .labelsHidden()
                .accessibilityIdentifier("transcription.batchTypeText")
        }
    }
}
