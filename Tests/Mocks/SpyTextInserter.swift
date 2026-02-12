import Foundation
import Testing
@testable import SpeakFlow

@MainActor
final class SpyTextInserter: TextInserting {
    var captureTargetCalled = false
    var insertedTexts: [String] = []
    var deletedCounts: [Int] = []
    var enterKeyPressed = false
    var cancelCalled = false
    var resetCalled = false
    var pendingTask: Task<Void, Never>?

    func captureTarget() { captureTargetCalled = true }
    func insertText(_ text: String) { insertedTexts.append(text) }
    func deleteChars(_ count: Int) { deletedCounts.append(count) }
    func pressEnterKey() { enterKeyPressed = true }
    func cancelAndReset() { cancelCalled = true }
    func reset() { resetCalled = true }
    func waitForPendingInsertions() async { await pendingTask?.value }
}
