import Foundation
import Observation
import SpeakFlowCore

struct VADRuntimeOperations {
    let load: @Sendable () async throws -> Void
    let unload: @Sendable () async -> Void
    let snapshot: @Sendable () async -> VADModelCacheSnapshot
    var setIdleDuration: @Sendable (Duration) async -> Void = { _ in }

    static let production = VADRuntimeOperations(load: {
        let threshold = await MainActor.run { Settings.shared.vadThreshold }
        try await VADModelCache.shared.load(threshold: threshold)
    },
        unload: { await VADModelCache.shared.unload() }, snapshot: { await VADModelCache.shared.snapshot() },
        setIdleDuration: { await VADModelCache.shared.setIdleDuration($0) })
}

@MainActor
@Observable
final class VADInstallController {
    static let shared = VADInstallController()
    private(set) var isInstalled = false
    private(set) var isBusy = false
    private(set) var message = "Checking local files..."
    private(set) var hasError = false
    var updateNotice: String?
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var isInUse = false
    private(set) var hasFiles = false
    private(set) var isDeleteReview = false
    private(set) var removalTargets: [LocalModelRemovalTarget] = []
    private(set) var availableRemovalTargets: [LocalModelRemovalTarget] = []
    private(set) var operationCancellable = false
    var removesInstallation: Bool { removalTargets.contains { $0.name == LocalVADAssets.manifest.installationName } }
    private let runtime: VADRuntimeOperations
    private let remove: @Sendable (URL) async throws -> Void
    private let inUse: @MainActor () -> Bool
    var externalBusy: @MainActor () -> Bool = { false }
    private var canManage: Bool { !isBusy && !isLoading && !isInUse && !inUse() && !externalBusy() }
    var canDownload: Bool { !isInstalled && !hasFiles && canManage }
    var canLoad: Bool { isInstalled && !isLoaded && canManage }
    var canUnload: Bool { isLoaded && canManage }
    var canDelete: Bool { (isInstalled || hasFiles || !availableRemovalTargets.isEmpty) && canManage }
    var confirmation: LocalModelManifest?
    private let root: URL
    private let verify: @Sendable (URL) async -> Result<URL, Error>
    private let installer: ExplicitModelInstaller
    private var download: Task<Void, Never>?
    private var verificationGeneration = UUID()

    init(root: URL = VADModelCache.modelCacheRoot(), installer: ExplicitModelInstaller? = nil,
         verify: @escaping @Sendable (URL) async -> Result<URL, Error> = { root in
             await Task.detached { Result { try LocalVADAssets.verifiedDirectory(root: root) } }.value
         }, runtime: VADRuntimeOperations = .production,
         remove: @escaping @Sendable (URL) async throws -> Void = { try FileManager.default.removeItem(at: $0) },
         inUse: @escaping @MainActor () -> Bool = {
             AppState.shared.isRecording || AppState.shared.isProcessingFinal || AppState.shared.isPreparingLocalModel
         }) {
        self.runtime = runtime
        self.remove = remove
        self.inUse = inUse
        self.root = root
        self.verify = verify
        self.installer = installer ?? ExplicitModelInstaller(root: root)
    }

    func refresh() async {
        guard !isBusy else { return }
        let generation = UUID()
        verificationGeneration = generation
        let result = await verify(root)
        guard !isBusy, verificationGeneration == generation else { return }
        hasFiles = FileManager.default.fileExists(atPath: root.appendingPathComponent(LocalVADAssets.manifest.installationName).path)
        if confirmation == nil {
            availableRemovalTargets = (try? LocalModelFiles.removalTargets(LocalVADAssets.manifest, root: root)) ?? []
            removalTargets = availableRemovalTargets
        }
        await refreshRuntime()
        switch result {
        case .success:
            isInstalled = true
            hasError = false
            message = "Verified local files. No download is needed for recording."
        case .failure(let error):
            isInstalled = false
            hasError = (error as? LocalModelError) != .missingVAD
            message = (error as? LocalModelError)?.localizedDescription ?? LocalModelError.invalidAssets.localizedDescription
        }
    }

    func reviewDownload() {
        guard canDownload else { return }
        isDeleteReview = false
        confirmation = LocalVADAssets.manifest
    }

    func confirmDownload() {
        guard !isDeleteReview, let approved = confirmation, canDownload, approved == LocalVADAssets.manifest else { return }
        confirmation = nil
        beginDownload()
        download = Task { do { try await transferApproved(approved) } catch { } }
    }

    func refreshRuntime() async {
        let state = await runtime.snapshot()
        isLoaded = state.isLoaded
        isLoading = state.isLoading
        isInUse = state.isInUse
    }

    func setIdleDuration(_ duration: Duration) async { await runtime.setIdleDuration(duration) }

    @discardableResult
    func load() -> Task<Void, Never>? {
        guard canLoad else { return nil }
        runLifecycle {
            self.message = "Loading voice activity detection. The microphone is off."
            try await self.runtime.load()
            try Task.checkCancellation()
            self.message = "Loaded. Voice activity detection is ready."
        }
        return download
    }

    func unload() {
        guard canUnload else { return }
        runLifecycle {
            try await self.validateIdleRuntime()
            await self.runtime.unload()
            self.message = "Unloaded. Downloaded voice activity files are retained."
        }
    }

