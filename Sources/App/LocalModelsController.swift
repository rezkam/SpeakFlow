import Foundation
import Observation
import SpeakFlowCore

struct LocalModelsStore {
    let root: URL
    let installer: ExplicitModelInstaller
    let audit: @Sendable (LocalSpeechModel, URL) async throws -> URL
    let remove: @Sendable (URL) async throws -> Void
}

@MainActor
struct LocalModelsSelection {
    let current: () -> String
    let commit: (String) -> Void
    let busy: () -> Bool
    let refresh: () -> Void
    let requiresVAD: () -> Bool
    let supported: Bool
}

struct LocalModelConfirmation {
    enum Kind { case download, delete }
    let kind: Kind
    let modelID: LocalSpeechModelID
    let manifests: [LocalModelManifest]
    var installedBytes: Int64? { kind == .delete ? removalTargets.reduce(0) { $0 + $1.bytes } : nil }
    var removalTargets: [LocalModelRemovalTarget]
    let availableRemovalTargets: [LocalModelRemovalTarget]
    var removesInstallation: Bool { removalTargets.contains { $0.name == manifests.last?.installationName } }
    init(kind: Kind, modelID: LocalSpeechModelID, manifests: [LocalModelManifest], removalTargets: [LocalModelRemovalTarget] = []) {
        self.kind = kind; self.modelID = modelID; self.manifests = manifests
        self.removalTargets = removalTargets; self.availableRemovalTargets = removalTargets
    }
}

@MainActor @Observable
final class LocalModelCardState {
    var isChecking = true
    var isInstalled = false
    var hasFiles = false
    var removalTargets: [LocalModelRemovalTarget] = []
    var hasError = false
    var message = "Checking local files..."
    var updateNotice: String?
}

@MainActor @Observable
final class LocalModelsController {
    static let shared = production()
    private(set) var models: [LocalSpeechModel]
    let reviewedModels: [LocalSpeechModel]
    let runtime: LocalSpeechRuntime
    let vad: VADInstallController
    var confirmation: LocalModelConfirmation?
    var catalogError: String?
    private(set) var resourceWarning: String?
    private(set) var runtimeState = LocalSpeechRuntimeSnapshot.empty
    private(set) var checkingUpdates = false
    private(set) var updateCheckFailed = false
    private(set) var updateMessage = "Checks metadata only. Downloads and activation remain explicit."
    private var updateCheck: Task<Void, Never>?
    private(set) var workingID: LocalSpeechModelID?
    private let store: LocalModelsStore
    private let selection: LocalModelsSelection
    private var cards: [String: LocalModelCardState] = [:]
    private var operation: Task<Void, Never>?
    private var auditGeneration = UUID()
    private var selectionGeneration = UUID()
    private var committingSelection = false
    private var selectingModel = false
    private(set) var operationCancellable = false

    var isBusy: Bool {
        operation != nil || checkingUpdates || vad.isBusy || runtimeState.loading != nil || !runtimeState.retiring.isEmpty
    }
    var blocksRecording: Bool { operation != nil || vad.isBusy }
    var recordingBusy: Bool { selection.busy() }
    var supported: Bool { selection.supported }
    var selectedProviderID: String { selection.current() }

    init(models: [LocalSpeechModel], store: LocalModelsStore, runtime: LocalSpeechRuntime,
         vad: VADInstallController, selection: LocalModelsSelection, reviewedVersions: [LocalSpeechModel] = []) {
        do {
            let catalog = try LocalModelVersionCatalog(preferred: models, retained: reviewedVersions)
            self.models = catalog.preferred.map { preferred in
                catalog.reviewed.first { $0.id == preferred.id && $0.providerID == selection.current() } ?? preferred
            }
            self.reviewedModels = catalog.reviewed
        } catch {
            self.models = []
            self.reviewedModels = []
            self.catalogError = LocalModelError.invalidManifest.localizedDescription
        }
        self.store = store
        self.runtime = runtime
        self.vad = vad
        self.selection = selection
        for model in reviewedModels { cards[model.providerID] = LocalModelCardState() }
        vad.externalBusy = { [weak self] in
            guard let self else { return false }
            return self.operation != nil || self.runtimeState.loading != nil || !self.runtimeState.retiring.isEmpty
        }
    }

