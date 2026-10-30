import Foundation

public struct ModelInstallProgress: Sendable {
    public enum Phase: String, Sendable { case downloading, verifying, preparing }
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
}

/// The only model network path. A matching reviewed manifest is required per transaction.
public actor ExplicitModelInstaller {
    public typealias TransferProgress = @Sendable (Int64) async throws -> Void
    public typealias Fetch = @Sendable (ModelArtifact, URL, URL, @escaping TransferProgress) async throws -> Void
    public typealias AvailableBytes = @Sendable (URL) throws -> Int64
    private let root: URL
    private let fetch: Fetch
    private let availableBytes: AvailableBytes
    private var installing = false

    public init(root: URL, fetch: @escaping Fetch = { artifact, url, destination, progress in
                    try await ModelArtifactTransport.transfer(artifact, url, to: destination, progress: progress)
                },
                availableBytes: @escaping AvailableBytes = ExplicitModelInstaller.freeBytes) {
        self.root = root
        self.fetch = fetch
        self.availableBytes = availableBytes
    }

    public func install(_ manifest: LocalModelManifest, consent: LocalModelManifest?,
                        progress: @escaping @Sendable (ModelInstallProgress) async -> Void = { _ in }) async throws {
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
        let staging = root.appendingPathComponent("partial-\(manifest.installationName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var completed: Int64 = 0
        for artifact in manifest.artifacts {
            try Task.checkCancellation()
            guard try availableBytes(root) >= manifest.transferBytes - completed else {
                throw LocalModelError.insufficientSpace
            }
            let file = staging.appendingPathComponent(artifact.path)
            try LocalModelFiles.rejectSymbolicLinks(file)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = completed
            await progress(ModelInstallProgress(phase: .downloading, completedBytes: before, totalBytes: manifest.transferBytes))
            try await fetch(artifact, manifest.url(for: artifact), file) { received in
                guard received >= 0, received <= artifact.bytes else { throw LocalModelError.invalidAssets }
                await progress(ModelInstallProgress(phase: .downloading,
                    completedBytes: before + received, totalBytes: manifest.transferBytes))
            }
            try Task.checkCancellation()
            await progress(ModelInstallProgress(phase: .verifying,
                completedBytes: before + artifact.bytes, totalBytes: manifest.transferBytes))
            try artifact.verify(fileAt: file)
            completed += artifact.bytes
        }
        try Task.checkCancellation()
        await progress(ModelInstallProgress(phase: .preparing, completedBytes: completed, totalBytes: manifest.transferBytes))
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

    public static func transfer(_ artifact: ModelArtifact, _ url: URL, to destination: URL,
                                progress: @escaping ExplicitModelInstaller.TransferProgress = { _ in },
                                configuration: URLSessionConfiguration = .ephemeral) async throws {
        guard allows(url), artifact.bytes > 0,
              let isolated = configuration.copy() as? URLSessionConfiguration else {
            throw LocalModelError.transferFailed
        }
        try Task.checkCancellation()
        try LocalModelFiles.rejectSymbolicLinks(destination)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LocalModelError.invalidAssets }
        isolated.httpCookieStorage = nil
        isolated.urlCredentialStorage = nil
        isolated.urlCache = nil
        isolated.waitsForConnectivity = false
        let session = URLSession(configuration: isolated, delegate: ModelRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (stream, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let finalURL = response.url, allows(finalURL),
                      response.expectedContentLength < 0 || response.expectedContentLength == artifact.bytes else {
                    throw LocalModelError.transferFailed
                }
                try Task.checkCancellation()
                try Data().write(to: destination, options: .withoutOverwriting)
                let file = try FileHandle(forWritingTo: destination)
                defer { try? file.close() }
                var buffer = Data()
                buffer.reserveCapacity(65_536)
                var received: Int64 = 0
                for try await byte in stream {
                    try Task.checkCancellation()
                    guard received < artifact.bytes else { throw LocalModelError.invalidAssets }
                    buffer.append(byte)
                    received += 1
                    if buffer.count == 65_536 {
                        try file.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                        try await progress(received)
                    }
                }
                try Task.checkCancellation()
                if !buffer.isEmpty { try file.write(contentsOf: buffer) }
                guard received == artifact.bytes else { throw LocalModelError.invalidAssets }
                try await progress(received)
            } catch {
                try Task.checkCancellation()
                throw normalized(error)
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private static func normalized(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? LocalModelError { return error }
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain, failure.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return LocalModelError.insufficientSpace
        }
        return LocalModelError.transferFailed
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
