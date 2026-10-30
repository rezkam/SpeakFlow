import FluidAudio
import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Local VAD consent", .serialized)
struct LocalVADConsentTests {
    @Test @MainActor func vadFailureStopsCaptureInsteadOfFallingBack() async {
        enum LoadFailure: Error { case corrupt }
        let settings = SpySettings()
        settings.vadEnabled = true
        let recorder = StreamingRecorder(settings: settings)
        recorder.forceVADInitializationForTesting = true
        recorder.beforeVADInitializationForTesting = { throw LoadFailure.corrupt }
        let started = await recorder.start()
        #expect(!started, "A VAD load failure must stop capture, not select a fallback")
        recorder.cancel()
        await recorder.waitForStopCompletion()
    }

    @Test func missingAssetsExplainExplicitInstallationWithoutDownloading() async {
        // Keep the pre-fix implementation offline while reproducing its failure.
        ModelNetworkPolicy.initialize()
        let absentRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test-fixtures/absent-vad-\(UUID().uuidString)")
        let cache = VADModelCache(modelRoot: absentRoot)
        do {
            _ = try await cache.getManager(threshold: 0.5)
            Issue.record("A fresh isolated store must not load an unapproved external model")
        } catch {
            #expect(error.localizedDescription == "Download the required voice activity model in Models before recording.")
        }
    }
}