    func entry(_ id: LocalSpeechModelID) -> LocalModelCardState {
        guard let model = model(id), let card = cards[model.providerID] else { preconditionFailure("Model is not in the bundled catalog") }
        return card
    }

    func refresh() async {
        guard operation == nil, !vad.isBusy else { return }
        let generation = UUID()
        auditGeneration = generation
        await vad.refresh()
        for model in reviewedModels {
            let installed: Bool
            do { _ = try await store.audit(model, store.root); installed = true } catch { installed = false }
            guard auditGeneration == generation, operation == nil else { return }
            guard let card = cards[model.providerID] else { continue }
            card.isChecking = false
            card.hasFiles = FileManager.default.fileExists(atPath: store.root.appendingPathComponent(model.manifest.installationName).path)
            card.removalTargets = (try? LocalModelFiles.removalTargets(model.manifest, root: store.root)) ?? []
            card.isInstalled = installed
            availability[model.providerID]?.setReady(card.isInstalled && supported)
            if !card.hasError {
                card.message = card.isInstalled ? "Downloaded and verified." : (card.hasFiles
                    ? "Files failed verification. Delete this exact revision before downloading it again."
                    : "Not downloaded. Review the download to install this model.")
            }
        }
        await refreshRuntime()
        selection.refresh()
    }

    private var availability: [String: LocalSpeechAvailability] = [:]
    func register(in registry: any ProviderRegistryProviding) {
        for model in reviewedModels {
            let readiness = availability[model.providerID] ?? LocalSpeechAvailability()
            readiness.setReady(cards[model.providerID]?.isInstalled == true && supported)
            availability[model.providerID] = readiness
            registry.register(LocalRecordingProvider(model: model, runtime: runtime, availability: readiness))
        }
    }

    func versions(_ id: LocalSpeechModelID) -> [LocalSpeechModel] { reviewedModels.filter { $0.id == id } }

    /// Browsing a retained revision does not activate it. Only a successful explicit
    /// Load changes the next-session provider pointer.
    func chooseVersion(_ providerID: String) {
        guard !isBusy, !recordingBusy, let candidate = reviewedModels.first(where: { $0.providerID == providerID }),
              let index = models.firstIndex(where: { $0.id == candidate.id }) else { return }
        models[index] = candidate
    }

    func refreshRuntime() async {
        runtimeState = await runtime.snapshot()
        await vad.refreshRuntime()
    }

    func bootstrap() async {
        let preferences = LocalModelPreferences.shared
        await vad.setIdleDuration(.seconds(preferences.idleSeconds))
        await runtime.setIdleDuration(.seconds(preferences.idleSeconds))
        await refresh()
        guard preferences.preloadOnLaunch, !isBusy, !recordingBusy else { return }
        let selected = selection.current()
        let model = models.first { $0.providerID == selected }
        let usesBatch = model.map { $0.mode == .batch } ?? (ProviderRegistry.shared.provider(for: selected)?.mode == .batch)
        if usesBatch, selection.requiresVAD() {
            guard vad.isInstalled else { return }
            if !vad.isLoaded {
                guard let preload = vad.load() else { return }
                await preload.value
                guard !vad.hasError, vad.isLoaded else { return }
            }
        }
        guard selection.current() == selected, !recordingBusy, !isBusy else { return }
        if let model { load(model.id) }
    }
    func setIdleSeconds(_ seconds: Int) {
        guard seconds >= 0 else { return }
        LocalModelPreferences.shared.idleSeconds = seconds
        Task {
            await runtime.setIdleDuration(.seconds(seconds))
            await vad.setIdleDuration(.seconds(seconds))
        }
    }

