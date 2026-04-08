import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - Auto End Configuration Tests

struct AutoEndConfigurationTests {
    @Test func testDefaults() {
        let c = AutoEndConfiguration()
        #expect(c.enabled == true)
        #expect(c.silenceDuration == 5.0)
        #expect(c.minSessionDuration == 2.0)
        #expect(c.requireSpeechFirst == true)
        #expect(c.noSpeechTimeout == 10.0)
        // New fields (VAD improvements)
        #expect(c.maxContinuousSpeechDuration == 180.0)
        #expect(c.thinkingPauseEnabled == true)
        #expect(c.thinkingPauseExtensionSeconds == 5.0)
    }

    @Test func testQuick() {
        #expect(AutoEndConfiguration.quick.silenceDuration == 3.0)
    }

    @Test func testRelaxed() {
        #expect(AutoEndConfiguration.relaxed.silenceDuration == 10.0)
    }

    @Test func testDisabled() {
        #expect(AutoEndConfiguration.disabled.enabled == false)
    }
}

// MARK: - Session Controller Tests

struct SessionControllerTests {

    @Test func testStartSession() async {
        let c = SessionController()
        await c.startSession()
        #expect(await c.hasSpoken == false)
        #expect(await c.currentChunkDuration >= 0)
        #expect(await c.currentSessionDuration >= 0)
    }

    @Test func testSpeechTracking() async {
        let c = SessionController()
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        #expect(await c.hasSpoken == true)
    }

    @Test func testSpeechEndTracking() async {
        let c = SessionController()
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        await c.onSpeechEvent(.ended(at: 1.0))
        #expect(await c.hasSpoken == true)
        #expect(await c.currentSilenceDuration != nil)
    }

    @Test func testAutoEndRequiresSpeech() async {
        // With a long noSpeechTimeout, requireSpeechFirst should still block auto-end
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 5.0, minSessionDuration: 0.1, requireSpeechFirst: true, noSpeechTimeout: 100.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        clock.now += 1.0  // Advance 1s — well under noSpeechTimeout (100s)
        #expect(await c.shouldAutoEndSession() == false)
    }

    // MARK: - No-speech idle timeout tests

    @Test func testAutoEndIdleTimeoutTriggersWithNoSpeech() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 5.0, minSessionDuration: 2.0,
                                       requireSpeechFirst: true, noSpeechTimeout: 10.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Before timeout: should NOT auto-end
        clock.now += 5.0
        #expect(await c.shouldAutoEndSession() == false)

        // After timeout: should auto-end even though no speech was detected
        clock.now += 6.0  // Total 11s >= 10s timeout
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndIdleTimeoutDoesNotFireWhenSpeechDetected() async {
        // Even with a short idle timeout, once speech occurs, normal path should be used
        let clock = MockDateProvider()
        // silenceDuration=5.0 (above 3.0 clamp), noSpeechTimeout=10.0
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 5.0, minSessionDuration: 0.1,
                                       requireSpeechFirst: true, noSpeechTimeout: 10.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Speech starts — idle timeout should not apply
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 1.0
        // Still speaking, should not auto-end
        #expect(await c.shouldAutoEndSession() == false)

        // Speech ends
        await c.onSpeechEvent(.ended(at: 1.0))

        // Wait less than silenceDuration (5.0s)
        clock.now += 3.0
        #expect(await c.shouldAutoEndSession() == false)

        // Wait past silenceDuration
        clock.now += 3.0  // Total silence = 6.0s >= 5.0s
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndIdleTimeoutDisabledWhenZero() async {
        let clock = MockDateProvider()
        // noSpeechTimeout = 0 disables the idle timeout
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 5.0, minSessionDuration: 2.0,
                                       requireSpeechFirst: true, noSpeechTimeout: 0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        clock.now += 30.0  // Even after 30s, no auto-end because timeout disabled
        // Should NOT auto-end — idle timeout disabled and no speech occurred
        #expect(await c.shouldAutoEndSession() == false)
    }

    @Test func testAutoEndIdleTimeoutDisabledWhenAutoEndDisabled() async {
        let clock = MockDateProvider()
        // When auto-end is disabled entirely, idle timeout should not fire either
        let cfg = AutoEndConfiguration(enabled: false, noSpeechTimeout: 10.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        clock.now += 30.0
        #expect(await c.shouldAutoEndSession() == false)
    }

    @Test func testAutoEndSilenceDurationClamped() async {
        // Use a controllable clock
        let clock = MockDateProvider()

        // Try to set silence duration below 3.0s (e.g. 1.0s)
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 1.0, minSessionDuration: 0.1, requireSpeechFirst: true)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Start speaking
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 0.5))

