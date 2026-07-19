import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

// MARK: - ModelCatalog activate/select — shared helper used by Providers, Transcription, and
// General settings tabs. Regression coverage for the extraction of the previously
// copy-pasted `activate(model:)` / `activeModelId(for:)` / `availableModels(for:)` logic.

/// One case per provider whose model selection is round-tripped through the helper.
enum ProviderCase: String, CaseIterable, Sendable, CustomStringConvertible {
    case chatGPT
    case deepgram
    case mistral
    case mistralBatch

    var description: String { rawValue }

    var providerId: String {
        switch self {
        case .chatGPT: ProviderId.chatGPT
        case .deepgram: ProviderId.deepgram
        case .mistral: ProviderId.mistral
        case .mistralBatch: ProviderId.mistralBatch
        }
    }

    @MainActor
    var model: ModelDescriptor {
        guard let match = ModelCatalog.all.first(where: { $0.providerRegistryId == providerId }) else {
            preconditionFailure("ModelCatalog is missing an entry for provider \(providerId)")
        }
        return match
    }

    /// Reads the persisted model id back from `Settings.shared` for this provider,
    /// or `nil` for providers (ChatGPT) with no dedicated model-selection key.
    @MainActor
    func readSettingsModel() -> String? {
        switch self {
        case .chatGPT: nil
        case .deepgram: Settings.shared.deepgramModel
        case .mistral: Settings.shared.mistralModel
        case .mistralBatch: Settings.shared.mistralBatchModel
        }
    }

    /// Writes a model id into `Settings.shared` for this provider (used to set up
    /// "stored value present" fixtures). No-op for providers with no key.
    @MainActor
    func writeSettingsModel(_ value: String) {
        switch self {
        case .chatGPT: break
        case .deepgram: Settings.shared.deepgramModel = value
        case .mistral: Settings.shared.mistralModel = value
        case .mistralBatch: Settings.shared.mistralBatchModel = value
        }
    }
}

/// Saves and restores the Settings.shared / ProviderSettings.shared keys the helper
/// touches, so the suite is order-independent (Settings/ProviderSettings are
/// process-isolated in test runs but shared across every test in this suite).
@MainActor
private struct SettingsSnapshot {
    let activeProviderId = ProviderSettings.shared.activeProviderId
    let deepgramModel = Settings.shared.deepgramModel
    let mistralModel = Settings.shared.mistralModel
    let mistralBatchModel = Settings.shared.mistralBatchModel

    func restore() {
        ProviderSettings.shared.activeProviderId = activeProviderId
        Settings.shared.deepgramModel = deepgramModel
        Settings.shared.mistralModel = mistralModel
        Settings.shared.mistralBatchModel = mistralBatchModel
    }
}

@Suite("ModelCatalog — activate(_:in:)")
struct ModelCatalogActivateTests {
    @MainActor
    @Test(arguments: ProviderCase.allCases)
    func activateSetsActiveProviderAndWritesTheCorrectSettingsKey(providerCase: ProviderCase) {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let state = AppState()
        let versionBefore = state.refreshVersion
        let model = providerCase.model

        ModelCatalog.activate(model, in: state)

        #expect(ProviderSettings.shared.activeProviderId == model.providerRegistryId,
                "activate must set ProviderSettings.shared.activeProviderId to the model's provider")

        if let stored = providerCase.readSettingsModel() {
            #expect(stored == model.id,
                    "activate must persist the model id under this provider's Settings key")
        }

        #expect(state.refreshVersion == versionBefore + 1,
                "activate must call state.refresh() exactly once")
    }

    @MainActor
    @Test
    func activateDoesNotWriteOtherProvidersSettingsKeys() {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        Settings.shared.mistralModel = "untouched-mistral-value"
        Settings.shared.mistralBatchModel = "untouched-mistral-batch-value"

        let state = AppState()
        ModelCatalog.activate(ProviderCase.deepgram.model, in: state)

        #expect(Settings.shared.mistralModel == "untouched-mistral-value")
        #expect(Settings.shared.mistralBatchModel == "untouched-mistral-batch-value")
    }
}

@Suite("ModelCatalog — activeModelId(for:in:)")
struct ModelCatalogActiveModelIdTests {
    @MainActor
    @Test(arguments: ProviderCase.allCases)
    func returnsStoredValueWhenSet(providerCase: ProviderCase) {
        guard providerCase != .chatGPT else { return } // no dedicated key to set
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let customValue = "custom-\(providerCase.providerId)-model"
        providerCase.writeSettingsModel(customValue)

        let state = AppState()
        state.refresh()

        #expect(ModelCatalog.activeModelId(for: providerCase.providerId, in: state) == customValue,
                "activeModelId must reflect the stored Settings value once state is refreshed")
    }

    @MainActor
    @Test
    func fallsBackToNamedDefaultForProviderWithNoModelKey() {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let state = AppState()
        let chatGPTModel = ProviderCase.chatGPT.model

        #expect(ModelCatalog.activeModelId(for: ProviderId.chatGPT, in: state) == ModelCatalog.defaultModelId)
        #expect(ModelCatalog.defaultModelId == chatGPTModel.id,
                "the named fallback constant must equal ModelCatalog's ChatGPT entry id")
    }

    @MainActor
    @Test
    func fallsBackToNamedDefaultForUnknownProviderId() {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let state = AppState()
        #expect(ModelCatalog.activeModelId(for: "some-future-provider", in: state) == ModelCatalog.defaultModelId)
    }
}

@Suite("ModelCatalog — availableModels(for:)")
struct ModelCatalogAvailableModelsTests {
    @MainActor
    @Test
    func emptyConfiguredProvidersYieldsNoModels() {
        #expect(ModelCatalog.availableModels(for: []).isEmpty)
    }

    @MainActor
    @Test(arguments: ProviderCase.allCases)
    func returnsExactlyTheCatalogEntriesForThisProvider(providerCase: ProviderCase) {
        let providerId = providerCase.providerId
        let provider = StubProvider(id: providerId, isConfigured: true)
        let expected = ModelCatalog.all.filter { model in
            providerId == model.providerAccountId || providerId == model.providerRegistryId
        }

        let result = ModelCatalog.availableModels(for: [provider])

        #expect(Set(result.map(\.id)) == Set(expected.map(\.id)))
        #expect(result.count == expected.count)
    }

    @MainActor
    @Test
    func mistralBatchAccountAloneOnlyMatchesTheBatchModelNotRealtime() {
        // Mistral realtime and Mistral batch share providerAccountId "mistral", but have
        // distinct providerRegistryId values ("mistral" vs "mistral-batch"). A configured
        // provider whose id is the mistral-batch registry id must match only the batch
        // model, not the realtime one, since it doesn't match providerAccountId either.
        let provider = StubProvider(id: ProviderId.mistralBatch, isConfigured: true)

        let result = ModelCatalog.availableModels(for: [provider])

        #expect(result.map(\.id) == ["voxtral-mini-latest"])
    }

    @MainActor
    @Test
    func allProvidersConfiguredYieldsFullCatalog() {
        let providers: [any TranscriptionProvider] = [
            StubProvider(id: ProviderId.chatGPT, isConfigured: true),
            StubProvider(id: ProviderId.deepgram, isConfigured: true),
            StubProvider(id: ProviderId.mistral, isConfigured: true)
        ]

        let result = ModelCatalog.availableModels(for: providers)

        #expect(Set(result.map(\.id)) == Set(ModelCatalog.all.map(\.id)))
    }
}
