import Foundation
import os
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

private actor ModelsFixtureEngine: LocalBatchSpeechEngine {
    func transcribe(samples: [Float]) async throws -> String { "fixture words" }
    func cleanup() async {}
}

@MainActor private final class ModelsSelectionFixture {
    var id = "fixture-cloud"
    var busy = false
    var commits = 0
}

@Suite("Models operations", .serialized)
struct LocalModelsControllerTests {
    @MainActor private struct Fixture {
        let controller: LocalModelsController
        let selection: ModelsSelectionFixture
        let runtime: LocalSpeechRuntime
        let root: URL
        let available: OSAllocatedUnfairLock<Set<LocalSpeechModelID>>
        let requests: OSAllocatedUnfairLock<Int>
        let removed: OSAllocatedUnfairLock<[String]>
        let vadLoads: OSAllocatedUnfairLock<Int>
    }

    @MainActor private func fixture(vadInstalled: Bool = false, vadLoadFails: Bool = false, retained: [LocalSpeechModel] = []) throws -> Fixture {
        let models = try LocalSpeechCatalog.models()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/models-operations-\(UUID().uuidString)")
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let removed = OSAllocatedUnfairLock(initialState: [String]())
        let available = OSAllocatedUnfairLock(initialState: Set<LocalSpeechModelID>())
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, _, _ in
            requests.withLock { $0 += 1 }
            throw LocalModelError.transferFailed
        }, availableBytes: { _ in Int64.max })
        let vadLoads = OSAllocatedUnfairLock(initialState: 0)
        let vadLoaded = OSAllocatedUnfairLock(initialState: false)
        let vad = VADInstallController(root: root, installer: installer, verify: { root in
            vadInstalled ? .success(root) : .failure(LocalModelError.missingVAD)
        }, runtime: VADRuntimeOperations(load: {
            vadLoads.withLock { $0 += 1 }
            if vadLoadFails { throw LocalModelError.invalidAssets }
            vadLoaded.withLock { $0 = true }
        }, unload: { vadLoaded.withLock { $0 = false } }, snapshot: {
            VADModelCacheSnapshot(isLoaded: vadLoaded.withLock { $0 }, isLoading: false)
        }))
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { model, _ in
            if model.id != .parakeetV2 { throw LocalSpeechRuntimeError.loadFailed }
            return ModelsFixtureEngine()
        })
        let state = ModelsSelectionFixture()
        let store = LocalModelsStore(root: root, installer: installer, audit: { model, root in
            guard available.withLock({ $0.contains(model.id) }) else { throw LocalSpeechRuntimeError.missingModel }
            return root.appendingPathComponent(model.manifest.installationName)
        }, remove: { target in
            removed.withLock { $0.append(target.lastPathComponent) }
            if target.lastPathComponent == models.first(where: { $0.id == .parakeetV2 })?.manifest.installationName {
                available.withLock { $0.remove(.parakeetV2) }
            }
        })
        let selection = LocalModelsSelection(current: { state.id }, commit: { state.id = $0; state.commits += 1 },
            busy: { state.busy }, refresh: {}, requiresVAD: { true }, supported: true)
        let controller = LocalModelsController(models: models, store: store, runtime: runtime, vad: vad, selection: selection, reviewedVersions: retained)
        return Fixture(controller: controller, selection: state, runtime: runtime, root: root,
            available: available, requests: requests, removed: removed, vadLoads: vadLoads)
    }

    @MainActor @Test func browseAndCancelledReviewNeverTransferOrCreateAStore() async throws {
        let fixture = try fixture()
        await fixture.controller.refresh()
        #expect(fixture.requests.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        fixture.controller.reviewDownload(.parakeetV2)
        let review = try #require(fixture.controller.confirmation)
        #expect(review.manifests.map(\.id) == [LocalVADAssets.manifest.id, LocalSpeechModelID.parakeetV2.rawValue])
        #expect(review.manifests.reduce(0) { $0 + $1.transferBytes } == 464_413_247 + 1_063_425)
        fixture.controller.confirmation = nil
        #expect(fixture.requests.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @MainActor @Test func confirmedFailedDownloadKeepsThePreviousSelectionAndAllowsRetry() async throws {
        let fixture = try fixture(vadInstalled: true)
        await fixture.controller.refresh()
        fixture.controller.reviewDownload(.parakeetV2)
        fixture.controller.confirmOperation()
        try await waitUntil { !fixture.controller.isBusy && fixture.controller.entry(.parakeetV2).hasError }
        #expect(fixture.requests.withLock { $0 } == 1)
        #expect(fixture.selection.id == "fixture-cloud" && fixture.selection.commits == 0)
        #expect(fixture.controller.canDownload(.parakeetV2))
    }

    @MainActor @Test func loadSelectsOnlyAfterSuccessAndUnloadKeepsFilesAndSelection() async throws {
        let fixture = try fixture(vadInstalled: true)
        fixture.available.withLock { $0 = [.parakeetV2, .nemotron1120] }
        await fixture.controller.refresh()
        fixture.controller.load(.parakeetV2)
        try await waitUntil { !fixture.controller.isBusy && fixture.selection.commits == 1 }
        let selected = fixture.selection.id
        #expect(selected.contains(LocalSpeechModelID.parakeetV2.rawValue))
        fixture.controller.load(.nemotron1120)
        try await waitUntil { !fixture.controller.isBusy && fixture.controller.entry(.nemotron1120).hasError }
        #expect(fixture.selection.id == selected && fixture.selection.commits == 1)
        fixture.controller.unload(.parakeetV2)
        try await waitUntil { !fixture.controller.isBusy && !fixture.controller.runtimeState.loaded.contains(.parakeetV2) }
        #expect(fixture.selection.id == selected)
        #expect(fixture.controller.entry(.parakeetV2).isInstalled)
        #expect(fixture.removed.withLock { $0.isEmpty })
    }

    @MainActor @Test func deletionRequiresConfirmationAndCannotActOnAnInUseModel() async throws {
        let fixture = try fixture(vadInstalled: true)
        fixture.available.withLock { $0.insert(.parakeetV2) }
        await fixture.controller.refresh()
        let model = try #require(fixture.controller.models.first { $0.id == .parakeetV2 })
        let installation = fixture.root.appendingPathComponent(model.manifest.installationName)
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        let lease = try await fixture.runtime.acquire(model)
        await fixture.controller.refreshRuntime()
        fixture.controller.reviewDelete(.parakeetV2)
        #expect(fixture.controller.confirmation == nil)
        #expect(fixture.removed.withLock { $0.isEmpty })
        await lease.release()
        await fixture.controller.refreshRuntime()
        fixture.controller.reviewDelete(.parakeetV2)
        #expect(fixture.controller.confirmation?.kind == .delete)
        #expect(fixture.removed.withLock { $0.isEmpty })
        fixture.controller.confirmOperation()
        try await waitUntil { !fixture.controller.isBusy && !fixture.controller.entry(.parakeetV2).isInstalled }
        #expect(fixture.removed.withLock { $0 } == [model.manifest.installationName])
        #expect(fixture.controller.vad.isInstalled)
    }

    @MainActor @Test func missingVADDisablesBatchLoadWithoutAnImplicitDependencyDownload() async throws {
        let fixture = try fixture()
        fixture.available.withLock { $0.insert(.parakeetV2) }
        await fixture.controller.refresh()
        #expect(!fixture.controller.canLoad(.parakeetV2))
        #expect(fixture.requests.withLock { $0 } == 0)
        #expect(fixture.selection.commits == 0)
    }

    @MainActor @Test func missingFilesDoNotPreventUnloadingAnAlreadyResidentModel() async throws {
        let fixture = try fixture(vadInstalled: true)
        fixture.available.withLock { $0.insert(.parakeetV2) }
        await fixture.controller.refresh()
        fixture.controller.load(.parakeetV2)
        try await waitUntil { !fixture.controller.isBusy && fixture.selection.commits == 1 }
        fixture.available.withLock { $0.remove(.parakeetV2) }
        await fixture.controller.refresh()
        #expect(!fixture.controller.entry(.parakeetV2).isInstalled)
        #expect(fixture.controller.canUnload(.parakeetV2))
        fixture.controller.unload(.parakeetV2)
        try await waitUntil { !fixture.controller.isBusy }
        #expect(await fixture.runtime.snapshot().loaded.isEmpty)
    }

}


