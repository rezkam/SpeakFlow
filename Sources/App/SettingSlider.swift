import SwiftUI

/// A labeled slider with title, formatted value display, and range hint labels.
struct SettingSlider: View {
    let title: String
    let displayValue: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let lowLabel: String
    let highLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(displayValue)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
