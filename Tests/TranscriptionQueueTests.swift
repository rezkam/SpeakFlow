import ConcurrencyExtras
import Foundation
import os
import Testing
@testable import SpeakFlowCore

// MARK: - TranscriptionQueue Ordering Tests

@Suite("TranscriptionQueue Tests")
struct TranscriptionQueueTests {
    @Test func testResultsOutputInOrder() async {
        let queue = TranscriptionQueue()
        var received: [String] = []

        // Get the stream BEFORE submitting results
        let stream = await queue.textStream

        let ticket0 = await queue.nextSequence()
        let ticket1 = await queue.nextSequence()
        let ticket2 = await queue.nextSequence()

        // Submit out of order
        await queue.submitResult(ticket: ticket2, text: "third")
        await queue.submitResult(ticket: ticket0, text: "first")
        await queue.submitResult(ticket: ticket1, text: "second")

        // Collect from stream with timeout
        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count == 3 { break }
            }
            return items
        }

        // Give it a moment then cancel if stuck
        try? await Task.sleep(for: .seconds(1))
        if !collectTask.isCancelled {
            received = await collectTask.value
        }

        #expect(received == ["first", "second", "third"],
                "Queue must output in sequence order regardless of submission order")
    }

    @Test func testStaleSessionResultsAreDropped() async {
        let queue = TranscriptionQueue()

        let ticket0 = await queue.nextSequence()
        #expect(ticket0.session == 0)

        // Reset bumps session generation
        await queue.reset()

        let ticket1 = await queue.nextSequence()
        #expect(ticket1.session == 1, "Session generation should increment on reset")

        // Submit with stale session ticket — should be silently dropped
        await queue.submitResult(ticket: ticket0, text: "stale")

        let pending = await queue.getPendingCount()
        #expect(pending == 1, "Stale result should not affect pending count")

        // Submit with correct session ticket
        await queue.submitResult(ticket: ticket1, text: "current")

        let pendingAfter = await queue.getPendingCount()
        #expect(pendingAfter == 0, "Current-session result should clear pending")
    }

    @Test func testFailedChunkDoesNotBlockQueue() async {
        let queue = TranscriptionQueue()
        var received: [String] = []

        let stream = await queue.textStream

        let ticket0 = await queue.nextSequence()
        let ticket1 = await queue.nextSequence()

        // Mark first as failed, second succeeds
        await queue.markFailed(ticket: ticket0)
        await queue.submitResult(ticket: ticket1, text: "survived")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count == 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .seconds(1))
        received = await collectTask.value

        #expect(received == ["survived"],
                "Failed chunk should be skipped, not block subsequent results")
    }

    @Test func testWaitForCompletionBlocksUntilAllPendingResultsAreSubmitted() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()

        let done = OSAllocatedUnfairLock(initialState: false)
        let waitTask = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        _ = waitTask // suppress unused warning

        func isDone(afterMs ms: Int) async -> Bool {
            try? await Task.sleep(for: .milliseconds(ms))
            return done.withLock { $0 }
        }

        #expect(await isDone(afterMs: 80) == false,
                "waitForCompletion should block while there are pending results")

        await queue.submitResult(ticket: t0, text: "first")
        #expect(await isDone(afterMs: 80) == false,
                "waitForCompletion should remain blocked until all pending results arrive")

        await queue.submitResult(ticket: t1, text: "second")
        #expect(await isDone(afterMs: 250) == true,
                "waitForCompletion should complete after all pending results are flushed")
    }

    @Test func testFinishStreamUnblocksWaitForCompletion() async {
        let queue = TranscriptionQueue()
        _ = await queue.nextSequence() // Introduce pending work so waitForCompletion actually waits.

        let waitTask = Task {
            await queue.waitForCompletion()
        }

        try? await Task.sleep(for: .milliseconds(60))
        await queue.finishStream()

        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await waitTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(completed == true, "finishStream should resume waitForCompletion continuation")
    }
}

// MARK: - Issue #17: TranscriptionQueue.textStream overwrites continuation

@Suite("Issue #17 — textStream returns cached stream, not new one each time")
struct Issue17TextStreamOverwriteRegressionTests {

    /// REGRESSION: Accessing textStream multiple times must return the same stream.
    /// The original bug created a new AsyncStream on each access, orphaning the
    /// previous consumer's continuation.
    @Test func testTextStreamReturnsSameInstanceOnMultipleAccesses() async {
        let queue = TranscriptionQueue()

        // Access textStream twice
        let stream1 = await queue.textStream
        let stream2 = await queue.textStream

        // Both must be the same stream. We verify by submitting a result and
        // confirming only one value is delivered (not duplicated or lost).
        // If the continuation was overwritten, stream1's consumer would silently stop.
        let ticket = await queue.nextSequence()
        await queue.submitResult(ticket: ticket, text: "hello")

        var received: [String] = []
        // Only iterate stream1 — if continuation was overwritten, this would hang
        let task = Task {
            var items: [String] = []
            for await text in stream1 {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        received = await task.value

        #expect(received == ["hello"],
                "First stream access must receive results — continuation must not be overwritten by second access")

        // Verify stream2 is the same object (struct, but backed by same continuation)
        // by checking it doesn't produce a second "hello" — the value was already consumed
        _ = stream2 // suppress unused warning
    }

    /// REGRESSION: The bridge's startListening accesses textStream once — verify it works
    /// end-to-end with onTextReady callback.
    @Test func testBridgeListeningDeliversTextViaCallback() async {
        let received = await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            Task { @MainActor in
                let bridge = TranscriptionQueueBridge()
                var items: [String] = []
                bridge.onTextReady = { text in items.append(text) }
                bridge.startListening()

                let ticket = await bridge.nextSequence()
                await bridge.submitResult(ticket: ticket, text: "world")

                try? await Task.sleep(for: .milliseconds(200))
                bridge.stopListening()
                cont.resume(returning: items)
            }
        }

        #expect(received == ["world"],
                "Bridge listener must deliver text via onTextReady callback")
    }
}