extension LocalModelsControllerTests {
    @MainActor @Test func retainedReviewedVersionCanBeBrowsedThenExplicitlyLoadedForRollback() async throws {
        let original = try #require(LocalSpeechCatalog.models().first { $0.id == .parakeetV2 })
        let manifest = original.manifest
        let older = LocalSpeechModel(id: original.id, name: original.name, mode: original.mode,
            manifest: LocalModelManifest(id: manifest.id, repository: manifest.repository,
                revision: String(repeating: "a", count: 40), license: manifest.license,
                modelDirectory: manifest.modelDirectory, artifacts: manifest.artifacts))
        let fixture = try fixture(vadInstalled: true, retained: [older])
        fixture.available.withLock { $0.insert(original.id) }
        await fixture.controller.refresh()
        fixture.controller.load(original.id)
        try await waitUntil { !fixture.controller.isBusy && fixture.selection.commits == 1 }
        fixture.controller.chooseVersion(older.providerID)
        #expect(fixture.selection.id == original.providerID)
        #expect(fixture.controller.models.first { $0.id == older.id }?.providerID == older.providerID)
        fixture.controller.load(older.id)
        try await waitUntil { !fixture.controller.isBusy && fixture.selection.commits == 2 }
        #expect(fixture.selection.id == older.providerID)
        #expect(fixture.requests.withLock { $0 } == 0)
        #expect(fixture.removed.withLock { $0.isEmpty })
    }
}