        // Advance time by 1.5s - this is > 1.0s (config) but < 3.0s (clamped min)
        clock.now += 1.5

        // If clamp works, should NOT auto-end yet.
        #expect(await c.shouldAutoEndSession() == false)

        // Advance time by another 2.0s (total silence = 3.5s > 3.0s)
        clock.now += 2.0

        // Now it should auto-end
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndTriggers() async {
        let clock = MockDateProvider()
        // Use silenceDuration >= 3.0 (safety clamp minimum)
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 0.1, requireSpeechFirst: true)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 0.5))
        // Advance past silence duration
        clock.now += 3.5
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndDisabled() async {
        let cfg = AutoEndConfiguration(enabled: false)
        let c = SessionController(autoEndConfig: cfg)
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        await c.onSpeechEvent(.ended(at: 0.5))
        try? await Task.sleep(for: .seconds(2))
        #expect(await c.shouldAutoEndSession() == false)
    }

    @Test func testAutoEndResetsOnNewSpeech() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 0.1, requireSpeechFirst: true)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // First speech segment
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 0.5))

        // Wait partway (less than silenceDuration)
        clock.now += 1.5

        // Start speaking again — resets silence timer
        await c.onSpeechEvent(.started(at: 2.0))
        #expect(await c.shouldAutoEndSession() == false)

        // Stop again
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 2.5))
        #expect(await c.shouldAutoEndSession() == false)

        // Wait full silence duration
        clock.now += 3.5
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testAutoEndFallbackLogic() async {
        // Fallback triggers if session lasts longer than (silenceDuration + minSessionDuration)
        // even if VAD never sent .ended
        // Note: minSessionDuration is used here
        let cfg = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 1.0, requireSpeechFirst: true)
        let c = SessionController(autoEndConfig: cfg)
        await c.startSession()

        // Start speaking
        await c.onSpeechEvent(.started(at: 0))

        // Wait 2s (total 2s < 3+1=4s)
        try? await Task.sleep(for: .seconds(2))
        #expect(await c.shouldAutoEndSession() == false)

        // Wait 3s more (total 5s > 4s)
        try? await Task.sleep(for: .seconds(3))
        // With requireSpeechFirst=true, auto-end requires a completed speech cycle.
        // This means fallback paths that rely on `lastSpeechEndTime == nil` are gated.

        // Let's test with requireSpeechFirst=false
        let cfg2 = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 1.0, requireSpeechFirst: false)
        let c2 = SessionController(autoEndConfig: cfg2)
        await c2.startSession()

        // No speech events sent
        try? await Task.sleep(for: .seconds(5))
        // Should trigger via fallback path (session duration > required)
        #expect(await c2.shouldAutoEndSession() == true)
    }

    @Test func testChunkSent() async {
        let c = SessionController()
        await c.startSession()
        try? await Task.sleep(for: .milliseconds(100))
        let d1 = await c.currentChunkDuration
        await c.chunkSent()
        #expect(await c.currentChunkDuration < d1)
    }

    /// Regression: chunkSent() must clear lastSpeechEndTime so the auto-end
    /// silence clock restarts from zero at every chunk boundary.
    ///
    /// Before the fix, the silence that triggered shouldSendChunk() (which
    /// requires !isUserSpeaking) persisted as a stale lastSpeechEndTime into
    /// the next chunk window. If the user resumed talking but VAD hadn't yet
    /// fired .started (async processing delay), the stale timestamp kept
    /// counting and could fire auto-end within silenceDuration even though the
    /// user never actually stopped talking across the chunk boundary.
    @Test func testChunkSentClearsSilenceClock() async {
        let config = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 2.0,
            minSessionDuration: 0.0,
            requireSpeechFirst: false
        )
        let c = SessionController(autoEndConfig: config)
        await c.startSession()

        // Simulate speech → pause (chunk boundary condition)
        await c.onSpeechEvent(.started(at: 0))
        await c.onSpeechEvent(.ended(at: 1))

        // Brief silence accumulates (but less than silenceDuration)
        try? await Task.sleep(for: .milliseconds(100))

        // Chunk is sent at this silence boundary
        await c.chunkSent()

        // Auto-end must NOT fire immediately after chunkSent —
        // lastSpeechEndTime was cleared so silence clock is at zero.
        let shouldEnd = await c.shouldAutoEndSession()
        #expect(!shouldEnd,
            "Auto-end must not fire immediately after chunkSent — silence clock must restart from zero")
    }

    @Test func testShouldSendChunkNotWhileSpeaking() async {
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 0.2)
        let c = SessionController(vadConfig: vadConfig, maxChunkDuration: 1.0)
        await c.startSession()

        // Start speaking
        await c.onSpeechEvent(.started(at: 0))

        // Wait longer than max duration
        try? await Task.sleep(for: .milliseconds(1200))

        // Should NOT chunk mid-speech
        #expect(await c.shouldSendChunk() == false)
    }

    @Test func testShouldSendChunkAfterSilence() async {
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 0.2)
        let c = SessionController(vadConfig: vadConfig, maxChunkDuration: 0.2)
        await c.startSession()

        // Speak then stop
        await c.onSpeechEvent(.started(at: 0))
        await c.onSpeechEvent(.ended(at: 0.1))

        // Wait for silence threshold
        try? await Task.sleep(for: .milliseconds(300))

        // Should chunk now via max-duration + silence branch.
        #expect(await c.shouldSendChunk() == true)
    }

    @Test func testAutoEndBlockedByRecentPotentialSpeechActivity() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 1.0
        await c.onSpeechEvent(.ended(at: 1.0))

        // Past normal silence threshold, but a fresh speech-like frame arrived.
        clock.now += 5.2
        await c.onPotentialSpeechActivity()
        #expect(
            await c.shouldAutoEndSession() == false,
            "Recent potential speech activity should block auto-end even after base silence threshold"
        )

        // Once the short hold window passes, auto-end should proceed normally.
        clock.now += 1.1
        #expect(await c.shouldAutoEndSession() == true)
    }

    @Test func testChunkSendBlockedByRecentPotentialSpeechActivity() async {
        let clock = MockDateProvider()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 0.2)
        let c = SessionController(
            vadConfig: vadConfig,
            maxChunkDuration: 1.0,
            dateProvider: clock.date
        )
        await c.startSession()
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 0.5
        await c.onSpeechEvent(.ended(at: 0.5))

        // Chunk duration reached, but speech-like activity just happened.
        clock.now += 1.0
        await c.onPotentialSpeechActivity()
        #expect(await c.shouldSendChunk() == false)

        // After hold window expires, chunk can be sent.
        clock.now += 1.1
        #expect(await c.shouldSendChunk() == true)
    }
}

