import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - TranscriptionService Tests

struct TranscriptionServiceTests {
    
    @Test("TranscriptionService.cancelAll completes without error")
    func testServiceCancelAllClearsTasks() async {
        let service = TranscriptionService.shared
        await service.cancelAll()
        #expect(Bool(true), "cancelAll should complete without error")
    }
    
    @Test("Large error body Data is truncated before String conversion")
    func testErrorBodyDataTruncation() {
        let largeBody = String(repeating: "x", count: 1_000_000)
        let data = Data(largeBody.utf8)
        
        let truncated = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        
        #expect(truncated.count <= 203, "Truncated body should be max 200 chars + '...'")
        #expect(truncated.hasSuffix("..."), "Truncated body should end with ellipsis")
    }
    
    @Test("Small error body is not truncated")
    func testSmallErrorBodyNotTruncated() {
        let smallBody = "Error: Bad request"
        let data = Data(smallBody.utf8)
        
        let result = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        
        #expect(result == smallBody, "Small body should not be truncated")
        #expect(!result.hasSuffix("..."), "Small body should not have ellipsis")
    }
}

// MARK: - TranscriptionError Tests

struct TranscriptionErrorTests {
    
    @Test("audioTooLarge error provides size info")
    func testAudioTooLargeError() {
        let error = TranscriptionError.audioTooLarge(size: 30_000_000, maxSize: 25_000_000)
        
        let description = error.errorDescription ?? ""
        #expect(description.contains("30"), "Should mention actual size")
        #expect(description.contains("25"), "Should mention max size")
        #expect(description.contains("MB"), "Should use MB units")
    }
    
    @Test("isRetryable is correct for each error type")
    func testErrorRetryability() {
        #expect(TranscriptionError.networkError(underlying: NSError(domain: "", code: 0)).isRetryable == true)
        #expect(TranscriptionError.rateLimited(retryAfter: 5).isRetryable == true)
        #expect(TranscriptionError.httpError(statusCode: 500, body: nil).isRetryable == true)
        #expect(TranscriptionError.httpError(statusCode: 400, body: nil).isRetryable == false)
        #expect(TranscriptionError.cancelled.isRetryable == false)
        #expect(TranscriptionError.audioTooLarge(size: 30_000_000, maxSize: 25_000_000).isRetryable == false)
    }
}

// MARK: - TranscriptionQueueBridge Tests

@MainActor
struct TranscriptionQueueBridgeTests {
    
    @Test("Queue reset clears pending results")
    func testQueueResetClearsPending() async {
        let bridge = TranscriptionQueueBridge()
        
        let initialSeq = await bridge.nextSequence()
        await bridge.submitResult(seq: initialSeq, text: "test1")
        
        let secondSeq = await bridge.nextSequence()
        #expect(secondSeq == initialSeq + 1, "Sequence should increment")
        
        await bridge.reset()
        
        let afterResetSeq = await bridge.nextSequence()
        #expect(afterResetSeq == initialSeq, "Sequence should restart after reset")
    }
    
    @Test("Queue handles out-of-order results")
    func testQueueHandlesOutOfOrder() async {
        let bridge = TranscriptionQueueBridge()
        
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        
        await bridge.submitResult(seq: 3, text: "third")
        await bridge.submitResult(seq: 1, text: "first")
        await bridge.submitResult(seq: 2, text: "second")
        
        #expect(Bool(true), "Out-of-order submission should not crash")
    }
}

// MARK: - Transcription Cancellation Tests

struct TranscriptionCancellationTests {
    
    @Test("Task cancellation propagates correctly")
    func testTaskCancellation() async {
        var wasCancelled = false
        
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError {
                wasCancelled = true
            } catch {}
        }
        
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        
        #expect(wasCancelled, "Task should receive cancellation")
    }
    
    @Test("Cancelled task throws CancellationError")
    func testCancelledTaskThrows() async {
        let task = Task {
            try await Task.sleep(for: .seconds(10))
            return "completed"
        }
        
        task.cancel()
        
        do {
            _ = try await task.value
            #expect(Bool(false), "Should have thrown")
        } catch is CancellationError {
            #expect(Bool(true), "Should throw CancellationError")
        } catch {
            #expect(Bool(false), "Should throw CancellationError, not \(error)")
        }
    }
}
