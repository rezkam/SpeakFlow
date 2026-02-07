import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - Platform Support Tests

struct PlatformSupportTests {
    @Test func testSupportsVAD() {
        #expect(PlatformSupport.supportsVAD == PlatformSupport.isAppleSilicon)
    }

    @Test func testDescription() {
        #expect(!PlatformSupport.platformDescription.isEmpty)
    }

    @Test func testVadUnavailableReason() {
        if PlatformSupport.isAppleSilicon {
            #expect(PlatformSupport.vadUnavailableReason == nil)
        } else {
            #expect(PlatformSupport.vadUnavailableReason != nil)
        }
    }
}

// MARK: - VAD Configuration Tests

struct VADConfigurationTests {
    @Test func testDefaults() {
        let c = VADConfiguration()
        #expect(c.threshold == 0.5)
        #expect(c.minSilenceAfterSpeech == 1.0)
        #expect(c.minSpeechDuration == 0.25)
        #expect(c.enabled == true)
    }

    @Test func testSensitive() {
        #expect(VADConfiguration.sensitive.threshold == 0.3)
    }

    @Test func testStrict() {
        #expect(VADConfiguration.strict.threshold == 0.7)
    }
}

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

// MARK: - VAD Processor Tests

struct VADProcessorTests {
    @Test func testIsAvailable() {
        #expect(VADProcessor.isAvailable == PlatformSupport.supportsVAD)
    }

    @Test func testInitialState() async {
        let p = VADProcessor()
        #expect(await p.isSpeaking == false)
        #expect(await p.lastSpeechEndTime == nil)
        #expect(await p.lastSpeechStartTime == nil)
    }

    @Test func testResetSession() async {
        let p = VADProcessor()
        await p.resetSession()
        #expect(await p.isSpeaking == false)
        #expect(await p.averageSpeechProbability == 0)
    }

    @Test func testAverageSpeechProbability() async {
        let p = VADProcessor()
        // Before processing, should be 0
        #expect(await p.averageSpeechProbability == 0)
    }

    @Test func testHasSignificantSpeech() async {
        let p = VADProcessor()
        // Before processing, should have no significant speech
        #expect(await p.hasSignificantSpeech() == false)
    }

    @Test func testCurrentSilenceDuration() async {
        let p = VADProcessor()
        // When not speaking and no last speech end, should be nil
        #expect(await p.currentSilenceDuration == nil)
    }
}

// MARK: - Session Controller Tests

struct SessionControllerTests {
    // MARK: - Helper Mock Clock
    final class MockDateProvider: @unchecked Sendable {
        var now = Date()
        func date() -> Date { now }
    }

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

// MARK: - Config VAD Tests

struct ConfigVADTests {
    @Test func testConstants() {
        #expect(Config.vadThreshold == 0.3)
        #expect(Config.vadMinSilenceAfterSpeech == 1.0)
        #expect(Config.vadMinSpeechDuration == 0.25)
        #expect(Config.autoEndSilenceDuration == 5.0)
        #expect(Config.autoEndMinSessionDuration == 2.0)
    }
}

// MARK: - Speech Event Tests

struct SpeechEventTests {
    @Test func testStartedEvent() {
        let event = SpeechEvent.started(at: 1.5)
        if case .started(let time) = event {
            #expect(time == 1.5)
        } else {
            Issue.record("Expected .started event")
        }
    }

    @Test func testEndedEvent() {
        let event = SpeechEvent.ended(at: 3.0)
        if case .ended(let time) = event {
            #expect(time == 3.0)
        } else {
            Issue.record("Expected .ended event")
        }
    }
}

// MARK: - VAD Result Tests

struct VADResultTests {
    @Test func testInit() {
        let result = VADResult(probability: 0.8, isSpeaking: true, event: .started(at: 1.0), processingTimeMs: 0.5)
        #expect(result.probability == 0.8)
        #expect(result.isSpeaking == true)
        #expect(result.processingTimeMs == 0.5)
    }

    @Test func testNilEvent() {
        let result = VADResult(probability: 0.3, isSpeaking: false, event: nil, processingTimeMs: 0.3)
        #expect(result.event == nil)
    }
}

// MARK: - VAD Error Tests

struct VADErrorTests {
    @Test func testNotInitialized() {
        let error = VADError.notInitialized
        if case .notInitialized = error {
            // Pass
        } else {
            Issue.record("Expected .notInitialized")
        }
    }

    @Test func testUnsupportedPlatform() {
        let error = VADError.unsupportedPlatform("Intel Mac")
        if case .unsupportedPlatform(let reason) = error {
            #expect(reason == "Intel Mac")
        } else {
            Issue.record("Expected .unsupportedPlatform")
        }
    }

    @Test func testProcessingFailed() {
        let error = VADError.processingFailed("Model error")
        if case .processingFailed(let msg) = error {
            #expect(msg == "Model error")
        } else {
            Issue.record("Expected .processingFailed")
        }
    }
}
