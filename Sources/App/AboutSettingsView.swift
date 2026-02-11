import SwiftUI
import AppKit
import SpeakFlowCore

/// App info: logo, name, version, links, and license.
struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo
            if let icon = Self.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            }

            VStack(spacing: 6) {
                Text("SpeakFlow")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version \(appVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Voice-to-text transcription for macOS")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 16)

            // Links
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/rezkam/SpeakFlow")!) {
                    Label("GitHub", systemImage: "link")
                }

                Text("·")
                    .foregroundStyle(.quaternary)

                Link(destination: URL(string: "https://github.com/rezkam/SpeakFlow/blob/main/LICENSE")!) {
                    Label("Apache 2.0 License", systemImage: "doc.text")
                }
            }
            .font(.callout)
            .padding(.top, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static let appIcon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "DockIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }()
}
