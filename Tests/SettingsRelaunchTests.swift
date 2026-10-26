import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Settings persistence across processes", .serialized)
struct SettingsRelaunchTests {
    @MainActor @Test
    func storedZerosSurviveASeparateProcess() throws {
        let suite = "SettingsRelaunchTests"
        guard NativeUIProbeSupport.isChild(for: suite) else {
            let defaultsSuite = "synthetic.settings.relaunch.\(UUID().uuidString)"
            for stage in ["write", "read"] {
                try NativeUIProbeSupport.runChild(suite: suite, environmentOverrides: [
                    "SPEAKFLOW_SETTINGS_STAGE": stage,
                    "SPEAKFLOW_SETTINGS_SUITE": defaultsSuite
                ])
            }
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let name = try #require(environment["SPEAKFLOW_SETTINGS_SUITE"])
        try #require(name.hasPrefix("synthetic.settings.relaunch."))
        let defaults = try #require(UserDefaults(suiteName: name))
        let settings = Settings(defaults: defaults)
        let keys = [
            "settings.autoEndNoSpeechTimeout", "settings.autoEndMaxContinuousSpeechDuration",
            "settings.autoEndMinSessionDuration", "settings.autoEnd.thinkingPauseExtensionSeconds",
            "settings.autoEnd.turnClassifierIncompleteExtensionSeconds"
        ]
        if environment["SPEAKFLOW_SETTINGS_STAGE"] == "write" {
            for key in keys { #expect(defaults.object(forKey: key) == nil) }
            settings.autoEndNoSpeechTimeout = 0
            settings.autoEndMaxContinuousSpeechDuration = 0
            settings.autoEndMinSessionDuration = 0
            settings.thinkingPauseExtensionSeconds = 0
            settings.turnClassifierIncompleteExtensionSeconds = 0
            #expect(defaults.synchronize())
        } else {
            try #require(environment["SPEAKFLOW_SETTINGS_STAGE"] == "read")
            for key in keys {
                #expect(defaults.object(forKey: key) as? Double == 0,
                        "A fresh process must read a persisted zero, not an absent setting")
            }
            #expect(settings.autoEndNoSpeechTimeout == 0)
            #expect(settings.autoEndMaxContinuousSpeechDuration == 0)
            #expect(settings.autoEndMinSessionDuration == 0)
            #expect(settings.thinkingPauseExtensionSeconds == 0)
            #expect(settings.turnClassifierIncompleteExtensionSeconds == 0)
        }
    }
}
