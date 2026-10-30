import Foundation
import Testing
@testable import SpeakFlow

@MainActor
final class SpyTextInserter: TextInserting {
    enum Operation: Equatable {
        case captureTarget
        case replaceTail(replacingChars: Int, text: String)
        case insertText(String)
        case insertTextDirectly(String)
        case deleteChars(Int)
        case pressEnterKey
        case cancelAndReset
        case reset
        case waitForPendingInsertions
    }

    var onDirectInsertionFailure: (() -> Void)?
    var directlyInsertedTexts: [String] = []
    var targetPid: pid_t = 0
    var captureTargetCalled = false
    var insertedTexts: [String] = []
    var deletedCounts: [Int] = []
    var enterKeyPressed = false
    var cancelCalled = false
    var resetCalled = false
    var replaceTailCallCount = 0
    private var streamingCommittedText = ""
    private var streamingPostedText = ""
    var pendingTask: Task<Void, Never>?
    var operations: [Operation] = []
    var observabilitySessionId: UUID?

    func setObservabilitySessionId(_ sessionId: UUID?) {
        observabilitySessionId = sessionId
    }

    /// Result `captureTarget()` reports; set false to simulate an AX failure.
    var captureSucceeds = true

    @discardableResult
    func captureTarget() -> Bool {
        captureTargetCalled = true
        operations.append(.captureTarget)
        return captureSucceeds
    }

    func insertTextDirectly(_ text: String) {
        directlyInsertedTexts.append(text)
        operations.append(.insertTextDirectly(text))
    }

    func insertText(_ text: String) {
        insertedTexts.append(text)
        operations.append(.insertText(text))
    }

    func updateStreamingText(_ text: String, isFinal: Bool) {
        let desired = streamingCommittedText + text + (isFinal && !text.isEmpty ? " " : "")
        if isFinal { streamingCommittedText = desired }
        let common = zip(streamingPostedText, desired).prefix { $0 == $1 }.count
        replaceTail(replacingChars: streamingPostedText.count - common, with: String(desired.dropFirst(common)))
        streamingPostedText = desired
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

    /// When set, becomes the pending task as soon as Enter is queued, so tests
    /// can hold a finalizer inside its synthetic-Enter wait.
    var pendingTaskAfterEnter: Task<Void, Never>?

    func pressEnterKey() {
        enterKeyPressed = true
        operations.append(.pressEnterKey)
        if let pendingTaskAfterEnter { pendingTask = pendingTaskAfterEnter }
    }

    func cancelAndReset() {
        streamingCommittedText = ""
        streamingPostedText = ""
        cancelCalled = true
        operations.append(.cancelAndReset)
    }

    func reset() {
        streamingCommittedText = ""
        streamingPostedText = ""
        resetCalled = true
        operations.append(.reset)
    }

    func waitForPendingInsertions() async {
        operations.append(.waitForPendingInsertions)
        await pendingTask?.value
    }
}