    func canDownload(_ id: LocalSpeechModelID) -> Bool {
        let card = entry(id)
        return supported && !card.isChecking && !card.isInstalled && !card.hasFiles && !isBusy && !recordingBusy
    }
    func canLoad(_ id: LocalSpeechModelID) -> Bool {
        supported && entry(id).isInstalled && !needsVAD(id) && !isBusy && !recordingBusy && !runtimeState.inUse.contains(id)
    }
    func needsVAD(_ id: LocalSpeechModelID) -> Bool {
        model(id)?.mode == .batch && selection.requiresVAD() && !vad.isInstalled
    }
    func canUnload(_ id: LocalSpeechModelID) -> Bool {
        runtimeState.loadedRevisions[id] == model(id)?.manifest.revision && runtimeState.loaded.contains(id) && !runtimeState.inUse.contains(id) && !isBusy && !recordingBusy
    }
    func canDelete(_ id: LocalSpeechModelID) -> Bool {
        supported && (entry(id).hasFiles || entry(id).isInstalled || !entry(id).removalTargets.isEmpty) && !isBusy && !recordingBusy && !runtimeState.inUse.contains(id)
    }

    func reviewDownload(_ id: LocalSpeechModelID) {
        guard canDownload(id), let model = model(id) else { return }
        let dependencies = model.mode == .batch && selection.requiresVAD() && !vad.isInstalled ? [LocalVADAssets.manifest] : []
        confirmation = LocalModelConfirmation(kind: .download, modelID: id, manifests: dependencies + [model.manifest])
    }
    func reviewDelete(_ id: LocalSpeechModelID) {
        guard canDelete(id), let model = model(id) else { return }
        do {
            let targets = try LocalModelFiles.removalTargets(model.manifest, root: store.root)
            guard !targets.isEmpty else { throw LocalModelError.invalidAssets }
            confirmation = LocalModelConfirmation(kind: .delete, modelID: id, manifests: [model.manifest],
                removalTargets: targets)
        } catch { fail(id, error) }
    }
    func selectRemovalTarget(_ name: String, included: Bool) {
        guard var review = confirmation, review.kind == .delete,
              review.availableRemovalTargets.contains(where: { $0.name == name }) else { return }
        var names = Set(review.removalTargets.map(\.name))
        if included { names.insert(name) } else { names.remove(name) }
        review.removalTargets = review.availableRemovalTargets.filter { names.contains($0.name) }
        confirmation = review
    }

    func confirmOperation() {
        guard let review = confirmation, let model = model(review.modelID), !isBusy, !recordingBusy,
              review.manifests.last == model.manifest,
              review.kind != .delete || !review.removalTargets.isEmpty else { return }
        confirmation = nil
        switch review.kind {
        case .download:
            let dependencies = model.mode == .batch && selection.requiresVAD() && !vad.isInstalled ? [LocalVADAssets.manifest] : []
            guard review.manifests == dependencies + [model.manifest] else { fail(model.id, LocalModelError.consentRequired); return }
            run(model.id) {
                if dependencies.contains(LocalVADAssets.manifest) { try await self.vad.installAsDependency(LocalVADAssets.manifest) }
                try await self.store.installer.install(model.manifest, consent: model.manifest) { [weak self] event in
                    await MainActor.run {
                        self?.entry(model.id).message = "\(event.phase.rawValue.capitalized): \(event.completedBytes) of \(event.totalBytes) bytes."
                    }
                }
                self.entry(model.id).isInstalled = true
                self.entry(model.id).hasFiles = true
                self.availability[model.providerID]?.setReady(true)
                self.entry(model.id).message = "Downloaded and verified. Load to select this model."
            }
        case .delete:
            guard review.manifests == [model.manifest] else { fail(model.id, LocalModelError.consentRequired); return }
            guard !review.removalTargets.isEmpty else { fail(model.id, LocalModelError.consentRequired); return }
            run(model.id, cancellable: false) {
                self.entry(model.id).message = "Removing the confirmed files..."
                if await self.runtime.snapshot().loadedRevisions[model.id] == model.manifest.revision,
                   review.removesInstallation { try await self.runtime.unload(model.id) }
                do {
                    for target in review.removalTargets {
                        let url = try LocalModelFiles.confirmedRemovalTarget(target, manifest: model.manifest, root: self.store.root)
                        try await self.store.remove(url)
                        if target.name == model.manifest.installationName {
                            self.availability[model.providerID]?.setReady(false)
                            self.entry(model.id).isInstalled = false
                            self.entry(model.id).hasFiles = false
                        }
                    }
                } catch {
                    let installed = (try? await self.store.audit(model, self.store.root)) != nil
                    self.entry(model.id).isInstalled = installed
                    self.availability[model.providerID]?.setReady(installed && self.supported)
                    throw error
                }
                self.entry(model.id).message = review.removesInstallation
                    ? "Deleted this revision. Other revisions and voice activity files are retained."
                    : "Deleted the confirmed incomplete transfers. Installed model files are retained."
            }
        }
    }