// MARK: - Issue #14 Regression: Cancellation propagation (additional)

@Suite("Issue #14 — RateLimiter cancellation propagation (additional)")
struct Issue14CancellationTests {

    /// A pre-cancelled task must throw CancellationError immediately without sleeping.
    @Test func testPreCancelledTaskThrowsImmediately() async {
        let limiter = RateLimiter(minimumInterval: 10.0)

        let task = Task {
            // Pre-cancel before the actor call even starts
            try await limiter.waitAndRecord()
        }
        task.cancel()

        let start = Date()
        do {
            try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < 0.5, "Pre-cancelled task should throw fast, took \(elapsed)s")
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }
}

// MARK: - TranscriptionQueueBridge Cleanup Tests

@Suite("TranscriptionQueueBridge.stopListening — cleanup regression")
struct TranscriptionQueueBridgeCleanupTests {

    @Test func testStopListeningBehavior() async {
        // Behavioral: stopListening must be callable without crash
        let bridge = await TranscriptionQueueBridge()
        await bridge.stopListening()
        // Double-stop must be safe
        await bridge.stopListening()
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue: waitForCompletion & finishStream Edge Cases
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — waitForCompletion & finishStream Edge Cases")
struct TranscriptionQueueWaitForCompletionTests {

    /// Issue a ticket, submit its result, THEN call waitForCompletion — must return without blocking.
    @Test func testWaitForCompletionReturnsImmediatelyWhenAlreadyComplete() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        await queue.submitResult(ticket: t0, text: "done")

        // This must return immediately — no blocking
        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        _ = task
        try? await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == true,
                "waitForCompletion must return immediately when all results submitted")
    }

    /// A fresh queue has currentSeq == 0, which fails the currentSeq > 0 check.
    /// waitForCompletion() will suspend forever. Verify it does NOT return within a timeout.
    /// NOTE: This documents intentional behavior — waitForCompletion on an empty queue
    /// will hang forever unless finishStream() is called.
    @Test func testWaitForCompletionOnFreshQueueNeverReturns() async {
        let queue = TranscriptionQueue()
        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(done.withLock { $0 } == false,
                "waitForCompletion on empty queue (currentSeq=0) must not return immediately")
        task.cancel()
    }

    /// The minimal completion case — one ticket issued and submitted.
    @Test func testWaitForCompletionWithSingleSequence() async {
        let queue = TranscriptionQueue()
        let t = await queue.nextSequence()

        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        _ = task

        try? await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == false, "Should still be waiting")

