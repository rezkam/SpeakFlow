import AppKit

/// Application identity comes from canonical bundle containment, never bundle-ID spelling.
enum ApplicationOwnership {
    nonisolated static func applicationURL(for pid: pid_t) -> URL? {
        let application = NSRunningApplication(processIdentifier: pid)
        return canonicalAppURL(application?.bundleURL ?? application?.executableURL)
    }

    nonisolated static func canonicalAppURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...appIndex])), isDirectory: true)
    }

    nonisolated static func matches(target: URL?, candidate: URL?) -> Bool {
        guard let target = canonicalAppURL(target), let candidate = canonicalAppURL(candidate) else { return false }
        return target == candidate
    }
}
