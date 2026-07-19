import Testing

// MARK: - Mistral Live Test Gate
//
// Behavioral coverage for the pure opt-in helpers that gate
// Tests/MistralAPITests.swift. These never touch the real process
// environment; every case passes an explicit dictionary so both
// branches are deterministic.

@Suite("Mistral Live Test Gate — Helper Functions")
struct MistralLiveTestGateTests {

    // MARK: - mistralLiveTestsEnabled

    @Test
    func liveTestsDisabledWhenFlagAbsent() {
        #expect(mistralLiveTestsEnabled([:]) == false)
    }

    @Test
    func liveTestsEnabledWhenFlagPresentAndNonEmpty() {
        #expect(mistralLiveTestsEnabled(["SPEAKFLOW_RUN_LIVE_MISTRAL": "1"]) == true)
    }

    @Test
    func liveTestsDisabledWhenFlagPresentButEmpty() {
        #expect(mistralLiveTestsEnabled(["SPEAKFLOW_RUN_LIVE_MISTRAL": ""]) == false)
    }

    // MARK: - mistralAPIKeyAvailable

    @Test
    func apiKeyUnavailableWhenAbsent() {
        #expect(mistralAPIKeyAvailable([:]) == false)
    }

    @Test
    func apiKeyAvailableWhenPresentAndNonEmpty() {
        #expect(mistralAPIKeyAvailable(["MISTRAL_API_KEY": "sk-xxx"]) == true)
    }

    @Test
    func apiKeyUnavailableWhenPresentButEmpty() {
        #expect(mistralAPIKeyAvailable(["MISTRAL_API_KEY": ""]) == false)
    }
}
