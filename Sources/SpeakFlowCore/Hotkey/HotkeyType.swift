import Foundation

/// Available hotkey activation methods
public enum HotkeyType: String, CaseIterable {
    case doubleTapControl
    case controlOptionD
    case controlOptionSpace
    case commandShiftD

    public var displayName: String {
        switch self {
        case .doubleTapControl: return "⌃⌃ (double-tap)"
        case .controlOptionD: return "⌃⌥D"
        case .controlOptionSpace: return "⌃⌥Space"
        case .commandShiftD: return "⇧⌘D"
        }
    }
}
