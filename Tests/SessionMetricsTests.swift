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

    /// The dashboard's "recent sessions" fallback must not surface sessions that
    /// pre-date a `Statistics.reset()`. Otherwise the provider breakdown and
    /// 30-day activity continue showing pre-reset usage even though the reset
    /// dialog tells the user all stats go to zero.
    @Test func recentCompletedSessionsExcludesSessionsBeforeCutoff() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-metrics-\(UUID().uuidString).json")
        let store = SessionMetricsStore(storageURL: url)

        let oldId = await store.startSession(providerId: ProviderId.deepgram, mode: .streaming)
        await store.endSession(sessionId: oldId, reason: "TEST")
        try await Task.sleep(for: .milliseconds(50))

        let cutoff = Date()
        try await Task.sleep(for: .milliseconds(50))

        let newId = await store.startSession(providerId: ProviderId.mistralBatch, mode: .batch)
        await store.endSession(sessionId: newId, reason: "TEST")

        let filtered = await store.recentCompletedSessions(after: cutoff, limit: 50)
        let ids = filtered.map(\.sessionId)
        #expect(ids == [newId],
                "After-cutoff query must return only sessions started at or after the cutoff; got \(ids)")

        let unfiltered = await store.recentCompletedSessions(limit: 50)
        #expect(unfiltered.count == 2,
                "Unfiltered query must still return all sessions (verifies the filter does not mutate stored state)")
    }
}
