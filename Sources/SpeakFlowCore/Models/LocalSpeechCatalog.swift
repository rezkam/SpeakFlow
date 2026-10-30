import Foundation

public enum LocalSpeechModelID: String, CaseIterable, Codable, Sendable {
    case parakeet110M = "parakeet-110m"
    case parakeetV2 = "parakeet-v2"
    case nemotron1120 = "nemotron-latin-1120"
}

public enum LocalSpeechMode: String, Codable, Sendable {
    case batch, streaming
}

public struct LocalSpeechModel: Identifiable, Sendable {
    public let id: LocalSpeechModelID
    public let name: String
    public let mode: LocalSpeechMode
    public let manifest: LocalModelManifest
    public let languages = ["en"]
    public let fluidAudioVersion = "0.18.0"
    public let measuredMemoryBytes: Int64? = nil

    public func unavailabilityReason(isAppleSilicon: Bool) -> String? {
        isAppleSilicon ? nil : "Requires Apple Silicon and macOS 26 or later."
    }
}

/// Bundled metadata only. Browsing never creates a store, resolves a remote source, or loads weights.
public enum LocalSpeechCatalog {
    public static func models() throws -> [LocalSpeechModel] {
        guard let url = Bundle.module.url(forResource: "LocalSpeechManifests", withExtension: "json") else {
            throw LocalModelError.invalidManifest
        }
        let manifests = try JSONDecoder().decode([LocalModelManifest].self, from: Data(contentsOf: url))
        return try models(manifests: manifests)
    }

    static func models(manifests: [LocalModelManifest]) throws -> [LocalSpeechModel] {
        let approved = LocalSpeechModelID.allCases
        guard manifests.count == approved.count,
              Set(manifests.map(\.id)) == Set(approved.map(\.rawValue)) else {
            throw LocalModelError.invalidManifest
        }
        return try approved.map { id in
            guard let manifest = manifests.first(where: { $0.id == id.rawValue }) else {
                throw LocalModelError.invalidManifest
            }
            try manifest.validate()
            let name: String
            let mode: LocalSpeechMode
            switch id {
            case .parakeet110M:
                name = "Parakeet 110M"
                mode = .batch
            case .parakeetV2:
                name = "Parakeet 0.6B v2"
                mode = .batch
            case .nemotron1120:
                name = "Nemotron 3.5 Streaming 0.6B"
                mode = .streaming
            }
            return LocalSpeechModel(id: id, name: name, mode: mode, manifest: manifest)
        }
    }
}
