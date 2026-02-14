import Foundation
import OSLog

/// Manages user preferences for hotkey activation.
///
/// In test runs, uses an isolated UserDefaults suite to avoid corrupting
/// the user's real hotkey preference.
@MainActor
public final class HotkeySettings {
    public static let shared = HotkeySettings()

    private let defaultsKey = "activationHotkey"
    private let defaults: UserDefaults

    private init() {
        let isTestRun = Bundle.main.bundlePath.contains(".xctest")
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") })
        if isTestRun {
            let suiteName = "app.monodo.speakflow.hotkey.tests.\(ProcessInfo.processInfo.processIdentifier)"
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            defaults = .standard
        }
    }

    public var currentHotkey: HotkeyType {
        get {
            if let raw = defaults.string(forKey: defaultsKey),
               let type = HotkeyType(rawValue: raw) {
                return type
            }
            return .doubleTapControl  // Default
        }
        set {
            defaults.set(newValue.rawValue, forKey: defaultsKey)
            Logger.hotkey.info("Hotkey changed to: \(newValue.displayName)")
        }
    }
}

extension HotkeySettings: HotkeySettingsProviding {}
