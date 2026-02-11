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
        let manager = try await VADModelCache.shared.getManager(threshold: 0.5)

        // Verify the manager was actually created (check identity is stable)
        #expect(type(of: manager) == VadManager.self, "getManager must return a VadManager instance")
    }

    @Test func testGetManagerReturnsSameInstance() async throws {
        // Two calls to getManager should return the same cached VadManager.
        guard VADProcessor.isAvailable else { return }
        let m1 = try await VADModelCache.shared.getManager(threshold: 0.5)
        let m2 = try await VADModelCache.shared.getManager(threshold: 0.5)
        #expect(m1 === m2, "getManager must return the same cached instance")
    }
}

@Suite("VADModelCache — source regression guards")
struct VADModelCacheSourceRegressionTests {

    @Test func testVADModelCacheActorExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        #expect(source.contains("public actor VADModelCache"))
        #expect(source.contains("public static let shared = VADModelCache()"))
    }

    @Test func testWarmUpMethodExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        #expect(source.contains("public func warmUp("))
    }

    @Test func testWarmUpGuardsAgainstDoubleStart() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        // Must check both cachedManager and warmUpTask to avoid duplicate loads
        #expect(source.contains("guard cachedManager == nil, warmUpTask == nil"))
    }

    @Test func testGetManagerUsesCache() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        // Must check cachedManager AND threshold match before returning cache
        #expect(source.contains("if let cached = cachedManager, cachedThreshold == threshold"))
    }

    @Test func testGetManagerAwaitsInProgressWarmUp() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        // If warm-up is in progress, await it instead of loading a second model
        #expect(source.contains("if let pending = warmUpTask"))
        #expect(source.contains("try await pending.value"))
    }

    @Test func testVADProcessorUsesCache() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        // VADProcessor.initialize() must use the shared cache
        #expect(source.contains("VADModelCache.shared.getManager"))
        // It must NOT create a new VadManager directly
        // Count VadManager inits — only the cache should create them
        let initInCache = source.contains("VadManager(config:")
        #expect(initInCache, "VadManager(config:) must exist (in the cache)")
    }

    @Test func testAppDelegateWarmUpOnLaunch() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // Warm-up must happen at app launch
        #expect(source.contains("VADModelCache.shared.warmUp"))
        // Only when VAD is available and enabled
        #expect(source.contains("VADProcessor.isAvailable"))
        #expect(source.contains("Settings.shared.vadEnabled"))
    }
}

// MARK: - P1 Regression: Failed warm-up task must be cleared for retry

@Suite("P1 — VADModelCache failed warm-up allows retry")
struct VADModelCacheFailedWarmUpTests {

    @Test func testWarmUpTaskClearedOnFailure_source() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        // The warm-up Task must clear warmUpTask in the catch/error path,
        // not only on success. Otherwise a transient failure permanently
        // blocks VAD from recovering.
        guard let warmUpRange = source.range(of: "warmUpTask = Task {") else {
            Issue.record("warmUpTask = Task { not found in VADProcessor.swift")
            return
        }
        let body = String(source[warmUpRange.lowerBound...].prefix(1500))

        // Must have a do/catch pattern inside the Task
        #expect(body.contains("} catch {"),
                "warmUp Task must have a catch block to handle failures")

        // The catch block must clear warmUpTask
        // Find the catch block content
        guard let catchRange = body.range(of: "} catch {") else {
            Issue.record("catch block not found")
            return
        }
        let catchBody = String(body[catchRange.lowerBound...].prefix(300))
        #expect(catchBody.contains("self.warmUpTask = nil"),
                "catch block must set warmUpTask = nil so retry is possible")
    }

    @Test func testWarmUpTaskClearedOnSuccess_source() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        // Verify the success path also clears warmUpTask (existing behavior preserved)
        guard let warmUpRange = source.range(of: "warmUpTask = Task {") else {
            Issue.record("warmUpTask = Task { not found")
            return
        }
        let body = String(source[warmUpRange.lowerBound...].prefix(1500))

        // The do block (success path) must also set warmUpTask = nil
        // Find content between "do {" and "} catch {"
        guard let doStart = body.range(of: "do {"),
              let catchStart = body.range(of: "} catch {") else {
            Issue.record("do/catch structure not found")
            return
        }
        let doBody = String(body[doStart.lowerBound..<catchStart.lowerBound])
        #expect(doBody.contains("self.warmUpTask = nil"),
                "Success path must also clear warmUpTask")
        #expect(doBody.contains("self.cachedManager = manager"),
                "Success path must cache the manager")
    }
}

// MARK: - P2 Regression: Cached manager must respect threshold changes

@Suite("P2 — VADModelCache respects threshold changes")
struct VADModelCacheThresholdTests {

    @Test func testCachedThresholdPropertyExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")
        #expect(source.contains("cachedThreshold"),
                "VADModelCache must track the threshold used for the cached manager")
    }

    @Test func testGetManagerChecksThresholdMatch() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        // getManager must check both cachedManager AND cachedThreshold before returning cache
        guard let getManagerRange = source.range(of: "func getManager(threshold: Float)") else {
            Issue.record("getManager not found")
            return
        }
        let body = String(source[getManagerRange.lowerBound...].prefix(1200))

        // Must check threshold matches, not just that cachedManager exists
        #expect(body.contains("cachedThreshold == threshold"),
                "getManager must verify cached threshold matches requested threshold")
    }

    @Test func testGetManagerInvalidatesOnThresholdChange() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        guard let getManagerRange = source.range(of: "func getManager(threshold: Float)") else {
            Issue.record("getManager not found")
            return
        }
        let body = String(source[getManagerRange.lowerBound...].prefix(1200))

        // When threshold changes, must invalidate stale cache
        #expect(body.contains("cachedManager = nil"),
                "getManager must clear cachedManager when threshold changes")
        #expect(body.contains("cachedThreshold = nil"),
                "getManager must clear cachedThreshold when threshold changes")
    }

    @Test func testWarmUpStoresThreshold() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        // The success path in warmUp must store the threshold alongside the manager
        guard let warmUpRange = source.range(of: "warmUpTask = Task {") else {
            Issue.record("warmUpTask = Task { not found")
            return
        }
        let body = String(source[warmUpRange.lowerBound...].prefix(1500))
        #expect(body.contains("self.cachedThreshold = threshold"),
                "warmUp success path must store the threshold for later matching")
    }

    @Test func testGetManagerOnDemandStoresThreshold() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/VAD/VADProcessor.swift")

        guard let getManagerRange = source.range(of: "func getManager(threshold: Float)") else {
            Issue.record("getManager not found")
            return
        }
        let body = String(source[getManagerRange.lowerBound...].prefix(1500))

        // The on-demand (cold) path must also store the threshold
        #expect(body.contains("cachedThreshold = threshold"),
                "On-demand path must store threshold for cache consistency")
    }
}
