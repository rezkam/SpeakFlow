import CoreML
import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Local speech catalog")
struct LocalSpeechCatalogTests {
    @Test func approvedExportsHaveCompleteImmutableManifests() throws {
        let models = try LocalSpeechCatalog.models()
        #expect(models.map(\.id) == [.parakeet110M, .parakeetV2, .nemotron1120])
        #expect(models.map(\.manifest.transferBytes) == [227_466_209, 464_413_247, 611_340_223])
        #expect(models.map(\.mode) == [.batch, .batch, .streaming])
        #expect(models.allSatisfy { $0.languages == ["en"] && $0.fluidAudioVersion == "0.18.0" })
        #expect(models.map(\.manifest.artifacts.count) == [16, 21, 22])
        for model in models { try model.manifest.validate() }
        let streaming = try #require(models.first { $0.id == .nemotron1120 })
        #expect(streaming.manifest.modelDirectory == "latin/1120ms")
        #expect(streaming.manifest.revision == "1a41b75758b0337ff67db7d5408280aaaf23074e")
    }

    @Test func catalogRejectsMissingDuplicateAndUnapprovedExports() throws {
        let manifests = try LocalSpeechCatalog.models().map(\.manifest)
        for invalid in [Array(manifests.dropLast()), manifests + [manifests[0]]] {
            #expect(throws: LocalModelError.invalidManifest) {
                try LocalSpeechCatalog.models(manifests: invalid)
            }
        }
        let unexpected = LocalModelManifest(id: "nemotron-latin-2240", repository: manifests[2].repository,
            revision: manifests[2].revision, license: manifests[2].license,
            modelDirectory: manifests[2].modelDirectory, artifacts: manifests[2].artifacts)
        #expect(throws: LocalModelError.invalidManifest) {
            try LocalSpeechCatalog.models(manifests: manifests + [unexpected])
        }
    }

    @Test func unsupportedHardwareHasAnExplanationWithoutInventedMemoryRequirements() throws {
        let model = try #require(LocalSpeechCatalog.models().first)
        #expect(model.unavailabilityReason(isAppleSilicon: false) == "Requires Apple Silicon and macOS 26 or later.")
        #expect(model.unavailabilityReason(isAppleSilicon: true) == nil)
        #expect(model.measuredMemoryBytes == nil)
    }
}

@Suite("Local speech acceleration")
struct LocalSpeechAccelerationTests {
    @Test func inferenceExplicitlyAllowsTheNeuralEngine() throws {
        let configuration = try LocalSpeechCompute.configuration(environment: [:])
        #expect(configuration.computeUnits == .cpuAndNeuralEngine)
        let ci = try LocalSpeechCompute.configuration(environment: ["CI": "1"])
        #expect(ci.computeUnits == .cpuAndNeuralEngine)
    }

    @Test(arguments: ["FLUIDAUDIO_ENCODER_CU", "FLUIDAUDIO_DECODER_CU", "FLUIDAUDIO_DECODERJOINT_CU",
                      "FLUIDAUDIO_JOINT_CU", "FLUIDAUDIO_JOINT_BATCHED_CU"])
    func libraryOverridesCannotSilentlyDisableAcceleration(key: String) throws {
        for value in ["CPU", "CPU_ONLY", "CPU_AND_GPU", "ALL", "invalid"] {
            #expect(throws: LocalSpeechComputeError.unsupportedOverride) {
                try LocalSpeechCompute.configuration(environment: [key: value])
            }
        }
        #expect(try LocalSpeechCompute.configuration(environment: [key: "CPU_AND_NE"]).computeUnits == .cpuAndNeuralEngine)
    }
}