    func load(_ id: LocalSpeechModelID) {
        guard canLoad(id), let model = model(id) else { return }
        guard model.mode != .batch || !selection.requiresVAD() || vad.isInstalled else {
            fail(id, LocalModelError.missingVAD); return
        }
        let generation = selectionGeneration, previous = selection.current()
        run(id, selectsModel: true) {
            self.entry(id).message = "Loading local model. The microphone is off."
            do {
                try await self.runtime.loadAndSelect(model)
                try Task.checkCancellation()
                guard self.selectionGeneration == generation, self.selection.current() == previous else { throw CancellationError() }
            } catch {
                if error is CancellationError { await self.runtime.clearSelection() }
                throw error
            }
            self.committingSelection = true
            self.selection.commit(model.providerID)
            self.committingSelection = false
            self.entry(id).message = "Loaded and selected for subsequent dictation."
        }
    }
    func load(providerID: String) {
        guard let model = reviewedModels.first(where: { $0.providerID == providerID }) else { return }
        chooseVersion(providerID)
        if self.model(model.id)?.providerID == providerID { load(model.id) }
    }
    func unload(_ id: LocalSpeechModelID) {
        guard canUnload(id) else { return }
        run(id) {
            try await self.runtime.unload(id)
            self.entry(id).message = "Unloaded. Downloaded files and selection are retained."
        }
    }
    func cancelOperation() {
        if let operation { if operationCancellable { operation.cancel() } } else if vad.isBusy { vad.cancelDownload() } else { updateCheck?.cancel() }
    }
    func providerSelectionChanged(_ id: String) {
        guard !committingSelection else { return }
        selectionGeneration = UUID()
        if selectingModel { operation?.cancel() }
        Task { await runtime.clearSelection() }
    }

    private func run(_ id: LocalSpeechModelID, selectsModel: Bool = false, cancellable: Bool = true,
                     action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil, !recordingBusy else { return }
        auditGeneration = UUID()
        workingID = id
        selectingModel = selectsModel
        operationCancellable = cancellable
        entry(id).hasError = false
        operation = Task {
            do { try await action() } catch is CancellationError { entry(id).message = "Cancelled. Native work may still be releasing its resources." } catch { fail(id, error) }
            await refreshRuntime()
            if let model = model(id) {
                entry(id).removalTargets = (try? LocalModelFiles.removalTargets(model.manifest, root: store.root)) ?? []
            }
            workingID = nil
            operationCancellable = false
            selectingModel = false
            operation = nil
            selection.refresh()
        }
    }
    private func fail(_ id: LocalSpeechModelID, _ error: Error) {
        entry(id).hasError = true
        entry(id).message = (error as? LocalModelError)?.localizedDescription
            ?? (error as? LocalSpeechRuntimeError)?.localizedDescription
            ?? (error as? LocalSpeechComputeError)?.localizedDescription
            ?? "The model operation failed. Review its files in Models and try again."
    }
    private func model(_ id: LocalSpeechModelID) -> LocalSpeechModel? { models.first { $0.id == id } }

