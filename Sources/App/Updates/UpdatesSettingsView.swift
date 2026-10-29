import SwiftUI

struct UpdatesSettingsView: View {
    let model: UpdateModel
    var canCheck: Bool
    @Binding var automaticChecks: Bool
    var check: () -> Void
    @Environment(\.appState) private var appState

    var body: some View {
        // Keep restart availability reactive through the existing observable recording state.
        let _ = appState.isRecording || appState.isProcessingFinal
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 54, height: 54)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    Spacer()
                    Text(status)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.background, in: Capsule())
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .accessibilityIdentifier("update-title")
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                progress
                actions
                if model.phase == .ready {
                    Label(model.canRestart
                          ? "SpeakFlow will quit and reopen. You can also cancel this update."
                          : "Finish dictation and wait for your text to be delivered before restarting.",
                          systemImage: model.canRestart ? "arrow.clockwise" : "waveform")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(Theme.line, lineWidth: 1))

            if model.hasUpdate && !model.releaseNotes.isEmpty {
                SectionCard("What’s new in \(model.version)") {
                    Text(model.releaseNotes)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .accessibilityIdentifier("update-release-notes")
                }
            }

            SectionCard("Preferences", footer: "Downloads and restarts always need your approval.") {
                SettingRow("Automatically check for updates", description: "Check for new versions in the background.") {
                    Toggle("Automatically check for updates", isOn: $automaticChecks)
                        .labelsHidden()
                        .disabled(model.phase == .unavailable)
                        .accessibilityIdentifier("update-automatic-checks")
                }
            }
            HStack {
                Text("Installed version \(installedVersion)")
                Spacer()
                if let checked = model.lastChecked {
                    Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
        }
    }

    @ViewBuilder private var progress: some View {
        switch model.phase {
        case .checking, .extracting, .installing:
            ProgressView().controlSize(.small).accessibilityLabel(status)
        case .downloading:
            VStack(alignment: .leading, spacing: 7) {
                if let fraction = model.downloadProgress {
                    ProgressView(value: fraction).tint(Theme.accent)
                        .accessibilityLabel("Download progress")
                    Text("\(Int(fraction * 100))% downloaded")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Downloading update")
                }
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .idle, .current, .failed:
                Button(model.phase == .failed ? "Try Again" : "Check for Updates", action: check)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!canCheck)
                    .accessibilityIdentifier("update-check")
            case .available:
                if let url = model.informationURL {
                    Link("View Release Details", destination: url).buttonStyle(.borderedProminent)
                } else {
                    Button("Download Update", action: { model.download() })
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .accessibilityIdentifier("update-download")
                }
                if model.canCancel { Button("Later", action: { model.cancel() }).buttonStyle(.bordered) }
            case .ready:
                Button("Restart and Install", action: { model.install() })
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!model.canRestart)
                    .accessibilityIdentifier("update-install")
                if model.canCancel { Button("Cancel Update", action: { model.cancel() }).buttonStyle(.bordered) }
            case .checking, .downloading:
                if model.canCancel {
                    Button("Cancel", action: { model.cancel() }).buttonStyle(.bordered)
                        .accessibilityIdentifier("update-cancel")
                }
            default: EmptyView()
            }
        }
        .controlSize(.large)
        if model.phase == .available && model.canSkip {
            Button("Skip This Version", action: { model.skip() })
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
        }
    }

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }
    private var status: String {
        switch model.phase {
        case .idle: "Automatic checks \(automaticChecks ? "on" : "off")"
        case .checking: "Checking"
        case .available: "Update available"
        case .downloading: "Downloading"
        case .extracting: "Verifying update"
        case .ready: model.canRestart ? "Ready to install" : "Dictation in progress"
        case .installing: "Installing"
        case .current: "Up to date"
        case .failed: "Update interrupted"
        case .unavailable: "Updates unavailable"
        }
    }
    private var title: String {
        switch model.phase {
        case .idle: "Keep SpeakFlow up to date"
        case .checking: "Looking for a new version"
        case .available: "A new version is here"
        case .downloading: "Downloading your update"
        case .extracting: "Preparing your update"
        case .ready: model.canRestart ? "Ready when you are" : "Finish dictation first"
        case .installing: "SpeakFlow is restarting"
        case .current: "You’re up to date"
        case .failed: "Couldn’t complete the update"
        case .unavailable: "Updates aren’t configured"
        }
    }
    private var detail: String {
        switch model.phase {
        case .idle: "Get improvements and fixes without leaving the app."
        case .checking: "This usually takes a few seconds."
        case .available: "SpeakFlow \(model.version) is available. Review what’s new before downloading."
        case .downloading: "You can keep using SpeakFlow while the update downloads."
        case .extracting: "Checking the download and preparing it for installation."
        case .ready: "Version \(model.version) is ready. Choose when to restart."
        case .installing: "The verified update will replace the current version and reopen SpeakFlow."
        case .current: "You have the latest compatible version of SpeakFlow."
        case .failed, .unavailable: model.message
        }
    }
    private var symbol: String {
        switch model.phase {
        case .current: "checkmark.circle"
        case .failed: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        case .ready: "arrow.clockwise"
        case .unavailable: "info.circle"
        default: "arrow.down.circle"
        }
    }
}