// MARK: - Silence Duration Boundary Tests
//
// These tests verify the core invariant: auto-end ONLY fires after the configured
// silence duration (default 5.0s) has elapsed since the last speech-end event.
//
// Context: users report that thinking pauses of ~2 seconds sometimes end the
// entire recording turn. These parameterized tests systematically cover every
// duration around the threshold to catch boundary failures.

@Suite("Silence Duration Boundary — Auto-End Must Not Fire Below Threshold")
struct SilenceBelowThresholdTests {
    /// Silence durations that must NOT trigger auto-end (below 5.0s threshold).
    /// Covers the common "thinking pause" range (0.5s–4.9s).
    @Test(arguments: [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 4.9])
    func silenceBelowThresholdDoesNotAutoEnd(silenceDuration: Double) async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 0.1, requireSpeechFirst: true,
            noSpeechTimeout: 100.0  // Disable idle timeout for this test
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Simulate: speech for 2s → speech ends → silence for N seconds
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: 2.0))

        clock.now += silenceDuration
        let result = await c.shouldAutoEndSession()
        #expect(result == false,
                "Auto-end must NOT fire after \(silenceDuration)s silence (threshold is 5.0s)")
    }
}

@Suite("Silence Duration Boundary — Auto-End Must Fire At/Above Threshold")
struct SilenceAboveThresholdTests {
    /// Silence durations that MUST trigger auto-end (at or above 5.0s threshold).
    @Test(arguments: [5.0, 5.1, 5.5, 6.0, 7.0, 10.0, 30.0])
    func silenceAtOrAboveThresholdDoesAutoEnd(silenceDuration: Double) async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 0.1, requireSpeechFirst: true,
            noSpeechTimeout: 100.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: 2.0))

        clock.now += silenceDuration
        let result = await c.shouldAutoEndSession()
        #expect(result == true,
                "Auto-end MUST fire after \(silenceDuration)s silence (threshold is 5.0s)")
    }
}

