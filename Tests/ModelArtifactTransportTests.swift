import CryptoKit
import Foundation
import os
import Testing
@testable import SpeakFlowCore

private final class ArtifactFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let bytes = Data(repeating: 0x5a, count: 131_073)
    static let requests = OSAllocatedUnfairLock(initialState: 0)

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        guard let url = request.url else { return }
        if url.lastPathComponent.hasPrefix("redirect-") {
            let host = url.lastPathComponent == "redirect-allowed" ? "cdn-lfs.huggingface.co" : "fixture.invalid"
            guard let destination = URL(string: "https://\(host)/fixture/complete"),
                  let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Location": destination.absoluteString]) else { return }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: url.lastPathComponent == "wrong-status" ? 503 : 200,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.lastPathComponent == "cancel" {
            client?.urlProtocol(self, didLoad: Data(Self.bytes.prefix(65_536)))
            return
        }
        var data = Self.bytes
        if url.lastPathComponent == "oversized" { data.append(0) }
        if url.lastPathComponent == "truncated" { data.removeLast() }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Bounded model artifact transport", .serialized)
struct ModelArtifactTransportTests {
    private func destination() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/artifact-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("weights.bin")
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactFixtureProtocol.self]
        return configuration
    }

    private var artifact: ModelArtifact {
        let bytes = ArtifactFixtureProtocol.bytes
        return ModelArtifact(path: "weights.bin", bytes: Int64(bytes.count), digest: .sha256,
            checksum: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    @Test func writesIncrementalProgressBeforeTheWholeArtifactCompletes() async throws {
        let destination = try destination()
        let progress = OSAllocatedUnfairLock(initialState: [Int64]())
        let url = try #require(URL(string: "https://huggingface.co/fixture/complete"))
        try await ModelArtifactTransport.transfer(artifact, url, to: destination, progress: { count in
            progress.withLock { $0.append(count) }
        }, configuration: configuration())
        try artifact.verify(fileAt: destination)
        let values = progress.withLock { $0 }
        #expect(values.count >= 2)
        #expect(try #require(values.first) < artifact.bytes)
        #expect(values.last == artifact.bytes)
        #expect(values == values.sorted())
    }

    @Test(arguments: ["oversized", "truncated"])
    func refusesAnUnexpectedBodyLength(variant: String) async throws {
        let destination = try destination()
        let url = try #require(URL(string: "https://huggingface.co/fixture/\(variant)"))
        await #expect(throws: LocalModelError.invalidAssets) {
            try await ModelArtifactTransport.transfer(artifact, url, to: destination, configuration: configuration())
        }
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(try #require(size) <= artifact.bytes)
    }

    @Test func cancellationInterruptsAStalledBody() async throws {
        let destination = try destination(), artifact = artifact, configuration = configuration()
        let progress = OSAllocatedUnfairLock(initialState: false)
        let url = try #require(URL(string: "https://huggingface.co/fixture/cancel"))
        let task = Task {
            try await ModelArtifactTransport.transfer(artifact, url, to: destination, progress: { _ in
                progress.withLock { $0 = true }
            }, configuration: configuration)
        }
        try await waitUntilAsync { progress.withLock { $0 } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize == 65_536)
    }

    @Test(arguments: ["http://huggingface.co/fixture", "https://fixture.invalid/weights", "https://user@huggingface.co/weights"])
    func unsafeDestinationsMakeNoRequest(value: String) async throws {
        let destination = try destination()
        let before = ArtifactFixtureProtocol.requests.withLock { $0 }
        let url = try #require(URL(string: value))
        await #expect(throws: LocalModelError.transferFailed) {
            try await ModelArtifactTransport.transfer(artifact, url, to: destination, configuration: configuration())
        }
        #expect(ArtifactFixtureProtocol.requests.withLock { $0 } == before)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(arguments: [false, true])
    func redirectsAreCheckedBeforeFollowingThem(allowed: Bool) async throws {
        let destination = try destination()
        let before = ArtifactFixtureProtocol.requests.withLock { $0 }
        let variant = allowed ? "redirect-allowed" : "redirect-denied"
        let url = try #require(URL(string: "https://huggingface.co/fixture/\(variant)"))
        if allowed {
            try await ModelArtifactTransport.transfer(artifact, url, to: destination, configuration: configuration())
            try artifact.verify(fileAt: destination)
            #expect(ArtifactFixtureProtocol.requests.withLock { $0 } == before + 2)
        } else {
            await #expect(throws: LocalModelError.transferFailed) {
                try await ModelArtifactTransport.transfer(artifact, url, to: destination, configuration: configuration())
            }
            #expect(ArtifactFixtureProtocol.requests.withLock { $0 } == before + 1)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func installerCancellationRetainsAnInertPartialWithoutPublishing() async throws {
        let root = try destination().deletingLastPathComponent()
        let artifact = artifact, configuration = configuration()
        let model = LocalModelManifest(id: "fixture-stream", repository: "example/model",
            revision: String(repeating: "a", count: 40), license: "MIT", modelDirectory: ".", artifacts: [artifact])
        let url = try #require(URL(string: "https://huggingface.co/fixture/cancel"))
        let progressed = OSAllocatedUnfairLock(initialState: false)
        let installer = ExplicitModelInstaller(root: root, fetch: { artifact, _, file, progress in
            try await ModelArtifactTransport.transfer(artifact, url, to: file, progress: progress, configuration: configuration)
        }, availableBytes: { _ in Int64.max })
        let task = Task {
            try await installer.install(model, consent: model) { event in
                if event.completedBytes > 0 { progressed.withLock { $0 = true } }
            }
        }
        try await waitUntilAsync { progressed.withLock { $0 } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(model.installationName).path))
        let partial = try #require(FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("partial-") })
        #expect(try partial.appendingPathComponent(artifact.path).resourceValues(forKeys: [.fileSizeKey]).fileSize == 65_536)
        #expect(!FileManager.default.fileExists(atPath: partial.appendingPathComponent("receipt.json").path))
    }

    @Test func existingFilesAreNotOverwrittenOrFetchedAgain() async throws {
        let destination = try destination()
        let original = Data("retained fixture".utf8)
        try original.write(to: destination, options: .withoutOverwriting)
        let before = ArtifactFixtureProtocol.requests.withLock { $0 }
        let url = try #require(URL(string: "https://huggingface.co/fixture/complete"))
        await #expect(throws: LocalModelError.invalidAssets) {
            try await ModelArtifactTransport.transfer(artifact, url, to: destination, configuration: configuration())
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(ArtifactFixtureProtocol.requests.withLock { $0 } == before)
    }

    @Test func rejectsAnUnsuccessfulResponseBeforeWriting() async throws {
        let destination = try destination()
        let url = try #require(URL(string: "https://huggingface.co/fixture/wrong-status"))
        await #expect(throws: LocalModelError.transferFailed) {
            try await ModelArtifactTransport.transfer(artifact, url, to: destination, configuration: configuration())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
