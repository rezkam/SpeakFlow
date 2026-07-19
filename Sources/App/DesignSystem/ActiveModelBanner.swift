import SwiftUI
import SpeakFlowCore

/// Shared model-status banner used by General and Transcription.
struct ActiveModelBanner: View {
    let activeProvider: (any TranscriptionProvider)?
    let activeModelId: String
    let configuredProviders: [any TranscriptionProvider]
    let allModels: [ModelDescriptor]
    let onActivate: (ModelDescriptor) -> Void
    let onManageProviders: () -> Void

    @State private var isOpen = false

    var body: some View {
        VStack(spacing: 8) {
            if activeProvider == nil || configuredProviders.isEmpty {
                emptyState
            } else {
                connectedState
                if isOpen { popover }
            }
        }
    }

    private var emptyState: some View {
        Button(action: onManageProviders) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.accentSoft)
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.orange)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("NO ACTIVE MODEL")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.orange)
                    Text("Connect a provider to start transcribing")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Connect")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(14)
            .background(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
    }

    private var connectedState: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Self.providerTint(activeProvider).opacity(0.18))
                    ProviderLogo(
                        providerId: activeProvider?.id ?? "",
                        tint: Self.providerTint(activeProvider),
                        size: 32
                    )
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ACTIVE MODEL")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.accent)
                    Text("\(activeProvider?.displayName ?? "-") · \(activeModelLabel)")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 10) {
                        ModePill(mode: activeProvider?.mode == .streaming ? .streaming : .batch)
                        if !activeLatency.isEmpty {
                            Text(activeLatency)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text3)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .monospacedDigit()
                        }
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Switch")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [Theme.card, Theme.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(isOpen ? Theme.accentLine : Theme.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Switch active model")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ForEach(Array(availableAccountIds.enumerated()), id: \.element) { index, accountId in
                if index > 0 {
                    Divider()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }

                HStack(spacing: 6) {
                    ProviderLogo(
                        providerId: accountId,
                        tint: Self.providerTint(forAccountId: accountId),
                        size: 18
                    )

                    Text(providerName(forAccountId: accountId))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)

                ForEach(allModels.filter { $0.providerAccountId == accountId }) { model in
                    Button {
                        onActivate(model)
                        isOpen = false
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            Circle()
                                .strokeBorder(isActive(model) ? Theme.accent : Theme.lineStrong, lineWidth: 1.5)
                                .background(Circle().fill(isActive(model) ? Theme.accent : Color.clear))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 5, height: 5)
                                        .opacity(isActive(model) ? 1 : 0)
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    ModePill(mode: model.mode == .streaming ? .streaming : .batch)
                                    Text(model.latency)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.text3)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .monospacedDigit()
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(isActive(model) ? Theme.accentSoft : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
                .padding(.top, 4)

            Button(action: onManageProviders) {
                HStack(spacing: 8) {
                    Image(systemName: "cloud")
                        .font(.system(size: 12))
                    Text("Manage providers and API keys")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.lineStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }

    private static func providerTint(_ provider: (any TranscriptionProvider)?) -> Color {
        providerTint(forAccountId: provider?.id ?? "")
    }

    private static func providerTint(forAccountId accountId: String) -> Color {
        switch accountId {
        case ProviderId.chatGPT:     Theme.green
        case ProviderId.deepgram:    Theme.blue
        case ProviderId.mistral,
             ProviderId.mistralBatch: Theme.accent
        default:                     Theme.accent
        }
    }

    private var activeModelLabel: String {
        allModels.first(where: isActive)?.name
            ?? allModels.first { $0.id == activeModelId }?.name
            ?? activeModelId
    }

    private var activeLatency: String {
        allModels.first(where: isActive)?.latency
            ?? allModels.first { $0.id == activeModelId }?.latency
            ?? ""
    }

    private var availableAccountIds: [String] {
        var ids: [String] = []
        for model in allModels where !ids.contains(model.providerAccountId) {
            ids.append(model.providerAccountId)
        }
        return ids
    }

    private func providerName(forAccountId accountId: String) -> String {
        configuredProviders.first { $0.id == accountId }?.displayName
            ?? accountDisplayName(for: accountId)
    }

    private func accountDisplayName(for accountId: String) -> String {
        switch accountId {
        case ProviderId.chatGPT: "ChatGPT"
        case ProviderId.deepgram: "Deepgram"
        case ProviderId.mistral: "Mistral"
        default: accountId
        }
    }

    private func isActive(_ model: ModelDescriptor) -> Bool {
        model.id == activeModelId && model.providerRegistryId == activeProvider?.id
    }
}

/// Lightweight descriptor used by the banner and provider cards.
struct ModelDescriptor: Identifiable, Hashable {
    let id: String
    let providerAccountId: String
    let providerRegistryId: String
    let name: String
    let mode: ProviderMode
    let latency: String
    let pricing: String
}

/// Catalog used by the settings UI.
enum ModelCatalog {
    /// Fallback model id used when no explicit selection exists for the active provider
    /// (i.e. the provider is ChatGPT, whose only model has no dedicated Settings key).
    static var defaultModelId: String {
        all.first { $0.providerRegistryId == ProviderId.chatGPT }?.id ?? ProviderId.chatGPT
    }

    static let all: [ModelDescriptor] = [
        .init(
            id: "gpt-4o-transcribe",
            providerAccountId: ProviderId.chatGPT,
            providerRegistryId: ProviderId.chatGPT,
            name: "GPT-4o Transcribe",
            mode: .batch,
            latency: "~2 s per chunk",
            pricing: "Included with ChatGPT Plus or Pro"
        ),
        .init(
            id: "nova-3",
            providerAccountId: ProviderId.deepgram,
            providerRegistryId: ProviderId.deepgram,
            name: "Nova-3",
            mode: .streaming,
            latency: "<300 ms partial",
            pricing: "$0.0058 / min"
        ),
        .init(
            id: "voxtral-mini-transcribe-realtime-2602",
            providerAccountId: ProviderId.mistral,
            providerRegistryId: ProviderId.mistral,
            name: "Voxtral Realtime",
            mode: .streaming,
            latency: "<500 ms partial",
            pricing: "$0.006 / min"
        ),
        .init(
            id: "voxtral-mini-latest",
            providerAccountId: ProviderId.mistral,
            providerRegistryId: ProviderId.mistralBatch,
            name: "Voxtral Mini",
            mode: .batch,
            latency: "~3 s per minute",
            pricing: "$0.003 / min"
        ),
    ]
}

// MARK: - Shared activate/select logic (used by Providers, Transcription, and General settings tabs)

extension ModelCatalog {
    /// Activates `model` as the app's active provider/model, persisting the choice to
    /// `ProviderSettings.shared` / `Settings.shared` and refreshing `state` so observers pick it up.
    @MainActor
    static func activate(_ model: ModelDescriptor, in state: AppState) {
        ProviderSettings.shared.activeProviderId = model.providerRegistryId
        switch model.providerRegistryId {
        case ProviderId.deepgram:
            Settings.shared.deepgramModel = model.id
        case ProviderId.mistral:
            Settings.shared.mistralModel = model.id
        case ProviderId.mistralBatch:
            Settings.shared.mistralBatchModel = model.id
        default:
            break
        }
        state.refresh()
    }

    /// Returns the active model id for `providerId`, read from `state` (which mirrors
    /// `Settings.shared` after `refresh()`). Falls back to `defaultModelId` for providers
    /// (namely ChatGPT) that have no dedicated model-selection key.
    @MainActor
    static func activeModelId(for providerId: String, in state: AppState) -> String {
        switch providerId {
        case ProviderId.deepgram:
            state.deepgramModel
        case ProviderId.mistral:
            state.mistralModel
        case ProviderId.mistralBatch:
            state.mistralBatchModel
        default:
            defaultModelId
        }
    }

    /// Filters the catalog down to models belonging to a currently configured provider.
    static func availableModels(for configured: [any TranscriptionProvider]) -> [ModelDescriptor] {
        all.filter { model in
            configured.contains { provider in
                provider.id == model.providerAccountId || provider.id == model.providerRegistryId
            }
        }
    }
}
