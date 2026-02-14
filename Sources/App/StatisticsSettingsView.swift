import SwiftUI
import SpeakFlowCore

/// Transcription usage statistics displayed as visual metric cards.
struct StatisticsSettingsView: View {
    @State private var showResetConfirm = false
    @Environment(\.statistics) private var stats

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                metricsGrid
                resetSection
            }
            .padding(24)
        }
        .navigationTitle("Statistics")
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            StatCard(
                title: "Total Duration",
                value: stats.formattedDuration,
                icon: "clock",
                tint: .blue
            )

            StatCard(
                title: "Words Transcribed",
                value: stats.formattedWords,
                icon: "text.word.spacing",
                tint: .purple
            )

            StatCard(
                title: "Characters",
                value: stats.formattedCharacters,
                icon: "character.cursor.ibeam",
                tint: .orange
            )

            StatCard(
                title: "API Calls",
                value: stats.formattedApiCalls,
                icon: "arrow.up.arrow.down.circle",
                tint: .green
            )
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        HStack {
            Text("Statistics are stored locally on this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Reset Statistics...", role: .destructive) {
                showResetConfirm = true
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
        .alert("Reset Statistics?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                stats.reset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently reset all transcription statistics to zero.")
        }
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
