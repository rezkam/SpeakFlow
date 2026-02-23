import AppKit

/// Semantic sound effects used throughout the app.
///
/// Centralizes system sound references so call sites express intent
/// (`.error`, `.start`) rather than magic strings (`"Basso"`, `"Blow"`).
public enum SoundEffect {
    case error, start, stop, complete

    /// Suppresses all sound playback when `true` (set during tests).
    @MainActor public static var isMuted = false

    static func shouldMute(
        environment: [String: String],
        arguments: [String],
        bundlePath: String
    ) -> Bool {
        if environment["SPEAKFLOW_ENABLE_SOUNDS_IN_TESTS"] == "1" { return false }
        if environment["SPEAKFLOW_MUTE_SOUNDS"] == "1" { return true }
        if environment["SPEAKFLOW_UI_TEST_MODE"] == "1" { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if bundlePath.localizedCaseInsensitiveContains(".xctest") { return true }
        return arguments.contains { $0.localizedCaseInsensitiveContains("xctest") }
    }

    /// Test/automation safety net:
    /// - Mute by default under XCTest/Swift Testing processes.
    /// - Mute in SpeakFlow UI test harness mode.
    /// - Allow explicit override via `SPEAKFLOW_ENABLE_SOUNDS_IN_TESTS=1`.
    /// - Allow explicit mute in any process via `SPEAKFLOW_MUTE_SOUNDS=1`.
    private static var shouldMuteFromEnvironment: Bool {
        shouldMute(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            bundlePath: Bundle.main.bundlePath
        )
    }

    @MainActor
    public func play() {
        guard !Self.isMuted, !Self.shouldMuteFromEnvironment else { return }
        let name: NSSound.Name = switch self {
        case .error: "Basso"
        case .start: "Blow"
        case .stop: "Pop"
        case .complete: "Glass"
        }
        NSSound(named: name)?.play()
    }
}

#if DEBUG
// swiftlint:disable identifier_name
extension SoundEffect {
    static func _testShouldMute(
        environment: [String: String],
        arguments: [String],
        bundlePath: String
    ) -> Bool {
        shouldMute(environment: environment, arguments: arguments, bundlePath: bundlePath)
    }
}
// swiftlint:enable identifier_name
#endif