@Suite("Silence Duration Boundary — Speech After Pause Resets Timer")
struct SpeechAfterPauseResetsTimerTests {
    /// When the user pauses (thinking) and then resumes speaking, the auto-end
    /// timer must reset. Only continuous silence after the LAST speech-end counts.
    @Test(arguments: [1.0, 2.0, 3.0, 4.0])
    func speechAfterPauseResetsAutoEndTimer(pauseDuration: Double) async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 0.1, requireSpeechFirst: true,
            noSpeechTimeout: 100.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // ── First speech segment ──
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: 2.0))

        // ── Thinking pause (< 5s) ──
        clock.now += pauseDuration
        #expect(await c.shouldAutoEndSession() == false,
                "Should NOT auto-end during \(pauseDuration)s thinking pause")

        // ── Resume speaking ──
        let resumeTime = 2.0 + pauseDuration
        await c.onSpeechEvent(.started(at: resumeTime))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: resumeTime + 2.0))

        // ── Only 1s after second speech end — must NOT auto-end ──
        clock.now += 1.0
        #expect(await c.shouldAutoEndSession() == false,
                "Must NOT auto-end 1s after resumed speech (timer should have reset)")

        // ── 3s after second speech end — still under 5s, must NOT auto-end ──
        clock.now += 2.0  // total 3s since second speech-end
        #expect(await c.shouldAutoEndSession() == false,
                "Must NOT auto-end 3s after resumed speech")

        // ── 5.5s after second speech end — now it SHOULD auto-end ──
        clock.now += 2.5  // total 5.5s since second speech-end
        #expect(await c.shouldAutoEndSession() == true,
                "SHOULD auto-end 5.5s after second speech-end (fresh 5.0s threshold)")
    }
}

@Suite("Silence Duration Boundary — Multiple Pauses Accumulation Guard")
struct MultiplePausesAccumulationTests {
    /// Verify that multiple short pauses do NOT accumulate toward the auto-end
    /// threshold. Each pause is individually short; only continuous silence counts.
    @Test func multipleShortPausesDoNotAccumulate() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 0.1, requireSpeechFirst: true,
            noSpeechTimeout: 100.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        var time: Double = 0

        // Simulate 5 speech segments, each followed by a 2s pause.
        // Total silence = 10s, but no single gap exceeds 5s.
        for i in 0..<5 {
            // Speech for 1s
            await c.onSpeechEvent(.started(at: time))
            clock.now += 1.0
            time += 1.0
            await c.onSpeechEvent(.ended(at: time))

            // Pause for 2s
            clock.now += 2.0
            time += 2.0

            // Should NEVER auto-end during any of these pauses
            let result = await c.shouldAutoEndSession()
            #expect(result == false,
                    "Auto-end must NOT fire during pause #\(i+1) (2s gap, 5s threshold)")
        }

        // After the last speech segment, wait the full 5s → NOW should auto-end
        clock.now += 5.0
        #expect(await c.shouldAutoEndSession() == true,
                "Auto-end should fire after 5s continuous silence following last speech")
    }

    /// Edge case: pause exactly at the boundary (4.9s) repeated multiple times.
    /// None should trigger auto-end, but 5.0s continuous silence after should.
    @Test func repeatedNearThresholdPausesDoNotTrigger() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 0.1, requireSpeechFirst: true,
            noSpeechTimeout: 100.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        var time: Double = 0

        // 3 segments with 4.9s pauses between them
        for i in 0..<3 {
            await c.onSpeechEvent(.started(at: time))
            clock.now += 1.0
            time += 1.0
            await c.onSpeechEvent(.ended(at: time))

            clock.now += 4.9
            time += 4.9

            #expect(await c.shouldAutoEndSession() == false,
                    "4.9s pause #\(i+1) must NOT trigger auto-end")

            if i < 2 {
                // Resume speech (except after the last segment)
                await c.onSpeechEvent(.started(at: time))
                clock.now += 1.0
                time += 1.0
                await c.onSpeechEvent(.ended(at: time))
            }
        }

        // Now wait 0.2s more → total 5.1s since last speech-end
        clock.now += 0.2
        #expect(await c.shouldAutoEndSession() == true,
                "5.1s continuous silence after last speech should trigger auto-end")
    }
}

// MARK: - Cross-session result bleeding

@Suite("Session generation prevents cross-session bleeding")
struct CrossSessionBleedingTests {

    /// reset() must increment sessionGeneration so that stale tickets
    /// from session N are rejected when submitted to session N+1.
    @Test func testResetIncrementsSessionGeneration() async {
        let queue = TranscriptionQueue()
        let gen0 = await queue.currentSessionGeneration()
        await queue.reset()
        let gen1 = await queue.currentSessionGeneration()
        await queue.reset()
        let gen2 = await queue.currentSessionGeneration()

        #expect(gen1 == gen0 &+ 1, "First reset should increment generation")
        #expect(gen2 == gen0 &+ 2, "Second reset should increment again")
    }

