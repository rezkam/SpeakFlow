import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Local model manifest paths")
struct LocalModelManifestTests {
    private func manifest(directory: String, paths: [String], repository: String = "example/model") -> LocalModelManifest {
        LocalModelManifest(id: "fixture", repository: repository,
            revision: String(repeating: "a", count: 40), license: "MIT", modelDirectory: directory,
            artifacts: paths.map {
                ModelArtifact(path: $0, bytes: 1, digest: .sha256, checksum: String(repeating: "a", count: 64))
            })
    }

    @Test func rootAndNestedExportsHaveUnambiguousArtifactLocations() throws {
        try manifest(directory: ".", paths: ["encoder.mlmodelc/weights.bin", "vocabulary.json"]).validate()
        try manifest(directory: "latin/1120ms", paths: ["latin/1120ms/encoder.mlmodelc/weights.bin"]).validate()
    }

    @Test(arguments: ["/example/model", "example//model", "example/model/", "../model"])
    func repositoryMustHaveExactlyTwoNonemptySafeComponents(repository: String) {
        #expect(throws: LocalModelError.invalidManifest) {
            try manifest(directory: "export", paths: ["export/weights.bin"], repository: repository).validate()
        }
    }

    @Test(arguments: ["../export", "latin//1120ms", "/export", "latin/../export", "export/"])
    func unsafeExportDirectoriesAreRejected(directory: String) {
        #expect(throws: LocalModelError.invalidManifest) {
            try manifest(directory: directory, paths: ["\(directory)/weights.bin"]).validate()
        }
    }

    @Test func filesCannotEscapeTheirExportOrCollideWithDirectoriesOrReceipt() {
        for (directory, paths) in [
            ("latin/1120ms", ["latin/2240ms/weights.bin"]),
            ("export", ["export/weights", "export/weights/data.bin"]),
            (".", ["receipt.json"]),
            (".", ["receipt.json/weights.bin"]),
            (".", ["Receipt.JSON"]),
            (".", ["Weights.bin", "weights.bin"]),
            (".", ["Weights", "weights/data.bin"]),
            (".", ["../weights.bin"]),
            (".", ["weights.bin", "weights.bin"])
        ] {
            #expect(throws: LocalModelError.invalidManifest) {
                try manifest(directory: directory, paths: paths).validate()
            }
        }
    }
}
