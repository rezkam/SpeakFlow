import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Local model removal guards")
struct LocalModelRemovalTests {
    @Test func removalRejectsNestedLinksBeforeCallingAnyRemover() throws {
        let model = try #require(LocalSpeechCatalog.models().first)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/removal-\(UUID().uuidString)")
        let target = root.appendingPathComponent(model.manifest.installationName)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent("unexpected-link").path,
                                                   withDestinationPath: "../outside")
        #expect(throws: LocalModelError.invalidAssets) {
            try LocalModelFiles.removalTarget(model.manifest, consent: model.manifest, root: root)
        }
    }
}

extension LocalModelRemovalTests {
    @Test func cleanupNamesOnlyThisExactRevisionAndRejectsChangedTargets() throws {
        let model = try #require(LocalSpeechCatalog.models().first)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/cleanup-\(UUID().uuidString)")
        let name = "partial-\(model.manifest.installationName)-\(UUID().uuidString)"
        let partial = root.appendingPathComponent(name)
        let foreign = root.appendingPathComponent("partial-\(model.id.rawValue)-\(String(repeating: "b", count: 40))-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let bytes = partial.appendingPathComponent("inert.bin")
        try Data("fixture".utf8).write(to: bytes)
        let targets = try LocalModelFiles.removalTargets(model.manifest, root: root)
        #expect(targets.map(\.name) == [name])
        #expect(targets.first?.bytes == 7)
        let approved = try #require(targets.first)
        // A directory hint may add a trailing slash without changing the filesystem target.
        #expect(try LocalModelFiles.confirmedRemovalTarget(approved, manifest: model.manifest, root: root).standardizedFileURL.path
            == partial.standardizedFileURL.path)
        try Data("changed fixture".utf8).write(to: bytes)
        #expect(throws: LocalModelError.consentRequired) {
            try LocalModelFiles.confirmedRemovalTarget(approved, manifest: model.manifest, root: root)
        }
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }
}
