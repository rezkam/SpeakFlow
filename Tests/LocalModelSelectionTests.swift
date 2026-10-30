import Foundation
import Testing
@testable import SpeakFlow
@testable import SpeakFlowCore

@Suite("Local model selection")
struct LocalModelSelectionTests {
    @MainActor private func provider(ready: Bool) throws -> LocalRecordingProvider {
        let model = try #require(LocalSpeechCatalog.models().first)
        let availability = LocalSpeechAvailability()
        availability.setReady(ready)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/selection-unused")
        let runtime = LocalSpeechRuntime(root: root, verify: { _, _ in
            Issue.record("Selection must not load or verify weights")
            throw LocalModelError.invalidAssets
        }, load: { _, _ in throw LocalModelError.invalidAssets })
        return LocalRecordingProvider(model: model, runtime: runtime, availability: availability)
    }

    @MainActor @Test func missingSelectedLocalModelDoesNotBecomeReadyBecauseACloudAccountExists() throws {
        let local = try provider(ready: false), cloud = MockStreamingProvider()
        cloud.isConfigured = true
        let registry = SpyProviderRegistry()
        registry.register(local)
        registry.register(cloud)
        let state = AppState(providerRegistry: registry, vadAvailability: { true })
        state.activeProviderId = local.id
        state.accessibilityGranted = true
        state.microphoneGranted = true
        #expect(!state.canStartDictation)
    }

    @MainActor @Test func installedLocalModelAppearsWithoutACloudAccountAndKeepsItsExactIdentity() throws {
        let local = try provider(ready: true)
        let state = AppState(providerRegistry: SpyProviderRegistry(), vadAvailability: { true })
        let models = ModelCatalog.availableModels(for: [local])
        #expect(models.count == 1)
        let descriptor = try #require(models.first)
        #expect(descriptor.id == local.id && descriptor.providerRegistryId == local.id)
        #expect(descriptor.name == local.model.name && descriptor.mode == .batch)
        #expect(ModelCatalog.activeModelId(for: local.id, in: state) == local.id)
    }
}

extension LocalModelSelectionTests {
    @MainActor @Test func anUnselectedLocalModelCannotMakeAnUnavailableCloudSelectionReady() throws {
        let local = try provider(ready: true)
        let registry = SpyProviderRegistry()
        registry.register(local)
        let state = AppState(providerRegistry: registry, vadAvailability: { true })
        state.activeProviderId = "unavailable-cloud"
        state.accessibilityGranted = true
        state.microphoneGranted = true
        #expect(!state.canStartDictation)
    }
}

extension LocalModelSelectionTests {
    @MainActor @Test func reviewedRevisionsHaveDistinctLabelsInTheModelPicker() throws {
        let original = try provider(ready: true), model = original.model, manifest = model.manifest
        let other = LocalSpeechModel(id: model.id, name: model.name, mode: model.mode,
            manifest: LocalModelManifest(id: manifest.id, repository: manifest.repository,
                revision: String(repeating: "b", count: 40), license: manifest.license,
                modelDirectory: manifest.modelDirectory, artifacts: manifest.artifacts))
        let available = LocalSpeechAvailability()
        available.setReady(true)
        let runtime = LocalSpeechRuntime(root: URL(fileURLWithPath: "/synthetic-model"))
        let retained = LocalRecordingProvider(model: other, runtime: runtime, availability: available)
        let descriptors = ModelCatalog.availableModels(for: [original, retained])
        #expect(Set(descriptors.map(\.name)).count == 2)
    }
}
