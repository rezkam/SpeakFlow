import SwiftUI
import SpeakFlowCore

/// Account management: ChatGPT login/logout, Deepgram API key.
struct AccountsSettingsView: View {
    @Environment(\.appState) private var state
    @Environment(\.authController) private var authController
    @State private var deepgramApiKey = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var showRemoveKeyConfirm = false
    @State private var isEditingKey = false

    private var isChatGPTConfigured: Bool {
        ProviderRegistry.shared.isProviderConfigured(ProviderId.chatGPT)
    }

    private var isDeepgramConfigured: Bool {
        ProviderRegistry.shared.isProviderConfigured(ProviderId.deepgram)
    }

    var body: some View {
        // Read refreshVersion to trigger re-evaluation when provider configuration changes
        // (e.g. after OAuth login or API key save calls AppState.shared.refresh())
        let _ = state.refreshVersion

        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: isChatGPTConfigured ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(isChatGPTConfigured ? .green : .secondary)
                            Text("ChatGPT")
                                .fontWeight(.medium)
                        }
                        Text(isChatGPTConfigured ? "Logged in — GPT-4o transcription available" : "Log in to use ChatGPT batch transcription")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isChatGPTConfigured {
                        Button("Log Out", role: .destructive) {
                            authController.handleLogout()
                        }
                        .controlSize(.small)
                    } else {
                        Button("Log In...") {
                            authController.startLoginFlow()
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
                            Image(systemName: isDeepgramConfigured ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(isDeepgramConfigured ? .green : .secondary)
                            Text("Deepgram")
                                .fontWeight(.medium)
                        }
                        Text(isDeepgramConfigured ? "API key configured — real-time streaming available" : "Set an API key to use Deepgram real-time transcription")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isDeepgramConfigured {
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

                if !isDeepgramConfigured || isEditingKey || keyValidationError != nil {
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
                authController.handleRemoveApiKey(for: ProviderId.deepgram)
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
            let validator = ProviderRegistry.shared.provider(for: ProviderId.deepgram) as? APIKeyValidatable
            let error = await validator?.validateAPIKey(key)
            isValidatingKey = false
            if let error {
                keyValidationError = error
            } else {
                ProviderSettings.shared.setApiKey(key, for: ProviderId.deepgram)
                deepgramApiKey = ""
                keyValidationError = nil
                isEditingKey = false
                AppState.shared.refresh()
            }
        }
    }
}
