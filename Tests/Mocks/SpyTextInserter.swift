import Foundation
import Testing
@testable import SpeakFlow

@MainActor
final class SpyTextInserter: TextInserting {
    enum Operation: Equatable {
        case captureTarget
        case replaceTail(replacingChars: Int, text: String)
        case insertText(String)
        case deleteChars(Int)
        case pressEnterKey
        case cancelAndReset
        case reset
        case waitForPendingInsertions
    }

    var targetPid: pid_t = 0
    var captureTargetCalled = false
    var insertedTexts: [String] = []
    var deletedCounts: [Int] = []
    var enterKeyPressed = false
    var cancelCalled = false
    var resetCalled = false
    var replaceTailCallCount = 0
    var pendingTask: Task<Void, Never>?
    var operations: [Operation] = []
    var observabilitySessionId: UUID?

    func setObservabilitySessionId(_ sessionId: UUID?) {
        observabilitySessionId = sessionId
    }

    func captureTarget() {
        captureTargetCalled = true
        operations.append(.captureTarget)
    }

    func insertText(_ text: String) {
        insertedTexts.append(text)
        operations.append(.insertText(text))
    }

    func replaceTail(replacingChars: Int, with text: String) {
        replaceTailCallCount += 1
        operations.append(.replaceTail(replacingChars: replacingChars, text: text))
        if replacingChars > 0 {
            deleteChars(replacingChars)
        }
        if !text.isEmpty {
            insertText(text)
        }
    }

    func deleteChars(_ count: Int) {
        deletedCounts.append(count)
        operations.append(.deleteChars(count))
    }

    func pressEnterKey() {
        enterKeyPressed = true
        operations.append(.pressEnterKey)
    }

    func cancelAndReset() {
        cancelCalled = true
        operations.append(.cancelAndReset)
    }

    func reset() {
        resetCalled = true
        operations.append(.reset)
    }

    func waitForPendingInsertions() async {
        operations.append(.waitForPendingInsertions)
        await pendingTask?.value
    }
}
