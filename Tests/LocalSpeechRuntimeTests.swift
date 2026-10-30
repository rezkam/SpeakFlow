import Foundation
import Testing
@testable import SpeakFlowCore

private actor RuntimeFixtureEngine: LocalBatchSpeechEngine {
    private(set) var cleanups = 0
    func transcribe(samples: [Float]) async throws -> String { "fixture speech" }
    func cleanup() async { cleanups += 1 }
}

private actor RuntimeLoadGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        started = true
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { waiter?.resume(); waiter = nil }
}

private actor RuntimeBusyEngine: LocalBatchSpeechEngine {
    let inference: RuntimeLoadGate?
    let cleanupGate: RuntimeLoadGate?
    private(set) var cleanups = 0
    init(inference: RuntimeLoadGate? = nil, cleanupGate: RuntimeLoadGate? = nil) {
        self.inference = inference
        self.cleanupGate = cleanupGate
    }
    func transcribe(samples: [Float]) async throws -> String {
        await inference?.wait()
        return "late fixture speech"
    }
    func cleanup() async {
        await cleanupGate?.wait()
        cleanups += 1
    }
}

private actor RuntimeConcurrencyEngine: LocalBatchSpeechEngine {
    let gate: RuntimeLoadGate
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var calls = 0
    init(gate: RuntimeLoadGate) { self.gate = gate }
    func transcribe(samples: [Float]) async throws -> String {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        if calls == 1 { await gate.wait() }
        active -= 1
        return "fixture speech"
    }
    func cleanup() async {}
}

