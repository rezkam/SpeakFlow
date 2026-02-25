import AppKit

/// Safe resource lookup for app UI assets.
///
/// Avoids direct `Bundle.module` usage in startup-critical paths because
/// SwiftPM's generated accessor can trap if the resource bundle cannot be
/// resolved on a specific machine/install layout.
enum AppResources {
    private static let moduleBundleName = "SpeakFlow_SpeakFlow"

    static func pngImage(named name: String) -> NSImage? {
        if let directURL = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: directURL) {
            return image
        }

        if let moduleBundleURL = Bundle.main.url(forResource: moduleBundleName, withExtension: "bundle"),
           let moduleBundle = Bundle(url: moduleBundleURL),
           let nestedURL = moduleBundle.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: nestedURL) {
            return image
        }

        return nil
    }
}

