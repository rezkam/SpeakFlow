import Foundation

/// Abstraction over text insertion via accessibility/CGEvent synthesis.
///
/// Allows RecordingController to be tested without real keystroke injection.
@MainActor
protocol TextInserting: AnyObject {
    /// PID of the app that owned the target element when `captureTarget()` was called.
    var targetPid: pid_t { get }
    var onBulkInsertionFailure: (() -> Void)? { get set }
    var onDeliveryFailure: (() -> Void)? { get set }
    func setObservabilitySessionId(_ sessionId: UUID?)
    /// Captures the focused field as the only destination for this recording.
    /// Returns false when no safe destination could be identified; callers must
    /// not start a recording that would type without one.
    @discardableResult
    func captureTarget() -> Bool
    /// Atomically replaces a tail segment by deleting `replacingChars` from the end
    /// and then typing `text`. Implementations should preserve ordering as one unit.
    func replaceTail(replacingChars: Int, with text: String)
    /// Reconciles a complete segment against successfully posted recording text.
    func updateStreamingText(_ text: String, isFinal: Bool)
    /// Inserts batch text in Unicode bursts without clipboard access or per-character delays.
    func insertTextInBulk(_ text: String)
    func insertText(_ text: String)
    func deleteChars(_ count: Int)
    func pressEnterKey()
    func cancelAndReset()
    func reset()
    func waitForPendingInsertions() async
    var pendingTask: Task<Void, Never>? { get }
}

extension TextInserting {
    var onDeliveryFailure: (() -> Void)? { get { nil } set {} }
    func setObservabilitySessionId(_ sessionId: UUID?) {}

    func replaceTail(replacingChars: Int, with text: String) {
        if replacingChars > 0 { deleteChars(replacingChars) }
        if !text.isEmpty { insertText(text) }
    }
}
