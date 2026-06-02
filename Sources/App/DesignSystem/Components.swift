import SwiftUI

// MARK: - SectionCard

/// A grouped settings section with a header label, body card, and optional footer.
struct SectionCard<Content: View>: View {
    let title: String?
    let trailingPill: AnyView?
    let footer: String?
    let content: () -> Content

    init(
        _ title: String? = nil,
        trailingPill: AnyView? = nil,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailingPill = trailingPill
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailingPill != nil {
                HStack(spacing: 8) {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 8)
                    trailingPill
                }
                .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(Theme.line, lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - SettingRow

/// One row inside a SectionCard, with a leading label and a trailing control.
struct SettingRow<Trailing: View>: View {
    let label: String
    let description: String?
    let trailing: () -> Trailing

    init(
        _ label: String,
        description: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.label = label
        self.description = description
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
                if let description {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(Divider().background(Theme.line), alignment: .bottom)
    }
}

// MARK: - SettingSliderRow

/// A row with a label, current value, slider, and low/high captions.
struct SettingSliderRow: View {
    let label: String
    let description: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatted: String
    let lowLabel: String
    let highLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                    if let description {
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Text(formatted)
                    .font(.system(size: 13, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text2)
            }

            Slider(value: $value, in: range, step: step)
                .tint(Theme.accent)

            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(Divider().background(Theme.line), alignment: .bottom)
    }
}

// MARK: - DisclosureCard

/// Bordered collapsible block used for advanced settings.
struct DisclosureCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @State private var isOpen: Bool
    let content: () -> Content

    init(
        _ title: String,
        subtitle: String? = nil,
        openByDefault: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isOpen = State(initialValue: openByDefault)
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let subtitle {
                        Text("·  \(subtitle)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isOpen ? Theme.card : Theme.surface)

            if isOpen {
                VStack(spacing: 14) {
                    content()
                }
                .padding(14)
                .background(Theme.card)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.line, lineWidth: 1)
        )
    }
}

// MARK: - ModePill

/// Small uppercase Streaming or Batch label used in headers and lists.
struct ModePill: View {
    enum Mode {
        case streaming
        case batch

        var label: String { self == .streaming ? "STREAMING" : "BATCH" }
        var fg: Color { self == .streaming ? Theme.blue : Theme.accent }
        var bg: Color { self == .streaming ? Theme.blueSoft : Theme.accentSoft }
    }

    let mode: Mode

    var body: some View {
        Text(mode.label)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(mode.fg)
            .background(mode.bg, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}
