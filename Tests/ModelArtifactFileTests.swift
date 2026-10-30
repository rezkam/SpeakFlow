import CryptoKit
import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Streamed model artifact verification")
struct ModelArtifactFileTests {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/artifact-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("weights.bin")
    }

    private func artifact(_ bytes: Data, digest: ModelArtifact.Digest = .sha256) -> ModelArtifact {
        let hash: String
        switch digest {
        case .sha256: hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        case .gitBlobSHA1:
            hash = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes)
                .map { String(format: "%02x", $0) }.joined()
        }
        return ModelArtifact(path: "weights.bin", bytes: Int64(bytes.count), digest: digest, checksum: hash)
    }

    @Test(arguments: [ModelArtifact.Digest.sha256, .gitBlobSHA1])
    func verifiesFilesAcrossReadBoundaries(digest: ModelArtifact.Digest) throws {
        let bytes = Data(repeating: 0x5a, count: 131_073)
        let file = try fixture()
        try bytes.write(to: file, options: .withoutOverwriting)
        try artifact(bytes, digest: digest).verify(fileAt: file)
    }

    @Test(arguments: ["truncated", "oversized", "changed-tail", "missing", "symlink"])
    func rejectsChangedOrUnsafeFiles(change: String) throws {
        let bytes = Data(repeating: 0x5a, count: 131_073)
        let file = try fixture()
        var modified = bytes
        switch change {
        case "truncated": modified.removeLast()
        case "oversized": modified.append(0)
        case "changed-tail": modified[modified.count - 1] = 0
        default: break
        }
        if change == "symlink" {
            try bytes.write(to: file.deletingLastPathComponent().appendingPathComponent("target.bin"))
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "target.bin")
        } else if change != "missing" {
            try modified.write(to: file, options: .withoutOverwriting)
        }
        #expect(throws: LocalModelError.invalidAssets) { try artifact(bytes).verify(fileAt: file) }
    }

    @Test func rejectsALFSStubEvenWhenItsHashMatches() throws {
        let bytes = Data("version https://git-lfs.github.com/spec/v1\noid sha256:fixture\nsize 123\n".utf8)
        let file = try fixture()
        try bytes.write(to: file, options: .withoutOverwriting)
        #expect(throws: LocalModelError.invalidAssets) { try artifact(bytes).verify(fileAt: file) }
    }
}
