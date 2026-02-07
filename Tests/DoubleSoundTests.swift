import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - Double Sound Bug Tests

/// Tests for the bug where completion sound plays multiple times.
///
/// Root cause: `finishIfDone()` can be called from multiple sources:
/// 1. Scheduled Task in stopRecording() (1 second delay)
/// 2. onAllComplete callback from TranscriptionQueueBridge.checkCompletion()
/// 3. Recursive calls from finishIfDone() itself when waiting for pending
///
/// If multiple calls reach the completion block simultaneously, they all
/// play the Glass sound because there's no guard against double-completion.

struct DoubleSoundBugTests {
    
    /// Simulates the completion callback being fired multiple times
    /// This can happen when multiple transcription chunks complete near-simultaneously
    @Test("checkCompletion should only fire onAllComplete once per session")
    func testCheckCompletionFiresOnce() async {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        
        bridge.onAllComplete = {
            completionCount += 1
        }
        
        // Simulate 3 chunks being queued
        let seq1 = await bridge.nextSequence()
        let seq2 = await bridge.nextSequence()
        let seq3 = await bridge.nextSequence()
        
        // All 3 complete and each calls checkCompletion
        await bridge.submitResult(seq: seq1, text: "first")
        await bridge.checkCompletion()
        
        await bridge.submitResult(seq: seq2, text: "second")
        await bridge.checkCompletion()
        
        await bridge.submitResult(seq: seq3, text: "third")
        await bridge.checkCompletion()
        
        // BUG: Currently completionCount will be 1 because only the last
        // checkCompletion sees pending==0. But if chunks complete simultaneously
        // in parallel tasks, multiple could see pending==0.
        #expect(completionCount == 1, "onAllComplete should only fire once, got \(completionCount)")
    }
    
    /// Simulates parallel completion checks - this demonstrates the race condition
    @Test("Parallel checkCompletion calls should only fire onAllComplete once")
    func testParallelCheckCompletionFiresOnce() async {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        
        bridge.onAllComplete = {
            completionCount += 1
        }
        
        // Queue one chunk and complete it
        let seq = await bridge.nextSequence()
        await bridge.submitResult(seq: seq, text: "done")
        
        // Simulate multiple parallel checkCompletion calls
        // (as would happen from stopRecording's scheduled task AND onAllComplete callback)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await bridge.checkCompletion()
                }
            }
        }
        
        // This test may pass sometimes due to timing, but exposes the race
        #expect(completionCount <= 1, "onAllComplete should fire at most once, got \(completionCount)")
    }
    
    /// Test that reset properly clears completion state
    @Test("Reset should allow completion to fire again for new session")
    func testResetAllowsNewCompletion() async {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        
        bridge.onAllComplete = {
            completionCount += 1
        }
        
        // First session
        let seq1 = await bridge.nextSequence()
        await bridge.submitResult(seq: seq1, text: "first session")
        await bridge.checkCompletion()
        
        #expect(completionCount == 1, "First session should complete")
        
        // Reset for new session
        await bridge.reset()
        
        // Second session
        let seq2 = await bridge.nextSequence()
        await bridge.submitResult(seq: seq2, text: "second session")
        await bridge.checkCompletion()
        
        #expect(completionCount == 2, "Second session should also complete")
    }
}

// MARK: - Completion Guard Tests

/// Tests for the fix: add a guard to prevent double completion

struct CompletionGuardTests {
    
    /// Models the expected behavior after fix
    @Test("Completion callback should have idempotent guard")
    func testIdempotentCompletion() async {
        var completed = false
        var soundPlayCount = 0
        
        // This models the fix: check and set a flag atomically
        func finishIfDone() {
            guard !completed else { return }  // Guard against double completion
            completed = true
            soundPlayCount += 1
        }
        
        // Multiple calls should only increment once
        finishIfDone()
        finishIfDone()
        finishIfDone()
        
        #expect(soundPlayCount == 1, "Sound should only play once")
    }
    
    /// Verifies the queue reports correct pending count
    @Test("getPendingCount accuracy during rapid submissions")
    func testPendingCountAccuracy() async {
        let bridge = TranscriptionQueueBridge()
        
        // Queue 3 chunks
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        
        let pending1 = await bridge.getPendingCount()
        #expect(pending1 == 3, "Should have 3 pending")
        
        // Complete first
        await bridge.submitResult(seq: 0, text: "first")
        let pending2 = await bridge.getPendingCount()
        #expect(pending2 == 2, "Should have 2 pending after first completes")
        
        // Complete remaining
        await bridge.submitResult(seq: 1, text: "second")
        await bridge.submitResult(seq: 2, text: "third")
        let pending3 = await bridge.getPendingCount()
        #expect(pending3 == 0, "Should have 0 pending after all complete")
    }
}
