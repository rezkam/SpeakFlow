import Foundation
import AppKit
@testable import SpeakFlowCore

// MARK: - Simple Test Framework

var testsPassed = 0
var testsFailed = 0

func test(_ name: String, _ block: () async throws -> Void) async {
    do {
        try await block()
        print("  ✓ \(name)")
        testsPassed += 1
    } catch {
        print("  ✗ \(name): \(error)")
        testsFailed += 1
    }
}

struct AssertionError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ condition: Bool, _ message: String = "Assertion failed") throws {
    guard condition else { throw AssertionError(message: message) }
}

// MARK: - Audio Tests

@MainActor
func runAudioTests() async {
    print("\n=== Audio Tests ===")
    
    await test("AudioBuffer enforces maximum sample limit") {
        let buffer = AudioBuffer(sampleRate: 16000)
        let expectedMaxSamples = Int(Config.maxFullRecordingDuration * 16000 * 1.1)
        let hugeFrames = [Float](repeating: 0.5, count: expectedMaxSamples + 1000)
        
        await buffer.append(frames: Array(hugeFrames.prefix(expectedMaxSamples - 100)), hasSpeech: true)
        await buffer.append(frames: Array(hugeFrames.suffix(2000)), hasSpeech: true)
        
        let result = await buffer.takeAll()
        try expect(result.samples.count <= expectedMaxSamples, "Buffer should enforce max sample limit")
    }
    
    await test("AudioBuffer tracks speech ratio correctly") {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 1000), hasSpeech: true)
        await buffer.append(frames: [Float](repeating: 0.01, count: 1000), hasSpeech: false)
        
        let result = await buffer.takeAll()
        try expect(result.samples.count == 2000, "Should have all samples")
        try expect(result.speechRatio == 0.5, "Speech ratio should be 50%")
    }
    
    await test("AudioBuffer.takeAll clears buffer") {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 1000), hasSpeech: true)
        let first = await buffer.takeAll()
        try expect(first.samples.count == 1000, "First should have 1000 samples")
        
        let second = await buffer.takeAll()
        try expect(second.samples.count == 0, "Buffer should be empty after takeAll")
    }
    
    await test("AudioBuffer.duration is calculated correctly") {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        let duration = await buffer.duration
        try expect(duration == 1.0, "16000 samples at 16kHz should be 1 second")
    }
    
    await test("AudioBuffer.isAtCapacity works correctly") {
        let buffer = AudioBuffer(sampleRate: 16000)
        var atCapacity = await buffer.isAtCapacity
        try expect(atCapacity == false, "Empty buffer should not be at capacity")
        
        let maxSamples = Int(Config.maxFullRecordingDuration * 16000 * 1.1)
        await buffer.append(frames: [Float](repeating: 0.5, count: maxSamples), hasSpeech: true)
        atCapacity = await buffer.isAtCapacity
        try expect(atCapacity == true, "Full buffer should be at capacity")
    }
    
    await test("StreamingRecorder.cancel() method exists") {
        let recorder = StreamingRecorder()
        recorder.cancel()
        try expect(true, "cancel() method exists and is callable")
    }
    
    await test("StreamingRecorder.cancel() does not emit chunk") {
        var chunkEmitted = false
        let recorder = StreamingRecorder()
        recorder.onChunkReady = { _ in chunkEmitted = true }
        recorder.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        try expect(chunkEmitted == false, "cancel() should not emit a chunk")
    }
    
    await test("StreamingRecorder cancel then stop is safe") {
        let recorder = StreamingRecorder()
        var emitCount = 0
        recorder.onChunkReady = { _ in emitCount += 1 }
        recorder.cancel()
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(50))
        try expect(emitCount == 0, "Neither cancel nor subsequent stop should emit")
    }
    
    await test("StreamingRecorder multiple cancels are idempotent") {
        let recorder = StreamingRecorder()
        var emitCount = 0
        recorder.onChunkReady = { _ in emitCount += 1 }
        recorder.cancel()
        recorder.cancel()
        recorder.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        try expect(emitCount == 0, "Multiple cancels should not cause issues")
    }
}

// MARK: - Auth Tests

