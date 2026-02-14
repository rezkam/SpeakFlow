import Foundation

/// Abstracts ProviderSettings for dependency injection.
@MainActor
public protocol ProviderSettingsProviding: AnyObject {
    var activeProviderId: String { get set }
    func apiKey(for providerId: String) -> String?
    func setApiKey(_ apiKey: String?, for providerId: String)
    func hasApiKey(for providerId: String) -> Bool
    func removeApiKey(for providerId: String)
}