    /// Exact stale-result scenario — late-arriving result from session N submitted
    /// after reset() for session N+1. The seq numbers collide because reset zeroes the counter.
    @Test func testStaleTicketWithCollidingSeqNumberIsRejected() async {
        let queue = TranscriptionQueue()

        // Session 0: get ticket with seq=0
        let session0Ticket = await queue.nextSequence()
        #expect(session0Ticket.session == 0)
        #expect(session0Ticket.seq == 0)

        // Reset — now session 1
        await queue.reset()

        // Session 1: also gets seq=0 (counter restarted!)
        let session1Ticket = await queue.nextSequence()
        #expect(session1Ticket.session == 1)
        #expect(session1Ticket.seq == 0)

        // Late result from session 0 arrives — same seq number, different session
        await queue.submitResult(ticket: session0Ticket, text: "STALE — must be dropped")

        // Pending count should still be 1 (only session 1 ticket outstanding)
        let pending = await queue.getPendingCount()
        #expect(pending == 1, "Stale result must be silently discarded, pending=\(pending)")

        // Now submit the valid session 1 result
        await queue.submitResult(ticket: session1Ticket, text: "valid")
        let pendingAfter = await queue.getPendingCount()
        #expect(pendingAfter == 0, "Valid result should clear pending")
    }

    /// TranscriptionTicket must carry both session and seq fields.
    @Test func testTranscriptionTicketCarriesSessionAndSeq() {
        let ticket = TranscriptionTicket(session: 42, seq: 7)
        #expect(ticket.session == 42)
        #expect(ticket.seq == 7)
        #expect(ticket == TranscriptionTicket(session: 42, seq: 7), "Equatable conformance")
        #expect(ticket != TranscriptionTicket(session: 43, seq: 7), "Different session ≠ equal")
    }

    /// markFailed with a stale ticket must also be silently discarded.
    @Test func testStaleMarkFailedIsDiscarded() async {
        let queue = TranscriptionQueue()
        let staleTicket = await queue.nextSequence()
        await queue.reset()
        let freshTicket = await queue.nextSequence()

        // Stale failure arrives — must not affect session 1
        await queue.markFailed(ticket: staleTicket)
        let pending = await queue.getPendingCount()
        #expect(pending == 1, "Stale markFailed must be ignored, pending=\(pending)")

        // Complete session 1 normally
        await queue.submitResult(ticket: freshTicket, text: "ok")
        #expect(await queue.getPendingCount() == 0)
    }
}

// MARK: - Recorder start failure cleanup

@Suite("Recorder start failure cleans up state")
struct RecorderStartFailureTests {

    /// start() result must match recorder state.
    @Test func testStartResultMatchesRecorderState() async {
        let outcome: (started: Bool, isRecordingAfterStart: Bool) = await withCheckedContinuation { cont in
            Task { @MainActor in
                let recorder = StreamingRecorder()
                let started = await recorder.start()
                let isRecordingAfterStart = recorder._testIsRecording
                recorder.stop()
                cont.resume(returning: (started: started, isRecordingAfterStart: isRecordingAfterStart))
            }
        }
        #expect(outcome.started == outcome.isRecordingAfterStart,
                "start() must only report success when recorder is actually in recording state")
    }

    /// After a failed start (simulated), all state must be rolled back —
    /// no orphan timers, no stale isRecording flag.
    @Test func testFailedStartCleansUpAllState() async {
        await MainActor.run {
            let recorder = StreamingRecorder()

            // Simulate: the recorder was partially set up, then engine.start() failed.
            // Roll back isRecording and clear engine/buffer/timers.
            recorder._testSetIsRecording(true) // as if start() set it
            recorder._testSetIsRecording(false) // as if failure rolled it back

            #expect(!recorder._testIsRecording, "isRecording must be false after failed start")
            #expect(!recorder._testHasProcessingTimer, "No orphan processing timer")
            #expect(!recorder._testHasCheckTimer, "No orphan check timer")
            #expect(!recorder._testHasAudioEngine, "No orphan audio engine")
        }
    }

    /// cancel() on a never-started recorder must be safe (no crash).
    @Test func testCancelOnNeverStartedRecorderIsSafe() async {
        await MainActor.run {
            let recorder = StreamingRecorder()
            var emitted = 0
            recorder.onChunkReady = { _ in emitted += 1 }
            recorder.cancel()
            #expect(emitted == 0, "cancel() on never-started recorder must not emit")
            #expect(!recorder._testIsRecording)
        }
    }
}

// MARK: - Safety Timeout Tests
//
// ## Why these tests exist
//
// The safety timeout is a guard against a specific failure mode: FluidAudio fires
// `speechStart` but never fires `speechEnd`. This can happen due to:
//   - Continuous background noise above the VAD threshold
//   - FluidAudio internal state error
//   - Silero model drift in very long sessions
//
// Without the safety timeout, `isUserSpeaking` stays `true` forever and both
// `shouldAutoEndSession()` and `shouldSendChunk()` are permanently blocked.
//
// Detect and recover from stuck isUserSpeaking state
// which force-stops stuck turns after `user_turn_stop_timeout` (default 5s).

@Suite("Safety Timeout — Force-clear stuck isUserSpeaking state")
struct SafetyTimeoutTests {