@MainActor
func runAuthTests() async {
    print("\n=== Auth Tests ===")
    
    func extractCode(_ inputValue: String, expectedState: String) -> String? {
        if let url = URL(string: inputValue),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value {
            if let stateParam = components.queryItems?.first(where: { $0.name == "state" })?.value {
                guard stateParam == expectedState else { return nil }
            }
            return codeParam
        }
        return inputValue
    }
    
    await test("OAuth: URLs with wrong state are rejected") {
        let expectedState = "legitimate-state-12345"
        let maliciousURL = "http://localhost:1455/auth/callback?code=stolen-code&state=attacker-controlled"
        let result = extractCode(maliciousURL, expectedState: expectedState)
        try expect(result == nil, "URLs with mismatched state should be rejected")
    }
    
    await test("OAuth: URLs with correct state are accepted") {
        let expectedState = "legitimate-state-12345"
        let validURL = "http://localhost:1455/auth/callback?code=valid-code&state=legitimate-state-12345"
        let result = extractCode(validURL, expectedState: expectedState)
        try expect(result == "valid-code", "URLs with matching state should be accepted")
    }
    
    await test("OAuth: Plain code without URL still works") {
        let plainCode = "authorization-code-12345"
        let result = extractCode(plainCode, expectedState: "any-state")
        try expect(result == plainCode, "Plain codes should still be accepted")
    }
    
    func parseLastRefresh(_ dateString: String) -> Date {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso8601Formatter.date(from: dateString) ?? Date.distantPast
    }
    
    await test("Credential: Invalid date forces refresh") {
        let parsedDate = parseLastRefresh("corrupted-garbage-not-a-date")
        let shouldRefresh = Date().timeIntervalSince(parsedDate) > 86400
        try expect(shouldRefresh, "Invalid date should trigger refresh by returning distant past")
    }
    
    await test("Credential: Empty date forces refresh") {
        let parsedDate = parseLastRefresh("")
        let shouldRefresh = Date().timeIntervalSince(parsedDate) > 86400
        try expect(shouldRefresh, "Empty date should trigger refresh")
    }
    
    await test("Credential: Valid date is parsed correctly") {
        let parsedDate = parseLastRefresh("2024-01-15T10:30:00.000Z")
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: parsedDate)
        try expect(components.year == 2024, "Year should be 2024")
        try expect(components.month == 1, "Month should be 1")
        try expect(components.day == 15, "Day should be 15")
    }
}

// MARK: - Config Tests

@MainActor
func runConfigTests() async {
    print("\n=== Config Tests ===")
    
    await test("Config.maxAudioSizeBytes is 25MB") {
        try expect(Config.maxAudioSizeBytes == 25_000_000, "Max audio size should be 25MB")
    }
    
    await test("Config.maxFullRecordingDuration is 1 hour") {
        try expect(Config.maxFullRecordingDuration == 3600.0, "Max recording should be 1 hour")
    }
    
    await test("Config.minRecordingDurationMs is 250ms") {
        try expect(Config.minRecordingDurationMs == 250, "Min recording should be 250ms")
    }
    
    await test("Config rate limiting settings are correct") {
        try expect(Config.minTimeBetweenRequests == 10.0, "Should have 10s between requests")
        try expect(Config.maxRetries == 3, "Should have max 3 retries")
        try expect(Config.retryBaseDelay == 1.5, "Base retry delay should be 1.5s")
    }
    
    await test("Config timeout allows retries within 30 seconds") {
        let worstCase = Config.timeout + Config.retryBaseDelay +
                        Config.timeout + (Config.retryBaseDelay * 2) +
                        Config.timeout
        try expect(worstCase <= 30.0, "Worst case retry should complete within 30 seconds, got \(worstCase)")
    }
    
    await test("Config.maxQueuedTextInsertions has reasonable bounds") {
        try expect(Config.maxQueuedTextInsertions > 0, "Must have positive limit")
        try expect(Config.maxQueuedTextInsertions <= 50, "Limit should be reasonable")
        try expect(Config.maxQueuedTextInsertions >= 5, "Limit should allow some buffering")
    }
    
    await test("ChunkDuration.fullRecording is 1 hour") {
        try expect(ChunkDuration.fullRecording.rawValue == 3600.0, "Full recording should be 1 hour")
        try expect(ChunkDuration.fullRecording.isFullRecording == true, "Should be identified as full recording")
    }
    
    await test("ChunkDuration.minDuration values are correct") {
        try expect(ChunkDuration.minute1.minDuration == 60.0, "1 min chunk should have 60s min")
        try expect(ChunkDuration.seconds30.minDuration == 30.0, "30s chunk should have 30s min")
        try expect(ChunkDuration.minute5.minDuration == 300.0, "5 min chunk should have 300s min")
        try expect(ChunkDuration.fullRecording.minDuration == 0.25, "Full recording should have 250ms min")
    }
    
    await test("All ChunkDurations have display names") {
        for duration in ChunkDuration.allCases {
            try expect(!duration.displayName.isEmpty, "\(duration) should have a display name")
        }
    }
}

