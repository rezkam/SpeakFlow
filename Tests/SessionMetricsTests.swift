import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("SessionMetricsStore")
struct SessionMetricsStoreTests {
    @Test func startMutateAndEndSession() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-metrics-\(UUID().uuidString).json")
        let store = SessionMetricsStore(storageURL: url)

        let sessionId = await store.startSession(providerId: ProviderId.deepgram, mode: .streaming)
        await store.addWords(sessionId: sessionId, count: 5)
        await store.incrementKeepAlive(sessionId: sessionId)
        await store.incrementReconnection(sessionId: sessionId)
        await store.incrementChunkSubmitted(sessionId: sessionId)
        await store.incrementChunkSucceeded(sessionId: sessionId)
        await store.recordSTTLatency(sessionId: sessionId, milliseconds: 220)

        await store.endSession(sessionId: sessionId, reason: "TEST_END")

        let recent = await store.recentCompletedSessions(limit: 1)
        #expect(recent.count == 1)
        #expect(recent[0].sessionId == sessionId)
        #expect(recent[0].wordsProduced == 5)
        #expect(recent[0].keepAlivesSent == 1)
        #expect(recent[0].reconnections == 1)
        #expect(recent[0].chunksSubmitted == 1)
        #expect(recent[0].chunksSucceeded == 1)
        #expect(recent[0].chunksFailed == 0)
        #expect(recent[0].sttLatenciesMs.count == 1)
        #expect(recent[0].endReason == "TEST_END")
    }
}
