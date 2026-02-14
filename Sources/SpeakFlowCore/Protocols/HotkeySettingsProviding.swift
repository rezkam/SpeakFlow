import Foundation

/// Abstracts HotkeySettings for dependency injection.
@MainActor
public protocol HotkeySettingsProviding: AnyObject {
    var currentHotkey: HotkeyType { get set }
}
