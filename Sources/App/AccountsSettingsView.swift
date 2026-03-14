import SwiftUI
import SpeakFlowCore

/// Account management for all transcription providers.
///
/// Each service gets a section showing connection status and key management.
/// Mistral uses a single API key that unlocks two transcription modes
/// (Voxtral Realtime streaming and Voxtral Mini batch), shown clearly
/// as sub-capabilities within one section.
struct AccountsSettingsView: View {
    @Environment(\.appState) private var state
    @Environment(\.authController) private var authController

    // Deepgram
    @State private var deepgramApiKey = ""
    @State private var isValidatingDeepgramKey = false
    @State private var deepgramKeyError: String?
    @State private var showRemoveDeepgramConfirm = false
    @State private var isEditingDeepgramKey = false

    // Mistral
    @State private var mistralApiKey = ""
    @State private var isValidatingMistralKey = false
    @State private var mistralKeyError: String?
    @State private var showRemoveMistralConfirm = false
    @State private var isEditingMistralKey = false

    private var isChatGPTConfigured: Bool {
        ProviderRegistry.shared.isProviderConfigured(ProviderId.chatGPT)
    }

    private var isDeepgramConfigured: Bool {
        ProviderRegistry.shared.isProviderConfigured(ProviderId.deepgram)
    }

    private var isMistralConfigured: Bool {
        ProviderRegistry.shared.isProviderConfigured(ProviderId.mistral)
    }

