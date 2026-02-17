import ApplicationServices
import Foundation

/// Abstraction over text insertion via accessibility/CGEvent synthesis.
///
/// Allows RecordingController to be tested without real keystroke injection.
@MainActor
protocol TextInserting: AnyObject {
    /// The AXUIElement that had focus when recording started.
    var targetElement: AXUIElement? { get }
    func captureTarget()
    func insertText(_ text: String)
    func deleteChars(_ count: Int)
    func pressEnterKey()
    func cancelAndReset()
    func reset()
    func waitForPendingInsertions() async
    var pendingTask: Task<Void, Never>? { get }
}
