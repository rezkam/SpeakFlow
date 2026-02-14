import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - LiveStreamingController — Advanced Event Sequences

@Suite("LiveStreamingController — Complex Event Sequences")
struct LiveStreamingAdvancedTests {

    // MARK: - Rapid Interim Updates

    @MainActor @Test
    func rapidInterimUpdates_onlyLatestTextShown() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Simulate rapid-fire interims (as when Deepgram refines in real-time)
        c.handleEvent(.interim(TranscriptionResult(transcript: "H", confidence: 0.5)))
        c.handleEvent(.interim(TranscriptionResult(transcript: "He", confidence: 0.6)))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hel", confidence: 0.7)))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hell", confidence: 0.8)))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9)))

        // Screen should show just "Hello" — each interim appends the delta
        #expect(col.screenText == "Hello")
        // All should be append-only (progressive text)
        for entry in col.entries {
            #expect(entry.replacingChars == 0, "Progressive interims should be append-only")
        }
    }

    // MARK: - Final After Interim

    @MainActor @Test
    func finalAfterInterim_replacesPartialWithFinalText() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Interim shows partial text
        c.handleEvent(.interim(TranscriptionResult(transcript: "hello worl", confidence: 0.7)))
        // Final corrects to complete text
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello world.", confidence: 0.99)))

        // Screen should show the final text with trailing space
        #expect(col.screenText == "Hello world. ")
        // The final event should have corrected the interim
        #expect(col.finals.count == 1)
        #expect(col.finals[0].fullText == "Hello world.")
    }

    // MARK: - Multiple Utterances

    @MainActor @Test
    func multipleUtterances_accumulateCorrectly() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // First utterance
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Good morning", confidence: 0.9)))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Good morning.", confidence: 0.99, speechFinal: true)))
        c.handleEvent(.utteranceEnd(lastWordEnd: 1.5))

        // Second utterance
        c.handleEvent(.speechStarted(timestamp: 2.0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "How are you", confidence: 0.9)))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "How are you?", confidence: 0.99, speechFinal: true)))
        c.handleEvent(.utteranceEnd(lastWordEnd: 3.5))

        #expect(col.screenText == "Good morning. How are you? ")
        #expect(col.finals.count == 2)
        #expect(col.speechStartCount == 2)
        #expect(col.utteranceEndCount >= 2)
    }

    // MARK: - Session Error During Recording

    @MainActor @Test
    func sessionError_midRecording_triggersErrorCallback() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c, simulateActive: true)
        var errorReceived: Error?
        c.onError = { errorReceived = $0 }

        // Some text was being transcribed
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "I was saying", confidence: 0.8)))

        // Then an error occurs
        c.handleEvent(.error(DeepgramError.webSocketError(NSError(domain: "ws", code: -1))))

        #expect(errorReceived != nil, "Error should propagate to onError callback")
    }

    // MARK: - Empty Final After Non-Empty Interim

    @MainActor @Test
    func emptyFinalAfterInterim_removesInterimText() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Interim shows text
        c.handleEvent(.interim(TranscriptionResult(transcript: "hmm", confidence: 0.5)))
        #expect(col.screenText == "hmm")

        // Empty final — server decided there was no real speech
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "", confidence: 0.0)))

        // Should remove the interim text
        let lastFinal = col.finals.last
        #expect(lastFinal != nil)
        #expect(lastFinal?.replacingChars == 3, "Should delete the 3 interim chars")
        #expect(lastFinal?.textToType == "", "Nothing to replace them with")
    }

    // MARK: - Closed Event During Active Session

    @MainActor @Test
    func closedEvent_whileActive_triggersSessionClosedCallback() async throws {
        let c = LiveStreamingController()
        c.isActive = true
        var sessionClosedCalled = false
        c.onSessionClosed = { sessionClosedCalled = true }

        c.handleEvent(.closed)

        // Wait for the async Task dispatch in handleEvent(.closed)
        try await Task.sleep(for: .milliseconds(200))

        #expect(sessionClosedCalled, "Unexpected close should trigger onSessionClosed")
        #expect(!c.isActive, "Session should be deactivated on unexpected close")
    }

    // MARK: - Interim Correction (word change mid-sentence)

    @MainActor @Test
    func interimCorrection_minimizesKeystrokes() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Deepgram progressively builds, then corrects a word
        c.handleEvent(.interim(TranscriptionResult(transcript: "I want to", confidence: 0.8)))
        c.handleEvent(.interim(TranscriptionResult(transcript: "I want two", confidence: 0.85)))

        // First interim: types "I want to"
        #expect(col.entries[0].textToType == "I want to")
        #expect(col.entries[0].replacingChars == 0)

        // Second interim: should only replace "to" → "two" (3 chars → 3 chars)
        // Common prefix: "I want t" (8 chars), old remainder: "o" (1 char), new remainder: "wo" (2 chars)
        #expect(col.entries[1].replacingChars == 1, "Delete 'o' from 'to'")
        #expect(col.entries[1].textToType == "wo", "Type 'wo' to form 'two'")
    }
}
