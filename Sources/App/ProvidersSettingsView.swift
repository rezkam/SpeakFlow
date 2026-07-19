import SwiftUI
import SpeakFlowCore

/// Providers tab with collapsible account cards and active-model radios.
struct ProvidersSettingsView: View {
    @Environment(\.appState) private var state
    @Environment(\.authController) private var auth

    @State private var expanded: Set<String> = []

    var body: some View {
        let _ = state.refreshVersion
        VStack(alignment: .leading, spacing: 14) {
            if configuredAccounts.isEmpty {
                emptyBanner
            } else {
                actionBar
            }

            ForEach(providerAccounts, id: \.id) { account in
                ProviderCard(
                    account: account,
                    isExpanded: expanded.contains(account.id),
                    activeProviderId: state.activeProviderId,
                    activeModelId: ModelCatalog.activeModelId(for: state.activeProviderId, in: state),
                    onToggle: { toggle(account.id) },
                    onActivate: { model in ModelCatalog.activate(model, in: state) },
                    onAuthAction: { action in handle(action, for: account) }
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                Text("API keys and tokens are stored in ~/.speakflow/auth.json via UnifiedAuthStorage. Credentials are used only for provider authentication and transcription requests.")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
        .onAppear(perform: expandActiveAccount)
    }

    private var emptyBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.white)
                .padding(6)
                .background(Theme.accent, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Connect at least one provider to start transcribing")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("SpeakFlow does not ship with a built-in engine. Pick the service that fits your workflow. You can connect more than one and switch anytime.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.accentSoft)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.accentLine, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private var actionBar: some View {
        HStack {
            Text("\(configuredAccounts.count) of \(providerAccounts.count) connected")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text3)
            Spacer()
            Button("Expand all") { expanded = Set(providerAccounts.map(\.id)) }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Collapse all") { expanded.removeAll() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 2)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func expandActiveAccount() {
        if let active = providerAccounts.first(where: { account in
            account.id == state.activeProviderId || account.altId == state.activeProviderId
        }) {
            expanded.insert(active.id)
        }
    }

    private func handle(_ action: ProviderCard.AuthAction, for account: ProviderAccount) {
        switch (account.id, action) {
        case (ProviderId.chatGPT, .login):
            auth.startLoginFlow()
        case (ProviderId.chatGPT, .logout):
            auth.handleLogout()
        case (_, .saveKey(let key)):
            ProviderSettings.shared.setApiKey(key, for: account.id)
            state.refresh()
        case (_, .removeKey):
            auth.handleRemoveApiKey(for: account.id)
        default:
            break
        }
    }

    private func isConfigured(_ account: ProviderAccount) -> Bool {
        ProviderRegistry.shared.isProviderConfigured(account.id)
            || account.altId.map { ProviderRegistry.shared.isProviderConfigured($0) } == true
    }

    private var configuredAccounts: [ProviderAccount] {
        providerAccounts.filter(isConfigured)
    }

    private var providerAccounts: [ProviderAccount] {
        [
            ProviderAccount(
                id: ProviderId.chatGPT,
                altId: nil,
                name: "ChatGPT",
                vendor: "OpenAI",
                authStyle: .oauth,
                blurb: "GPT-4o transcription, signed in with your ChatGPT account.",
                models: ModelCatalog.all.filter { $0.providerAccountId == ProviderId.chatGPT }
            ),
            ProviderAccount(
                id: ProviderId.deepgram,
                altId: nil,
                name: "Deepgram",
                vendor: "Deepgram",
                authStyle: .apiKey,
                blurb: "Nova-3 real-time streaming with sub-500 ms partials.",
                models: ModelCatalog.all.filter { $0.providerAccountId == ProviderId.deepgram }
            ),
            ProviderAccount(
                id: ProviderId.mistral,
                altId: ProviderId.mistralBatch,
                name: "Mistral",
                vendor: "Mistral AI",
                authStyle: .apiKey,
                blurb: "Voxtral Realtime and Voxtral Mini, one API key and two modes.",
                models: ModelCatalog.all.filter { $0.providerAccountId == ProviderId.mistral }
            ),
        ]
    }
}

// MARK: - Account model

struct ProviderAccount: Identifiable {
    enum AuthStyle { case oauth, apiKey }

    let id: String
    let altId: String?
    let name: String
    let vendor: String
    let authStyle: AuthStyle
    let blurb: String
    let models: [ModelDescriptor]
}

// MARK: - Provider card

struct ProviderCard: View {
    enum AuthAction {
        case login
        case logout
        case saveKey(String)
        case removeKey
    }

    let account: ProviderAccount
    let isExpanded: Bool
    let activeProviderId: String
    let activeModelId: String
    let onToggle: () -> Void
    let onActivate: (ModelDescriptor) -> Void
    let onAuthAction: (AuthAction) -> Void

    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var isEditingKey = false
    @State private var isValidatingKey = false
    @State private var showRemoveConfirm = false

    private var isConfigured: Bool {
        ProviderRegistry.shared.isProviderConfigured(account.id)
            || account.altId.map { ProviderRegistry.shared.isProviderConfigured($0) } == true
    }

    private var activeModelInThisAccount: ModelDescriptor? {
        guard activeProviderBelongsToAccount else { return nil }
        return account.models.first { model in
            model.id == activeModelId && model.providerRegistryId == activeProviderId
        }
    }

    private var activeProviderBelongsToAccount: Bool {
        activeProviderId == account.id || activeProviderId == account.altId
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().background(Theme.line)
                bodyContent(isConfigured: isConfigured)
            }
        }
        .background(Theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .alert("Remove \(account.name) API Key?", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) { onAuthAction(.removeKey) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the stored API key. You will need to enter it again to use \(account.name).")
        }
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.accentSoft)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: account.authStyle == .oauth ? "person.crop.circle" : "key")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(account.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        StatusPill(connected: isConfigured)
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if !isConfigured {
            return account.authStyle == .oauth
                ? "Sign in with your \(account.vendor) account"
                : "Add an API key to start transcribing"
        }
        if let active = activeModelInThisAccount {
            return "Active, \(active.name)"
        }
        return "\(account.models.count) model\(account.models.count == 1 ? "" : "s") available"
    }

