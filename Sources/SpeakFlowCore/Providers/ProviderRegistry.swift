import Foundation

/// Central registry for all transcription providers.
///
/// Providers register themselves at app startup. The rest of the app queries the
/// registry for available providers instead of maintaining hardcoded lists.
/// This enables Open/Closed compliance: adding a new provider only requires
/// creating a conforming type and registering it — no existing code changes.
@MainActor
public final class ProviderRegistry {
    public static let shared = ProviderRegistry()

    /// Registered providers keyed by their `id`.
    private var providers: [String: any TranscriptionProvider] = [:]

    /// Ordered list of provider IDs (preserves registration order for UI display).
    private var orderedIds: [String] = []

    private init() {}

    // MARK: - Registration

    /// Register a provider. If a provider with the same `id` already exists, it is replaced.
    public func register(_ provider: any TranscriptionProvider) {
        if providers[provider.id] == nil {
            orderedIds.append(provider.id)
        }
        providers[provider.id] = provider
    }

    // MARK: - Lookup

    /// All registered providers in registration order.
    public var allProviders: [any TranscriptionProvider] {
        orderedIds.compactMap { providers[$0] }
    }

    /// Look up a provider by its unique ID.
    public func provider(for id: String) -> (any TranscriptionProvider)? {
        providers[id]
    }

    /// Look up a streaming provider by ID. Returns nil if the provider isn't streaming.
    public func streamingProvider(for id: String) -> (any StreamingTranscriptionProvider)? {
        providers[id] as? (any StreamingTranscriptionProvider)
    }

    /// Look up a batch provider by ID. Returns nil if the provider isn't batch.
    public func batchProvider(for id: String) -> (any BatchTranscriptionProvider)? {
        providers[id] as? (any BatchTranscriptionProvider)
    }

    /// Providers that the user has configured (credentials set up).
    public var configuredProviders: [any TranscriptionProvider] {
        allProviders.filter(\.isConfigured)
    }

    /// Check if a specific provider is configured and ready.
    public func isProviderConfigured(_ id: String) -> Bool {
        providers[id]?.isConfigured ?? false
    }
}
