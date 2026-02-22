import Testing
@testable import SpeakFlowCore

@Suite("AudioFilter")
struct AudioFilterTests {
    @Test
    func noiseGateZerosLowEnergyFrames() {
        let filter = NoiseGateFilter(rmsThreshold: 0.01)
        let quiet = [Float](repeating: 0.001, count: 1024)
        let output = filter.filter(quiet)
        #expect(output.allSatisfy { $0 == 0 })
    }

    @Test
    func noiseGateKeepsSpeechFrames() {
        let filter = NoiseGateFilter(rmsThreshold: 0.01)
        let speech = [Float](repeating: 0.1, count: 1024)
        let output = filter.filter(speech)
        #expect(output == speech)
    }
}