    @ViewBuilder
    private func bodyContent(isConfigured: Bool) -> some View {
        if isConfigured {
            VStack(spacing: 0) {
                accountStrip
                modelsList
            }
        } else {
            VStack(spacing: 14) {
                if account.authStyle == .oauth {
                    HStack {
                        Text(account.blurb)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text2)
                        Spacer()
                        Button("Log In...") { onAuthAction(.login) }
                            .controlSize(.small)
                    }
                } else {
                    keyEntry
                }
            }
            .padding(14)
        }
    }

    private var accountStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.caption)
                Text(account.authStyle == .oauth ? "Signed in to ChatGPT" : "API key saved in ~/.speakflow/auth.json")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                Spacer()
                if account.authStyle == .oauth {
                    Button("Log Out") { onAuthAction(.logout) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else {
                    Button("Update Key...") {
                        keyDraft = ""
                        keyError = nil
                        isEditingKey.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Button("Remove") { showRemoveConfirm = true }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface)

            if isEditingKey {
                keyEntry.padding(14)
            }
        }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.blurb)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)

            SecureField("Paste your \(account.vendor) API key", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(isValidatingKey)

            if let keyError {
                Text(keyError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    keyDraft = ""
                    keyError = nil
                    isEditingKey = false
                }
                .controlSize(.small)
                .disabled(isValidatingKey)

                Button(isValidatingKey ? "Validating..." : "Validate & Save") {
                    validateAndSaveKey()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 || isValidatingKey)
            }
        }
    }

    private var modelsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(account.models.count == 1 ? "MODEL" : "\(account.models.count) MODELS")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(account.models) { model in
                ModelRow(
                    model: model,
                    isActive: isActive(model),
                    isEnabled: isConfigured,
                    onActivate: { onActivate(model) }
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text("Per-model settings live on the Transcription tab.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func isActive(_ model: ModelDescriptor) -> Bool {
        activeProviderId == model.providerRegistryId && activeModelId == model.id
    }

    private func validateAndSaveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 8 else { return }

        isValidatingKey = true
        keyError = nil

        Task { @MainActor in
            let validator = ProviderRegistry.shared.provider(for: account.id) as? APIKeyValidatable
            let error = await validator?.validateAPIKey(key)
            isValidatingKey = false
            if let error {
                keyError = error
                return
            }

            onAuthAction(.saveKey(key))
            keyDraft = ""
            keyError = nil
            isEditingKey = false
        }
    }
}

private struct StatusPill: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connected ? Theme.green : Theme.textMuted)
                .frame(width: 6, height: 6)
            Text(connected ? "CONNECTED" : "NOT CONNECTED")
                .lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.4)
        .foregroundStyle(connected ? Theme.green : Theme.textMuted)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ModelRow: View {
    let model: ModelDescriptor
    let isActive: Bool
    let isEnabled: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .strokeBorder(isActive ? Theme.accent : Theme.lineStrong, lineWidth: 1.5)
                    .background(Circle().fill(isActive ? Theme.accent : Color.clear))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                            .opacity(isActive ? 1 : 0)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        ModePill(mode: model.mode == .streaming ? .streaming : .batch)
                        Spacer()
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.5)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .foregroundStyle(.white)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.text3)
                        Text(model.latency)
                        Text("·")
                        Text(model.pricing)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isActive ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .overlay(Divider().background(Theme.line), alignment: .bottom)
    }
}
