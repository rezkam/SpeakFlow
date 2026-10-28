import Foundation
import Testing
@testable import SpeakFlowCore

private actor HeldTurnClassification {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<Float, Never>?

    func classify() async -> Float {
        await withCheckedContinuation { continuation in
            resultWaiter = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() { resultWaiter?.resume(returning: 0.1) }
}

struct TurnCompletionIdentityTests {
    private func session(clock: MockDateProvider) async -> SessionController {
        var config = AutoEndConfiguration(
            enabled: true, silenceDuration: 3, minSessionDuration: 0,
            requireSpeechFirst: true, thinkingPauseEnabled: false
        )
        config.turnClassifierEnabled = true
        config.turnClassifierMinimumSilence = 0
        config.turnClassifierIncompleteExtensionSeconds = 10
        let session = SessionController(autoEndConfig: config, dateProvider: clock.date)
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 0))
        await session.set(lastTranscript: "Synthetic first sentence.")
        clock.now += 4
        return session
    }

    @Test func changedTranscriptInvalidatesProbabilityAndEvaluationMarker() async {
        let clock = MockDateProvider()
        let session = await session(clock: clock)
        await session.evaluateTurnCompletion { _ in 0.1 }
        #expect(await session.shouldAutoEndSession() == false)
        #expect(await session.shouldEvaluateTurnCompletion() == false)
        await session.set(lastTranscript: "Synthetic final sentence.")
        #expect(await session.shouldAutoEndSession() == true)
        #expect(await session.shouldEvaluateTurnCompletion() == true)
        await session.evaluateTurnCompletion { _ in 0.1 }
        await session.set(lastTranscript: "Synthetic final sentence.")
        #expect(await session.shouldEvaluateTurnCompletion() == false, "Identical text preserves a valid result")
    }

    @Test(arguments: ["transcript", "speech", "potential", "session"])
    func obsoleteInFlightClassificationIsDiscarded(change: String) async {
        let clock = MockDateProvider()
        let session = await session(clock: clock)
        let held = HeldTurnClassification()
        let evaluation = Task {
            await session.evaluateTurnCompletion { _ in await held.classify() }
        }
        await held.waitForStart()
        switch change {
        case "transcript":
            await session.set(lastTranscript: "Synthetic revised sentence.")
        case "speech":
            await session.onSpeechEvent(.started(at: 1))
            await session.onSpeechEvent(.ended(at: 1))
        case "potential":
            await session.onPotentialSpeechActivity()
        default:
            await session.startSession()
            await session.onSpeechEvent(.started(at: 1))
            await session.onSpeechEvent(.ended(at: 1))
        }
        clock.now += 4
        await held.finish()
        await evaluation.value
        #expect(await session.shouldEvaluateTurnCompletion() == true)
        #expect(await session.shouldAutoEndSession() == true, "Obsolete incomplete result must not extend the current window")
    }
}
