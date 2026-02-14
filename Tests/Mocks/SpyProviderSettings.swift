import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
final class SpyProviderSettings: ProviderSettingsProviding {
    var activeProviderId: String = "chatgpt"
    var storedKeys: [String: String] = [:]
    var removedKeys: [String] = []

    func apiKey(for providerId: String) -> String? {
        storedKeys[providerId]
    }

    func setApiKey(_ apiKey: String?, for providerId: String) {
        if let apiKey {
            storedKeys[providerId] = apiKey
        } else {
            storedKeys.removeValue(forKey: providerId)
        }
    }

    func hasApiKey(for providerId: String) -> Bool {
        storedKeys[providerId] != nil
    }

    func removeApiKey(for providerId: String) {
        storedKeys.removeValue(forKey: providerId)
        removedKeys.append(providerId)
    }
}
