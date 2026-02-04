import Foundation

/// Actor for thread-safe audio buffer management
actor AudioBuffer {
    private var samples: [Float] = []
    private var speechFrameCount: Int = 0
    private var totalFrameCount: Int = 0
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    var duration: Double {
        Double(samples.count) / sampleRate
    }

    var speechRatio: Float {
        totalFrameCount > 0 ? Float(speechFrameCount) / Float(totalFrameCount) : 0
    }

    func append(frames: [Float], hasSpeech: Bool) {
        samples.append(contentsOf: frames)
        totalFrameCount += frames.count
        if hasSpeech { speechFrameCount += frames.count }
    }

    func takeAll() -> (samples: [Float], speechRatio: Float) {
        let result = (samples: samples, speechRatio: speechRatio)
        samples = []
        speechFrameCount = 0
        totalFrameCount = 0
        return result
    }

    func reset() {
        samples = []
        speechFrameCount = 0
        totalFrameCount = 0
    }
}
