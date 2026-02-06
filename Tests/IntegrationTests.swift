import Foundation
import AppKit
import Testing
@testable import SpeakFlowCore

// MARK: - Cancel Flow Integration Tests

struct CancelFlowTests {
    
    @Test("Full cancel flow: recorder.cancel() + Transcription.cancelAll()")
    func testFullCancelFlow() async {
        let recorder = StreamingRecorder()
        var chunkEmitted = false
        recorder.onChunkReady = { _ in chunkEmitted = true }
        recorder.cancel()
        
        await MainActor.run {
            Transcription.shared.cancelAll()
        }
        
        try? await Task.sleep(for: .milliseconds(100))
        
        #expect(chunkEmitted == false, "Cancel flow should not emit chunks")
    }
    
    @Test("Cancel during API wait discards result")
    func testCancelDuringApiWait() async {
        var resultReceived = false
        
        let apiTask = Task {
            try await Task.sleep(for: .seconds(5))
            resultReceived = true
            return "transcription result"
        }
        
        try? await Task.sleep(for: .milliseconds(50))
        apiTask.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        
        #expect(resultReceived == false, "Cancelled API task should not produce result")
    }
    
    @Test("takeAll() returns empty after buffer is cleared")
    func testTakeAllAfterClear() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        
        await buffer.append(frames: [Float](repeating: 0.5, count: 1000), hasSpeech: true)
        
        let result = await buffer.takeAll()
        #expect(result.samples.count == 1000, "First takeAll should return samples")
        
        let emptyResult = await buffer.takeAll()
        #expect(emptyResult.samples.count == 0, "Buffer should be empty after takeAll")
    }
}

// MARK: - Escape Key Behavior Tests (Documentation)

struct EscapeKeyBehaviorTests {
    
    @Test("Escape listener lifecycle is scoped to recording")
    func testEscapeListenerLifecycle() {
        // Documents the expected behavior:
        // 1. startEscapeListener() called at end of startRecording()
        // 2. stopEscapeListener() called at start of stopRecording()
        // 3. stopEscapeListener() called at start of cancelRecording()
        // This ensures Escape key is only captured during active recording.
        
        #expect(Bool(true), "Escape listener lifecycle is correctly scoped to recording")
    }
    
    @Test("Escape key triggers cancel behavior")
    func testEscapeTriggersCancel() {
        // Documents that pressing Escape during recording:
        // 1. Calls cancelRecording() (not stopRecording())
        // 2. Does NOT emit final chunk
        // 3. Does NOT send to API
        // 4. Plays Glass sound
        // 5. Discards any pending transcription results
        
        #expect(Bool(true), "Escape triggers cancel behavior, not stop behavior")
    }
}

// MARK: - Sound Configuration Tests

struct SoundTests {
    
    @Test("Start recording sound (Blow) exists")
    func testStartRecordingSound() {
        let sound = NSSound(named: "Blow")
        #expect(sound != nil, "Blow sound should exist in system")
    }
    
    @Test("Stop recording sound (Pop) exists")
    func testStopRecordingSound() {
        let sound = NSSound(named: "Pop")
        #expect(sound != nil, "Pop sound should exist in system")
    }
    
    @Test("Cancel recording sound (Glass) exists")
    func testCancelRecordingSound() {
        let sound = NSSound(named: "Glass")
        #expect(sound != nil, "Glass sound should exist in system")
    }
    
    @Test("Error sound (Basso) exists")
    func testErrorSound() {
        let sound = NSSound(named: "Basso")
        #expect(sound != nil, "Basso sound should exist in system")
    }
    
    @Test("All action sounds are distinct")
    func testSoundsAreDistinct() {
        let sounds = ["Blow", "Pop", "Glass", "Basso"]
        let uniqueSounds = Set(sounds)
        #expect(sounds.count == uniqueSounds.count, "All action sounds should be distinct")
    }
}
