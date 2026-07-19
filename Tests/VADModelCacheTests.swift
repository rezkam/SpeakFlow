import FluidAudio
import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - VAD Model Cache Tests

@Suite("VADModelCache — warm-up and caching", .serialized)
struct VADModelCacheTests {

    @Test func testWarmUpIsIdempotent() async {
        // Calling warmUp multiple times must not crash or create duplicate tasks.
        // We can't observe private state, but we verify no throwing/crash.
        await VADModelCache.shared.warmUp()
        await VADModelCache.shared.warmUp()
        await VADModelCache.shared.warmUp()
        // If we reach here without crash, idempotency holds.
    }

    @Test func testGetManagerSucceedsOnAppleSilicon() async throws {
        // Verify that getManager can actually create/return a manager on supported platforms
        guard VADProcessor.isAvailable else { return }

        // This should succeed without throwing
        let manager: VadManager
        do {
            manager = try await VADModelCache.shared.getManager(threshold: 0.5)
        } catch let error as NSError where error.domain == NSURLErrorDomain
            && (error.code == NSURLErrorCancelled || error.code == NSURLErrorNotConnectedToInternet) {
            // Network unavailable or request cancelled by sandbox (e.g. macOS 26 CI).
            // The model download requires outbound network; skip gracefully.
            return
        }

        // Verify the manager was actually created (check identity is stable)
        #expect(type(of: manager) == VadManager.self, "getManager must return a VadManager instance")
    }

    @Test func testGetManagerReturnsSameInstance() async throws {
        // Two sequential calls with the same threshold must return the identical
        // cached instance. Uses a private cache to avoid interference from other
        // suites that touch VADModelCache.shared with different thresholds.
        guard VADProcessor.isAvailable else { return }
        let cache = VADModelCache()
        let m1: VadManager
        let m2: VadManager
        do {
            m1 = try await cache.getManager(threshold: 0.5)
            m2 = try await cache.getManager(threshold: 0.5)
        } catch let error as NSError where error.domain == NSURLErrorDomain
            && (error.code == NSURLErrorCancelled || error.code == NSURLErrorNotConnectedToInternet) {
            return
        }
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
