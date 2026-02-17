import Foundation

/// Abstraction over keyboard event interception during recording.
///
/// Allows RecordingController to be tested without a real CGEvent tap.
/// The `targetPid` parameter in `start(targetPid:)` enables focus-aware
/// interception: Escape/Enter are only intercepted when keyboard focus
/// is in the target app. System overlays (Spotlight, password dialogs)
/// receive keys normally.
@MainActor
protocol KeyIntercepting: AnyObject {
    var onEscapePressed: (() -> Void)? { get set }
    var onEnterPressed: (() -> Void)? { get set }
    func start(targetPid: pid_t)
    func stop()
}
