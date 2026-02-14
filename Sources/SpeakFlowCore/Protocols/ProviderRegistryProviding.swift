import Foundation

/// Abstracts ProviderRegistry for dependency injection.
@MainActor
public protocol ProviderRegistryProviding: AnyObject {
    var allProviders: [any TranscriptionProvider] { get }
    var configuredProviders: [any TranscriptionProvider] { get }
    func register(_ provider: any TranscriptionProvider)
    func provider(for id: String) -> (any TranscriptionProvider)?
    func streamingProvider(for id: String) -> (any StreamingTranscriptionProvider)?
    func batchProvider(for id: String) -> (any BatchTranscriptionProvider)?
    func isProviderConfigured(_ id: String) -> Bool
}
