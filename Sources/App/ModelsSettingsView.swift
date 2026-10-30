import SwiftUI
import SpeakFlowCore

struct ModelsSettingsView: View {
    @State var vad = VADInstallController()
    @FocusState private var downloadFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Models stay on this Mac. Downloads always require confirmation.")
                .font(.callout)
                .foregroundStyle(Theme.text2)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Voice activity detection").font(.headline)
                    Spacer()
                    Text(vad.isInstalled ? "Downloaded" : "Not downloaded")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                Text("SILERO V6.2.1 · SPEECH DETECTION · ON-DEVICE")
                    .font(.caption).foregroundStyle(Theme.text2)
                Text("Detects speech and silence for recordings that use local voice activity detection. This model does not transcribe words.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Download: 1,063,425 bytes · License: MIT")
                    .font(.caption).foregroundStyle(Theme.text2)
                HStack {
                    Button("Download") { vad.reviewDownload() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!vad.canDownload)
                        .focused($downloadFocused)
                        .accessibilityIdentifier("vad.download")
                    Button("Cancel download") { vad.cancelDownload() }
                        .disabled(!vad.isBusy)
                        .opacity(vad.isBusy ? 1 : 0)
                        .accessibilityHidden(!vad.isBusy)
                    Spacer()
                }
                .frame(height: 32)
                Text(vad.message)
                    .font(.caption)
                    .foregroundStyle(vad.hasError ? Theme.red : Theme.text2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
                    .help(vad.message)
                    .accessibilityIdentifier("vad.status")
            }
            .padding(20)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(Theme.line))
        }
        .task { await vad.refresh() }
        .sheet(isPresented: Binding(get: { vad.confirmation != nil }, set: { if !$0 { vad.confirmation = nil } }),
               onDismiss: { downloadFocused = true }) {
            confirmation
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download voice activity detection?").font(.headline)
            Text("Silero VAD v6.2.1 · MIT license")
            Text("5 files · 1,063,425 bytes")
            Text("Source: FluidInference/silero-vad-coreml\nRevision: b419383c55c110e2c9271fa6ee0ea83d03c70d96")
                .font(.caption).textSelection(.enabled)
            Text("Required for local speech detection. No audio is uploaded. "
                 + "Files are verified before use. Requires at least 1,063,425 bytes of free storage.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(LocalVADAssets.manifest.artifacts, id: \.path) { artifact in
                HStack {
                    Text(artifact.path.split(separator: "/").dropFirst().joined(separator: "/"))
                    Spacer()
                    Text("\(artifact.bytes) bytes")
                }
                .font(.caption2)
            }
            HStack {
                Spacer()
                Button("Cancel") { vad.confirmation = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Confirm download") { vad.confirmDownload() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.text)
        .background(Theme.surface)
    }
}
