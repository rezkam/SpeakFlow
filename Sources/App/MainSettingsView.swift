import SwiftUI

/// Main settings window with a warm custom sidebar and title bar.
struct MainSettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @Environment(\.appState) private var state

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)

            VStack(spacing: 0) {
                titleBar
                Divider().background(Theme.line)
                banner

                ScrollView {
                    detailView
                        .padding(.horizontal, 32)
                        .padding(.top, 24)
                        .padding(.bottom, 80)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Theme.background)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SPEAKFLOW")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 8)

            VStack(spacing: 1) {
                ForEach(SettingsTab.allCases) { tab in
                    Button { selectedTab = tab } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.icon)
                                .frame(width: 18)
                                .foregroundStyle(selectedTab == tab ? .white : Theme.text2)
                            Text(tab.label)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(selectedTab == tab ? .white : Theme.text2)
                        .background(selectedTab == tab ? Theme.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .contentShape(Rectangle())
                        .animation(nil, value: selectedTab)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .overlay(Divider().background(Theme.line), alignment: .trailing)
    }

    // MARK: - Title bar

    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selectedTab.label)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(selectedTab.subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(Theme.surface)
    }

    // MARK: - Banner

    @ViewBuilder
    private var banner: some View {
        if state.bannerVisible {
            HStack(spacing: 8) {
                Image(systemName: bannerIcon)
                Text(state.bannerMessage)
                    .font(.callout)
                Spacer()
                Button { state.dismissBanner() } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bannerColor.opacity(0.12))
            .foregroundStyle(bannerColor)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var bannerIcon: String {
        switch state.bannerStyle {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var bannerColor: Color {
        switch state.bannerStyle {
        case .info: Theme.blue
        case .success: Theme.green
        case .error: Theme.red
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView(switchTab: { selectedTab = $0 })
        case .transcription:
            TranscriptionSettingsView(switchTab: { selectedTab = $0 })
        case .providers:
            ProvidersSettingsView()
        case .statistics:
            StatisticsSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}
