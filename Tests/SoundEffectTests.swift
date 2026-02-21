import Testing
@testable import SpeakFlowCore

@Suite("SoundEffect Mute Policy")
struct SoundEffectMutePolicyTests {
    @Test
    func explicitEnableOverridesTestDetection() {
        let muted = SoundEffect._testShouldMute(
            environment: [
                "SPEAKFLOW_ENABLE_SOUNDS_IN_TESTS": "1",
                "XCTestConfigurationFilePath": "/tmp/config"
            ],
            arguments: [],
            bundlePath: "/tmp/SpeakFlowPackageTests.xctest"
        )
        #expect(!muted)
    }

    @Test
    func explicitMuteAlwaysWins() {
        let muted = SoundEffect._testShouldMute(
            environment: ["SPEAKFLOW_MUTE_SOUNDS": "1"],
            arguments: [],
            bundlePath: "/Applications/SpeakFlow.app"
        )
        #expect(muted)
    }

    @Test
    func uiTestHarnessModeMutesSounds() {
        let muted = SoundEffect._testShouldMute(
            environment: ["SPEAKFLOW_UI_TEST_MODE": "1"],
            arguments: [],
            bundlePath: "/Applications/SpeakFlow.app"
        )
        #expect(muted)
    }

    @Test
    func xctestEnvironmentMutesSounds() {
        let muted = SoundEffect._testShouldMute(
            environment: ["XCTestConfigurationFilePath": "/tmp/config"],
            arguments: [],
            bundlePath: "/Applications/SpeakFlow.app"
        )
        #expect(muted)
    }

    @Test
    func xctestBundlePathMutesSounds() {
        let muted = SoundEffect._testShouldMute(
            environment: [:],
            arguments: [],
            bundlePath: "/tmp/SpeakFlowPackageTests.xctest"
        )
        #expect(muted)
    }

    @Test
    func xctestArgumentsMuteSounds() {
        let muted = SoundEffect._testShouldMute(
            environment: [:],
            arguments: ["/usr/bin/xctest"],
            bundlePath: "/Applications/SpeakFlow.app"
        )
        #expect(muted)
    }
}