@Suite("Local speech runtime")
struct LocalSpeechRuntimeTests {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".agents/test-fixtures/runtime-\(UUID().uuidString)") }

    private func model(_ id: LocalSpeechModelID = .parakeetV2) throws -> LocalSpeechModel {
        try #require(LocalSpeechCatalog.models().first { $0.id == id })
    }

    private func runtime(_ engine: RuntimeFixtureEngine) -> LocalSpeechRuntime {
        LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in engine })
    }

    @Test func constructionDoesNotLoadOrCreateAStore() async {
        let root = root
        let runtime = LocalSpeechRuntime(root: root, verify: { _, _ in
            Issue.record("Construction must not verify or load")
            throw LocalModelError.invalidAssets
        }, load: { _, _ in
            Issue.record("Construction must not load")
            throw LocalModelError.invalidAssets
        })
        let state = await runtime.snapshot()
        #expect(state.selected == nil && state.loaded.isEmpty && state.loading == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func switchRetainsTheOldEngineUntilItsLastRecordingLeaseEnds() async throws {
        let old = RuntimeFixtureEngine(), next = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory },
            load: { model, _ in
                if model.id == .parakeetV2 { return old }
                return next
            })
        let small = try model(), large = try model(.nemotron1120)
        let lease = try await runtime.acquire(small)
        try await runtime.loadAndSelect(large)
        let state = await runtime.snapshot()
        #expect(state.selected == large.id)
        #expect(state.loaded == [small.id, large.id])
        #expect(state.inUse == [small.id])
        #expect(await old.cleanups == 0)
        #expect(try await lease.transcribe(samples: [0]) == "fixture speech")
        await lease.release()
        #expect(await old.cleanups == 1)
        #expect(await runtime.snapshot().loaded == [large.id])
        await lease.release()
        #expect(await old.cleanups == 1)
        try await runtime.unload(large.id)
    }

    @Test(arguments: [false, true])
    func failedVerificationOrLoadKeepsThePreviousSelection(failVerification: Bool) async throws {
        let engine = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { model, directory in
            if failVerification && model.id == .nemotron1120 { throw LocalModelError.invalidAssets }
            return directory
        }, load: { model, _ in
            if !failVerification && model.id == .nemotron1120 { throw LocalModelError.invalidAssets }
            return engine
        })
        let small = try model()
        try await runtime.loadAndSelect(small)
        let candidate = try model(.nemotron1120)
        await #expect(throws: LocalModelError.invalidAssets) { try await runtime.loadAndSelect(candidate) }
        let state = await runtime.snapshot()
        #expect(state.selected == small.id && state.loaded == [small.id])
        #expect(await engine.cleanups == 0)
        try await runtime.unload(small.id)
    }

    @Test func unloadIsBlockedDuringARecordingAndKeepsFilesAndSelection() async throws {
        let engine = RuntimeFixtureEngine()
        let runtime = runtime(engine)
        let model = try model()
        let lease = try await runtime.acquire(model)
        await #expect(throws: LocalModelError.busy) { try await runtime.unload(model.id) }
        await lease.release()
        try await runtime.unload(model.id)
        let state = await runtime.snapshot()
        #expect(state.selected == model.id && state.loaded.isEmpty)
        await #expect(throws: LocalSpeechRuntimeError.expiredLease) { try await lease.transcribe(samples: [0]) }
        #expect(await engine.cleanups == 1)
    }

    @Test(arguments: [false, true])
    func cancelledNonCooperativeLoadCannotSelectOrStartAnotherLoad(selectionChanged: Bool) async throws {
        let gate = RuntimeLoadGate(), engine = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in
            await gate.wait()
            return engine
        })
        let model = try model()
        let task = Task { try await runtime.loadAndSelect(model) }
        try await waitUntilAsync { await gate.started }
        if selectionChanged { await runtime.clearSelection() } else { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await runtime.snapshot().selected == nil)
        await #expect(throws: LocalModelError.busy) { try await runtime.loadAndSelect(model) }
        await gate.open()
        try await waitUntilAsync { await engine.cleanups == 1 }
        try await waitUntilAsync { await runtime.snapshot().loading == nil }
        #expect(await runtime.snapshot().loaded.isEmpty)
    }

    @Test func loadTimeoutReturnsWhileCoreMLWorkIsStillRetiring() async throws {
        let gate = RuntimeLoadGate(), engine = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, loadTimeout: .milliseconds(25),
            verify: { _, directory in directory }, load: { _, _ in await gate.wait(); return engine })
        let model = try model()
        await #expect(throws: LocalSpeechRuntimeError.loadTimedOut) { try await runtime.loadAndSelect(model) }
        #expect(await gate.started)
        #expect(await runtime.snapshot().selected == nil)
        #expect(await runtime.snapshot().loading == model.id)
        await gate.open()
        try await waitUntilAsync { await engine.cleanups == 1 }
        try await waitUntilAsync { await runtime.snapshot().loading == nil }
    }

    @Test func idleExpiryWaitsForTheLeaseAndUnloadsWithoutChangingSelection() async throws {
        let engine = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, idleDuration: .milliseconds(25),
            verify: { _, directory in directory }, load: { _, _ in engine })
        let model = try model()
        let lease = try await runtime.acquire(model)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await engine.cleanups == 0)
        await lease.release()
        try await waitUntilAsync { await engine.cleanups == 1 }
        let state = await runtime.snapshot()
        #expect(state.selected == model.id && state.loaded.isEmpty)
    }

    @Test func releasedInferenceRetainsItsEngineAndCannotReturnLateText() async throws {
        let inference = RuntimeLoadGate()
        let held = RuntimeBusyEngine(inference: inference), next = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory },
            load: { model, _ in
                if model.id == .parakeetV2 { return held }
                return next
            })
        let small = try model(), large = try model(.nemotron1120)
        let lease = try await runtime.acquire(small)
        let work = Task { try await lease.transcribe(samples: [0]) }
        try await waitUntilAsync { await inference.started }
        try await runtime.loadAndSelect(large)
        await lease.release()
        #expect(await held.cleanups == 0)
        #expect(await runtime.snapshot().inUse == [small.id])
        await inference.open()
        await #expect(throws: LocalSpeechRuntimeError.expiredLease) { try await work.value }
        #expect(await held.cleanups == 1)
        #expect(await runtime.snapshot().inUse.isEmpty)
        try await runtime.unload(large.id)
    }

    @Test func aNewLoadCannotOverlapNativeCleanup() async throws {
        let gate = RuntimeLoadGate()
        let old = RuntimeBusyEngine(cleanupGate: gate)
        let next = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory },
            load: { model, _ in
                if model.id == .parakeetV2 { return old }
                return next
            })
        let small = try model(), large = try model(.nemotron1120)
        try await runtime.loadAndSelect(small)
        let switchTask = Task { try await runtime.loadAndSelect(large) }
        try await waitUntilAsync { await gate.started }
        await #expect(throws: LocalModelError.busy) { try await runtime.loadAndSelect(small) }
        await gate.open()
        try await switchTask.value
        #expect(await old.cleanups == 1)
        try await runtime.unload(large.id)
    }

    @Test func concurrentChunksUseOneInferenceOwner() async throws {
        let gate = RuntimeLoadGate()
        let held = RuntimeConcurrencyEngine(gate: gate)
        let runtime = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in held })
        let model = try model()
        let lease = try await runtime.acquire(model)
        let first = Task { try await lease.transcribe(samples: [0]) }
        try await waitUntilAsync { await gate.started }
        let second = Task { try await lease.transcribe(samples: [0]) }
        // Keep the first inference suspended while the second request reaches the runtime.
        try await Task.sleep(for: .milliseconds(40))
        await gate.open()
        _ = try await first.value
        _ = try await second.value
        #expect(await held.calls == 2)
        #expect(await held.maximumActive == 1)
        await lease.release()
        try await runtime.unload(model.id)
    }

    @Test(arguments: [false, true])
    func choosingAnotherProviderReleasesTheLocalModelAfterItsLastLease(inUse: Bool) async throws {
        let engine = RuntimeFixtureEngine()
        let held = LocalSpeechRuntime(root: root, verify: { _, directory in directory }, load: { _, _ in engine })
        let model = try model()
        try await held.loadAndSelect(model)
        let lease = inUse ? try await held.acquire(model) : nil
        await held.clearSelection()
        #expect(await held.snapshot().selected == nil)
        if inUse { #expect(await engine.cleanups == 0) }
        await lease?.release()
        #expect(await engine.cleanups == 1)
        #expect(await held.snapshot().loaded.isEmpty)
    }
}


