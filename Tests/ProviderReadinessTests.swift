import Testing
@testable import SpeakFlowCore

@Suite("Provider readiness")
struct ProviderReadinessTests {
    @Test
    func apiKeyLookupUsesEnvironmentFallback() {
        let key = ProviderAPIKeys.apiKey(
            for: ProviderId.deepgram,
            storedKey: nil,
            environment: ["DEEPGRAM_API_KEY": "env-deepgram-key"]
        )

        #expect(key == "env-deepgram-key")
    }

    @Test
    func apiKeyLookupPrefersStoredKeyOverEnvironment() {
        let key = ProviderAPIKeys.apiKey(
            for: ProviderId.deepgram,
            storedKey: "stored-deepgram-key",
            environment: ["DEEPGRAM_API_KEY": "env-deepgram-key"]
        )

        #expect(key == "stored-deepgram-key")
    }

    @MainActor @Test
    func deepgramProviderReadinessUsesSharedApiKeyLookup() {
        let provider = DeepgramProvider(hasAPIKey: { $0 == ProviderId.deepgram })

        #expect(provider.isConfigured)
    }

    @MainActor @Test
    func mistralProviderReadinessUsesSharedApiKeyLookup() {
        let provider = MistralProvider(hasAPIKey: { $0 == ProviderId.mistral })

        #expect(provider.isConfigured)
    }

    @MainActor @Test
    func mistralBatchReadinessUsesRealtimeMistralKey() {
        let provider = MistralBatchProvider(hasAPIKey: { $0 == ProviderId.mistral })

        #expect(provider.isConfigured)
    }
}
