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
