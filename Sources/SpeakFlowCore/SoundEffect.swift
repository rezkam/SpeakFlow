import AppKit

/// Semantic sound effects used throughout the app.
///
/// Centralizes system sound references so call sites express intent
/// (`.error`, `.start`) rather than magic strings (`"Basso"`, `"Blow"`).
public enum SoundEffect {
    case error, start, stop, complete

    /// Suppresses all sound playback when `true` (set during tests).
    @MainActor public static var isMuted = false

    @MainActor
    public func play() {
        guard !Self.isMuted else { return }
        let name: NSSound.Name = switch self {
        case .error: "Basso"
        case .start: "Blow"
        case .stop: "Pop"
        case .complete: "Glass"
        }
        NSSound(named: name)?.play()
    }
}
