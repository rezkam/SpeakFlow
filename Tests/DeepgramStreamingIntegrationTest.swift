import Foundation
import os
import Testing
@testable import SpeakFlowCore

/// Integration test: exercises the real Deepgram streaming path.
/// Only runs when the DEEPGRAM_API_KEY environment variable is set or
/// a key exists in ~/.speakflow/auth.json.
@Suite("Deepgram Streaming — Live Integration")
struct DeepgramStreamingIntegrationTests {

    private static var hasApiKey: Bool {
        // Check env var fallback (CI/test) or file storage
        UnifiedAuthStorage.shared.apiKey(for: ProviderId.deepgram) != nil
            || ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] != nil
    }

    @Test(.enabled(if: hasApiKey))
    @MainActor
    func testStreamingSessionConnectsAndReceivesEvents() async throws {
        // 1. Create provider — inject ProviderSettings which checks env var fallback
        let provider = DeepgramProvider()

        // isConfigured checks UnifiedAuthStorage directly (no env fallback),
        // so use ProviderSettings which has the env fallback for CI/tests
        let apiKeyAvailable = ProviderSettings.shared.hasApiKey(for: ProviderId.deepgram)
        #expect(apiKeyAvailable, "Deepgram must have an API key (file or DEEPGRAM_API_KEY env)")

        // 2. Build session config
        let config = provider.buildSessionConfig()
        #expect(config.model == Settings.shared.deepgramModel)

        // 3. Start session — this connects the WebSocket
        let session = try await provider.startSession(config: config)

        // 4. Collect events
        var receivedEvents: [String] = []
        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .interim: receivedEvents.append("interim")
                case .finalResult: receivedEvents.append("final")
                case .utteranceEnd: receivedEvents.append("utteranceEnd")
                case .speechStarted: receivedEvents.append("speechStarted")
                case .metadata: receivedEvents.append("metadata")
                case .error(let e): receivedEvents.append("error:\(e)")
                case .closed: receivedEvents.append("closed")
                }
            }
        }

        // 5. Send 1 second of silence (PCM16, 16kHz, mono)
        var pcmData = Data(capacity: 32000)
        for _ in 0..<16000 {
            withUnsafeBytes(of: Int16(0).littleEndian) { pcmData.append(contentsOf: $0) }
        }
        try await session.sendAudio(pcmData)

        // 6. Finalize and wait for responses
        try await session.finalize()
        try await Task.sleep(for: .seconds(3))

        // 7. Close
        try await session.close()
        eventTask.cancel()

        // 8. Verify we got events (at minimum: Results + Metadata + closed)
        #expect(!receivedEvents.isEmpty,
                "Must receive at least one event from Deepgram, got: \(receivedEvents)")
        #expect(!receivedEvents.contains(where: { $0.hasPrefix("error:") }),
                "Should not receive errors: \(receivedEvents)")
    }
}
