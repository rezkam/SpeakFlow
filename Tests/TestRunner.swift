import Foundation
@testable import SpeakFlowCore

// Simple test framework
var testsPassed = 0
var testsFailed = 0

func test(_ name: String, _ block: () async throws -> Void) async {
    do {
        try await block()
        print("✓ \(name)")
        testsPassed += 1
    } catch {
        print("✗ \(name): \(error)")
        testsFailed += 1
    }
}

struct AssertionError: Error {
    let message: String
}

func expect(_ condition: Bool, _ message: String = "Assertion failed") throws {
    guard condition else { throw AssertionError(message: message) }
}

// MARK: - Double Sound Bug Tests

@MainActor
func runDoubleSoundTests() async {
    print("\n=== Double Sound Bug Tests ===\n")
    
    await test("checkCompletion should only fire onAllComplete once per session") {
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
        
        try expect(completionCount == 1, "onAllComplete should only fire once, got \(completionCount)")
    }
    
    await test("Parallel checkCompletion calls should only fire onAllComplete once") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        
        bridge.onAllComplete = {
            completionCount += 1
        }
        
        // Queue one chunk and complete it
        let seq = await bridge.nextSequence()
        await bridge.submitResult(seq: seq, text: "done")
        
        // Simulate multiple parallel checkCompletion calls
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await bridge.checkCompletion()
                }
            }
        }
        
        try expect(completionCount <= 1, "onAllComplete should fire at most once, got \(completionCount)")
    }
    
    await test("Reset should allow completion to fire again for new session") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        
        bridge.onAllComplete = {
            completionCount += 1
        }
        
        // First session
        let seq1 = await bridge.nextSequence()
        await bridge.submitResult(seq: seq1, text: "first session")
        await bridge.checkCompletion()
        
        try expect(completionCount == 1, "First session should complete, got \(completionCount)")
        
        // Reset for new session
        await bridge.reset()
        
        // Second session
        let seq2 = await bridge.nextSequence()
        await bridge.submitResult(seq: seq2, text: "second session")
        await bridge.checkCompletion()
        
        try expect(completionCount == 2, "Second session should also complete, got \(completionCount)")
    }
    
    await test("getPendingCount accuracy during rapid submissions") {
        let bridge = TranscriptionQueueBridge()
        
        // Queue 3 chunks
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        
        let pending1 = await bridge.getPendingCount()
        try expect(pending1 == 3, "Should have 3 pending, got \(pending1)")
        
        // Complete first
        await bridge.submitResult(seq: 0, text: "first")
        let pending2 = await bridge.getPendingCount()
        try expect(pending2 == 2, "Should have 2 pending after first completes, got \(pending2)")
        
        // Complete remaining
        await bridge.submitResult(seq: 1, text: "second")
        await bridge.submitResult(seq: 2, text: "third")
        let pending3 = await bridge.getPendingCount()
        try expect(pending3 == 0, "Should have 0 pending after all complete, got \(pending3)")
    }
    
    print("\n=== Results: \(testsPassed) passed, \(testsFailed) failed ===\n")
}

// Entry point
@main
struct TestMain {
    static func main() async {
        await runDoubleSoundTests()
        exit(testsFailed > 0 ? 1 : 0)
    }
}
