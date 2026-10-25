#if DEBUG
import Foundation
import LiveE2EKit
import SpeakFlowCore

private actor SilenceNetworkTripwire: BatchTranscriptionProvider, HTTPDataProvider {
    nonisolated let id = "synthetic-batch"
    nonisolated let displayName = "Synthetic Batch"
    nonisolated let mode: ProviderMode = .batch
    nonisolated let isConfigured = true
    nonisolated let authRequirement: ProviderAuthRequirement = .apiKey(providerId: "synthetic-batch")
    private(set) var requests = 0

    func transcribe(audio: Data) async throws -> String {
        requests += 1
        throw CancellationError()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        throw CancellationError()
    }
}

@MainActor
enum AuthenticatedSilenceProbe {
    static func run() async -> Int32 {
        guard await StorageIsolationProbe.run() == 0 else { return 1 }
        let tripwire = SilenceNetworkTripwire()
        OpenAICodexAuth.httpProvider = tripwire
        Transcription.shared.setActiveBatchProvider(tripwire)
        do {
            let payload: [String: Any] = [
                "accessToken": "synthetic-access", "refreshToken": "synthetic-refresh",
                "accountId": "fixture-account", "lastRefresh": Date().timeIntervalSinceReferenceDate
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let credentials = try JSONDecoder().decode(OAuthCredentials.self, from: data)
            try UnifiedAuthStorage.shared.saveChatGPTCredentials(credentials)
            guard OpenAICodexAuth.isLoggedIn else {
                print("FAIL: synthetic authenticated state was not established")
                return 1
            }
            // Exercise the real runner and recorder without downloading a model.
            // Nonempty audio proves the no-upload policy even if silence gating fails.
            Settings.shared.vadEnabled = false
            Settings.shared.autoEndEnabled = false
            let scenario = TestScenario(
                name: "synthetic-policy", segments: [TextSegment(text: "fixture words", silenceAfterSeconds: 0)],
                chunkDuration: .seconds15, expectedMinChunks: 1, expectedMaxChunks: 1,
                trailingSeconds: 0, rate: nil, validateTranscript: true
            )
            // Stay above the one-second final-chunk floor even when paced mock
            // playback runs slightly behind wall time under suite load.
            let fixture = AudioFixture(durationSeconds: 2, samples: [Float](repeating: 0.2, count: 32_000))
            let result = await SpeakFlowLiveE2E.runScenario(scenario: scenario, fixture: fixture)
            guard await tripwire.requests == 0 else {
                print("FAIL: authenticated silence mode attempted a request")
                return 1
            }
            guard result.success else {
                print("FAIL: authenticated silence audio assertions failed")
                return 1
            }
            var configured = LiveE2EScenarioConfig(audio: .file(path: "unused-fixture"))
            configured.expectPhrase = "fixture words"
            configured.recordSeconds = 2.2
            configured.timeoutSeconds = 5
            let observation = await SpeakFlowLiveE2E.observeConfigured(configured, fixture: fixture)
            guard await tripwire.requests == 0 else {
                print("FAIL: authenticated silence mode attempted a request")
                return 1
            }
            guard observation.chunks == 1, observation.transcript == nil else {
                print("FAIL: configured silence audio assertions failed")
                return 1
            }
            print("PASS: authenticated silence mode emitted audio without auth or transcription requests")
            return 0
        } catch {
            print("FAIL: synthetic authentication setup failed")
            return 1
        }
    }
}
#endif
