import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("VAD installation state")
struct VADInstallControllerTests {
    @Test @MainActor func staleVerificationCannotOverwriteNewerVerifiedState() async throws {
        let gate = VADVerificationGate()
        let controller = VADInstallController(verify: { await gate.verify($0) })
        let first = Task { await controller.refresh() }
        try await waitUntilAsync { await gate.pendingCount == 1 }
        let second = Task { await controller.refresh() }
        try await waitUntilAsync { await gate.pendingCount == 2 }
        await gate.complete(index: 1, installed: true)
        await second.value
        #expect(controller.isInstalled)
        await gate.complete(index: 0, installed: false)
        await first.value
        #expect(controller.isInstalled, "An older disk check must not replace the latest verified state")
    }
}

private actor VADVerificationGate {
    private var pending: [CheckedContinuation<Result<URL, Error>, Never>] = []
    var pendingCount: Int { pending.count }

    func verify(_ root: URL) async -> Result<URL, Error> {
        await withCheckedContinuation { pending.append($0) }
    }

    func complete(index: Int, installed: Bool) {
        pending[index].resume(returning: installed
            ? .success(URL(fileURLWithPath: "/synthetic-model")) : .failure(LocalModelError.missingVAD))
    }
}


extension VADInstallControllerTests {
    @MainActor @Test func explicitLoadUnloadAndDeleteReviewPreserveReadinessUntilConfirmed() async throws {
        actor State {
            var loaded = false
            var removals = 0
            func load() { loaded = true }
            func unload() { loaded = false }
            func remove() { removals += 1 }
            func snapshot() -> VADModelCacheSnapshot { VADModelCacheSnapshot(isLoaded: loaded, isLoading: false) }
        }
        let state = State()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/vad-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(LocalVADAssets.manifest.installationName),
                                                withIntermediateDirectories: true)
        let controller = VADInstallController(root: root, verify: { .success($0) },
            runtime: VADRuntimeOperations(load: { await state.load() }, unload: { await state.unload() },
                snapshot: { await state.snapshot() }), remove: { _ in await state.remove() })
        await controller.refresh()
        controller.load()
        try await waitUntil { controller.isLoaded && !controller.isBusy }
        controller.unload()
        try await waitUntil { !controller.isLoaded && !controller.isBusy }
        #expect(controller.isInstalled)
        #expect(await state.removals == 0)
        controller.reviewDelete()
        #expect(controller.isDeleteReview)
        #expect(controller.confirmation == LocalVADAssets.manifest)
        controller.confirmation = nil
        #expect(controller.isInstalled)
        #expect(await state.removals == 0)
    }

    @MainActor @Test func inUseBlocksVADModelActions() async {
        let controller = VADInstallController(verify: { .success($0) }, inUse: { true })
        await controller.refresh()
        controller.load()
        controller.unload()
        controller.reviewDelete()
        #expect(!controller.isBusy)
        #expect(controller.confirmation == nil)
        #expect(!controller.canLoad && !controller.canUnload && !controller.canDelete)
    }
}


extension VADInstallControllerTests {
    @MainActor @Test func aRetiredRecordingLeaseStillBlocksDeleteAfterUIRecordingEnds() async {
        let controller = VADInstallController(verify: { .success($0) }, runtime: VADRuntimeOperations(load: {}, unload: {},
            snapshot: { VADModelCacheSnapshot(isLoaded: true, isLoading: false, isInUse: true) }), inUse: { false })
        await controller.refresh()
        #expect(!controller.canDelete && !controller.canUnload)
        controller.reviewDelete()
        #expect(controller.confirmation == nil)
    }
}

extension VADInstallControllerTests {
    @MainActor @Test func failedVADTransferCanBeReviewedForExactPartialCleanup() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/vad-cleanup-\(UUID().uuidString)")
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, _, _ in throw LocalModelError.transferFailed },
                                               availableBytes: { _ in Int64.max })
        let controller = VADInstallController(root: root, installer: installer, verify: { _ in .failure(LocalModelError.missingVAD) })
        await controller.refresh()
        controller.reviewDownload()
        controller.confirmDownload()
        try await waitUntil { controller.hasError && !controller.isBusy }
        #expect(controller.canDelete)
        controller.reviewDelete()
        #expect(controller.isDeleteReview)
        #expect(!controller.removalTargets.isEmpty)
        #expect(controller.removalTargets.allSatisfy { $0.name.hasPrefix("partial-\(LocalVADAssets.manifest.installationName)-") })
        controller.confirmation = nil
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
}


extension VADInstallControllerTests {
    @MainActor @Test func partialCleanupDoesNotUnloadOrRemoveInstalledVAD() async throws {
        actor Removed {
            var names: [String] = []
            func append(_ name: String) { names.append(name) }
        }
        let removed = Removed()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/vad-partial-only-\(UUID().uuidString)")
        let manifest = LocalVADAssets.manifest
        let partialName = "partial-\(manifest.installationName)-\(UUID().uuidString)"
        for name in [manifest.installationName, partialName] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let controller = VADInstallController(root: root, verify: { .success($0) },
            runtime: VADRuntimeOperations(load: {}, unload: { Issue.record("Partial cleanup must not unload VAD") },
                snapshot: { VADModelCacheSnapshot(isLoaded: true, isLoading: false) }),
            remove: { await removed.append($0.lastPathComponent) }, inUse: { false })
        await controller.refresh()
        controller.reviewDelete()
        controller.selectRemovalTarget(manifest.installationName, included: false)
        controller.confirmDelete()
        try await waitUntil { !controller.isBusy }
        #expect(await removed.names == [partialName])
        #expect(controller.isInstalled && controller.isLoaded)
    }
}
