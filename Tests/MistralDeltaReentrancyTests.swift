import Testing
@testable import SpeakFlowCore

private actor FinalYieldGate {
    private var entered = false
    private var release: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func pauseFirst() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation in
            release = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    func waitForArrival() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func resume() { release?.resume(); release = nil }
}

@Suite("Mistral delta consumption before suspension")
struct MistralDeltaReentrancyTests {
    @Test(arguments: ["segment", "done"], [false, true])
    func closeDuringFinalPublicationDeliversExactlyOnce(boundary: String, cancelledClose: Bool) async throws {
        let gate = FinalYieldGate()
        let session = MistralStreamingSession(
            apiKey: "synthetic-key", config: .default,
            beforeFinalYield: { await gate.pauseFirst() }
        )
        let events = session.events
        let collected = Task {
            var finals: [String] = []
            for await event in events {
                if case .finalResult(let result) = event { finals.append(result.transcript) }
            }
            return finals
        }
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"first"}"#)
        let publication = Task {
            await session.parseMessage("{\"type\":\"transcription.\(boundary)\"}")
        }
        await gate.waitForArrival()
        // Close must not wait on the paused parser to publish its owned final.
        let closing = Task {
            if cancelledClose { withUnsafeCurrentTask { $0?.cancel() } }
            try await session.close()
        }
        try await closing.value
        await gate.resume()
        await publication.value
        #expect(await collected.value == ["first"])
    }

    @Test(arguments: ["segment", "done", "close"])
    func concurrentBoundaryPreservesNextDelta(boundary: String) async throws {
        let gate = FinalYieldGate()
        let session = MistralStreamingSession(
            apiKey: "synthetic-key", config: .default,
            beforeFinalYield: { await gate.pauseFirst() }
        )
        let events = session.events
        let collected = Task {
            var finals: [String] = []
            for await event in events {
                if case .finalResult(let result) = event { finals.append(result.transcript) }
            }
            return finals
        }
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"first"}"#)
        let first = Task {
            if boundary == "close" { try await session.close() }
            else { await session.parseMessage("{\"type\":\"transcription.\(boundary)\"}") }
        }
        await gate.waitForArrival()
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"next"}"#)
        if boundary == "close" {
            await session.parseMessage(#"{"type":"transcription.done"}"#)
        }
        await gate.resume()
        try await first.value
        // After segment/done, the next delta must still be pending. Close flushes it.
        if boundary != "close" { try await session.close() }
        let finals = await collected.value
        #expect(finals == ["first", "next"])
    }
}
