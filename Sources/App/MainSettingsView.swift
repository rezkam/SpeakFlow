import SwiftUI

/// Main settings window with sidebar navigation and inline status banner.
struct MainSettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    private let state = AppState.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                banner
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 450)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(SettingsTab.allCases, selection: $selectedTab) { tab in
            Label(tab.label, systemImage: tab.icon)
                .tag(tab)
        }
        .listStyle(.sidebar)
        .navigationTitle("SpeakFlow")
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
                Button {
                    state.dismissBanner()
                } label: {
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
        case .info: .blue
        case .success: .green
        case .error: .red
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView()
        case .transcription:
            TranscriptionSettingsView()
        case .accounts:
            AccountsSettingsView()
        case .statistics:
            StatisticsSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}