    var body: some View {
        let _ = state.refreshVersion

        Form {
            // ──────────────────────────────────────────────
            // MARK: - ChatGPT
            // ──────────────────────────────────────────────
            Section {
                providerRow(
                    name: "ChatGPT",
                    isConfigured: isChatGPTConfigured,
                    subtitle: isChatGPTConfigured
                        ? "Logged in — GPT-4o transcription available"
                        : "Log in to use ChatGPT batch transcription"
                ) {
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

                if isChatGPTConfigured {
                    capabilityTag(label: "Batch", icon: "square.stack", color: .blue)
                }
            } header: {
                Text("ChatGPT")
            } footer: {
                Text("Uses OpenAI's GPT-4o model for batch transcription. Audio is sent in chunks after recording stops.")
            }

            // ──────────────────────────────────────────────
            // MARK: - Deepgram
            // ──────────────────────────────────────────────
            Section {
                providerRow(
                    name: "Deepgram",
                    isConfigured: isDeepgramConfigured,
                    subtitle: isDeepgramConfigured
                        ? "API key configured — Nova-3 real-time streaming"
                        : "Set an API key to use Deepgram real-time transcription"
                ) {
                    if isDeepgramConfigured {
                        HStack(spacing: 8) {
                            Button("Update Key...") {
                                deepgramApiKey = ""
                                deepgramKeyError = nil
                                isEditingDeepgramKey = true
                            }
                            .controlSize(.small)

                            Button("Remove", role: .destructive) {
                                showRemoveDeepgramConfirm = true
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if !isDeepgramConfigured || isEditingDeepgramKey || deepgramKeyError != nil {
                    apiKeyEntry(
                        placeholder: "Paste your Deepgram API key",
                        key: $deepgramApiKey,
                        error: $deepgramKeyError,
                        isValidating: $isValidatingDeepgramKey,
                        onSave: validateAndSaveDeepgramKey
                    )
                }

                if isDeepgramConfigured {
                    capabilityTag(label: "Streaming", icon: "waveform", color: .green)
                }
            } header: {
                Text("Deepgram")
            } footer: {
                Text("Uses Deepgram Nova-3 for real-time streaming transcription. Get a free API key with $200 credit at [deepgram.com/pricing](https://deepgram.com/pricing)")
            }

            // ──────────────────────────────────────────────
            // MARK: - Mistral
            // ──────────────────────────────────────────────
            Section {
                providerRow(
                    name: "Mistral",
                    isConfigured: isMistralConfigured,
                    subtitle: isMistralConfigured
                        ? "API key configured — Voxtral transcription available"
                        : "Set an API key to use Mistral Voxtral transcription"
                ) {
                    if isMistralConfigured {
                        HStack(spacing: 8) {
                            Button("Update Key...") {
                                mistralApiKey = ""
                                mistralKeyError = nil
                                isEditingMistralKey = true
                            }
                            .controlSize(.small)

                            Button("Remove", role: .destructive) {
                                showRemoveMistralConfirm = true
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if !isMistralConfigured || isEditingMistralKey || mistralKeyError != nil {
                    apiKeyEntry(
                        placeholder: "Paste your Mistral API key",
                        key: $mistralApiKey,
                        error: $mistralKeyError,
                        isValidating: $isValidatingMistralKey,
                        onSave: validateAndSaveMistralKey
                    )
                }

                // Show both modes unlocked by this single key
                if isMistralConfigured {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("One key, two modes:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            capabilityBadge(
                                label: "Voxtral Realtime",
                                detail: "Streaming",
                                icon: "waveform",
                                color: .green
                            )

                            capabilityBadge(
                                label: "Voxtral Mini",
                                detail: "Batch",
                                icon: "square.stack",
                                color: .blue
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Mistral")
            } footer: {
                Text("One API key enables both modes. Voxtral Realtime streams transcription live with sub-500ms latency. Voxtral Mini transcribes in batch with speaker diarization support. Get a key at [console.mistral.ai](https://console.mistral.ai)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .alert("Remove Deepgram API Key?", isPresented: $showRemoveDeepgramConfirm) {
            Button("Remove", role: .destructive) {
                authController.handleRemoveApiKey(for: ProviderId.deepgram)
                deepgramApiKey = ""
                deepgramKeyError = nil
                isEditingDeepgramKey = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove your stored API key. You'll need to enter it again to use Deepgram.")
        }
        .alert("Remove Mistral API Key?", isPresented: $showRemoveMistralConfirm) {
            Button("Remove", role: .destructive) {
                authController.handleRemoveApiKey(for: ProviderId.mistral)
                mistralApiKey = ""
                mistralKeyError = nil
                isEditingMistralKey = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove your stored API key. You'll need to enter it again to use Mistral.")
        }
    }

    // MARK: - Reusable Components

    /// Standard provider row: status icon, name, subtitle, and trailing action buttons.
    @ViewBuilder
    private func providerRow<Actions: View>(
        name: String,
        isConfigured: Bool,
        subtitle: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: isConfigured ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(isConfigured ? .green : .secondary)
                    Text(name)
                        .fontWeight(.medium)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            actions()
        }
    }

    /// Inline mode tag shown when a provider is configured.
    @ViewBuilder
    private func capabilityTag(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
    }

    /// A compact badge showing a mode name + detail (used in the Mistral "two modes" row).
    @ViewBuilder
    private func capabilityBadge(label: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Reusable API key entry field with validation.
    @ViewBuilder
    private func apiKeyEntry(
        placeholder: String,
        key: Binding<String>,
        error: Binding<String?>,
        isValidating: Binding<Bool>,
        onSave: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(placeholder, text: key)
                .textFieldStyle(.roundedBorder)

            if let errorMsg = error.wrappedValue {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isValidating.wrappedValue ? "Validating..." : "Save Key") {
                    onSave()
                }
                .disabled(key.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || isValidating.wrappedValue)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Key Validation

    private func validateAndSaveDeepgramKey() {
        validateAndSaveKey(
            apiKey: deepgramApiKey,
            providerId: ProviderId.deepgram,
            setKey: { deepgramApiKey = $0 },
            setError: { deepgramKeyError = $0 },
            setValidating: { isValidatingDeepgramKey = $0 },
            setEditing: { isEditingDeepgramKey = $0 }
        )
    }

    private func validateAndSaveMistralKey() {
        validateAndSaveKey(
            apiKey: mistralApiKey,
            providerId: ProviderId.mistral,
            setKey: { mistralApiKey = $0 },
            setError: { mistralKeyError = $0 },
            setValidating: { isValidatingMistralKey = $0 },
            setEditing: { isEditingMistralKey = $0 }
        )
    }

    private func validateAndSaveKey(
        apiKey: String,
        providerId: String,
        setKey: @escaping (String) -> Void,
        setError: @escaping (String?) -> Void,
        setValidating: @escaping (Bool) -> Void,
        setEditing: @escaping (Bool) -> Void
    ) {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        setValidating(true)
        setError(nil)

        Task {
            let validator = ProviderRegistry.shared.provider(for: providerId) as? APIKeyValidatable
            let error = await validator?.validateAPIKey(key)
            setValidating(false)
            if let error {
                setError(error)
            } else {
                ProviderSettings.shared.setApiKey(key, for: providerId)
                setKey("")
                setError(nil)
                setEditing(false)
                AppState.shared.refresh()
            }
        }
    }
}