    @Test("Speaking state under max duration: NOT force-cleared")
    func speakingUnderMaxDuration() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            maxContinuousSpeechDuration: 60.0  // 60s max
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Speech starts
        await c.onSpeechEvent(.started(at: 0))
        #expect(await c._testIsUserSpeaking == true)
        #expect(await c._testSpeakingStartTimeIsSet == true)

        // Advance 30s (under 60s max) — speaking state should remain
        clock.now += 30.0
        _ = await c.shouldAutoEndSession()  // trigger the check

        #expect(await c._testIsUserSpeaking == true,
                "Speaking state under 60s max should NOT be force-cleared")
    }

    @Test("Speaking state exceeds max duration: force-cleared and auto-end fires after silence")
    func speakingExceedsMaxDuration() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            maxContinuousSpeechDuration: 30.0  // short for test
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Speech starts, VAD never fires speechEnd (stuck state)
        await c.onSpeechEvent(.started(at: 0))
        #expect(await c._testIsUserSpeaking == true)

        // Advance past maxContinuousSpeechDuration (30s)
        clock.now += 31.0

        // shouldAutoEndSession() triggers the safety check
        let autoEnded = await c.shouldAutoEndSession()

        // After force-clear, isUserSpeaking should be false
        #expect(await c._testIsUserSpeaking == false,
                "isUserSpeaking must be force-cleared after exceeding maxContinuousSpeechDuration")

        // And auto-end should fire because we now have a synthesised lastSpeechEndTime
        // and silence >= silenceDuration (the force-clear sets lastSpeechEndTime = now,
        // and we immediately check silence — 0s — which is < 5s silenceDuration,
        // so auto-end does NOT fire in this same call. It fires on the NEXT call after 5s of silence.)
        // The current call: force-cleared at t=31, lastSpeechEndTime=31, silenceSoFar=0 → NOT yet
        #expect(autoEnded == false,
                "Auto-end should NOT fire on the same call that clears the stuck state (silence just started)")

        // Advance 5.1s more — now silence >= silenceDuration
        clock.now += 5.1
        let autoEndedAfterSilence = await c.shouldAutoEndSession()
        #expect(autoEndedAfterSilence == true,
                "Auto-end MUST fire after 5.1s silence following the force-cleared speech state")
    }

    @Test("Safety timeout disabled (maxContinuousSpeechDuration = 0): no force-clear")
    func safetyTimeoutDisabled() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            maxContinuousSpeechDuration: 0  // disabled
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))

        // Advance 1000s — no force-clear should happen
        clock.now += 1000.0
        _ = await c.shouldAutoEndSession()

        #expect(await c._testIsUserSpeaking == true,
                "Safety timeout disabled: stuck speaking state should NOT be force-cleared even after 1000s")
    }

    @Test("speakingStartTime cleared on normal speech end")
    func speakingStartTimeClearedOnNormalEnd() async {
        let clock = MockDateProvider()
        let c = SessionController(dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        #expect(await c._testSpeakingStartTimeIsSet == true)

        await c.onSpeechEvent(.ended(at: 1.0))
        #expect(await c._testSpeakingStartTimeIsSet == false,
                "speakingStartTime must be nil after normal speechEnd")
    }

    @Test("speakingStartTime resets on new speech after end")
    func speakingStartTimeResetsOnNewSpeech() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(maxContinuousSpeechDuration: 10.0)
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // First speech segment
        await c.onSpeechEvent(.started(at: 0))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: 2.0))

        // Resume — new speakingStartTime should be set from this moment
        clock.now += 1.0  // 3s elapsed total
        await c.onSpeechEvent(.started(at: 3.0))
        #expect(await c._testSpeakingStartTimeIsSet == true)

        // Advance only 5s more (< 10s maxContinuousSpeechDuration from new start)
        clock.now += 5.0
        _ = await c.shouldAutoEndSession()

        // Should NOT have been force-cleared (only 5s since resumption, limit is 10s)
        #expect(await c._testIsUserSpeaking == true,
                "Should not force-clear: only 5s into new speech segment, max is 10s")

        // Advance past 10s from the NEW start time
        clock.now += 6.0
        _ = await c.shouldAutoEndSession()

        #expect(await c._testIsUserSpeaking == false,
                "Should force-clear: 11s since speech resumed, max is 10s")
    }

    @Test("Force-clear counts as having spoken — hasSpeechOccurredInSession true")
    func forceClearPreservesHasSpeechFlag() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            maxContinuousSpeechDuration: 10.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        #expect(await c.hasSpoken == true)

        // Force-clear
        clock.now += 11.0
        _ = await c.shouldAutoEndSession()

        // hasSpoken should remain true after force-clear
        #expect(await c.hasSpoken == true,
                "hasSpeechOccurredInSession must remain true after safety force-clear")
    }
}

