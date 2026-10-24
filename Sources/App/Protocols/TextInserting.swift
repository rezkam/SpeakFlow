import Foundation

/// Abstraction over text insertion via accessibility/CGEvent synthesis.
///
/// Allows RecordingController to be tested without real keystroke injection.
@MainActor
protocol TextInserting: AnyObject {
    /// PID of the app that owned the target element when `captureTarget()` was called.
    var targetPid: pid_t { get }
    func setObservabilitySessionId(_ sessionId: UUID?)
    /// Captures the focused field as the only destination for this recording.
    /// Returns false when no safe destination could be identified; callers must
    /// not start a recording that would type without one.
    @discardableResult
    func captureTarget() -> Bool
    /// Atomically replaces a tail segment by deleting `replacingChars` from the end
    /// and then typing `text`. Implementations should preserve ordering as one unit.
    func replaceTail(replacingChars: Int, with text: String)
    func insertText(_ text: String)
    func deleteChars(_ count: Int)
    func pressEnterKey()
    func cancelAndReset()
    func reset()
    func waitForPendingInsertions() async
    var pendingTask: Task<Void, Never>? { get }
}

extension TextInserting {
    func setObservabilitySessionId(_ sessionId: UUID?) {}

    func replaceTail(replacingChars: Int, with text: String) {
        if replacingChars > 0 { deleteChars(replacingChars) }
        if !text.isEmpty { insertText(text) }
    }
}
