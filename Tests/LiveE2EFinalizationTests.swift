import Foundation
import Testing
@testable import SpeakFlowCore
@testable import SpeakFlowLiveE2E

private actor FinalChunkAcknowledgementGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            entered = true
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Live E2E finalization acknowledgement", .serialized)
struct LiveE2EFinalizationTests {
    @Test @MainActor
    func builtInVerdictWaitsForTheFinalChunkAcknowledgement() async throws {
        let settings = Settings.shared
        let savedVAD = settings.vadEnabled
        let savedAutoEnd = settings.autoEndEnabled
        settings.vadEnabled = false
        settings.autoEndEnabled = false
        defer {
            settings.vadEnabled = savedVAD
            settings.autoEndEnabled = savedAutoEnd
        }
        let gate = FinalChunkAcknowledgementGate()
        defer { Task { await gate.release() } }
        let scenario = TestScenario(
            name: "synthetic-finalization", segments: [], chunkDuration: .seconds15,
            expectedMinChunks: 1, expectedMaxChunks: 1,
            trailingSeconds: 0, rate: nil, validateTranscript: false
        )
        var verdictReturned = false
        let task = Task { @MainActor in
            let result = await SpeakFlowLiveE2E.runScenario(
                scenario: scenario,
                fixture: AudioFixture(durationSeconds: 0, samples: []),
                beforeStopForTesting: { recorder in
                    let buffer = AudioBuffer(sampleRate: 16_000)
                    await buffer.append(frames: [Float](repeating: 0.2, count: 32_000))
                    recorder._testInjectAudioBuffer(buffer)
                },
                beforeChunkDeliveryForTesting: { await gate.hold() }
            )
            verdictReturned = true
            return result
        }
        try await waitUntilAsync(timeout: .seconds(5)) { await gate.entered }
        await #expect(throws: PollingError.self) {
            try await waitUntil(timeout: .seconds(3)) { verdictReturned }
        }
        await gate.release()
        let result = await task.value
        #expect(result.success, "The acknowledged final audio must satisfy the exact one-chunk assertion")
    }
}
