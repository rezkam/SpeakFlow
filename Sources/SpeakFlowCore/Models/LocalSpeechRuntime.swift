import Foundation

public protocol LocalSpeechEngine: Sendable {
    func cleanup() async
}

public protocol LocalBatchSpeechEngine: LocalSpeechEngine {
    func transcribe(samples: [Float]) async throws -> String
}

public protocol LocalStreamingSpeechEngine: LocalSpeechEngine {
    func reset() async throws
    func process(samples: [Float]) async throws -> String
    func finish() async throws -> String
}

public enum LocalSpeechRuntimeError: Error, LocalizedError, Equatable {
    case expiredLease, loadTimedOut, unsupportedMode, loadFailed, inferenceFailed, missingModel, unsupportedPlatform, audioBacklog, finalizationTimedOut

    public var errorDescription: String? {
        switch self {
        case .finalizationTimedOut: "Local transcription did not finish before the recording deadline. Automatic submit was cancelled. Review any existing text and start a new recording."
        case .audioBacklog: "Local inference could not keep up with captured audio. Recording was cancelled without submitting. Start a new recording or load a different model."
        case .expiredLease: "This local recording has ended. Start a new recording to continue."
        case .loadTimedOut: "Model loading exceeded the time limit. No microphone was started. Try again after loading stops."
        case .unsupportedMode: "This model does not support the requested recording mode."
        case .loadFailed: "The local model could not load. Review its files in Models and try again."
        case .inferenceFailed: "Local transcription failed. No fallback was used. Try a new recording or reload the model in Models."
        case .missingModel: "Download this speech model in Models before recording."
        case .unsupportedPlatform: "Local speech models require Apple Silicon and macOS 26 or later."
        }
    }
}

public struct LocalSpeechRuntimeSnapshot: Sendable, Equatable {
    public static let empty = LocalSpeechRuntimeSnapshot(selected: nil, loaded: [], inUse: [], retiring: [], loading: nil, loadedRevisions: [:])
    public let selected: LocalSpeechModelID?
    public let loaded: Set<LocalSpeechModelID>
    public let inUse: Set<LocalSpeechModelID>
    public let retiring: Set<LocalSpeechModelID>
    /// Includes cancelled or timed-out loads until their native work and cleanup finish.
    public let loading: LocalSpeechModelID?
    public let loadedRevisions: [LocalSpeechModelID: String]
}

/// One recording owns its lease through finalization. Ending it retires new work immediately;
/// already-running inference keeps the engine alive until it has actually returned.
public final class LocalSpeechLease: Sendable {
    public let model: LocalSpeechModel
    private let token: UUID
    private let runtime: LocalSpeechRuntime

    fileprivate init(model: LocalSpeechModel, token: UUID, runtime: LocalSpeechRuntime) {
        self.model = model
        self.token = token
        self.runtime = runtime
    }

    public func transcribe(samples: [Float]) async throws -> String {
        try await runtime.transcribe(token, samples: samples)
    }
    public func resetStreaming() async throws { try await runtime.resetStreaming(token) }
    public func process(samples: [Float]) async throws -> String { try await runtime.process(token, samples: samples) }
    public func finishStreaming() async throws -> String { try await runtime.finishStreaming(token) }
    public func release() async { await runtime.release(token) }
    /// Stop queued work while the owning recording still retains its finalization lease.
    public func cancelOperations() async { await runtime.cancelOperations(token) }

    deinit {
        let runtime = runtime, token = token
        Task { await runtime.release(token) }
    }
}