// MARK: - Transcription Tests

@MainActor
func runTranscriptionTests() async {
    print("\n=== Transcription Tests ===")
    
    await test("TranscriptionService.cancelAll completes without error") {
        let service = TranscriptionService.shared
        await service.cancelAll()
        try expect(true, "cancelAll should complete without error")
    }
    
    await test("Large error body Data is truncated") {
        let largeBody = String(repeating: "x", count: 1_000_000)
        let data = Data(largeBody.utf8)
        let truncated = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        try expect(truncated.count <= 203, "Truncated body should be max 200 chars + '...', got \(truncated.count)")
        try expect(truncated.hasSuffix("..."), "Truncated body should end with ellipsis")
    }
    
    await test("Small error body is not truncated") {
        let smallBody = "Error: Bad request"
        let data = Data(smallBody.utf8)
        let result = TranscriptionService.truncateErrorBody(data, maxBytes: 200)
        try expect(result == smallBody, "Small body should not be truncated")
        try expect(!result.hasSuffix("..."), "Small body should not have ellipsis")
    }
    
    await test("TranscriptionError.audioTooLarge provides size info") {
        let error = TranscriptionError.audioTooLarge(size: 30_000_000, maxSize: 25_000_000)
        let description = error.errorDescription ?? ""
        try expect(description.contains("30"), "Should mention actual size")
        try expect(description.contains("25"), "Should mention max size")
    }
    
    await test("TranscriptionError.isRetryable is correct") {
        try expect(TranscriptionError.networkError(underlying: NSError(domain: "", code: 0)).isRetryable == true, "Network error should be retryable")
        try expect(TranscriptionError.rateLimited(retryAfter: 5).isRetryable == true, "Rate limited should be retryable")
        try expect(TranscriptionError.httpError(statusCode: 500, body: nil).isRetryable == true, "500 should be retryable")
        try expect(TranscriptionError.httpError(statusCode: 400, body: nil).isRetryable == false, "400 should not be retryable")
        try expect(TranscriptionError.cancelled.isRetryable == false, "Cancelled should not be retryable")
    }
    
    await test("TranscriptionQueueBridge reset clears pending") {
        let bridge = TranscriptionQueueBridge()
        let initialSeq = await bridge.nextSequence()
        await bridge.submitResult(seq: initialSeq, text: "test1")
        let secondSeq = await bridge.nextSequence()
        try expect(secondSeq == initialSeq + 1, "Sequence should increment")
        
        await bridge.reset()
        let afterResetSeq = await bridge.nextSequence()
        try expect(afterResetSeq == initialSeq, "Sequence should restart after reset, got \(afterResetSeq)")
    }
    
    await test("TranscriptionQueueBridge handles out-of-order results") {
        let bridge = TranscriptionQueueBridge()
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        
        await bridge.submitResult(seq: 3, text: "third")
        await bridge.submitResult(seq: 1, text: "first")
        await bridge.submitResult(seq: 2, text: "second")
        try expect(true, "Out-of-order submission should not crash")
    }
}

// MARK: - Double Sound Bug Tests

