import FluidAudio
import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - VAD Model Cache Tests

@Suite("VADModelCache — warm-up and caching", .serialized)
struct VADModelCacheTests {

    @Test(.enabled(if: VADModelTestSupport.integrationTestsEnabled()))
    func testWarmUpIsIdempotent() async {
        // Calling warmUp multiple times must not crash or create duplicate tasks.
        // We can't observe private state, but we verify no throwing/crash.
        await VADModelCache.shared.warmUp()
        await VADModelCache.shared.warmUp()
        await VADModelCache.shared.warmUp()
        // If we reach here without crash, idempotency holds.
    }

    @Test(.enabled(if: VADModelTestSupport.integrationTestsEnabled()))
    func testGetManagerSucceedsOnAppleSilicon() async throws {
        // Verify that getManager can actually create/return a manager on supported platforms

        // This should succeed without throwing
        let manager = try await VADModelCache.shared.getManager(threshold: 0.5)

        // Verify the manager was actually created (check identity is stable)
        #expect(type(of: manager) == VadManager.self, "getManager must return a VadManager instance")
    }

    @Test(.enabled(if: VADModelTestSupport.integrationTestsEnabled()))
    func testGetManagerReturnsSameInstance() async throws {
        // Two sequential calls with the same threshold must return the identical
        // cached instance. Uses a private cache to avoid interference from other
        // suites that touch VADModelCache.shared with different thresholds.
        let cache = VADModelCache()
        let m1 = try await cache.getManager(threshold: 0.5)
        let m2 = try await cache.getManager(threshold: 0.5)
        #expect(m1 === m2, "getManager must return the same cached instance")
    }

    @Test func testGetManagerRetriesAfterFailedLoad() async {
        // Regression test: a failed load must NOT be cached forever. Before the
        // fix, getManager's cold-path Task had no catch, so warmUpTask kept
        // pointing at the failed task and every subsequent call re-awaited
        // (and rethrew from) that same task without ever invoking the factory
        // again. With the fix, a failure clears warmUpTask so the next call
        // attempts a fresh load.
        actor CallCounter {
            private(set) var count = 0
            func increment() -> Int {
                count += 1
                return count
            }
        }
        struct SyntheticLoadError: Error {}

        let counter = CallCounter()
        let cache = VADModelCache(managerFactory: { _ in
            _ = await counter.increment()
            throw SyntheticLoadError()
        })

        var firstThrew = false
        do {
            _ = try await cache.getManager(threshold: 0.5)
        } catch {
            firstThrew = true
        }
        #expect(firstThrew, "first getManager call must throw")
        let countAfterFirst = await counter.count
        #expect(countAfterFirst == 1, "factory must be invoked exactly once for the first call")

        var secondThrew = false
        do {
            _ = try await cache.getManager(threshold: 0.5)
        } catch {
            secondThrew = true
        }
        #expect(secondThrew, "second getManager call must also throw")
        let countAfterSecond = await counter.count
        #expect(
            countAfterSecond == 2,
            "factory must be invoked again on retry; a stuck cache would leave the count at 1"
        )
    }
}


extension VADModelCacheTests {
    @Test func cancelledLoadRemainsTrackedUntilNativeWorkEnds() async throws {
        actor Gate {
            var waiter: CheckedContinuation<Void, Never>?
            var calls = 0
            func wait() async { calls += 1; await withCheckedContinuation { waiter = $0 } }
            func open() { waiter?.resume(); waiter = nil }
        }
        struct SyntheticFailure: Error {}
        let gate = Gate()
        let cache = VADModelCache(managerFactory: { _ in
            await gate.wait()
            throw SyntheticFailure()
        })
        await cache.warmUp()
        try await waitUntilAsync { await gate.calls == 1 }
        await cache.unload()
        #expect(await cache.snapshot().isLoading)
        #expect(!(await cache.snapshot().isLoaded))
        await #expect(throws: LocalModelError.busy) { try await cache.load() }
        await gate.open()
        try await waitUntilAsync { !(await cache.snapshot().isLoading) }
        #expect(!(await cache.snapshot().isLoaded))
    }
}


extension VADModelCacheTests {
    @Test func explicitLoadCancellationReturnsBeforeNonCooperativeNativeWork() async throws {
        actor Gate {
            var waiter: CheckedContinuation<Void, Never>?
            var started = false
            var returned = false
            func wait() async { started = true; await withCheckedContinuation { waiter = $0 } }
            func open() { waiter?.resume(); waiter = nil }
            func finish() { returned = true }
        }
        struct SyntheticFailure: Error {}
        let gate = Gate()
        let cache = VADModelCache(managerFactory: { _ in await gate.wait(); throw SyntheticFailure() })
        let task = Task {
            do { try await cache.load() } catch { }
            await gate.finish()
        }
        try await waitUntilAsync { await gate.started }
        task.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gate.returned)
        #expect(await cache.snapshot().isLoading)
        await gate.open()
        await task.value
        try await waitUntilAsync { !(await cache.snapshot().isLoading) }
    }
}


extension VADModelCacheTests {
    @Test(.enabled(if: VADModelTestSupport.integrationTestsEnabled()))
    func activeProcessorLeaseRemainsVisibleAfterCacheUnloading() async throws {
        let cache = VADModelCache()
        let lease = try await cache.acquireManager(threshold: 0.5)
        #expect(await cache.snapshot().isInUse)
        await cache.unload()
        #expect(!(await cache.snapshot().isLoaded))
        #expect(await cache.snapshot().isInUse)
        let result = try await lease.manager.process([Float](repeating: 0, count: 4096))
        #expect(!result.isEmpty)
        await lease.release()
        #expect(!(await cache.snapshot().isInUse))
    }
}

extension VADModelCacheTests {
    @Test(.enabled(if: VADModelTestSupport.integrationTestsEnabled()))
    func idleExpiryKeepsFilesAndNeverUnloadsAnActiveProcessorLease() async throws {
        let cache = VADModelCache()
        await cache.setIdleDuration(.milliseconds(30))
        let lease = try await cache.acquireManager(threshold: 0.5)
        try await Task.sleep(for: .milliseconds(80))
        let active = await cache.snapshot()
        #expect(active.isLoaded && active.isInUse)
        await lease.release()
        try await waitUntilAsync { !(await cache.snapshot().isLoaded) }
        #expect(!(await cache.snapshot().isInUse))
        #expect((try? LocalVADAssets.verifiedDirectory()) != nil)
    }
}
