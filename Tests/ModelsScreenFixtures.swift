import Foundation
@testable import SpeakFlow
@testable import SpeakFlowCore

private actor ModelPreviewEngine: LocalBatchSpeechEngine, LocalStreamingSpeechEngine {
    func transcribe(samples: [Float]) async throws -> String { "fixture words" }
    func reset() async throws {}
    func process(samples: [Float]) async throws -> String { "fixture words" }
    func finish() async throws -> String { "fixture words" }
    func cleanup() async {}
}

@MainActor private final class ModelPreviewSelection { var id = "fixture-cloud" }

@MainActor
enum ModelsScreenFixtures {
    /// Inference and transfers are fake. Physical removal requires a separately approved,
    /// explicitly enabled marker fixture and is restricted to its exact known contents.
    static func make(root: URL, vad: VADInstallController,
                     available: @escaping @Sendable () -> Bool = { false }, allowFixtureRemoval: Bool = false) throws -> LocalModelsController {
        let catalog = try LocalSpeechCatalog.models()
        guard let expectedName = catalog.first(where: { $0.id == .parakeet110M })?.manifest.installationName else {
            throw LocalModelError.invalidManifest
        }
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, _, _ in throw LocalModelError.transferFailed },
            availableBytes: { _ in Int64.max })
        let store = LocalModelsStore(root: root, installer: installer, audit: { _, root in
            guard available() else { throw LocalSpeechRuntimeError.missingModel }
            return root
        }, remove: { target in
            guard allowFixtureRemoval, root.lastPathComponent == "model-delete-verification-20261030",
                  target.lastPathComponent == expectedName,
                  target.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                  try FileManager.default.contentsOfDirectory(atPath: target.path) == ["synthetic-marker.txt"],
                  try Data(contentsOf: target.appendingPathComponent("synthetic-marker.txt")) == Data("Disposable model test fixture.\n".utf8) else {
                throw LocalModelError.invalidAssets
            }
            try FileManager.default.removeItem(at: target)
        })
        let runtime = LocalSpeechRuntime(root: root, verify: { _, root in root }, load: { _, _ in ModelPreviewEngine() })
        let selected = ModelPreviewSelection()
        let selection = LocalModelsSelection(current: { selected.id }, commit: { selected.id = $0 }, busy: { false },
            refresh: {}, requiresVAD: { true }, supported: true)
        return LocalModelsController(models: catalog, store: store, runtime: runtime, vad: vad, selection: selection)
    }
}
