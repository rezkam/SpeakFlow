#!/usr/bin/env swift
import Foundation

func prepare(_ bin: URL) throws {
    let manager = FileManager.default
    let targets = try manager.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)
    let pattern = #"appendingPathComponent\("([A-Za-z0-9_.-]+\.bundle)"\)"#
    let expression = try NSRegularExpression(pattern: pattern)
    let replacements = bin.appendingPathComponent("portable-resource-accessors", isDirectory: true)
    try manager.createDirectory(at: replacements, withIntermediateDirectories: true)
    var mappings: [[String: String]] = []
    var count = 0
    for target in targets where target.lastPathComponent.hasSuffix(".build") {
        let accessor = target.appendingPathComponent("DerivedSources/resource_bundle_accessor.swift")
        guard manager.fileExists(atPath: accessor.path) else { continue }
        let original = try String(contentsOf: accessor, encoding: .utf8)
        guard let match = expression.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)),
              let range = Range(match.range(at: 1), in: original) else {
            throw ResourceError.unsupportedAccessor
        }
        let name = String(original[range])
        let portable = """
        import Foundation

        private final class ReleaseResourceBundleAnchor {}

        extension Foundation.Bundle {
            static let module: Bundle = {
                let owner = Bundle(for: ReleaseResourceBundleAnchor.self)
                let roots: [URL?] = [Bundle.main.resourceURL, Bundle.main.bundleURL, owner.resourceURL, owner.bundleURL]
                for root in roots.compactMap({ $0 }) {
                    if let bundle = Bundle(url: root.appendingPathComponent("\(name)")) {
                        return bundle
                    }
                }
                fatalError("Missing packaged resource bundle: \(name)")
            }()
        }
        """ + "\n"
        let replacement = replacements.appendingPathComponent("\(count).swift")
        try portable.write(to: replacement, atomically: true, encoding: .utf8)
        mappings.append(["type": "file", "name": accessor.path, "external-contents": replacement.path])
        count += 1
    }
    guard count > 0 else { throw ResourceError.noAccessors }
    let overlay: [String: Any] = ["version": 0, "use-external-names": false, "roots": mappings]
    try JSONSerialization.data(withJSONObject: overlay).write(to: bin.appendingPathComponent("release-resources.json"))
    print("Prepared \(count) portable resource accessor(s)")
}

func package(_ bin: URL, app: URL) throws {
    let manager = FileManager.default
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    try manager.createDirectory(at: resources, withIntermediateDirectories: true)
    let products = try manager.contentsOfDirectory(at: bin.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey])
    var count = 0
    for bundle in products where bundle.pathExtension == "bundle" {
        guard try bundle.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
        try manager.copyItem(at: bundle, to: resources.appendingPathComponent(bundle.lastPathComponent))
        count += 1
    }
    guard count > 0 else { throw ResourceError.noAccessors }
    print("Packaged \(count) resource bundle(s)")
}

enum ResourceError: Error { case unsupportedAccessor, noAccessors }

do {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "prepare" {
        try prepare(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    } else if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "package" {
        try package(
            URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
            app: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        )
    } else {
        throw ResourceError.unsupportedAccessor
    }
} catch {
    FileHandle.standardError.write(Data("Release resource preparation failed\n".utf8))
    exit(1)
}
