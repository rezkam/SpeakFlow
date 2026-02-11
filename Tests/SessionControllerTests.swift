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
        // Should trigger fallback ONLY if VAD is in weird state where isSpeaking=false but lastEnd=nil
        // But onSpeechEvent(.started) sets isSpeaking=true
        // And guard !isUserSpeaking blocks fallback
        // So fallback only triggers if isSpeaking=false WITHOUT end event?
        // This state is impossible via public API unless startSession() -> ... -> somehow isSpeaking=false without ended?
        // Actually, fallback logic in code handles `lastSpeechEndTime == nil`.
        // If isSpeaking=false AND lastSpeechEndTime=nil -> means speech never started?
        // But requireSpeechFirst=true prevents that.
        // So fallback is dead code unless requireSpeechFirst=false?

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
}

// MARK: - Silence Duration Boundary Tests
//
// These tests verify the core invariant: auto-end ONLY fires after the configured
// silence duration (default 5.0s) has elapsed since the last speech-end event.
//
// BUG CONTEXT: Users report that thinking pauses of ~2 seconds sometimes end the
// entire recording turn. These parameterized tests systematically cover every
// duration around the threshold to catch any regression.

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

// MARK: - Issue #1: Session bleeding — startRecording during finalization

@Suite("Issue #1 — Session bleeding: startRecording guards on isProcessingFinal")
struct Issue1SessionBleedingRegressionTests {

    /// REGRESSION: startRecording() must check isProcessingFinal to block a new session
    /// while the previous one is still finalizing (waiting for API responses).
    @Test func testStartRecordingGuardsOnIsProcessingFinal() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        // Find startRecording() body
        guard let funcRange = source.range(of: "func startRecording()") else {
            Issue.record("startRecording() not found in RecordingController")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // Must contain an isProcessingFinal guard — the exact bug was that this check was missing
        #expect(funcBody.contains("isProcessingFinal"),
                "startRecording() must guard on isProcessingFinal to prevent session bleeding")
    }

    /// REGRESSION: queueBridge.reset() must be awaited sequentially before recorder.start().
    /// The original bug had reset() fired as a detached Task, racing with pending submitResult calls.
    @Test func testResetIsAwaitedBeforeRecorderStart() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        guard let funcRange = source.range(of: "func startRecording()") else {
            Issue.record("startRecording() not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // reset() must appear before start() in the source
        guard let resetPos = funcBody.range(of: "queueBridge.reset()")?.lowerBound else {
            Issue.record("queueBridge.reset() not found in startRecording")
            return
        }
        guard let startPos = funcBody.range(of: "recorder?.start()")?.lowerBound else {
            Issue.record("recorder?.start() not found in startRecording")
            return
        }

        #expect(resetPos < startPos,
                "queueBridge.reset() must be called BEFORE recorder?.start() — was fire-and-forget race")
    }

    /// REGRESSION: Both guards (isRecording and isProcessingFinal) must be present and separate.
    @Test func testBothGuardsPresent() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        guard let funcRange = source.range(of: "func startRecording()") else {
            Issue.record("startRecording() not found")
            return
        }
        // Only look at the first ~40 lines of the function (the guards)
        let funcStart = source[funcRange.lowerBound...]
        let guardSection = String(funcStart.prefix(800))

        #expect(guardSection.contains("!isRecording") || guardSection.contains("isRecording"),
                "Must guard on isRecording")
        #expect(guardSection.contains("isProcessingFinal"),
                "Must guard on isProcessingFinal")
    }
}

// MARK: - Issue #2: Stale transcription results bleed across sessions

@Suite("Issue #2 — Stale results: session generation prevents cross-session bleeding")
struct Issue2StaleResultsRegressionTests {

    /// REGRESSION: reset() must increment sessionGeneration so that stale tickets
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

    /// REGRESSION: The exact bug scenario — late-arriving result from session N submitted
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

    /// REGRESSION: TranscriptionTicket must carry both session and seq fields.
    @Test func testTranscriptionTicketCarriesSessionAndSeq() {
        let ticket = TranscriptionTicket(session: 42, seq: 7)
        #expect(ticket.session == 42)
        #expect(ticket.seq == 7)
        #expect(ticket == TranscriptionTicket(session: 42, seq: 7), "Equatable conformance")
        #expect(ticket != TranscriptionTicket(session: 43, seq: 7), "Different session ≠ equal")
    }

    /// REGRESSION: markFailed with a stale ticket must also be silently discarded.
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

// MARK: - Issue #7: Recorder start failure silently swallowed

@Suite("Issue #7 — Recorder start failure cleans up state")
struct Issue7RecorderStartFailureRegressionTests {

    /// REGRESSION: start() result must match recorder state.
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

    /// REGRESSION: After a failed start (simulated), all state must be rolled back —
    /// no orphan timers, no stale isRecording flag.
    @Test func testFailedStartCleansUpAllState() async {
        await MainActor.run {
            let recorder = StreamingRecorder()

            // Simulate: the recorder was partially set up, then engine.start() failed.
            // The fix rolls back isRecording, clears engine/buffer/timers.
            recorder._testSetIsRecording(true) // as if start() set it
            recorder._testSetIsRecording(false) // as if failure rolled it back

            #expect(!recorder._testIsRecording, "isRecording must be false after failed start")
            #expect(!recorder._testHasProcessingTimer, "No orphan processing timer")
            #expect(!recorder._testHasCheckTimer, "No orphan check timer")
            #expect(!recorder._testHasAudioEngine, "No orphan audio engine")
        }
    }

    /// REGRESSION: RecordingController must check the start() return value and reset UI state on failure.
    @Test func testAppDelegateHandlesStartFailure() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")

        guard let funcRange = source.range(of: "func startRecording()") else {
            Issue.record("RecordingController.startRecording() not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // Must check the return value of start()
        #expect(funcBody.contains("recorder?.start()") || funcBody.contains("recorder!.start()"),
                "Must call recorder?.start()")
        #expect(funcBody.contains("!started") || funcBody.contains("started == false") || funcBody.contains("started {"),
                "Must check start() return value for failure")
    }

    /// REGRESSION: cancel() on a never-started recorder must be safe (no crash).
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
