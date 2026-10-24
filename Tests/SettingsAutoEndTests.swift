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

/// A setting whose setter and UI accept zero must read back zero, not the
/// default: "0 s" is a real choice, distinct from "never set".
@Suite("Settings — Stored Zero Is Not Unset", .serialized)
struct SettingsStoredZeroTests {
    @MainActor @Test
    func minimumSessionDurationZeroPersists() {
        let settings = Settings.shared
        let saved = settings.autoEndMinSessionDuration
        defer { settings.autoEndMinSessionDuration = saved }

        settings.autoEndMinSessionDuration = 0

        #expect(settings.autoEndMinSessionDuration == 0)
    }

    @MainActor @Test
    func thinkingPauseExtensionZeroPersists() {
        let settings = Settings.shared
        let saved = settings.thinkingPauseExtensionSeconds
        defer { settings.thinkingPauseExtensionSeconds = saved }

        settings.thinkingPauseExtensionSeconds = 0

        #expect(settings.thinkingPauseExtensionSeconds == 0)
    }

    @MainActor @Test
    func turnClassifierIncompleteExtensionZeroPersists() {
        let settings = Settings.shared
        let saved = settings.turnClassifierIncompleteExtensionSeconds
        defer { settings.turnClassifierIncompleteExtensionSeconds = saved }

        settings.turnClassifierIncompleteExtensionSeconds = 0

        #expect(settings.turnClassifierIncompleteExtensionSeconds == 0)
    }
}
