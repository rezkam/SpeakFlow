import Foundation
import OSLog

/// Manages user preferences for hotkey activation
@MainActor
public final class HotkeySettings {
    public static let shared = HotkeySettings()

    private let defaultsKey = "activationHotkey"

    private init() {}

    public var currentHotkey: HotkeyType {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let type = HotkeyType(rawValue: raw) {
                return type
            }
            return .doubleTapControl  // Default
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            Logger.hotkey.info("Hotkey changed to: \(newValue.displayName)")
        }
    }
}
