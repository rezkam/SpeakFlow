import Testing
@testable import SpeakFlowCore

@Suite("WavEncoder")
struct WavEncoderTests {
    @Test
    func encodeProducesValidHeader() {
        let wav = WavEncoder.encode(samples: [0.0, 0.5, -0.5], sampleRate: 16_000)
        #expect(wav.count == 44 + 6)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
    }
}
