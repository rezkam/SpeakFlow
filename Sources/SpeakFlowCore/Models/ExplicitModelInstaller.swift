import Foundation

/// The only model network path. A matching reviewed manifest is required per transaction.
public actor ExplicitModelInstaller {
    public typealias Fetch = @Sendable (ModelArtifact, URL) async throws -> Data
    public typealias AvailableBytes = @Sendable (URL) throws -> Int64
    private let root: URL
    private let fetch: Fetch
    private let availableBytes: AvailableBytes
    private var installing = false

    public init(root: URL, fetch: @escaping Fetch = ModelArtifactTransport.fetch,
                availableBytes: @escaping AvailableBytes = ExplicitModelInstaller.freeBytes) {
        self.root = root
        self.fetch = fetch
        self.availableBytes = availableBytes
    }

    public func install(_ manifest: LocalModelManifest, consent: LocalModelManifest?,
                        progress: @Sendable (Int64, Int64) async -> Void = { _, _ in }) async throws {
        guard consent == manifest else { throw LocalModelError.consentRequired }
        try manifest.validate()
        guard !installing else { throw LocalModelError.busy }
        installing = true
        defer { installing = false }
        ModelNetworkPolicy.initialize()
        try Task.checkCancellation()
        try LocalModelFiles.rejectSymbolicLinks(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(manifest.installationName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LocalModelError.alreadyInstalled }
        guard try availableBytes(root) >= manifest.transferBytes else { throw LocalModelError.insufficientSpace }
        let staging = root.appendingPathComponent("partial-\(manifest.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var completed: Int64 = 0
        for artifact in manifest.artifacts {
            try Task.checkCancellation()
            guard try availableBytes(root) >= manifest.transferBytes - completed else {
                throw LocalModelError.insufficientSpace
            }
            let data = try await fetch(artifact, manifest.url(for: artifact))
            try Task.checkCancellation()
            let file = staging.appendingPathComponent(artifact.path)
            try LocalModelFiles.rejectSymbolicLinks(file)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .withoutOverwriting)
            try artifact.verify(data)
            completed += artifact.bytes
            await progress(completed, manifest.transferBytes)
        }
        try Task.checkCancellation()
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
        try LocalModelFiles.verify(manifest, installation: staging)
        try Task.checkCancellation()
        // Same-volume rename publishes the receipt and every verified component together.
        // Failed or cancelled staging stays inert until an exact-target cleanup is confirmed.
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    public nonisolated static func freeBytes(_ directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else { throw LocalModelError.insufficientSpace }
        return bytes
    }
}

public enum ModelArtifactTransport {
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host == "cdn-lfs.huggingface.co"
            || host == "cdn-lfs-us-1.huggingface.co" || host == "cas-bridge.xethub.hf.co"
            || host == "us.aws.cdn.hf.co" || host == "eu.aws.cdn.hf.co"
    }

    public static func fetch(_ artifact: ModelArtifact, _ url: URL) async throws -> Data {
        guard allows(url) else { throw LocalModelError.transferFailed }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ModelRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, allows(finalURL),
              response.expectedContentLength < 0 || response.expectedContentLength == artifact.bytes else {
            throw LocalModelError.transferFailed
        }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < artifact.bytes else { throw LocalModelError.invalidAssets }
            data.append(byte)
        }
        try artifact.verify(data)
        return data
    }
}

private final class ModelRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ModelArtifactTransport.allows(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
