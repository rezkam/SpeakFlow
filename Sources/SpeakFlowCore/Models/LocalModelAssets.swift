import CryptoKit
import Foundation
import FluidAudio

/// Set once before any library loader can run. Installation uses its own transport.
public enum ModelNetworkPolicy {
    private static let bootstrap: Void = { ModelHub.offlineMode = true }()
    public static func initialize() { _ = bootstrap }
}

public enum LocalModelError: Error, LocalizedError, Equatable {
    case missingVAD
    case invalidAssets
    case invalidManifest
    case consentRequired
    case alreadyInstalled
    case transferFailed
    case insufficientSpace
    case busy

    public var errorDescription: String? {
        switch self {
        case .missingVAD: "Download the required voice activity model in Models before recording."
        case .invalidAssets: "Model files failed verification. Review the files in Models before trying again."
        case .invalidManifest: "The model manifest is incomplete or unsafe. Installation is unavailable."
        case .consentRequired: "Review and confirm the exact model files first."
        case .alreadyInstalled: "This model revision is already installed."
        case .transferFailed: "Download failed. Partial files are kept for explicit cleanup."
        case .insufficientSpace: "There is not enough free storage for this download."
        case .busy: "Another model operation is already running."
        }
    }
}

public struct ModelArtifact: Codable, Hashable, Sendable {
    public enum Digest: String, Codable, Sendable { case sha256, gitBlobSHA1 }
    public let path: String
    public let bytes: Int64
    public let digest: Digest
    public let checksum: String

    public init(path: String, bytes: Int64, digest: Digest, checksum: String) {
        self.path = path
        self.bytes = bytes
        self.digest = digest
        self.checksum = checksum
    }

    public func verify(fileAt url: URL) throws {
        do {
            try LocalModelFiles.rejectSymbolicLinks(url)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard bytes > 0, values.isRegularFile == true, values.fileSize.map(Int64.init) == bytes else {
                throw LocalModelError.invalidAssets
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var sha256 = SHA256()
            var gitSHA1 = Insecure.SHA1()
            if digest == .gitBlobSHA1 { gitSHA1.update(data: Data("blob \(bytes)\0".utf8)) }
            var consumed: Int64 = 0
            while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation()
                guard Int64(chunk.count) <= bytes - consumed,
                      consumed != 0 || !chunk.starts(with: Data("version https://git-lfs.github.com/spec/".utf8)) else {
                    throw LocalModelError.invalidAssets
                }
                consumed += Int64(chunk.count)
                switch digest {
                case .sha256: sha256.update(data: chunk)
                case .gitBlobSHA1: gitSHA1.update(data: chunk)
                }
            }
            let actual = digest == .sha256 ? Array(sha256.finalize()) : Array(gitSHA1.finalize())
            guard consumed == bytes, actual.map({ String(format: "%02x", $0) }).joined() == checksum else {
                throw LocalModelError.invalidAssets
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalModelError.invalidAssets
        }
    }
}

public struct LocalModelManifest: Codable, Hashable, Sendable {
    public let id: String
    public let repository: String
    public let revision: String
    public let license: String
    public let modelDirectory: String
    public let artifacts: [ModelArtifact]

    public init(id: String, repository: String, revision: String, license: String,
                modelDirectory: String, artifacts: [ModelArtifact]) {
        self.id = id
        self.repository = repository
        self.revision = revision
        self.license = license
        self.modelDirectory = modelDirectory
        self.artifacts = artifacts
    }

    public var transferBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    public var installationName: String { "\(id)-\(revision)" }

    public func validate() throws {
        let safe: (String) -> Bool = { value in
            !value.isEmpty && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            } && value != "." && value != ".."
        }
        let directory = modelDirectory == "." ? [] : modelDirectory.split(separator: "/", omittingEmptySubsequences: false)
        let source = repository.split(separator: "/", omittingEmptySubsequences: false)
        let validDirectory = modelDirectory == "." || (!directory.isEmpty && directory.allSatisfy({ safe(String($0)) }))
        guard safe(id), validDirectory,
              source.count == 2, source.allSatisfy({ safe(String($0)) }),
              revision.count == 40, revision.allSatisfy({ $0.isHexDigit }), !license.isEmpty,
              !artifacts.isEmpty, Set(artifacts.map(\.path)).count == artifacts.count else {
            throw LocalModelError.invalidManifest
        }
        // The store must be unambiguous on both case-sensitive and case-insensitive volumes.
        let paths = artifacts.map { $0.path.lowercased() }
        let pathSet = Set(paths)
        guard pathSet.count == paths.count else { throw LocalModelError.invalidManifest }
        var total: Int64 = 0
        for artifact in artifacts {
            let parts = artifact.path.split(separator: "/", omittingEmptySubsequences: false)
            let (sum, overflow) = total.addingReportingOverflow(artifact.bytes)
            guard !overflow, artifact.bytes > 0, parts.allSatisfy({ safe(String($0)) }),
                  parts.count > directory.count, parts.starts(with: directory),
                  parts.first?.lowercased() != "receipt.json",
                  artifact.checksum.count == (artifact.digest == .sha256 ? 64 : 40),
                  artifact.checksum.allSatisfy({ $0.isHexDigit }) else { throw LocalModelError.invalidManifest }
            for depth in 1..<parts.count {
                let ancestor = parts.prefix(depth).joined(separator: "/").lowercased()
                guard !pathSet.contains(ancestor) else { throw LocalModelError.invalidManifest }
            }
            total = sum
        }
    }

