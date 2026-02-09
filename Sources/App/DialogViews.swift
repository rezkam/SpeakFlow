import SwiftUI
import SpeakFlowCore

// MARK: - Statistics Window

struct StatisticsWindowView: View {
    @Environment(\.dismiss) private var envDismiss
    var onDismiss: (() -> Void)?
    @State private var showResetConfirm = false
    @State private var summary = Statistics.shared.summary

    private func close() { if let onDismiss { onDismiss() } else { envDismiss() } }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            Text("Transcription Statistics")
                .font(.headline)

            Text(summary)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button("Reset...", role: .destructive) {
                    showResetConfirm = true
                }

                Spacer()

                Button("OK") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { summary = Statistics.shared.summary }
        .alert("Reset Statistics?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                Statistics.shared.reset()
                summary = Statistics.shared.summary
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently reset all transcription statistics to zero.")
        }
    }
}

// MARK: - Deepgram API Key Window

struct DeepgramApiKeyWindowView: View {
    @Environment(\.dismiss) private var envDismiss
    var onDismiss: (() -> Void)?
    @State private var apiKey = ""
    @State private var isValidating = false
    @State private var errorMessage: String?

    private func close() { if let onDismiss { onDismiss() } else { envDismiss() } }

    private var isUpdate: Bool {
        ProviderSettings.shared.hasApiKey(for: "deepgram")
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)

            Text(isUpdate ? "Update Deepgram API Key" : "Enter Deepgram API Key")
                .font(.headline)

            Text("Get a free API key with $200 credit at deepgram.com/pricing")
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField("Paste your API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)

                Button(isValidating ? "Validating..." : "Save") {
                    validate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func validate() {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        isValidating = true
        errorMessage = nil

        Task {
            let error = await ProviderSettings.shared.validateDeepgramKey(key)
            isValidating = false
            if let error {
                errorMessage = error
            } else {
                ProviderSettings.shared.setApiKey(key, for: "deepgram")
                AppState.shared.refresh()
                close()
            }
        }
    }
}

// MARK: - Login Window

struct LoginWindowView: View {
    @Environment(\.dismiss) private var envDismiss
    var onDismiss: (() -> Void)?
    @State private var manualCode = ""
    @State private var phase: Phase = .confirm

    private func close() { if let onDismiss { onDismiss() } else { envDismiss() } }

    enum Phase { case confirm, waitingForCallback, manualEntry }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            Text("Login to ChatGPT")
                .font(.headline)

            switch phase {
            case .confirm:
                Text("A browser window will open for you to log in.\n\nAfter logging in, you'll be redirected back automatically.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open Browser") {
                        AppDelegate.shared.startLoginFlow()
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }

            case .waitingForCallback:
                ProgressView()
                    .controlSize(.large)
                Text("Waiting for login...")
                    .foregroundStyle(.secondary)

            case .manualEntry:
                Text("If the browser didn't redirect automatically, paste the URL or authorization code here:")
                    .foregroundStyle(.secondary)

                TextField("Paste URL or code", text: $manualCode)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Submit") {
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(manualCode.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - Alert Window

struct AlertWindowView: View {
    @Environment(\.dismiss) private var envDismiss
    var onDismiss: (() -> Void)?

    private func close() { if let onDismiss { onDismiss() } else { envDismiss() } }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 32))
                .foregroundStyle(iconColor)

            Text(AppState.shared.alertTitle)
                .font(.headline)

            Text(AppState.shared.alertMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("OK") { close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
    }

    private var iconName: String {
        switch AppState.shared.alertStyle {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch AppState.shared.alertStyle {
        case .info: .blue
        case .success: .green
        case .error: .red
        }
    }
}
