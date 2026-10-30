import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Explicitly approved VAD installation")
struct ApprovedVADInstallationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKFLOW_APPROVED_VAD_REVISION"] == LocalVADAssets.manifest.revision))
    func installApprovedRevisionAndLoadOffline() async throws {
        let override = try #require(ProcessInfo.processInfo.environment["SPEAKFLOW_VAD_MODEL_CACHE_ROOT"])
        let root = URL(fileURLWithPath: override, isDirectory: true)
        let manifest = LocalVADAssets.manifest
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(manifest.installationName).path) {
            let installer = ExplicitModelInstaller(root: root)
            try await installer.install(manifest, consent: manifest)
        }
        let directory = try LocalVADAssets.verifiedDirectory(root: root)
        #expect(directory.lastPathComponent == manifest.modelDirectory)
        let cache = VADModelCache(modelRoot: root)
        let manager = try await cache.getManager(threshold: 0.5)
        let state = await manager.makeStreamState()
        #expect(state.processedSamples == 0)
    }
}
