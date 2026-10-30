import CryptoKit
import Foundation
import os
import Testing
@testable import SpeakFlowCore

@Suite("Explicit model installation")
struct ExplicitModelInstallerTests {
    private let bytes = Data("synthetic model fixture".utf8)

    private func manifest(path: String = "fixture.mlmodelc/weights.bin", directory: String = "fixture.mlmodelc") -> LocalModelManifest {
        LocalModelManifest(id: "fixture", repository: "example/model", revision: String(repeating: "a", count: 40),
            license: "MIT", modelDirectory: directory, artifacts: [
                ModelArtifact(path: path, bytes: Int64(bytes.count), digest: .sha256,
                    checksum: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            ])
    }

    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/installer-\(UUID().uuidString)")
    }

    @Test func denialMakesNoRequestAndCreatesNoStore() async throws {
        let root = root()
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, _, _ in
            Issue.record("Denied installation must not fetch anything")
        })
        await #expect(throws: LocalModelError.consentRequired) {
            try await installer.install(manifest(), consent: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func exactConsentPublishesVerifiedReceiptAndFiles() async throws {
        let root = root(), manifest = manifest(), bytes = bytes
        let installer = ExplicitModelInstaller(root: root, fetch: { artifact, url, file, _ in
            #expect(url.host == "huggingface.co")
            #expect(url.path.contains(manifest.revision))
            #expect(artifact.bytes == bytes.count)
            try bytes.write(to: file, options: .withoutOverwriting)
        }, availableBytes: { _ in Int64.max })
        try await installer.install(manifest, consent: manifest)
        try LocalModelFiles.verify(manifest, installation: root.appendingPathComponent(manifest.installationName))
        #expect(ModelHubPolicyProbe.offline)
    }

    @Test(arguments: [".", "latin/1120ms"])
    func exportLayoutsInstallWithVerifiedReceipts(directory: String) async throws {
        let path = directory == "." ? "weights.bin" : "\(directory)/weights.bin"
        let root = root(), manifest = manifest(path: path, directory: directory), bytes = bytes
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, file, _ in
            try bytes.write(to: file, options: .withoutOverwriting)
        }, availableBytes: { _ in Int64.max })
        try await installer.install(manifest, consent: manifest)
        let installation = root.appendingPathComponent(manifest.installationName)
        try LocalModelFiles.verify(manifest, installation: installation)
        #expect(try Data(contentsOf: installation.appendingPathComponent(path)) == bytes)
    }

    @Test func changedManifestInvalidatesConsent() async throws {
        let installer = ExplicitModelInstaller(root: root(), fetch: { _, _, _, _ in
            Issue.record("Changed manifest must not transfer")
        })
        await #expect(throws: LocalModelError.consentRequired) {
            try await installer.install(manifest(), consent: manifest(path: "fixture.mlmodelc/other.bin"))
        }
    }

    @Test func invalidHashNeverPublishesAndRetainsPartialForExplicitCleanup() async throws {
        let root = root(), manifest = manifest()
        let invalidBytes = Data(repeating: 0, count: bytes.count)
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, file, _ in
            try invalidBytes.write(to: file, options: .withoutOverwriting)
        },
                                               availableBytes: { _ in Int64.max })
        await #expect(throws: LocalModelError.invalidAssets) {
            try await installer.install(manifest, consent: manifest)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(manifest.installationName).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("partial-") })
    }

    @Test func lowDiskRefusesBeforeTransfer() async throws {
        let installer = ExplicitModelInstaller(root: root(), fetch: { _, _, _, _ in
            Issue.record("Low disk must refuse before network access")
        }, availableBytes: { _ in 0 })
        let manifest = manifest()
        await #expect(throws: LocalModelError.insufficientSpace) {
            try await installer.install(manifest, consent: manifest)
        }
    }

    @Test func unsafePathsAreRejected() throws {
        for path in ["../outside", "/absolute", "fixture.mlmodelc/../outside", "fixture.mlmodelc//weights.bin"] {
            #expect(throws: LocalModelError.invalidManifest) { try manifest(path: path).validate() }
        }
    }

    @Test func cancelledInstallNeverPublishes() async throws {
        let root = root(), manifest = manifest()
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, _, _ in throw CancellationError() },
                                               availableBytes: { _ in Int64.max })
        await #expect(throws: CancellationError.self) { try await installer.install(manifest, consent: manifest) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(manifest.installationName).path))
    }

    @Test func missingOrChangedReceiptAndSymlinksAreNotTrusted() async throws {
        let root = root(), manifest = manifest(), bytes = bytes
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, file, _ in
            try bytes.write(to: file, options: .withoutOverwriting)
        }, availableBytes: { _ in Int64.max })
        try await installer.install(manifest, consent: manifest)
        let installation = root.appendingPathComponent(manifest.installationName)
        try Data("invalid receipt".utf8).write(to: installation.appendingPathComponent("receipt.json"))
        #expect(throws: LocalModelError.invalidAssets) { try LocalModelFiles.verify(manifest, installation: installation) }
        let link = root.appendingPathComponent("linked-model")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installation)
        #expect(throws: LocalModelError.invalidAssets) { try LocalModelFiles.verify(manifest, installation: link) }
    }

    @Test func reportsDownloadVerificationAndPreparationAsDistinctPhases() async throws {
        let root = root(), manifest = manifest(), bytes = bytes
        let phases = OSAllocatedUnfairLock(initialState: [String]())
        let installer = ExplicitModelInstaller(root: root, fetch: { _, _, file, _ in
            try bytes.write(to: file, options: .withoutOverwriting)
        }, availableBytes: { _ in Int64.max })
        try await installer.install(manifest, consent: manifest) { event in
            phases.withLock { $0.append(event.phase.rawValue) }
        }
        #expect(phases.withLock { $0 } == ["downloading", "verifying", "preparing"])
    }

    @Test func approvedVADManifestIsComplete() throws {
        let manifest = LocalVADAssets.manifest
        try manifest.validate()
        #expect(manifest.artifacts.count == 5)
        #expect(manifest.transferBytes == 1_063_425)
    }
}

import FluidAudio
private enum ModelHubPolicyProbe {
    static var offline: Bool { ModelHub.offlineMode }
}