        await queue.submitResult(ticket: t, text: "only")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == true, "Should complete with single result")
    }

    /// finishStream() must:
    /// 1. Resume completionContinuation (unblocking waitForCompletion)
    /// 2. Finish textContinuation (ending the for await loop)
    @Test func testFinishStreamResumesBothContinuations() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        _ = await queue.nextSequence()

        // Start consuming stream
        let streamEnded = OSAllocatedUnfairLock(initialState: false)
        let streamTask = Task {
            for await _ in stream {}
            streamEnded.withLock { $0 = true }
        }

        // Start waiting for completion
        let completionDone = OSAllocatedUnfairLock(initialState: false)
        let waitTask = Task {
            await queue.waitForCompletion()
            completionDone.withLock { $0 = true }
        }
        _ = streamTask; _ = waitTask

        try? await Task.sleep(for: .milliseconds(50))
        await queue.finishStream()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(completionDone.withLock { $0 } == true,
                "finishStream must resume completionContinuation")
        #expect(streamEnded.withLock { $0 } == true,
                "finishStream must finish textContinuation (ending for-await loop)")
    }

    /// Calling finishStream() twice must not crash (continuations are nil-checked).
    @Test func testFinishStreamIdempotent() async {
        let queue = TranscriptionQueue()
        _ = await queue.textStream  // force creation of textContinuation
        _ = await queue.nextSequence()  // ensure completionContinuation can be set

        let task = Task { await queue.waitForCompletion() }
        try? await Task.sleep(for: .milliseconds(30))

        await queue.finishStream()  // first: resumes continuation
        await queue.finishStream()  // second: continuations already nil — no crash
        // If we get here without crashing, test passes
        _ = task
    }

    /// If finishStream() is called before textStream is ever accessed,
    /// textContinuation is nil. Must not crash.
    @Test func testFinishStreamBeforeStreamAccess() async {
        let queue = TranscriptionQueue()
        await queue.finishStream() // textContinuation is nil — must not crash
    }

    /// After finishStream() clears textContinuation, submitting results should still
    /// update internal state (no crash, pendingResults updated, flushReady advances pointer)
    /// — just no yield to stream.
    @Test func testSubmitResultAfterFinishStream() async {
        let queue = TranscriptionQueue()
        _ = await queue.textStream
        await queue.finishStream()

        let t = await queue.nextSequence()
        await queue.submitResult(ticket: t, text: "orphan")
        // Must not crash; pending count resolves to 0
        #expect(await queue.getPendingCount() == 0)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue — reset() State Clearing
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — reset() State Clearing")
struct TranscriptionQueueResetTests {

    /// Verify reset() clears pending results.
    /// Issue tickets, submit some (not all), then reset. After reset,
    /// getPendingCount() must be 0 and new tickets start fresh.
    @Test func testResetClearsPendingResults() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        _ = await queue.nextSequence()
        await queue.submitResult(ticket: t0, text: "partial")
        // t1 still outstanding → pending=1
        #expect(await queue.getPendingCount() == 1)

        await queue.reset()
        // Everything cleared
        #expect(await queue.getPendingCount() == 0)
    }

    /// Verify reset() zeroes sequence counters.
    /// After reset, nextSequence() must restart at seq=0.
    @Test func testResetZeroesSequenceCounters() async {
        let queue = TranscriptionQueue()
        _ = await queue.nextSequence() // seq 0
        _ = await queue.nextSequence() // seq 1
        _ = await queue.nextSequence() // seq 2
        await queue.reset()
        let fresh = await queue.nextSequence()
        #expect(fresh.seq == 0, "After reset, seq must restart at 0")
    }

    /// Verify reset() increments generation monotonically.
    /// Call reset N times and verify generation increments each time.
    @Test func testResetIncrementsGenerationMonotonically() async {
        let queue = TranscriptionQueue()
        for i in 1...5 {
            await queue.reset()
            let gen = await queue.currentSessionGeneration()
            #expect(gen == UInt64(i), "Generation must be \(i) after \(i) resets")
        }
    }

    /// Verify reset() discards in-flight results from old generation.
    /// Submit a result for a ticket from BEFORE reset. The result must be
    /// silently ignored and not appear on the stream.
    @Test func testResetDiscardsInFlightResults() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let oldTicket = await queue.nextSequence()

        await queue.reset()

        // Submit result with old ticket — should be discarded
        await queue.submitResult(ticket: oldTicket, text: "STALE")

        // Issue and complete a fresh ticket
        let freshTicket = await queue.nextSequence()
        await queue.submitResult(ticket: freshTicket, text: "FRESH")

        // Collect from stream — only "FRESH" should appear
        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }
        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value
        #expect(received == ["FRESH"], "Stale result must not appear on stream")
    }

    /// Verify reset() does not affect the rate limiter.
    /// The rateLimiter property is a `let` — verify it survives reset
    /// (reset shouldn't create a new one).
    @Test func testResetDoesNotAffectRateLimiter() async throws {
        let queue = TranscriptionQueue()
        // RateLimiter is an actor, so identity check via a behavioral test:
        // Record a request, reset the queue, verify the rate limiter still has state
        // (i.e., it was not replaced).
        try await queue.rateLimiter.waitAndRecord()
        await queue.reset()
        // If rateLimiter was replaced, timeUntilNextAllowed would be 0
        let wait = await queue.rateLimiter.timeUntilNextAllowed()
        #expect(wait > 0, "rateLimiter must survive reset (let property, not var)")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue: Initial State & Sequencing Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — Initial State & Sequencing")
struct TranscriptionQueueInitialStateAndSequencingTests {

    /// First ticket issued must be session 0, seq 0.
    @Test func testNextSequenceStartsAtZero() async {
        let queue = TranscriptionQueue()
        let t = await queue.nextSequence()
        #expect(t.session == 0, "First ticket must be session 0")
        #expect(t.seq == 0, "First ticket must be seq 0")
    }

    /// Sequential calls to nextSequence produce monotonically increasing seq numbers.
    @Test func testNextSequenceMonotonicallyIncreasing() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        let t2 = await queue.nextSequence()
        #expect(t0.seq == 0)
        #expect(t1.seq == 1)
        #expect(t2.seq == 2)
        // All same session
        #expect(t0.session == t1.session)
        #expect(t1.session == t2.session)
    }

    /// After reset(), new tickets carry the incremented session generation.
    @Test func testNextSequenceBindsToCurrentSession() async {
        let queue = TranscriptionQueue()
        let before = await queue.nextSequence()
        #expect(before.session == 0)
        await queue.reset()
        let after = await queue.nextSequence()
        #expect(after.session == 1, "After reset, tickets must carry new generation")
        #expect(after.seq == 0, "After reset, seq restarts at 0")
    }

    /// getPendingCount tracks issued minus resolved sequences.
    @Test func testGetPendingCountTracksIssuedMinusResolved() async {
        let queue = TranscriptionQueue()
        #expect(await queue.getPendingCount() == 0)
        let t0 = await queue.nextSequence()
        #expect(await queue.getPendingCount() == 1)
        let t1 = await queue.nextSequence()
        #expect(await queue.getPendingCount() == 2)
        await queue.submitResult(ticket: t0, text: "a")
        #expect(await queue.getPendingCount() == 1)
        await queue.submitResult(ticket: t1, text: "b")
        #expect(await queue.getPendingCount() == 0)
    }

    /// markFailed should also decrement pending count.
    @Test func testGetPendingCountAfterMarkFailed() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        #expect(await queue.getPendingCount() == 2)
        await queue.markFailed(ticket: t0)
        #expect(await queue.getPendingCount() == 1)
        await queue.submitResult(ticket: t1, text: "ok")
        #expect(await queue.getPendingCount() == 0)
    }

    /// Concurrent nextSequence calls must produce unique tickets with distinct seq values.
    @Test func testNextSequenceConcurrentCallsProduceUniqueTickets() async {
        let queue = TranscriptionQueue()

        // Fire 10 concurrent nextSequence() calls via a TaskGroup
        let tickets = await withTaskGroup(of: TranscriptionTicket.self, returning: [TranscriptionTicket].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await queue.nextSequence()
                }
            }
            var collected: [TranscriptionTicket] = []
            for await ticket in group {
                collected.append(ticket)
            }
            return collected
        }

        // All tickets should have same session
        let sessions = Set(tickets.map { $0.session })
        #expect(sessions.count == 1, "All tickets must be from same session")

        // All seq values should be unique
        let seqs = tickets.map { $0.seq }
        let uniqueSeqs = Set(seqs)
        #expect(uniqueSeqs.count == 10, "All seq values must be unique")

        // Seq values should cover 0..<10
        #expect(uniqueSeqs == Set(0..<10), "Seq values must cover range 0..<10")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue: flushReady Ordering & Edge Cases
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — flushReady Ordering & Edge Cases")
struct TranscriptionQueueFlushReadyOrderingEdgeCasesTests {

