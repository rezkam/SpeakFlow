import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@MainActor
final class SpyHotkeySettings: HotkeySettingsProviding {
    var currentHotkey: HotkeyType = .doubleTapControl
}
