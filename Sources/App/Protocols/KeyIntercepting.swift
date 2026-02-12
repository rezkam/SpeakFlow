/// Abstraction over keyboard event interception during recording.
///
/// Allows RecordingController to be tested without a real CGEvent tap.
@MainActor
protocol KeyIntercepting: AnyObject {
    var onEscapePressed: (() -> Void)? { get set }
    var onEnterPressed: (() -> Void)? { get set }
    func start()
    func stop()
}