    var measuredBytes: Int64? {
        if isDeleteReview { return removalTargets.reduce(0) { $0 + $1.bytes } }
        return try? LocalModelFiles.measuredBytes(at: root.appendingPathComponent(LocalVADAssets.manifest.installationName))
    }

    func releaseIdleResources() async {
        // The cache owns a warm handle only. Active processors retain their own manager.
        await runtime.unload()
        await refreshRuntime()
    }

    func reviewDelete() {
        guard canDelete else { return }
        do {
            availableRemovalTargets = try LocalModelFiles.removalTargets(LocalVADAssets.manifest, root: root)
            removalTargets = availableRemovalTargets
            guard !removalTargets.isEmpty else { throw LocalModelError.invalidAssets }
            isDeleteReview = true
            confirmation = LocalVADAssets.manifest
        } catch {
            hasError = true
            message = LocalModelError.invalidAssets.localizedDescription
        }
    }

    func selectRemovalTarget(_ name: String, included: Bool) {
        guard isDeleteReview, confirmation != nil, availableRemovalTargets.contains(where: { $0.name == name }) else { return }
        var names = Set(removalTargets.map(\.name))
        if included { names.insert(name) } else { names.remove(name) }
        removalTargets = availableRemovalTargets.filter { names.contains($0.name) }
    }

    func confirmDelete() {
        guard isDeleteReview, let approved = confirmation, approved == LocalVADAssets.manifest, canDelete, !removalTargets.isEmpty else { return }
        confirmation = nil
        let targets = removalTargets, removesInstallation = removesInstallation
        guard !targets.isEmpty else { return }
        runLifecycle(cancellable: false) {
            try await self.validateIdleRuntime()
            if removesInstallation { await self.runtime.unload() }
            try await self.validateIdleRuntime()
            self.message = "Removing the confirmed voice activity files..."
            do {
                for target in targets {
                    let url = try LocalModelFiles.confirmedRemovalTarget(target, manifest: approved, root: self.root)
                    try await self.remove(url)
                    if target.name == approved.installationName {
                        self.isInstalled = false
                        self.hasFiles = false
                    }
                }
            } catch {
                self.isInstalled = (try? (await self.verify(self.root)).get()) != nil
                throw error
            }
            self.message = removesInstallation
                ? "Deleted this voice activity revision. Recordings requiring it need an explicit download before use."
                : "Deleted the confirmed incomplete transfers. Installed voice activity files are retained."
        }
    }

    private func validateIdleRuntime() async throws {
        let state = await runtime.snapshot()
        guard !state.isInUse, !state.isLoading, !inUse(), !externalBusy() else { throw LocalModelError.busy }
    }

    private func runLifecycle(cancellable: Bool = true, _ action: @escaping @MainActor () async throws -> Void) {
        verificationGeneration = UUID()
        isBusy = true
        operationCancellable = cancellable
        hasError = false
        download = Task {
            do { try await action() }
            catch is CancellationError {
                await self.runtime.unload()
                self.message = "Model operation cancelled. No download was started."
            } catch {
                self.hasError = true
                self.message = (error as? LocalModelError)?.localizedDescription ?? (error as? LocalSpeechRuntimeError)?.localizedDescription ?? "Voice activity model operation failed. Review its files and try again."
            }
            await self.refreshRuntime()
            self.availableRemovalTargets = (try? LocalModelFiles.removalTargets(LocalVADAssets.manifest, root: self.root)) ?? []
            self.removalTargets = self.availableRemovalTargets
            self.isBusy = false
            self.operationCancellable = false
            self.download = nil
            AppState.shared.refresh()
        }
    }

    func installAsDependency(_ approved: LocalModelManifest) async throws {
        guard approved == LocalVADAssets.manifest else { throw LocalModelError.consentRequired }
        guard !isBusy else { throw LocalModelError.busy }
        guard !isInstalled else { throw LocalModelError.alreadyInstalled }
        beginDownload()
        try await transferApproved(approved)
    }

    private func beginDownload() {
        verificationGeneration = UUID()
        isBusy = true
        operationCancellable = true
        hasError = false
        message = "Downloading approved voice activity files..."
    }

    private func transferApproved(_ approved: LocalModelManifest) async throws {
        defer {
            availableRemovalTargets = (try? LocalModelFiles.removalTargets(approved, root: root)) ?? []
            removalTargets = availableRemovalTargets
            isBusy = false; operationCancellable = false; download = nil
            AppState.shared.refresh()
        }
        do {
            try await installer.install(approved, consent: approved) { [weak self] event in
                let message: String
                switch event.phase {
                case .downloading: message = "Downloading: \(ModelDisplayFormatting.size(event.completedBytes)) of \(ModelDisplayFormatting.size(event.totalBytes))."
                case .verifying: message = "Verifying downloaded voice activity files..."
                case .preparing: message = "Preparing the verified installation..."
                }
                await MainActor.run { self?.message = message }
            }
            isInstalled = true
            hasFiles = true
            message = "Downloaded and verified. Voice activity detection is available."
        } catch is CancellationError {
            message = "Download cancelled. Partial files are kept; nothing was installed."
            throw CancellationError()
        } catch {
            hasError = true
            message = (error as? LocalModelError)?.localizedDescription ?? LocalModelError.transferFailed.localizedDescription
            throw error
        }
    }

    func cancelDownload() {
        guard operationCancellable else { return }
        download?.cancel()
        message = "Cancelling model operation..."
    }
}
