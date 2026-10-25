import Foundation
import Testing
@testable import LiveE2EKit

/// The live E2E wrappers describe one scenario through SPEAKFLOW_E2E_*
/// variables. The runner must honor that configuration and report which
/// assertions actually executed, so a wrapper cannot pass on a run that
/// ignored its request.
@Suite("Live E2E Contract")
struct LiveE2EContractTests {
    @MainActor @Test
    func completionDeadlineCancelsOutstandingWork() async {
        var cancellations = 0
        let completed = await LiveE2ECompletion.wait(
            timeout: .zero, isIdle: { false }, cancel: { cancellations += 1 }
        )
        #expect(!completed)
        #expect(cancellations == 1)
    }

    @MainActor @Test
    func completedWorkDoesNotCancel() async {
        var cancellations = 0
        let completed = await LiveE2ECompletion.wait(
            timeout: .zero, isIdle: { true }, cancel: { cancellations += 1 }
        )
        #expect(completed)
        #expect(cancellations == 0)
    }

    @Test
    func noScenarioVariablesMeansTheBuiltInSuite() throws {
        #expect(try LiveE2EScenarioConfig.fromEnvironment([:]) == nil)
    }

    @Test
    func wrapperVariablesBecomeOneScenario() throws {
        let config = try #require(try LiveE2EScenarioConfig.fromEnvironment([
            "SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "first part",
            "SPEAKFLOW_E2E_AUTO_SPEAK_TEXT_PART2": "second part",
            "SPEAKFLOW_E2E_AUTO_SPEAK_GAP_SECONDS": "2",
            "SPEAKFLOW_E2E_AUTO_SPEAK_RATE": "170",
            "SPEAKFLOW_E2E_CHUNK_DURATION": "15",
            "SPEAKFLOW_E2E_EXPECT_PHRASE": "first second",
            "SPEAKFLOW_E2E_TEST_AUTO_END": "true",
            "SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS": "6",
            "SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS": "14",
            "SPEAKFLOW_E2E_TIMEOUT_SECONDS": "30",
            "SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS": "2"
        ]))
        #expect(config.audio == .speech(text: "first part", secondText: "second part", gapSeconds: 2, rate: 170))
        #expect(config.chunkSeconds == 15)
        #expect(config.expectPhrase == "first second")
        #expect(config.autoEnd == .mustFire(minSeconds: 6, maxSeconds: 14))
        #expect(config.timeoutSeconds == 30)
        #expect(config.minChunks == 2)
    }

    @Test
    func explicitSilenceDurationIsNotIgnored() throws {
        let base = ["SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "synthetic speech"]
        let defaults = try LiveE2EScenarioConfig.fromEnvironment(base)
        let configured = try LiveE2EScenarioConfig.fromEnvironment(base.merging([
            "SPEAKFLOW_E2E_AUTO_END_SILENCE_SECONDS": "5"
        ]) { _, value in value })
        #expect(configured != defaults, "The wrapper's explicit silence duration must reach the scenario")
        #expect(configured?.autoEndSilenceSeconds == 5)
        #expect(defaults?.autoEndSilenceSeconds == nil)
    }

    @Test(arguments: ["0", "0.5", "-1", "nan", "inf", "invalid"])
    func invalidSilenceDurationIsRejected(value: String) {
        #expect(throws: LiveE2EConfigError.self) {
            try LiveE2EScenarioConfig.fromEnvironment([
                "SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "synthetic speech",
                "SPEAKFLOW_E2E_AUTO_END_SILENCE_SECONDS": value
            ])
        }
    }

    @Test
    func noiseRejectionNeedsAnAudioFile() {
        #expect(throws: LiveE2EConfigError.self) {
            try LiveE2EScenarioConfig.fromEnvironment(["SPEAKFLOW_E2E_TEST_NOISE_REJECTION": "1"])
        }
    }

    @Test
    func invalidNumbersAreRejectedNotIgnored() {
        #expect(throws: LiveE2EConfigError.self) {
            try LiveE2EScenarioConfig.fromEnvironment([
                "SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "hi", "SPEAKFLOW_E2E_CHUNK_DURATION": "fifteen"
            ])
        }
    }

    @Test
    func phraseAssertionWithoutTranscriptionFailsInsteadOfPassing() throws {
        let config = try #require(try LiveE2EScenarioConfig.fromEnvironment([
            "SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "hello world", "SPEAKFLOW_E2E_EXPECT_PHRASE": "hello world"
        ]))
        let verdict = config.evaluate(.init(chunks: 1, autoEndSeconds: nil, transcript: nil))

        #expect(!verdict.passed, "A requested phrase check that could not run is a failure")
        #expect(!verdict.executed.contains("phrase"))
    }

    @Test
    func matchingPartialTranscriptCannotPassBeforeCompletion() throws {
        let config = try #require(try LiveE2EScenarioConfig.fromEnvironment([
            "SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "hello world", "SPEAKFLOW_E2E_EXPECT_PHRASE": "hello world"
        ]))
        let verdict = config.evaluate(.init(
            chunks: 2, autoEndSeconds: nil, transcript: "hello world", transcriptionCompleted: false
        ))
        #expect(!verdict.passed)
        #expect(verdict.failures.contains { $0.contains("incomplete") })
        #expect(!verdict.executed.contains("phrase"))
    }

    @Test
    func passingRunReportsEveryExecutedAssertion() throws {
        let config = try #require(try LiveE2EScenarioConfig.fromEnvironment([
            "SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "hello world",
            "SPEAKFLOW_E2E_EXPECT_PHRASE": "hello world",
            "SPEAKFLOW_E2E_TEST_AUTO_END": "true",
            "SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS": "3",
            "SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS": "20",
            "SPEAKFLOW_E2E_EXPECT_MIN_CHUNKS": "1"
        ]))
        let verdict = config.evaluate(.init(chunks: 1, autoEndSeconds: 8, transcript: "Hello, world.", transcriptionCompleted: true))

        #expect(verdict.passed, "\(verdict.failures)")
        #expect(verdict.executed == ["phrase", "autoEndFired", "autoEndWindow", "chunkRange"])
        #expect(verdict.resultLine.hasPrefix("E2E_RESULT status=pass assertions=phrase,autoEndFired,autoEndWindow,chunkRange"))
    }

    @Test
    func autoEndOutsideTheWindowFails() throws {
        let config = try #require(try LiveE2EScenarioConfig.fromEnvironment([
            "SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "hi",
            "SPEAKFLOW_E2E_TEST_AUTO_END": "true",
            "SPEAKFLOW_E2E_EXPECT_AUTO_END_MIN_SECONDS": "6",
            "SPEAKFLOW_E2E_EXPECT_AUTO_END_MAX_SECONDS": "14"
        ]))
        #expect(!config.evaluate(.init(chunks: 1, autoEndSeconds: 3, transcript: nil)).passed)
        #expect(!config.evaluate(.init(chunks: 1, autoEndSeconds: nil, transcript: nil)).passed)
    }

    @Test
    func noiseRejectionRequiresZeroChunks() throws {
        let config = try #require(try LiveE2EScenarioConfig.fromEnvironment([
            "SPEAKFLOW_E2E_TEST_NOISE_REJECTION": "1", "SPEAKFLOW_E2E_AUDIO_FILE_PATH": "/tmp/noise.wav"
        ]))
        #expect(config.evaluate(.init(chunks: 0, autoEndSeconds: nil, transcript: nil)).executed == ["noChunks"])
        #expect(!config.evaluate(.init(chunks: 1, autoEndSeconds: nil, transcript: nil)).passed)
    }

    @Test
    func aScenarioWithNoAssertionsCannotPass() throws {
        let config = try #require(try LiveE2EScenarioConfig.fromEnvironment(["SPEAKFLOW_E2E_AUTO_SPEAK_TEXT": "hi"]))
        #expect(!config.evaluate(.init(chunks: 3, autoEndSeconds: nil, transcript: nil)).passed,
                "A run that asserted nothing proves nothing")
    }

    @Test
    func chunkLinesAreMachineReadable() {
        #expect(LiveE2EOutput.chunkLine(index: 2, seconds: 15.04, speechPercent: 87) == "E2E_CHUNK index=2 seconds=15.0 speech=87")
        #expect(LiveE2EOutput.autoEndLine(seconds: 8.25) == "E2E_AUTO_END seconds=8.2")
    }
}