extension LocalModelsControllerTests {
    @MainActor @Test func updateChecksAreManualMetadataOnlyAndNeverSelectOrDownload() async throws {
        let fixture = try fixture(vadInstalled: true)
        await fixture.controller.refresh()
        #expect(fixture.requests.withLock { $0 } == 0)
        let checker = LocalModelUpdateChecker(fetch: { _ in Data("{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}".utf8) })
        fixture.controller.checkForUpdates(using: checker)
        try await waitUntil { !fixture.controller.checkingUpdates }
        #expect(fixture.controller.entry(.parakeetV2).updateNotice != nil)
        #expect(fixture.selection.commits == 0)
        #expect(fixture.requests.withLock { $0 } == 0)
        #expect(fixture.removed.withLock { $0.isEmpty })
    }

    @MainActor @Test func anOfflineUpdateCheckPreservesTheWorkingSelection() async throws {
        let fixture = try fixture(vadInstalled: true)
        fixture.available.withLock { $0.insert(.parakeetV2) }
        await fixture.controller.refresh()
        fixture.controller.load(.parakeetV2)
        try await waitUntil { !fixture.controller.isBusy && fixture.selection.commits == 1 }
        let selected = fixture.selection.id
        fixture.controller.checkForUpdates(using: LocalModelUpdateChecker(fetch: { _ in throw LocalModelError.transferFailed }))
        try await waitUntil { !fixture.controller.checkingUpdates }
        #expect(fixture.controller.updateCheckFailed)
        #expect(fixture.selection.id == selected && fixture.selection.commits == 1)
        #expect(fixture.controller.entry(.parakeetV2).isInstalled)
        #expect(fixture.requests.withLock { $0 } == 0)
    }
}


