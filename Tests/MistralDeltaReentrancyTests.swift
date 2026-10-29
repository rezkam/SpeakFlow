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

    // Segment/done retire only their own snapshot, not input accepted during publication.
    @Test(arguments: ["segment", "done"])
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
            await session.parseMessage("{\"type\":\"transcription.\(boundary)\"}")
        }
        await gate.waitForArrival()
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"next"}"#)
        await gate.resume()
        await first.value
        // After segment/done, the next delta must still be pending. Close flushes it.
        try await session.close()
        let finals = await collected.value
        #expect(finals == ["first", "next"])
    }

    @Test(arguments: [false, true])
    func closeRejectsInputBeforeSuspending(concurrentClose: Bool) async throws {
        let gate = FinalYieldGate()
        let session = MistralStreamingSession(
            apiKey: "synthetic-key", config: .default,
            beforeFinalYield: { await gate.pauseFirst() }
        )
        let collected = Task {
            var transcripts: [String] = []
            for await event in session.events {
                switch event {
                case .interim(let result): transcripts.append("interim:" + result.transcript)
                case .finalResult(let result): transcripts.append("final:" + result.transcript)
                default: break
                }
            }
            return transcripts
        }
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"first"}"#)
        let closing = Task { try await session.close() }
        await gate.waitForArrival()
        // Close is terminal: unlike segment/done it must reject new input. No done
        // message is sent to rescue a delta mistakenly accepted after its snapshot.
        await session.parseMessage(#"{"type":"transcription.text.delta","text":"next"}"#)
        if concurrentClose { try await session.close() }
        await gate.resume()
        try await closing.value
        #expect(await collected.value == ["interim:first", "final:first"])
    }
}
