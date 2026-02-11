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

// MARK: - Config VAD Tests

struct ConfigVADTests {
    @Test func testConstants() {
        #expect(Config.vadThreshold == 0.15)
        #expect(Config.vadMinSilenceAfterSpeech == 3.0)
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