public actor LocalSpeechRuntime {
    public typealias Verify = @Sendable (LocalSpeechModel, URL) async throws -> URL
    public typealias Load = @Sendable (LocalSpeechModel, URL) async throws -> any LocalSpeechEngine

    private struct Resident {
        let engine: any LocalSpeechEngine
        let manifest: LocalModelManifest
        var leases: Set<UUID> = []
        var jobs = 0
        var tail: Task<Void, Never>?
    }
    private let root: URL
    private let verify: Verify
    private let load: Load
    private let loadTimeout: Duration
    private var idleDuration: Duration
    private var selected: LocalSpeechModelID?
    private var selectionGeneration = UUID()
    private var cancelPendingLoad: (@Sendable () -> Void)?
    private var residents: [LocalSpeechModelID: Resident] = [:]
    private var leases: [UUID: LocalSpeechModelID] = [:]
    private var jobs: [UUID: [UUID: Task<String, Error>]] = [:]
    private var retiring: Set<LocalSpeechModelID> = []
    private var evictAfterUse: Set<LocalSpeechModelID> = []
    private var idleTasks: [LocalSpeechModelID: Task<Void, Never>] = [:]
    private var idleTokens: [LocalSpeechModelID: UUID] = [:]
    private var operation: (token: UUID, model: LocalSpeechModelID)?
    private var nativeLoad: (token: UUID, model: LocalSpeechModelID)?

    public init(root: URL, loadTimeout: Duration = .seconds(60), idleDuration: Duration = .seconds(300),
                selected: LocalSpeechModelID? = nil,
                verify: @escaping Verify = LocalSpeechRuntime.verifyFiles,
                load: @escaping Load = LocalSpeechEngines.load) {
        self.root = root
        self.loadTimeout = loadTimeout
        self.idleDuration = idleDuration
        self.selected = selected
        self.verify = verify
        self.load = load
        ModelNetworkPolicy.initialize()
    }

    public func snapshot() -> LocalSpeechRuntimeSnapshot {
        LocalSpeechRuntimeSnapshot(selected: selected, loaded: Set(residents.keys),
            inUse: Set(residents.compactMap { !$0.value.leases.isEmpty || $0.value.jobs > 0 ? $0.key : nil }),
            retiring: retiring, loading: operation?.model ?? nativeLoad?.model,
            loadedRevisions: residents.mapValues { $0.manifest.revision })
    }

    public func loadAndSelect(_ model: LocalSpeechModel) async throws {
        try Task.checkCancellation()
        guard operation == nil, nativeLoad == nil, retiring.isEmpty else { throw LocalModelError.busy }
        let selectionRequest = UUID()
        selectionGeneration = selectionRequest
        if let resident = residents[model.id], resident.manifest != model.manifest,
           !resident.leases.isEmpty || resident.jobs > 0 { throw LocalModelError.busy }
        if residents[model.id]?.manifest != model.manifest {
            let token = UUID()
            operation = (token, model.id)
            nativeLoad = (token, model.id)
            defer { operation = nil; cancelPendingLoad = nil }
            let race = LocalSpeechLoadResult()
            let verify = verify, load = load, root = root
            let worker = Task.detached { [weak self] in
                do {
                    let directory = try await verify(model, root)
                    try Task.checkCancellation()
                    let engine = try await load(model, directory)
                    if !(await race.complete(.success(engine))) { await engine.cleanup() }
                } catch { _ = await race.complete(.failure(error)) }
                await self?.nativeLoadFinished(token)
            }
            cancelPendingLoad = {
                worker.cancel()
                Task { _ = await race.complete(.failure(CancellationError())) }
            }
            let deadline = Task {
                do {
                    try await Task.sleep(for: loadTimeout)
                    if await race.complete(.failure(LocalSpeechRuntimeError.loadTimedOut)) { worker.cancel() }
                } catch { }
            }
            defer { deadline.cancel() }
            let engine = try await withTaskCancellationHandler {
                try await race.value()
            } onCancel: {
                worker.cancel()
                Task { _ = await race.complete(.failure(CancellationError())) }
            }
            do {
                try Task.checkCancellation()
                guard selectionGeneration == selectionRequest else { throw CancellationError() }
            } catch {
                await engine.cleanup()
                nativeLoadFinished(token)
                throw error
            }
            nativeLoadFinished(token)
            if residents[model.id] != nil { await removeResident(model.id) }
            guard selectionGeneration == selectionRequest, !Task.isCancelled else {
                await engine.cleanup()
                throw CancellationError()
            }
            residents[model.id] = Resident(engine: engine, manifest: model.manifest)
        }
        try Task.checkCancellation()
        selected = model.id
        evictAfterUse.remove(model.id)
        cancelIdle(model.id)
        for id in Array(residents.keys) where id != model.id { await retireIfIdle(id) }
        guard selectionGeneration == selectionRequest else { throw CancellationError() }
        scheduleIdle(model.id)
    }

    /// A separately selected provider makes local models unselected; active recordings
    /// retain their own leases, and a pending local load cannot select itself later.
    public func clearSelection() async {
        selectionGeneration = UUID()
        cancelPendingLoad?()
        selected = nil
        for id in Array(residents.keys) { await retireIfIdle(id) }
    }

    public func acquire(_ model: LocalSpeechModel) async throws -> LocalSpeechLease {
        guard operation == nil, nativeLoad == nil, retiring.isEmpty else { throw LocalModelError.busy }
        if residents[model.id]?.manifest != model.manifest { try await loadAndSelect(model) }
        try Task.checkCancellation()
        guard var resident = residents[model.id], resident.leases.isEmpty, resident.jobs == 0 else {
            throw LocalModelError.busy
        }
        cancelIdle(model.id)
        let token = UUID()
        resident.leases.insert(token)
        residents[model.id] = resident
        leases[token] = model.id
        return LocalSpeechLease(model: model, token: token, runtime: self)
    }

    public func unload(_ id: LocalSpeechModelID) async throws {
        guard operation == nil, nativeLoad == nil, retiring.isEmpty else { throw LocalModelError.busy }
        guard let resident = residents[id] else { return }
        guard resident.leases.isEmpty, resident.jobs == 0 else { throw LocalModelError.busy }
        await removeResident(id)
    }

    /// Resource warnings retire idle handles immediately. An active recording keeps its
    /// engine until both its lease and native jobs end. Installed files and selection remain.
    public func releaseIdleResources() async {
        selectionGeneration = UUID()
        cancelPendingLoad?()
        evictAfterUse.formUnion(residents.keys)
        for id in Array(residents.keys) { await retireIfIdle(id) }
    }

    public func setIdleDuration(_ duration: Duration) {
        idleDuration = duration
        for id in residents.keys { scheduleIdle(id) }
    }

    fileprivate func release(_ token: UUID) async {
        guard let id = leases.removeValue(forKey: token) else { return }
        residents[id]?.leases.remove(token)
        cancelOperations(token)
        await retireIfIdle(id)
    }

    fileprivate func cancelOperations(_ token: UUID) {
        for task in jobs[token]?.values ?? [:].values { task.cancel() }
    }

    fileprivate func transcribe(_ token: UUID, samples: [Float]) async throws -> String {
        try await perform(token) { engine in
            guard let batch = engine as? any LocalBatchSpeechEngine else { throw LocalSpeechRuntimeError.unsupportedMode }
            return try await batch.transcribe(samples: samples)
        }
    }
    fileprivate func resetStreaming(_ token: UUID) async throws {
        _ = try await perform(token) { engine in
            guard let streaming = engine as? any LocalStreamingSpeechEngine else { throw LocalSpeechRuntimeError.unsupportedMode }
            try await streaming.reset()
            return ""
        }
    }
    fileprivate func process(_ token: UUID, samples: [Float]) async throws -> String {
        try await perform(token) { engine in
            guard let streaming = engine as? any LocalStreamingSpeechEngine else { throw LocalSpeechRuntimeError.unsupportedMode }
            return try await streaming.process(samples: samples)
        }
    }
    fileprivate func finishStreaming(_ token: UUID) async throws -> String {
        try await perform(token) { engine in
            guard let streaming = engine as? any LocalStreamingSpeechEngine else { throw LocalSpeechRuntimeError.unsupportedMode }
            return try await streaming.finish()
        }
    }

    private func perform(_ token: UUID,
                         action: @escaping @Sendable (any LocalSpeechEngine) async throws -> String) async throws -> String {
        try Task.checkCancellation()
        guard let id = leases[token], let engine = residents[id]?.engine else { throw LocalSpeechRuntimeError.expiredLease }
        let previous = residents[id]?.tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await action(engine)
        }
        let job = UUID()
        jobs[token, default: [:]][job] = task
        residents[id]?.tail = Task { _ = await task.result }
        residents[id]?.jobs += 1
        do {
            let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard leases[token] == id else { throw LocalSpeechRuntimeError.expiredLease }
            await jobFinished(id, token: token, job: job)
            return text
        } catch {
            let released = leases[token] == nil
            await jobFinished(id, token: token, job: job)
            if released { throw LocalSpeechRuntimeError.expiredLease }
            throw error
        }
    }

    private func jobFinished(_ id: LocalSpeechModelID, token: UUID, job: UUID) async {
        jobs[token]?.removeValue(forKey: job)
        if jobs[token]?.isEmpty == true { jobs.removeValue(forKey: token) }
        residents[id]?.jobs -= 1
        await retireIfIdle(id)
    }
    private func nativeLoadFinished(_ token: UUID) {
        if nativeLoad?.token == token { nativeLoad = nil }
    }
    private func retireIfIdle(_ id: LocalSpeechModelID) async {
        guard let resident = residents[id], resident.leases.isEmpty, resident.jobs == 0 else { return }
        if id == selected && !evictAfterUse.contains(id) { scheduleIdle(id) } else { await removeResident(id) }
    }
    private func removeResident(_ id: LocalSpeechModelID) async {
        cancelIdle(id)
        evictAfterUse.remove(id)
        guard let resident = residents.removeValue(forKey: id) else { return }
        retiring.insert(id)
        await resident.engine.cleanup()
        retiring.remove(id)
    }
    private func cancelIdle(_ id: LocalSpeechModelID) {
        idleTasks.removeValue(forKey: id)?.cancel()
        idleTokens.removeValue(forKey: id)
    }
    private func scheduleIdle(_ id: LocalSpeechModelID) {
        cancelIdle(id)
        guard let resident = residents[id], resident.leases.isEmpty, resident.jobs == 0 else { return }
        let token = UUID(), duration = idleDuration
        idleTokens[id] = token
        idleTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
                await self?.expire(id, token: token)
            } catch { }
        }
    }
    private func expire(_ id: LocalSpeechModelID, token: UUID) async {
        guard idleTokens[id] == token, let resident = residents[id], resident.leases.isEmpty, resident.jobs == 0 else { return }
        await removeResident(id)
    }

    public nonisolated static func verifyFiles(_ model: LocalSpeechModel, root: URL) async throws -> URL {
        let installation = root.appendingPathComponent(model.manifest.installationName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: installation.path) else { throw LocalSpeechRuntimeError.missingModel }
        try LocalModelFiles.verify(model.manifest, installation: installation)
        return installation.appendingPathComponent(model.manifest.modelDirectory, isDirectory: true)
    }
}

/// The first completion wins. The native loader is deliberately unstructured so a timeout
/// or cancellation can return without waiting for non-cooperative CoreML work.
private actor LocalSpeechLoadResult {
    private var result: Result<any LocalSpeechEngine, Error>?
    private var continuation: CheckedContinuation<any LocalSpeechEngine, Error>?

    func complete(_ result: Result<any LocalSpeechEngine, Error>) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
        return true
    }
    func value() async throws -> any LocalSpeechEngine {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