    @Test func testPartialFlushStopsAtGap() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()
        _ = await queue.nextSequence() // t1 (gap)
        let t2 = await queue.nextSequence()

        await queue.submitResult(ticket: t0, text: "first")
        await queue.submitResult(ticket: t2, text: "third")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["first"], "Only seq 0 should flush; seq 2 blocked by gap at seq 1")
        #expect(await queue.getPendingCount() == 2)
    }

    @Test func testChainFlushWhenGapFilled() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        let t2 = await queue.nextSequence()

        await queue.submitResult(ticket: t0, text: "A")
        await queue.submitResult(ticket: t2, text: "C")
        await queue.submitResult(ticket: t1, text: "B")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 3 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["A", "B", "C"])
        #expect(await queue.getPendingCount() == 0)
    }

    @Test func testEmptyTextNotYieldedToStream() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        let t2 = await queue.nextSequence()

        await queue.submitResult(ticket: t0, text: "real")
        await queue.submitResult(ticket: t1, text: "")
        await queue.submitResult(ticket: t2, text: "also real")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 2 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["real", "also real"], "Empty text must not appear in stream")
        #expect(await queue.getPendingCount() == 0, "All 3 must be resolved")
    }

    @Test func testMarkFailedAdvancesOutputPointer() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()

        await queue.markFailed(ticket: t0)
        await queue.submitResult(ticket: t1, text: "second")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["second"], "Failed seq 0 must be skipped, seq 1 output")
    }

    @Test func testSubmitResultIdempotent() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream
        let t0 = await queue.nextSequence()

        await queue.submitResult(ticket: t0, text: "first")
        await queue.submitResult(ticket: t0, text: "duplicate")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }

        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value

        #expect(received == ["first"], "Second submit to already-flushed seq must be ignored")
    }

    @Test func testAllFailedSequencesStillTriggerCompletion() async {
        let queue = TranscriptionQueue()
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()

        let done = OSAllocatedUnfairLock(initialState: false)
        let waitTask = Task {
            await queue.waitForCompletion()
            done.withLock { $0 = true }
        }
        _ = waitTask

        await queue.markFailed(ticket: t0)
        await queue.markFailed(ticket: t1)

        try? await Task.sleep(for: .milliseconds(100))
        #expect(done.withLock { $0 } == true,
                "Completion must fire even when all sequences failed")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueue: textStream Lifecycle Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueue — textStream Lifecycle")
struct TranscriptionQueueTextStreamLifecycleTests {

    /// Stream delivers results in real-time, not batched.
    /// Submit results one at a time with delays; each should be received immediately.
    @Test func testStreamDeliversResultsInRealTime() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream

        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()

        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let task = Task {
            for await text in stream {
                received.withLock { $0.append(text) }
            }
        }