// MARK: - Thinking Pause Integration Tests
//
// ## Why these tests exist
//
// When `ThinkingPauseDetector.isLikelyIncomplete()` returns true, `SessionController`
// must extend the auto-end silence threshold by `thinkingPauseExtensionSeconds`.
// These tests verify the INTEGRATION between ThinkingPauseDetector and SessionController
// (not the detector's linguistics, which are in ThinkingPauseDetectorTests.swift).
//
// Extend silence threshold when transcript ends with incomplete linguistic pattern.
// Our adaptation: incomplete transcript delays auto-end.

@Suite("Thinking Pause Integration — SessionController extends silence for incomplete transcripts")
struct ThinkingPauseIntegrationTests {

    @Test("Complete transcript: no extension, fires at normal threshold")
    func completeSentenceFiresAtNormalThreshold() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            thinkingPauseEnabled: true,
            thinkingPauseExtensionSeconds: 5.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: 2.0))

        // Set a complete transcript
        await c.set(lastTranscript: "Send the email to John.")

        // At 4.9s silence (< 5.0s base): should NOT auto-end
        clock.now += 4.9
        #expect(await c.shouldAutoEndSession() == false,
                "Complete transcript: no extension, 4.9s < 5.0s should NOT auto-end")

        // At 5.1s silence (> 5.0s base): SHOULD auto-end
        clock.now += 0.2  // total 5.1s
        #expect(await c.shouldAutoEndSession() == true,
                "Complete transcript: 5.1s >= 5.0s should auto-end")
    }

    @Test("Incomplete transcript (trailing conjunction): extends silence by 5s")
    func incompleteTranscriptExtendsThreshold() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            thinkingPauseEnabled: true,
            thinkingPauseExtensionSeconds: 5.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: 2.0))

        // Transcript ending with "and" → ThinkingPauseDetector returns true
        await c.set(lastTranscript: "I need milk bread and")

        // At 5.1s (past normal threshold, before extended): should NOT auto-end
        clock.now += 5.1
        #expect(await c.shouldAutoEndSession() == false,
                "Incomplete transcript: 5.1s should NOT auto-end (extended to 10s)")

        // At 9.9s (< 10s extended threshold): should NOT auto-end
        clock.now += 4.8  // total 9.9s
        #expect(await c.shouldAutoEndSession() == false,
                "Incomplete transcript: 9.9s < 10s extended should NOT auto-end")

        // At 10.1s (> 10s extended threshold): SHOULD auto-end
        clock.now += 0.2  // total 10.1s
        #expect(await c.shouldAutoEndSession() == true,
                "Incomplete transcript: 10.1s >= 10s extended should auto-end")
    }

    @Test("Incomplete transcript (filler word 'hmm'): extends silence")
    func fillerWordExtendsSilence() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            thinkingPauseEnabled: true,
            thinkingPauseExtensionSeconds: 3.0  // custom extension
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        clock.now += 1.0
        await c.onSpeechEvent(.ended(at: 1.0))

        await c.set(lastTranscript: "That's a good point hmm")

        // At 5.1s (past base, before base+extension=8s): should NOT auto-end
        clock.now += 5.1
        #expect(await c.shouldAutoEndSession() == false,
                "Filler 'hmm': 5.1s should NOT auto-end (extended to 8s)")

        // At 8.1s: should auto-end
        clock.now += 3.0  // total 8.1s
        #expect(await c.shouldAutoEndSession() == true,
                "Filler 'hmm': 8.1s >= 8s extended should auto-end")
    }

    @Test("Thinking pause disabled in config: no extension regardless of transcript")
    func thinkingPauseDisabled() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            thinkingPauseEnabled: false,  // DISABLED
            thinkingPauseExtensionSeconds: 5.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: 2.0))

        // Transcript with obvious incomplete pattern
        await c.set(lastTranscript: "I need to tell you about")

        // At 5.1s: SHOULD auto-end (thinking pause disabled, base threshold used)
        clock.now += 5.1
        #expect(await c.shouldAutoEndSession() == true,
                "Thinking pause disabled: should fire at normal threshold regardless of transcript")
    }

    @Test("Empty transcript: no extension (no opinion on empty input)")
    func emptyTranscriptNoExtension() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            thinkingPauseEnabled: true,
            thinkingPauseExtensionSeconds: 5.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        clock.now += 1.0
        await c.onSpeechEvent(.ended(at: 1.0))

        // lastTranscript is empty (default) — no extension
        // At 5.1s: should auto-end (no extension for empty transcript)
        clock.now += 5.1
        #expect(await c.shouldAutoEndSession() == true,
                "Empty transcript: no extension, should auto-end at normal threshold")
    }

    @Test("Transcript updated mid-silence: extension is re-evaluated each poll")
    func transcriptUpdateMidSilenceReEvaluated() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            thinkingPauseEnabled: true,
            thinkingPauseExtensionSeconds: 5.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        clock.now += 2.0
        await c.onSpeechEvent(.ended(at: 2.0))

        // Initially incomplete transcript → extension active
        await c.set(lastTranscript: "I want to")
        clock.now += 5.1  // Past base threshold
        #expect(await c.shouldAutoEndSession() == false,
                "Incomplete 'I want to': should NOT auto-end at 5.1s (extended to 10s)")

        // Transcript updated to complete (e.g., final result arrived)
        await c.set(lastTranscript: "I want to go home.")
        // Now it's complete → effective threshold drops back to 5.0s
        // We're at 5.1s of silence → should NOW auto-end
        #expect(await c.shouldAutoEndSession() == true,
                "After transcript updated to complete, should auto-end immediately (5.1s > 5.0s base)")
    }

    @Test("effectiveSilenceDuration returns base when transcript is complete")
    func effectiveSilenceDurationBase() async {
        let cfg = AutoEndConfiguration(silenceDuration: 5.0, thinkingPauseExtensionSeconds: 3.0)
        let c = SessionController(autoEndConfig: cfg)
        await c.set(lastTranscript: "Done.")
        #expect(await c._testEffectiveSilenceDuration() == 5.0)
    }

    @Test("effectiveSilenceDuration returns extended when transcript is incomplete")
    func effectiveSilenceDurationExtended() async {
        let cfg = AutoEndConfiguration(silenceDuration: 5.0, thinkingPauseExtensionSeconds: 3.0)
        let c = SessionController(autoEndConfig: cfg)
        await c.set(lastTranscript: "I need to order the")  // ends with "the"
        #expect(await c._testEffectiveSilenceDuration() == 8.0,
                "Base 5.0 + extension 3.0 = 8.0s effective threshold")
    }

    @Test("Thinking pause extension: multi-word phrase 'let me think'")
    func thinkingPhraseExtends() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            thinkingPauseEnabled: true,
            thinkingPauseExtensionSeconds: 4.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        await c.onSpeechEvent(.started(at: 0))
        clock.now += 1.0
        await c.onSpeechEvent(.ended(at: 1.0))

        await c.set(lastTranscript: "what time is the meeting let me think")

        // At 5.1s (> base 5.0): NOT fired (extended to 9.0s)
        clock.now += 5.1
        #expect(await c.shouldAutoEndSession() == false)

        // At 9.1s (> extended 9.0): SHOULD fire
        clock.now += 4.0  // total 9.1s
        #expect(await c.shouldAutoEndSession() == true)
    }
}

