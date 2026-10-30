import SwiftUI

/// Shared by every batch model. Streaming models never display this control.
struct BatchInsertionSetting: View {
    @Binding var typeText: Bool

    var body: some View {
        SettingRow(
            "Type batch results",
            description: "Off: insert completed text in quick bursts without using the clipboard. Turn on for character-by-character typing."
        ) {
            Toggle("Type batch results", isOn: $typeText)
                .labelsHidden()
                .accessibilityIdentifier("transcription.batchTypeText")
        }
    }
}