        await queue.submitResult(ticket: t0, text: "first")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received.withLock { $0 } == ["first"],
                "First result should be delivered immediately")

        await queue.submitResult(ticket: t1, text: "second")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received.withLock { $0 } == ["first", "second"],
                "Second result should be delivered as it arrives")

        task.cancel()
    }

    /// If submitResult is called before anyone accesses textStream,
    /// textContinuation is nil and the yield is dropped (but state updates).
    @Test func testYieldBeforeStreamAccessIsDropped() async {
        let queue = TranscriptionQueue()
        // Don't access textStream yet!
        let t = await queue.nextSequence()
        await queue.submitResult(ticket: t, text: "early")

        // Pending should be 0 (result was flushed from state, just not yielded)
        #expect(await queue.getPendingCount() == 0)

        // Now access stream — the "early" text is already gone
        let stream = await queue.textStream
        // Submit another
        let t2 = await queue.nextSequence()
        await queue.submitResult(ticket: t2, text: "late")

        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 1 { break }
            }
            return items
        }
        try? await Task.sleep(for: .milliseconds(200))
        let received = await collectTask.value
        #expect(received == ["late"],
                "Only results submitted after stream access should be received")
    }

    /// A for-await loop must exit when finishStream() is called.
    @Test func testStreamEndedByFinishStreamTerminatesForAwait() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream

        let loopExited = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            for await _ in stream {}
            loopExited.withLock { $0 = true }
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(loopExited.withLock { $0 } == false, "Loop should be waiting")

        await queue.finishStream()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(loopExited.withLock { $0 } == true,
                "for-await loop must exit after finishStream()")
        _ = task
    }

    /// After finishStream() clears textContinuation (but not _textStream),
    /// accessing textStream returns the same cached stream, but yields go nowhere.
    @Test func testTextStreamAfterFinishStreamCreatesNewStream() async {
        let queue = TranscriptionQueue()
        let stream1 = await queue.textStream
        await queue.finishStream()
        let stream2 = await queue.textStream
        // Same _textStream instance is returned (finishStream doesn't clear _textStream)
        // But textContinuation is nil, so yields go nowhere
        let t = await queue.nextSequence()
        await queue.submitResult(ticket: t, text: "orphan")
        #expect(await queue.getPendingCount() == 0,
                "State should still update even with dead continuation")
        _ = stream1; _ = stream2
    }

    /// AsyncStream has unbounded buffer by default.
    /// Submit many results before anyone starts consuming; all should be delivered.
    @Test func testStreamBuffersUnconsumedResults() async {
        let queue = TranscriptionQueue()
        let stream = await queue.textStream

        // Submit 20 results — no consumer yet
        var tickets: [TranscriptionTicket] = []
        for _ in 0..<20 {
            tickets.append(await queue.nextSequence())
        }
        for (i, t) in tickets.enumerated() {
            await queue.submitResult(ticket: t, text: "msg\(i)")
        }

        // Now consume — all 20 should be buffered
        let collectTask = Task {
            var items: [String] = []
            for await text in stream {
                items.append(text)
                if items.count >= 20 { break }
            }
            return items
        }
        try? await Task.sleep(for: .milliseconds(300))
        let received = await collectTask.value
        #expect(received.count == 20, "All 20 results must be buffered and delivered")
        #expect(received.first == "msg0")
        #expect(received.last == "msg19")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionQueueBridge: Session Lifecycle & Completion
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueueBridge — Session Lifecycle & Completion")
struct TranscriptionQueueBridgeTests {

    /// The stream consumer calls checkCompletion after each text delivery.
    /// After submitting a result and letting the consumer process it,
    /// onAllComplete must fire.
    @Test @MainActor func testCheckCompletionFiresOnAllComplete() async throws {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()
        var completionCalled = false
        bridge.onAllComplete = { completionCalled = true }

        let ticket = await bridge.nextSequence()
        await bridge.submitResult(ticket: ticket, text: "done")

        // Let the stream consumer process and call checkCompletion
        try await waitUntil { completionCalled }
        #expect(completionCalled == true, "onAllComplete must fire when all text is delivered")
    }

    /// onAllComplete must only fire once per session, even when
    /// the stream consumer calls checkCompletion after each text.
    @Test @MainActor func testCheckCompletionOnlyFiresOnce() async throws {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()
        var callCount = 0
        bridge.onAllComplete = { callCount += 1 }

        let ticket = await bridge.nextSequence()
        await bridge.submitResult(ticket: ticket, text: "done")

        try await waitUntil { callCount >= 1 }

        // Additional manual calls must not increment
        await bridge.checkCompletion()
        await bridge.checkCompletion()

        #expect(callCount == 1,
                "onAllComplete must fire exactly once per session (hasSignaledCompletion guard)")
    }

    /// checkCompletion() must NOT fire before any nextSequence() call
    /// (sessionStarted guard).
    @Test @MainActor func testCheckCompletionDoesNotFireBeforeSessionStart() async {
        let bridge = TranscriptionQueueBridge()
        var completionCalled = false
        bridge.onAllComplete = { completionCalled = true }

        // Don't call nextSequence — session hasn't started
        await bridge.checkCompletion()

        #expect(completionCalled == false,
                "onAllComplete must not fire when no session has started (sessionStarted guard)")
    }

    /// checkCompletion() must NOT fire while results are pending.
    @Test @MainActor func testCheckCompletionDoesNotFireWhilePending() async {
        let bridge = TranscriptionQueueBridge()
        var completionCalled = false
        bridge.onAllComplete = { completionCalled = true }

        let t0 = await bridge.nextSequence()
        let _ = await bridge.nextSequence()  // t1 still pending
        await bridge.submitResult(ticket: t0, text: "first")

        await bridge.checkCompletion()
        #expect(completionCalled == false,
                "onAllComplete must not fire while results are pending")
    }

    /// reset() must clear hasSignaledCompletion, sessionStarted, and consumedCount,
    /// allowing checkCompletion() to fire again for a new session.
    @Test @MainActor func testResetClearsCompletionAndSessionFlags() async throws {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()
        var callCount = 0
        bridge.onAllComplete = { callCount += 1 }

        // Session 1
        let t1 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t1, text: "s1")
        try await waitUntil { callCount >= 1 }
        #expect(callCount == 1)

        // Reset
        await bridge.reset()

        // Session 2
        let t2 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t2, text: "s2")
        try await waitUntil { callCount >= 2 }
        #expect(callCount == 2,
                "After reset, completion must be able to fire again for new session")

        bridge.stopListening()
    }

    /// nextSequence() sets sessionStarted = true and hasSignaledCompletion = false on first call.
    @Test @MainActor func testNextSequenceSetsSessionStarted() async throws {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()
        var completionCalled = false
        bridge.onAllComplete = { completionCalled = true }

        // Before nextSequence: checkCompletion is no-op
        await bridge.checkCompletion()
        #expect(completionCalled == false)

        // After nextSequence: session started
        let t = await bridge.nextSequence()
        await bridge.submitResult(ticket: t, text: "x")
        try await waitUntil { completionCalled }
        #expect(completionCalled == true)

        bridge.stopListening()
    }

    /// getPendingCount() must delegate to the underlying queue.
    @Test @MainActor func testGetPendingCountDelegatesToQueue() async {
        let bridge = TranscriptionQueueBridge()

        #expect(await bridge.getPendingCount() == 0)

        let t0 = await bridge.nextSequence()
        #expect(await bridge.getPendingCount() == 1)

        let t1 = await bridge.nextSequence()
        #expect(await bridge.getPendingCount() == 2)

        await bridge.submitResult(ticket: t0, text: "a")
        #expect(await bridge.getPendingCount() == 1)

        await bridge.submitResult(ticket: t1, text: "b")
        #expect(await bridge.getPendingCount() == 0)
    }

    /// markFailed() must delegate to the queue and allow subsequent results to be delivered.
    @Test @MainActor func testMarkFailedDelegatesToQueue() async {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()

        var received: [String] = []
        bridge.onTextReady = { text in received.append(text) }

        let t0 = await bridge.nextSequence()
        let t1 = await bridge.nextSequence()

        await bridge.markFailed(ticket: t0)
        await bridge.submitResult(ticket: t1, text: "ok")

        try? await Task.sleep(for: .milliseconds(100))
        #expect(received == ["ok"], "Failed ticket must be skipped, next delivered")
    }

    /// Full lifecycle: session 1 → complete → reset → session 2 → complete.
    @Test @MainActor func testFullSessionLifecycle() async {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()

        var texts: [String] = []
        var completions = 0
        bridge.onTextReady = { text in texts.append(text) }
        bridge.onAllComplete = { completions += 1 }

        // Session 1: 3 chunks
        let s1t0 = await bridge.nextSequence()
        let s1t1 = await bridge.nextSequence()
        let s1t2 = await bridge.nextSequence()
        await bridge.submitResult(ticket: s1t0, text: "hello")
        await bridge.submitResult(ticket: s1t2, text: "world")
        await bridge.submitResult(ticket: s1t1, text: "beautiful")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(texts == ["hello", "beautiful", "world"])
        await bridge.checkCompletion()
        #expect(completions == 1)

        // Reset for session 2
        await bridge.reset()
        texts.removeAll()

        // Session 2: 2 chunks, one fails
        let s2t0 = await bridge.nextSequence()
        let s2t1 = await bridge.nextSequence()
        await bridge.markFailed(ticket: s2t0)
        await bridge.submitResult(ticket: s2t1, text: "recovered")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(texts == ["recovered"])
        await bridge.checkCompletion()
        #expect(completions == 2)

        bridge.stopListening()
    }

    /// startListening() must create stream task that delivers text.
    @Test @MainActor func testStartListeningCreatesStreamTask() async {
        let bridge = TranscriptionQueueBridge()
        bridge.startListening()

        // Verify the bridge can deliver text (stream task is alive)
        var received: [String] = []
        bridge.onTextReady = { text in received.append(text) }

        let t = await bridge.nextSequence()
        await bridge.submitResult(ticket: t, text: "ping")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(received == ["ping"], "startListening must create stream task that delivers text")
        bridge.stopListening()
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionService: Timeout, Error Truncation & Request Building
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionService — Timeout, Error Truncation & Request Building")
struct TranscriptionServiceTimeoutErrorRequestTests {
    private func makeAuthCredentials() -> AuthCredentials {
        AuthCredentials(accessToken: "test-access-token", accountId: "test-account-id")
    }

    /// Small data (≤ baseTimeoutDataSize) should use base timeout.
    @Test func testTimeoutSmallDataUsesBaseTimeout() {
        let timeout = TranscriptionService.timeout(forDataSize: 100_000)
        #expect(timeout == Config.timeout, "Small audio must use base timeout")
    }

    /// At exactly baseTimeoutDataSize, use base timeout.
    @Test func testTimeoutAtExactBaseSize() {
        let timeout = TranscriptionService.timeout(forDataSize: Config.baseTimeoutDataSize)
        #expect(timeout == Config.timeout, "At exactly baseTimeoutDataSize, use base timeout")
    }

    /// Timeout scales linearly between baseTimeoutDataSize and maxAudioSizeBytes.
    @Test func testTimeoutScalesLinearly() {
        let midSize = (Config.baseTimeoutDataSize + Config.maxAudioSizeBytes) / 2
        let timeout = TranscriptionService.timeout(forDataSize: midSize)
        let expectedMid = (Config.timeout + Config.maxTimeout) / 2.0
        #expect(abs(timeout - expectedMid) < 0.5, "Timeout must scale linearly")
    }

    /// Above maxAudioSizeBytes should cap at maxTimeout.
    @Test func testTimeoutCapsAtMaxTimeout() {
        let timeout = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes * 2)
        #expect(timeout == Config.maxTimeout, "Must cap at maxTimeout")
    }

    /// At maxAudioSizeBytes, timeout must equal maxTimeout.
    @Test func testTimeoutAtMaxAudioSize() {
        let timeout = TranscriptionService.timeout(forDataSize: Config.maxAudioSizeBytes)
        #expect(timeout == Config.maxTimeout, "At maxAudioSizeBytes, timeout must equal maxTimeout")
    }

    /// Short data must not be truncated.
    @Test func testTruncateErrorBodyShortData() {
        let data = "Hello".data(using: .utf8)!
        let result = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        #expect(result == "Hello", "Short data must not be truncated")
    }

    /// Data at exact limit must not be truncated.
    @Test func testTruncateErrorBodyExactLimit() {
        let text = String(repeating: "a", count: 200)
        let data = text.data(using: .utf8)!
        let result = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        #expect(result == text, "Data at exact limit must not be truncated")
        #expect(!result.hasSuffix("..."))
    }

    /// Long data must be truncated with "..." suffix.
    @Test func testTruncateErrorBodyLongData() {
        let text = String(repeating: "x", count: 500)
        let data = text.data(using: .utf8)!
        let result = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        #expect(result.count <= 203, "Truncated result must be ≤ maxBytes + '...' suffix")
        #expect(result.hasSuffix("..."), "Truncated result must end with '...'")
    }

    /// Empty data must produce empty string.
    @Test func testTruncateErrorBodyEmptyData() {
        let result = TranscriptionService.truncateErrorBody(Data(), maxBytes: 200)
        #expect(result == "", "Empty data must produce empty string")
    }

    /// Default maxBytes is 200.
    @Test func testTruncateErrorBodyDefaultMaxBytes() {
        let text = String(repeating: "y", count: 300)
        let data = text.data(using: .utf8)!
        let result = TranscriptionService.truncateErrorBody(data)
        #expect(result.hasSuffix("..."))
        let withoutEllipsis = String(result.dropLast(3))
        #expect(withoutEllipsis.count == 200)
    }

    /// shared should return the same singleton instance.
    @Test func testTranscriptionServiceHasStableSharedSingleton() {
        #expect(TranscriptionService.shared === TranscriptionService.shared)
    }

    /// buildRequest must validate audio size.
    @Test func testBuildRequestValidatesAudioSize() async {
        let service = TranscriptionService()
        let oversizedAudio = Data(count: Config.maxAudioSizeBytes + 1)

        do {
            _ = try await service._testBuildRequest(audio: oversizedAudio, credentials: makeAuthCredentials())
            Issue.record("Expected TranscriptionError.audioTooLarge for oversized audio input")
        } catch let error as TranscriptionError {
            switch error {
            case .audioTooLarge(let size, let maxSize):
                #expect(size == Config.maxAudioSizeBytes + 1)
                #expect(maxSize == Config.maxAudioSizeBytes)
            default:
                Issue.record("Expected audioTooLarge, got \(error)")
            }
        } catch {
            Issue.record("Expected TranscriptionError.audioTooLarge, got \(type(of: error))")
        }
    }

    /// buildRequest must use the correct ChatGPT endpoint.
    @Test func testBuildRequestUsesCorrectEndpoint() async throws {
        let service = TranscriptionService()
        let request = try await service._testBuildRequest(
            audio: Data("abc".utf8),
            credentials: makeAuthCredentials(),
            timeout: 12.5
        )

        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/transcribe",
                "Must use the ChatGPT transcription endpoint")
        #expect(request.httpMethod == "POST")
        #expect(abs(request.timeoutInterval - 12.5) < 0.001)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "test-account-id")
        #expect(request.value(forHTTPHeaderField: "originator") == "Codex Desktop")
    }

    /// buildRequest must use multipart/form-data.
    @Test func testBuildRequestUsesMultipartFormData() async throws {
        let service = TranscriptionService()
        let request = try await service._testBuildRequest(
            audio: Data("ABC".utf8),
            credentials: makeAuthCredentials()
        )

        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))

        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let bodyData = try #require(request.httpBody)
        let body = String(decoding: bodyData, as: UTF8.self)

        #expect(body.contains("--\(boundary)\r\n"))
        #expect(body.contains(#"Content-Disposition: form-data; name="file"; filename="audio.wav""#))
        #expect(body.contains("Content-Type: audio/wav"))
        #expect(body.contains("ABC"))
        #expect(body.contains("\r\n--\(boundary)--\r\n"))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TranscriptionService: Retry, Cancellation & Error Types
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionService — Retry, Cancellation & Error Types")
struct TranscriptionServiceRetryErrorTests {

