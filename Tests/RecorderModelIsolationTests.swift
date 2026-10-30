import Foundation
import Testing
@testable import SpeakFlowCore

@Suite("Recorder model loading isolation")
struct RecorderModelIsolationTests {
    private enum ProbeError: Error { case blocked }

    @Test func modelLoadingRequiresExplicitOptInOnlyForIsolatedCapture() {
        #expect(StreamingRecorder.allowsModelInitialization(isolatedAudio: false, environment: [:]))
        #expect(!StreamingRecorder.allowsModelInitialization(isolatedAudio: true, environment: [:]))
        #expect(!StreamingRecorder.allowsModelInitialization(
            isolatedAudio: true, environment: ["SPEAKFLOW_RUN_VAD_MODEL_TESTS": "true"]
        ))
        #expect(StreamingRecorder.allowsModelInitialization(
            isolatedAudio: true, environment: ["SPEAKFLOW_RUN_VAD_MODEL_TESTS": "1"]
        ))
    }

    @Test @MainActor
    func isolatedRecorderStartRequiresExplicitModelOptIn() async {
        let settings = SpySettings()
        settings.vadEnabled = true
        let recorder = StreamingRecorder(settings: settings)
        var modelLoads = 0
        recorder.beforeVADInitializationForTesting = {
            modelLoads += 1
            throw ProbeError.blocked
        }
        let started = await recorder.start()
        let optedIn = ProcessInfo.processInfo.environment["SPEAKFLOW_RUN_VAD_MODEL_TESTS"] == "1"
        #expect(started == !optedIn, "An explicitly exercised VAD failure must refuse capture")
        #expect(modelLoads == (optedIn ? 1 : 0), "Isolated capture must honor explicit CoreML opt-in")
        recorder.cancel()
        await recorder.waitForStopCompletion()
    }
}