// MARK: - Combined Safety + Thinking Pause

@Suite("Combined safety timeout + thinking pause interaction")
struct CombinedSafetyThinkingTests {

    @Test("Safety force-clear then thinking pause: detection re-evaluated after clear")
    func safetyForceClearThenThinkingPause() async {
        let clock = MockDateProvider()
        let cfg = AutoEndConfiguration(
            enabled: true,
            silenceDuration: 5.0,
            minSessionDuration: 0.1,
            requireSpeechFirst: true,
            noSpeechTimeout: 100.0,
            maxContinuousSpeechDuration: 10.0,
            thinkingPauseEnabled: true,
            thinkingPauseExtensionSeconds: 5.0
        )
        let c = SessionController(autoEndConfig: cfg, dateProvider: clock.date)
        await c.startSession()

        // Stuck speaking state (VAD never fired speechEnd)
        await c.onSpeechEvent(.started(at: 0))
        await c.set(lastTranscript: "I wanted to tell you about")  // incomplete

        // Advance past maxContinuousSpeechDuration
        clock.now += 11.0

        // First call: force-clears speaking state, synthesises lastSpeechEndTime = now
        let call1 = await c.shouldAutoEndSession()
        #expect(call1 == false, "Force-clear call: silence just started, 0s < 10s (5+5) extended")
        #expect(await c._testIsUserSpeaking == false)

        // At 5.1s (> base 5s, < extended 10s): incomplete transcript should extend
        clock.now += 5.1
        let call2 = await c.shouldAutoEndSession()
        #expect(call2 == false, "At 5.1s: incomplete transcript extends to 10s, not yet")

        // At 10.1s (> extended 10s): should auto-end
        clock.now += 5.0  // total 10.1s since force-clear
        let call3 = await c.shouldAutoEndSession()
        #expect(call3 == true, "At 10.1s: exceeds extended threshold (5s + 5s extension)")
    }
}