    public func url(for artifact: ModelArtifact) throws -> URL {
        try validate()
        guard artifacts.contains(artifact), let url = URL(string:
            "https://huggingface.co/\(repository)/resolve/\(revision)/\(artifact.path)") else {
            throw LocalModelError.invalidManifest
        }
        return url
    }
}

public enum LocalVADAssets {
    public static let manifest = LocalModelManifest(
        id: "silero-vad-6.2.1", repository: "FluidInference/silero-vad-coreml",
        revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96", license: "MIT",
        modelDirectory: "silero-vad-unified-256ms-v6.2.1.mlmodelc",
        artifacts: [
            artifact("analytics/coremldata.bin", 243, .sha256,
                     "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
            artifact("coremldata.bin", 625, .sha256,
                     "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
            artifact("metadata.json", 3335, .gitBlobSHA1, "8ecdc26edff98896279d325d0dfffc46a65f5f53"),
            artifact("model.mil", 176918, .gitBlobSHA1, "adf9d2a7d9a4c02164644ff7c5d864d08eb409a9"),
            artifact("weights/weight.bin", 882304, .sha256,
                     "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063")
        ]
    )

    private static func artifact(_ path: String, _ bytes: Int64, _ digest: ModelArtifact.Digest,
                                 _ checksum: String) -> ModelArtifact {
        ModelArtifact(path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/\(path)", bytes: bytes,
                      digest: digest, checksum: checksum)
    }

    public static func verifiedDirectory(root: URL = VADModelCache.modelCacheRoot()) throws -> URL {
        let installation = root.appendingPathComponent(manifest.installationName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: installation.path) else { throw LocalModelError.missingVAD }
        try LocalModelFiles.verify(manifest, installation: installation)
        return installation.appendingPathComponent(manifest.modelDirectory, isDirectory: true)
    }
}

public enum LocalModelFiles {
    public static func removalTarget(_ manifest: LocalModelManifest, consent: LocalModelManifest?, root: URL) throws -> URL {
        guard consent == manifest else { throw LocalModelError.consentRequired }
        try manifest.validate()
        let target = root.appendingPathComponent(manifest.installationName, isDirectory: true)
        try rejectSymbolicLinks(target)
        guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LocalModelError.invalidAssets }
        _ = try measuredBytes(at: target)
        return target
    }

    /// Validates the whole owned tree before measuring or removing it, including links
    /// not listed in a receipt. Never follows directory links or ignores enumeration errors.
    public static func measuredBytes(at directory: URL) throws -> Int64 {
        try rejectSymbolicLinks(directory)
        var pending = [directory]
        var total: Int64 = 0
        while let folder = pending.popLast() {
            for file in try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]) {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw LocalModelError.invalidAssets }
                if values.isDirectory == true { pending.append(file) }
                else if values.isRegularFile == true, let size = values.fileSize {
                    let (sum, overflow) = total.addingReportingOverflow(Int64(size))
                    guard !overflow else { throw LocalModelError.invalidAssets }
                    total = sum
                } else { throw LocalModelError.invalidAssets }
            }
        }
        return total
    }

    public static func verify(_ manifest: LocalModelManifest, installation: URL) throws {
        try manifest.validate()
        let receiptURL = installation.appendingPathComponent("receipt.json")
        try rejectSymbolicLinks(receiptURL)
        let receiptSize = try? receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let receiptSize, receiptSize <= 65_536,
              let receipt = try? JSONDecoder().decode(LocalModelManifest.self, from: Data(contentsOf: receiptURL)),
              receipt == manifest else { throw LocalModelError.invalidAssets }
        for artifact in manifest.artifacts {
            let url = installation.appendingPathComponent(artifact.path)
            try rejectSymbolicLinks(url)
            try artifact.verify(fileAt: url)
        }
        let expected = Set(manifest.artifacts.map(\.path) + ["receipt.json"])
        guard let entries = FileManager.default.enumerator(at: installation,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw LocalModelError.invalidAssets }
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LocalModelError.invalidAssets }
            if values.isRegularFile == true {
                let relative = String(url.path.dropFirst(installation.path.count + 1))
                guard expected.contains(relative) else { throw LocalModelError.invalidAssets }
            }
        }
    }

    static func rejectSymbolicLinks(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw LocalModelError.invalidAssets
            }
            current.deleteLastPathComponent()
        }
    }
}
