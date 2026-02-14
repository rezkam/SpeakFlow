import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
final class SpyProviderRegistry: ProviderRegistryProviding {
    var registeredProviders: [String: any TranscriptionProvider] = [:]
    private var orderedIds: [String] = []

    var allProviders: [any TranscriptionProvider] {
        orderedIds.compactMap { registeredProviders[$0] }
    }

    var configuredProviders: [any TranscriptionProvider] {
        allProviders.filter(\.isConfigured)
    }

    func register(_ provider: any TranscriptionProvider) {
        if registeredProviders[provider.id] == nil {
            orderedIds.append(provider.id)
        }
        registeredProviders[provider.id] = provider
    }

    func provider(for id: String) -> (any TranscriptionProvider)? {
        registeredProviders[id]
    }

    func streamingProvider(for id: String) -> (any StreamingTranscriptionProvider)? {
        registeredProviders[id] as? (any StreamingTranscriptionProvider)
    }

    func batchProvider(for id: String) -> (any BatchTranscriptionProvider)? {
        registeredProviders[id] as? (any BatchTranscriptionProvider)
    }

    func isProviderConfigured(_ id: String) -> Bool {
        registeredProviders[id]?.isConfigured ?? false
    }
}