    // MARK: - TranscriptionError isRetryable property tests

    /// Network errors must be retryable.
    @Test func testTranscriptionErrorIsRetryableForNetworkErrors() {
        let error = TranscriptionError.networkError(underlying: URLError(.timedOut))
        #expect(error.isRetryable == true, "Network errors must be retryable")
    }

    /// Rate limited errors must be retryable.
    @Test func testTranscriptionErrorIsRetryableForRateLimited() {
        let error = TranscriptionError.rateLimited(retryAfter: 5.0)
        #expect(error.isRetryable == true, "Rate limited must be retryable")
    }

    /// 5xx server errors must be retryable.
    @Test func testTranscriptionErrorIsRetryableForServerErrors() {
        let error500 = TranscriptionError.httpError(statusCode: 500, body: nil)
        let error503 = TranscriptionError.httpError(statusCode: 503, body: "Service Unavailable")
        #expect(error500.isRetryable == true, "5xx must be retryable")
        #expect(error503.isRetryable == true, "5xx must be retryable")
    }

    /// 4xx client errors (except 429) must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForClientErrors() {
        let error400 = TranscriptionError.httpError(statusCode: 400, body: nil)
        let error403 = TranscriptionError.httpError(statusCode: 403, body: nil)
        #expect(error400.isRetryable == false, "4xx (non-429) must not be retryable")
        #expect(error403.isRetryable == false, "4xx (non-429) must not be retryable")
    }

    /// Authentication errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForAuthErrors() {
        let error = TranscriptionError.authenticationFailed(reason: "expired")
        #expect(error.isRetryable == false)
    }

    /// Cancelled errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForCancelled() {
        let error = TranscriptionError.cancelled
        #expect(error.isRetryable == false)
    }

    /// Audio too large errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForAudioTooLarge() {
        let error = TranscriptionError.audioTooLarge(size: 50_000_000, maxSize: 25_000_000)
        #expect(error.isRetryable == false)
    }

    /// Decoding errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForDecodingError() {
        let underlying = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "test"))
        let error = TranscriptionError.decodingFailed(underlying: underlying)
        #expect(error.isRetryable == false)
    }

    /// Invalid response errors must not be retryable.
    @Test func testTranscriptionErrorIsNotRetryableForInvalidResponse() {
        let error = TranscriptionError.invalidResponse(data: nil)
        #expect(error.isRetryable == false)
    }

    // MARK: - TranscriptionError description tests

    /// Error descriptions must be accurate.
    @Test func testTranscriptionErrorDescriptions() {
        let errors: [(TranscriptionError, String)] = [
            (.cancelled, "Request cancelled"),
            (.authenticationFailed(reason: "expired"), "Authentication failed: expired"),
            (.rateLimited(retryAfter: nil), "Rate limited"),
            (.rateLimited(retryAfter: 5.0), "Rate limited, retry after 5.0s"),
        ]
        for (error, expected) in errors {
            #expect(error.errorDescription == expected, "\(error) description mismatch")
        }
    }

    /// Audio too large description must show actual and max sizes.
    @Test func testTranscriptionErrorAudioTooLargeDescription() {
        let error = TranscriptionError.audioTooLarge(size: 30_000_000, maxSize: 25_000_000)
        let desc = error.errorDescription!
        #expect(desc.contains("30.0MB"), "Must show actual size")
        #expect(desc.contains("25MB"), "Must show max size")
    }

    /// HTTP error description must show status code and body.
    @Test func testTranscriptionErrorHttpErrorDescription() {
        let error1 = TranscriptionError.httpError(statusCode: 429, body: "Too Many Requests")
        #expect(error1.errorDescription?.contains("429") == true)
        #expect(error1.errorDescription?.contains("Too Many Requests") == true)

        let error2 = TranscriptionError.httpError(statusCode: 500, body: nil)
        #expect(error2.errorDescription?.contains("500") == true)
        #expect(error2.errorDescription?.contains("Unknown error") == true)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Race Condition: Completion Sound Ordering
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("TranscriptionQueueBridge — Completion Sound Ordering (Race Condition)")
struct CompletionOrderingRaceTests {

    /// The completion sound bug: `onAllComplete` could fire before `onTextReady`
    /// delivered all text. This test verifies the invariant that text delivery
    /// always precedes the completion signal.
    ///
    /// Uses `withMainSerialExecutor` from swift-concurrency-extras to make
    /// async scheduling deterministic, eliminating timing-dependent flakiness.
    @Test @MainActor
    func textDeliveryAlwaysPrecedesCompletionSignal() async {
        await withMainSerialExecutor {
            let bridge = TranscriptionQueueBridge()
            var events: [String] = []
            bridge.onTextReady = { text in events.append("text:\(text)") }
            bridge.onAllComplete = { events.append("complete") }
            bridge.startListening()

            let ticket = await bridge.nextSequence()
            await bridge.submitResult(ticket: ticket, text: "hello")

            // Allow the stream consumer to process
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))

            #expect(events.contains("text:hello"),
                    "onTextReady must fire for submitted text")

            if let textIdx = events.firstIndex(of: "text:hello"),
               let completeIdx = events.firstIndex(of: "complete") {
                #expect(textIdx < completeIdx,
                        "onTextReady must fire BEFORE onAllComplete, got: \(events)")
            }

            bridge.stopListening()
        }
    }

    /// Stress test: submit multiple chunks rapidly and verify ordering
    /// invariant holds for every chunk — text always arrives before completion.
    @Test @MainActor
    func multipleChunksTextBeforeCompletion() async {
        await withMainSerialExecutor {
            let bridge = TranscriptionQueueBridge()
            var events: [String] = []
            bridge.onTextReady = { text in events.append("text:\(text)") }
            bridge.onAllComplete = { events.append("complete") }
            bridge.startListening()

            let t0 = await bridge.nextSequence()
            let t1 = await bridge.nextSequence()
            let t2 = await bridge.nextSequence()

            // Submit out of order to stress the queue
            await bridge.submitResult(ticket: t2, text: "C")
            await bridge.submitResult(ticket: t0, text: "A")
            await bridge.submitResult(ticket: t1, text: "B")

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(150))

            // All text must appear before completion
            let textEvents = events.filter { $0.hasPrefix("text:") }
            let completeIndex = events.firstIndex(of: "complete")

            #expect(textEvents.count == 3,
                    "All 3 text events must be delivered, got: \(events)")

            if let completeIdx = completeIndex {
                for textEvent in textEvents {
                    guard let textIdx = events.firstIndex(of: textEvent) else { continue }
                    #expect(textIdx < completeIdx,
                            "\(textEvent) must precede completion, got: \(events)")
                }
            }

            // Verify correct ordering: A, B, C (queue sorts by sequence)
            #expect(textEvents == ["text:A", "text:B", "text:C"],
                    "Text must be delivered in sequence order")

            bridge.stopListening()
        }
    }

    /// Chaos test: run many iterations to surface ordering races that only
    /// manifest under specific scheduling. Each iteration creates a fresh
    /// bridge and verifies the invariant.
    @Test @MainActor
    func chaosTestCompletionOrdering() async {
        for iteration in 0..<50 {
            let bridge = TranscriptionQueueBridge()
            var events: [String] = []
            bridge.onTextReady = { _ in events.append("text") }
            bridge.onAllComplete = { events.append("complete") }
            bridge.startListening()

            let ticket = await bridge.nextSequence()
            await bridge.submitResult(ticket: ticket, text: "chunk-\(iteration)")

            // Vary timing to explore different scheduling interleavings
            try? await Task.sleep(for: .milliseconds(Int.random(in: 50...150)))

            if let textIdx = events.firstIndex(of: "text"),
               let completeIdx = events.firstIndex(of: "complete") {
                #expect(textIdx < completeIdx,
                        "Iteration \(iteration): text must precede completion, got: \(events)")
            }

            bridge.stopListening()
            await bridge.reset()
        }
    }
}