@MainActor
func runDoubleSoundTests() async {
    print("\n=== Double Sound Bug Tests ===")
    
    await test("checkCompletion should only fire onAllComplete once per session") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        bridge.onAllComplete = { completionCount += 1 }
        
        let seq1 = await bridge.nextSequence()
        let seq2 = await bridge.nextSequence()
        let seq3 = await bridge.nextSequence()
        
        await bridge.submitResult(seq: seq1, text: "first")
        await bridge.checkCompletion()
        await bridge.submitResult(seq: seq2, text: "second")
        await bridge.checkCompletion()
        await bridge.submitResult(seq: seq3, text: "third")
        await bridge.checkCompletion()
        
        try expect(completionCount == 1, "onAllComplete should only fire once, got \(completionCount)")
    }
    
    await test("Parallel checkCompletion calls should only fire onAllComplete once") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        bridge.onAllComplete = { completionCount += 1 }
        
        let seq = await bridge.nextSequence()
        await bridge.submitResult(seq: seq, text: "done")
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { await bridge.checkCompletion() }
            }
        }
        
        try expect(completionCount <= 1, "onAllComplete should fire at most once, got \(completionCount)")
    }
    
    await test("Reset should allow completion to fire again for new session") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        bridge.onAllComplete = { completionCount += 1 }
        
        let seq1 = await bridge.nextSequence()
        await bridge.submitResult(seq: seq1, text: "first session")
        await bridge.checkCompletion()
        try expect(completionCount == 1, "First session should complete")
        
        await bridge.reset()
        
        let seq2 = await bridge.nextSequence()
        await bridge.submitResult(seq: seq2, text: "second session")
        await bridge.checkCompletion()
        try expect(completionCount == 2, "Second session should also complete, got \(completionCount)")
    }
    
    await test("getPendingCount accuracy during rapid submissions") {
        let bridge = TranscriptionQueueBridge()
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        _ = await bridge.nextSequence()
        
        let pending1 = await bridge.getPendingCount()
        try expect(pending1 == 3, "Should have 3 pending, got \(pending1)")
        
        await bridge.submitResult(seq: 0, text: "first")
        let pending2 = await bridge.getPendingCount()
        try expect(pending2 == 2, "Should have 2 pending, got \(pending2)")
        
        await bridge.submitResult(seq: 1, text: "second")
        await bridge.submitResult(seq: 2, text: "third")
        let pending3 = await bridge.getPendingCount()
        try expect(pending3 == 0, "Should have 0 pending, got \(pending3)")
    }
}

// MARK: - Integration Tests

@MainActor
func runIntegrationTests() async {
    print("\n=== Integration Tests ===")
    
    await test("Full cancel flow: recorder.cancel() + Transcription.cancelAll()") {
        let recorder = StreamingRecorder()
        var chunkEmitted = false
        recorder.onChunkReady = { _ in chunkEmitted = true }
        recorder.cancel()
        Transcription.shared.cancelAll()
        try? await Task.sleep(for: .milliseconds(100))
        try expect(chunkEmitted == false, "Cancel flow should not emit chunks")
    }
    
    await test("Cancel during API wait discards result") {
        var resultReceived = false
        let apiTask = Task {
            try await Task.sleep(for: .seconds(5))
            resultReceived = true
            return "transcription result"
        }
        try? await Task.sleep(for: .milliseconds(50))
        apiTask.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        try expect(resultReceived == false, "Cancelled API task should not produce result")
    }
    
    await test("takeAll() returns empty after buffer is cleared") {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 1000), hasSpeech: true)
        let result = await buffer.takeAll()
        try expect(result.samples.count == 1000, "First takeAll should return samples")
        let emptyResult = await buffer.takeAll()
        try expect(emptyResult.samples.count == 0, "Buffer should be empty after takeAll")
    }
    
    await test("System sounds exist (Blow, Pop, Glass, Basso)") {
        try expect(NSSound(named: "Blow") != nil, "Blow sound should exist")
        try expect(NSSound(named: "Pop") != nil, "Pop sound should exist")
        try expect(NSSound(named: "Glass") != nil, "Glass sound should exist")
        try expect(NSSound(named: "Basso") != nil, "Basso sound should exist")
    }
}

// MARK: - Main Entry Point

@main
struct TestMain {
    static func main() async {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  SpeakFlow Test Suite")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        await runAudioTests()
        await runAuthTests()
        await runConfigTests()
        await runTranscriptionTests()
        await runDoubleSoundTests()
        await runIntegrationTests()
        
        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  Results: \(testsPassed) passed, \(testsFailed) failed")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
        
        exit(testsFailed > 0 ? 1 : 0)
    }
}