extension LocalSpeechRuntimeTests {
    @Test func pressureReleasesIdleModelsButPreservesSelectionAndRecordingLeases() async throws {
        let engine = RuntimeFixtureEngine()
        let runtime = runtime(engine)
        let model = try model()
        let lease = try await runtime.acquire(model)
        await runtime.releaseIdleResources()
        #expect(await engine.cleanups == 0)
        #expect(await runtime.snapshot().inUse == [model.id])
        #expect(try await lease.transcribe(samples: [0]) == "fixture speech")
        await lease.release()
        #expect(await engine.cleanups == 1)
        #expect(await runtime.snapshot().loaded.isEmpty)
        #expect(await runtime.snapshot().selected == model.id)
    }

    @Test func pressureCancelsPendingLoadWithoutLateSelection() async throws {
        let gate = RuntimeLoadGate(), engine = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, root in root }, load: { _, _ in
            await gate.wait()
            return engine
        })
        let model = try model()
        let task = Task { try await runtime.loadAndSelect(model) }
        try await waitUntilAsync { await gate.started }
        await runtime.releaseIdleResources()
        await #expect(throws: CancellationError.self) { try await task.value }
        await gate.open()
        try await waitUntilAsync { await engine.cleanups == 1 }
        #expect(await runtime.snapshot().selected == nil)
    }

    @Test func aDifferentRevisionCannotReuseAnExistingEngineOrReplaceAnActiveLease() async throws {
        let first = try model()
        let manifest = first.manifest
        let other = LocalSpeechModel(id: first.id, name: first.name, mode: first.mode,
            manifest: LocalModelManifest(id: manifest.id, repository: manifest.repository,
                revision: String(repeating: "a", count: 40), license: manifest.license,
                modelDirectory: manifest.modelDirectory, artifacts: manifest.artifacts))
        actor Loads {
            var revisions: [String] = []
            func add(_ revision: String) { revisions.append(revision) }
        }
        let loads = Loads()
        let engine = RuntimeFixtureEngine()
        let runtime = LocalSpeechRuntime(root: root, verify: { _, root in root }, load: { model, _ in
            await loads.add(model.manifest.revision)
            return engine
        })
        let lease = try await runtime.acquire(first)
        await #expect(throws: LocalModelError.busy) { try await runtime.loadAndSelect(other) }
        await lease.release()
        try await runtime.loadAndSelect(other)
        #expect(await loads.revisions == [first.manifest.revision, other.manifest.revision])
        #expect(await engine.cleanups == 1)
        try await runtime.unload(other.id)
    }
}
