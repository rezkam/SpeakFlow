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
                    .foregroundStyle(Theme.text)

                Text("Version \(appVersion) · macOS 26+")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)

                Text("Voice-first dictation for the Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .padding(.top, 4)
            }
            .padding(.top, 16)

            // Links
            HStack(spacing: 18) {
                Link("Acknowledgements", destination: Self.githubURL)
                Link("License", destination: Self.licenseURL)
                Link("Release Notes", destination: Self.githubURL)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.accent)
            .padding(.top, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }

    // MARK: - Constants

    private static let githubURL: URL = {
        guard let url = URL(string: "https://github.com/rezkam/SpeakFlow") else {
            preconditionFailure("Invalid GitHub URL constant")
        }
        return url
    }()

    private static let licenseURL: URL = {
        guard let url = URL(string: "https://github.com/rezkam/SpeakFlow/blob/main/LICENSE") else {
            preconditionFailure("Invalid license URL constant")
        }
        return url
    }()

    // MARK: - Helpers

    private var appVersion: String {
        if let display = Bundle.main.object(forInfoDictionaryKey: "SpeakFlowDisplayVersion") as? String,
           !display.isEmpty {
            return display
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static let appIcon: NSImage? = {
        AppResources.pngImage(named: "DockIcon")
    }()
}