    func checkForUpdates(using checker: LocalModelUpdateChecker = LocalModelUpdateChecker()) {
        guard !isBusy, !recordingBusy else { return }
        checkingUpdates = true
        updateCheckFailed = false
        updateMessage = "Checking source metadata. No model files are transferred."
        updateCheck = Task {
            defer { checkingUpdates = false; updateCheck = nil }
            for model in models {
                do {
                    let result = try await checker.check(model.manifest)
                    cards[model.providerID]?.updateNotice = updateNotice(result, repository: model.manifest.repository)
                } catch is CancellationError { updateMessage = "Update check cancelled. Installed models are unchanged."; return }
                catch { updateCheckFailed = true }
            }
            do {
                let result = try await checker.check(LocalVADAssets.manifest)
                vad.updateNotice = updateNotice(result, repository: LocalVADAssets.manifest.repository)
            } catch is CancellationError { updateMessage = "Update check cancelled. Installed models are unchanged."; return }
            catch { updateCheckFailed = true }
            updateMessage = updateCheckFailed
                ? "Some sources could not be checked. Installed models remain usable. Try the check again later."
                : "Source checks completed. Only app-reviewed revisions can be installed or activated."
        }
    }

    private func updateNotice(_ update: LocalModelSourceUpdate, repository: String) -> String {
        switch update {
        case .current: "Source metadata matches this reviewed revision."
        case .unreviewed(let revision):
            if reviewedModels.contains(where: { $0.manifest.repository == repository && $0.manifest.revision == revision }) {
                "Another reviewed revision is available in Versions. Download and Load remain explicit."
            } else { "Source metadata points to a different revision. App catalog review is required before downloading or loading it." }
        }
    }

    func handleResourceEvent(_ event: LocalModelResourceEvent) {
        switch event {
        case .thermalWarning:
            resourceWarning = "High thermal pressure may slow local inference. Recordings retain their current model."
        case .thermalRecovered:
            resourceWarning = nil
        case .wake:
            Task { await self.refresh() }
        case .sleep, .memoryPressure:
            if selectingModel || event == .sleep { operation?.cancel() }
            resourceWarning = event == .sleep
                ? "Local dictation was cancelled for sleep. Start a new recording after wake."
                : "Memory pressure released idle models. Active recordings keep their model until they finish."
            Task {
                await self.runtime.releaseIdleResources()
                await self.vad.releaseIdleResources()
                await self.refreshRuntime()
            }
        }
    }

    private static func production() -> LocalModelsController {
        let models: [LocalSpeechModel]
        let retained: [LocalSpeechModel]
        var catalogFailed = false
        do {
            let preferredModels = try LocalSpeechCatalog.models()
            let retainedModels = try LocalSpeechCatalog.retainedModels()
            models = preferredModels
            retained = retainedModels
        } catch { models = []; retained = []; catalogFailed = true }
        let root: URL
        if let path = ProcessInfo.processInfo.environment["SPEAKFLOW_LOCAL_MODEL_CACHE_ROOT"], !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else { root = VADModelCache.modelCacheRoot() }
        let current = ProviderSettings.shared.activeProviderId
        let runtime = LocalSpeechRuntime(root: root, idleDuration: .seconds(LocalModelPreferences.shared.idleSeconds),
            selected: models.first { $0.providerID == current }?.id)
        let store = LocalModelsStore(root: root, installer: ExplicitModelInstaller(root: root), audit: { model, root in
            try await Task.detached { try await LocalSpeechRuntime.verifyFiles(model, root: root) }.value
        }, remove: { target in try FileManager.default.removeItem(at: target) })
        #if arch(arm64)
        let supported = true
        #else
        let supported = false
        #endif
        let selection = LocalModelsSelection(current: { ProviderSettings.shared.activeProviderId }, commit: {
            ProviderSettings.shared.activeProviderId = $0
            AppState.shared.refresh()
        }, busy: { AppState.shared.isRecording || AppState.shared.isProcessingFinal || AppState.shared.isPreparingLocalModel },
            refresh: { AppState.shared.refresh() }, requiresVAD: { Settings.shared.vadEnabled }, supported: supported)
        let controller = LocalModelsController(models: models, store: store, runtime: runtime,
            vad: VADInstallController.shared, selection: selection, reviewedVersions: retained)
        if catalogFailed { controller.catalogError = LocalModelError.invalidManifest.localizedDescription }
        return controller
    }
}
