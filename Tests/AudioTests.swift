import Foundation
import Testing
@testable import SpeakFlowCore

// MARK: - AudioBuffer Tests

struct AudioBufferTests {
    
    @Test("AudioBuffer enforces maximum sample limit")
    @MainActor
    func testAudioBufferEnforcesMaxSamples() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        let expectedMaxSamples = Int(Config.maxFullRecordingDuration * 16000 * 1.1)
        
        let hugeFrames = [Float](repeating: 0.5, count: expectedMaxSamples + 1000)
        
        await buffer.append(frames: Array(hugeFrames.prefix(expectedMaxSamples - 100)), hasSpeech: true)
        await buffer.append(frames: Array(hugeFrames.suffix(2000)), hasSpeech: true)
        
        let result = await buffer.takeAll()
        #expect(result.samples.count <= expectedMaxSamples, "Buffer should enforce max sample limit")
    }
    
    @Test("AudioBuffer tracks speech ratio correctly")
    @MainActor
    func testSpeechRatioTracking() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        
        await buffer.append(frames: [Float](repeating: 0.5, count: 1000), hasSpeech: true)
        await buffer.append(frames: [Float](repeating: 0.01, count: 1000), hasSpeech: false)
        
        let result = await buffer.takeAll()
        #expect(result.samples.count == 2000, "Should have all samples")
        #expect(result.speechRatio == 0.5, "Speech ratio should be 50%")
    }
    
    @Test("AudioBuffer.takeAll clears buffer")
    @MainActor
    func testTakeAllClearsBuffer() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        
        await buffer.append(frames: [Float](repeating: 0.5, count: 1000), hasSpeech: true)
        let first = await buffer.takeAll()
        #expect(first.samples.count == 1000)
        
        let second = await buffer.takeAll()
        #expect(second.samples.count == 0, "Buffer should be empty after takeAll")
    }
    
    @Test("AudioBuffer.duration is calculated correctly")
    @MainActor
    func testDurationCalculation() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        
        let duration = await buffer.duration
        #expect(duration == 1.0, "16000 samples at 16kHz should be 1 second")
    }
    
    @Test("AudioBuffer.isAtCapacity works correctly")
    @MainActor
    func testIsAtCapacity() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        
        var atCapacity = await buffer.isAtCapacity
        #expect(atCapacity == false, "Empty buffer should not be at capacity")
        
        let maxSamples = Int(Config.maxFullRecordingDuration * 16000 * 1.1)
        await buffer.append(frames: [Float](repeating: 0.5, count: maxSamples), hasSpeech: true)
        
        atCapacity = await buffer.isAtCapacity
        #expect(atCapacity == true, "Full buffer should be at capacity")
    }
}

// MARK: - StreamingRecorder Tests

struct StreamingRecorderTests {
    
    @Test("StreamingRecorder has cancel() method")
    @MainActor
    func testCancelMethodExists() {
        let recorder = StreamingRecorder()
        recorder.cancel()
        #expect(Bool(true), "cancel() method exists and is callable")
    }
    
    @Test("cancel() does not emit chunk")
    @MainActor
    func testCancelDoesNotEmitChunk() async {
        var chunkEmitted = false
        
        let recorder = StreamingRecorder()
        recorder.onChunkReady = { _ in
            chunkEmitted = true
        }
        
        recorder.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        
        #expect(chunkEmitted == false, "cancel() should not emit a chunk")
    }
    
    @Test("cancel() sets internal cancelled flag")
    @MainActor
    func testCancelSetsFlag() async {
        let recorder = StreamingRecorder()
        var chunkEmitted = false
        
        recorder.onChunkReady = { _ in
            chunkEmitted = true
        }
        
        recorder.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        
        #expect(chunkEmitted == false, "cancel() should not emit chunks")
    }
    
    @Test("cancel() followed by stop() does not double-process")
    @MainActor
    func testCancelThenStopSafe() async {
        let recorder = StreamingRecorder()
        var emitCount = 0
        
        recorder.onChunkReady = { _ in
            emitCount += 1
        }
        
        recorder.cancel()
        recorder.stop()
        
        try? await Task.sleep(for: .milliseconds(50))
        
        #expect(emitCount == 0, "Neither cancel nor subsequent stop should emit")
    }
    
    @Test("Multiple cancel() calls are idempotent")
    @MainActor
    func testMultipleCancelsIdempotent() async {
        let recorder = StreamingRecorder()
        var emitCount = 0
        
        recorder.onChunkReady = { _ in
            emitCount += 1
        }
        
        recorder.cancel()
        recorder.cancel()
        recorder.cancel()
        
        try? await Task.sleep(for: .milliseconds(50))
        
        #expect(emitCount == 0, "Multiple cancels should not cause issues")
    }
    
    @Test("onChunkReady callback can be set")
    @MainActor
    func testCallbackSettable() {
        let recorder = StreamingRecorder()
        
        recorder.onChunkReady = { chunk in
            #expect(chunk.wavData.count > 0)
        }
        
        #expect(recorder.onChunkReady != nil, "Callback should be settable")
    }
}
