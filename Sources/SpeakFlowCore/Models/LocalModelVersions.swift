import Foundation

/// Only app-reviewed manifests can name an installable or retained compatible revision.
/// Upstream metadata never extends this list.
public struct LocalModelVersionCatalog: Sendable {
    public let preferred: [LocalSpeechModel]
    public let reviewed: [LocalSpeechModel]

    public init(preferred: [LocalSpeechModel], retained: [LocalSpeechModel]) throws {
        guard preferred.count == LocalSpeechModelID.allCases.count,
              Set(preferred.map(\.id)) == Set(LocalSpeechModelID.allCases) else { throw LocalModelError.invalidManifest }
        var identities = Set<String>()
        for model in preferred + retained {
            try model.manifest.validate()
            let expected: LocalSpeechMode = model.id == .nemotron1120 ? .streaming : .batch
            guard model.manifest.id == model.id.rawValue, model.mode == expected,
                  model.fluidAudioVersion == "0.18.0", model.languages == ["en"],
                  identities.insert(model.providerID).inserted else { throw LocalModelError.invalidManifest }
        }
        self.preferred = preferred
        reviewed = preferred + retained
    }
}

public enum LocalModelSourceUpdate: Equatable, Sendable {
    case current
    /// This is an advisory source revision, never a download or activation manifest.
    case unreviewed(String)
}

public struct LocalModelUpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    private let fetch: Fetch
    public init(fetch: @escaping Fetch = LocalModelUpdateChecker.fetchMetadata) { self.fetch = fetch }

    public func check(_ manifest: LocalModelManifest) async throws -> LocalModelSourceUpdate {
        try manifest.validate()
        try Task.checkCancellation()
        guard let url = URL(string: "https://huggingface.co/api/models/\(manifest.repository)?expand=sha") else {
            throw LocalModelError.invalidManifest
        }
        let data = try await fetch(url)
        try Task.checkCancellation()
        struct Metadata: Decodable { let sha: String }
        guard data.count <= 65_536, let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.sha.count == 40, metadata.sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw LocalModelError.invalidManifest
        }
        return metadata.sha == manifest.revision ? .current : .unreviewed(metadata.sha)
    }

    public static func fetchMetadata(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "huggingface.co", url.user == nil, url.password == nil,
              url.port == nil, url.path.hasPrefix("/api/models/"), url.query == "expand=sha" else {
            throw LocalModelError.invalidManifest
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: ModelMetadataRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SpeakFlow", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 65_536 else { throw LocalModelError.transferFailed }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw LocalModelError.invalidManifest }
            data.append(byte)
        }
        return data
    }
}

private final class ModelMetadataRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
