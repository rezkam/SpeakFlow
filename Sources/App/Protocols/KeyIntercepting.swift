import ApplicationServices

/// Abstraction over keyboard event interception during recording.
///
/// Allows RecordingController to be tested without a real CGEvent tap.
@MainActor
protocol KeyIntercepting: AnyObject {
    var onEscapePressed: (() -> Void)? { get set }
    var onEnterPressed: (() -> Void)? { get set }

    /// Begin intercepting keys. Pass the target element so Enter is only
    /// captured while the user remains in the original text field.
    func start(target: AXUIElement?)
    func stop()
}
