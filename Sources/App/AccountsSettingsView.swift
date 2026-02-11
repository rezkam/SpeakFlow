import SwiftUI
import SpeakFlowCore

/// Account management: ChatGPT login/logout, Deepgram API key.
struct AccountsSettingsView: View {
    private let state = AppState.shared
    @State private var deepgramApiKey = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var showRemoveKeyConfirm = false
    @State private var isEditingKey = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: state.isLoggedIn ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(state.isLoggedIn ? .green : .secondary)
                            Text("ChatGPT")
                                .fontWeight(.medium)
                        }
                        Text(state.isLoggedIn ? "Logged in — GPT-4o transcription available" : "Log in to use ChatGPT batch transcription")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if state.isLoggedIn {
                        Button("Log Out", role: .destructive) {
                            AuthController.shared.handleLogout()
                        }
                        .controlSize(.small)
                    } else {
                        Button("Log In...") {
                            AuthController.shared.startLoginFlow()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("ChatGPT")
            } footer: {
                Text("Uses OpenAI's GPT-4o model for batch transcription. Audio is sent in chunks after recording stops.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: state.hasDeepgramKey ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(state.hasDeepgramKey ? .green : .secondary)
                            Text("Deepgram")
                                .fontWeight(.medium)
                        }
                        Text(state.hasDeepgramKey ? "API key configured — real-time streaming available" : "Set an API key to use Deepgram real-time transcription")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if state.hasDeepgramKey {
                        HStack(spacing: 8) {
                            Button("Update Key...") {
                                deepgramApiKey = ""
                                keyValidationError = nil
                                isEditingKey = true
                            }
                            .controlSize(.small)

                            Button("Remove", role: .destructive) {
                                showRemoveKeyConfirm = true
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if !state.hasDeepgramKey || isEditingKey || keyValidationError != nil {
                    deepgramKeyEntry
                }
            } header: {
                Text("Deepgram")
            } footer: {
                Text("Uses Deepgram Nova-3 for real-time streaming transcription. Get a free API key with $200 credit at deepgram.com/pricing")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .alert("Remove Deepgram API Key?", isPresented: $showRemoveKeyConfirm) {
            Button("Remove", role: .destructive) {
                AuthController.shared.handleRemoveDeepgramKey()
                deepgramApiKey = ""
                keyValidationError = nil
                isEditingKey = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove your stored API key. You'll need to enter it again to use Deepgram.")
        }
    }

    // MARK: - Deepgram Key Entry

    @ViewBuilder
    private var deepgramKeyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Paste your Deepgram API key", text: $deepgramApiKey)
                .textFieldStyle(.roundedBorder)

            if let error = keyValidationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isValidatingKey ? "Validating..." : "Save Key") {
                    validateAndSaveKey()
                }
                .disabled(deepgramApiKey.trimmingCharacters(in: .whitespaces).isEmpty || isValidatingKey)
                .controlSize(.small)
            }
        }
    }

    private func validateAndSaveKey() {
        let key = deepgramApiKey.trimmingCharacters(in: .whitespaces)
        isValidatingKey = true
        keyValidationError = nil

        Task {
            let error = await ProviderSettings.shared.validateDeepgramKey(key)
            isValidatingKey = false
            if let error {
                keyValidationError = error
            } else {
                ProviderSettings.shared.setApiKey(key, for: "deepgram")
                deepgramApiKey = ""
                keyValidationError = nil
                isEditingKey = false
                AppState.shared.refresh()
            }
        }
    }
}
