import Foundation

public struct LocalModelRemovalTarget: Equatable, Sendable {
    public let name: String
    public let bytes: Int64
}

extension LocalModelFiles {
    /// Lists only this immutable installation and revision-named inert transfers.
    /// Unknown, older unnamed, external and other-revision directories are retained.
    public static func removalTargets(_ manifest: LocalModelManifest, root: URL) throws -> [LocalModelRemovalTarget] {
        try manifest.validate()
        try rejectSymbolicLinks(root)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let prefix = "partial-\(manifest.installationName)-"
        var targets: [LocalModelRemovalTarget] = []
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = file.lastPathComponent
            let suffix = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : ""
            let isPartial = suffix.count == 36 && UUID(uuidString: suffix) != nil
            guard name == manifest.installationName || isPartial else { continue }
            try rejectSymbolicLinks(file)
            guard try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LocalModelError.invalidAssets }
            targets.append(LocalModelRemovalTarget(name: name, bytes: try measuredBytes(at: file)))
        }
        return targets.sorted { $0.name < $1.name }
    }

    public static func confirmedRemovalTarget(_ target: LocalModelRemovalTarget, manifest: LocalModelManifest, root: URL) throws -> URL {
        guard try removalTargets(manifest, root: root).contains(target) else { throw LocalModelError.consentRequired }
        return root.appendingPathComponent(target.name, isDirectory: true)
    }
}