extension LocalModelsControllerTests {
    @MainActor @Test func anInterruptedRevisionCanBeReviewedForNamedPartialCleanup() async throws {
        let fixture = try fixture(vadInstalled: true)
        await fixture.controller.refresh()
        fixture.controller.reviewDownload(.parakeetV2)
        fixture.controller.confirmOperation()
        try await waitUntil { !fixture.controller.isBusy && fixture.controller.entry(.parakeetV2).hasError }
        #expect(fixture.controller.canDelete(.parakeetV2))
        fixture.controller.reviewDelete(.parakeetV2)
        let confirmation = try #require(fixture.controller.confirmation)
        #expect(!confirmation.removalTargets.isEmpty)
        #expect(confirmation.removalTargets.allSatisfy { $0.name.hasPrefix("partial-parakeet-v2-") })
        #expect(fixture.removed.withLock { $0.isEmpty })
        fixture.controller.confirmation = nil
        #expect(fixture.removed.withLock { $0.isEmpty })
    }
}


extension LocalModelsControllerTests {
    @MainActor @Test func partialCleanupCanKeepTheInstalledLoadedRevision() async throws {
        let fixture = try fixture(vadInstalled: true)
        let model = try #require(fixture.controller.models.first { $0.id == .parakeetV2 })
        let partialName = "partial-\(model.manifest.installationName)-\(UUID().uuidString)"
        for name in [model.manifest.installationName, partialName] {
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        fixture.available.withLock { $0.insert(model.id) }
        await fixture.controller.refresh()
        fixture.controller.load(model.id)
        try await waitUntil { !fixture.controller.isBusy && fixture.selection.commits == 1 }
        fixture.controller.reviewDelete(model.id)
        fixture.controller.selectRemovalTarget(model.manifest.installationName, included: false)
        #expect(fixture.controller.confirmation?.removalTargets.map(\.name) == [partialName])
        #expect(fixture.controller.confirmation?.removesInstallation == false)
        fixture.controller.confirmOperation()
        try await waitUntil { !fixture.controller.isBusy }
        #expect(fixture.removed.withLock { $0 } == [partialName])
        #expect(fixture.controller.entry(model.id).isInstalled)
        #expect(await fixture.runtime.snapshot().loaded == [model.id])
        #expect(fixture.selection.id == model.providerID)
    }
    @MainActor @Test func startupPreloadsOnlyAfterOptInAndLoadsRequiredVADFirst() async throws {
        let preferences = LocalModelPreferences.shared
        let original = preferences.preloadOnLaunch
        defer { preferences.preloadOnLaunch = original }
        let fixture = try fixture(vadInstalled: true)
        fixture.available.withLock { $0 = [.parakeetV2] }
        fixture.selection.id = try #require(fixture.controller.models.first { $0.id == .parakeetV2 }).providerID
        preferences.preloadOnLaunch = false
        await fixture.controller.bootstrap()
        #expect(fixture.vadLoads.withLock { $0 } == 0)
        #expect(await fixture.runtime.snapshot().loaded.isEmpty)
        preferences.preloadOnLaunch = true
        await fixture.controller.bootstrap()
        try await waitUntil { !fixture.controller.isBusy }
        #expect(fixture.vadLoads.withLock { $0 } == 1)
        #expect(await fixture.runtime.snapshot().loaded == [.parakeetV2])
        #expect(fixture.requests.withLock { $0 } == 0)
    }

    @MainActor @Test func failedPreloadDependencyNeverLoadsOrSelectsSpeechModel() async throws {
        let preferences = LocalModelPreferences.shared
        let original = preferences.preloadOnLaunch
        defer { preferences.preloadOnLaunch = original }
        preferences.preloadOnLaunch = true
        let fixture = try fixture(vadInstalled: true, vadLoadFails: true)
        fixture.available.withLock { $0 = [.parakeetV2] }
        fixture.selection.id = try #require(fixture.controller.models.first { $0.id == .parakeetV2 }).providerID
        await fixture.controller.bootstrap()
        try await waitUntil { !fixture.controller.isBusy }
        #expect(fixture.vadLoads.withLock { $0 } == 1)
        #expect(fixture.controller.vad.hasError)
        #expect(await fixture.runtime.snapshot().loaded.isEmpty)
        #expect(fixture.selection.commits == 0)
        #expect(fixture.requests.withLock { $0 } == 0)
    }

}
