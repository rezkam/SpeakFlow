import Testing
@testable import SpeakFlowCore

@Suite("Settings auto-end persistence", .serialized)
struct SettingsAutoEndTests {
    @MainActor @Test
    func noSpeechTimeoutZeroRoundTripsAsDisabled() {
        let settings = Settings.shared
        let saved = settings.autoEndNoSpeechTimeout
        defer { settings.autoEndNoSpeechTimeout = saved }

        settings.autoEndNoSpeechTimeout = 0

        #expect(settings.autoEndNoSpeechTimeout == 0)
    }

    @MainActor @Test
    func maxContinuousSpeechZeroRoundTripsAsDisabled() {
        let settings = Settings.shared
        let saved = settings.autoEndMaxContinuousSpeechDuration
        defer { settings.autoEndMaxContinuousSpeechDuration = saved }

        settings.autoEndMaxContinuousSpeechDuration = 0

        #expect(settings.autoEndMaxContinuousSpeechDuration == 0)
    }
}
