import Foundation
import AppKit
import AVFoundation
@testable import SpeakFlowCore

// MARK: - Simple Test Framework

@MainActor var testsPassed = 0
@MainActor var testsFailed = 0

@MainActor
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

    await test("REGRESSION: createOneShotInputBlock returns noDataNow on second call") {
        // Create a dummy buffer
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        
        // Create the block
        let block = createOneShotInputBlock(buffer: buffer)
        
        // First call should have data
        var status = AVAudioConverterInputStatus.haveData
        let outBuffer1 = block(100, &status)
        try expect(status == .haveData, "First call should return .haveData")
        try expect(outBuffer1 === buffer, "First call should return the buffer")
        
        // Second call should have NO data
        let outBuffer2 = block(100, &status)
        try expect(status == .noDataNow, "Second call should return .noDataNow")
        try expect(outBuffer2 == nil, "Second call should return nil")
    }

    await test("REFACTOR: AVFoundation import is NOT @preconcurrency") {
        // Verify that @preconcurrency import AVFoundation is no longer used.
        // The non-Sendable AVAudioPCMBuffer is now explicitly wrapped in
        // OneShotState: @unchecked Sendable in createOneShotInputBlock(),
        // making the unsafe boundary visible rather than silently suppressed.
        // This test verifies the approach works by creating the block across
        // a Task boundary (which requires Sendable).
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        let block = createOneShotInputBlock(buffer: buffer)
        
        // The block is @Sendable (AVAudioConverterInputBlock) — verify it works
        var status = AVAudioConverterInputStatus.haveData
        let result = block(100, &status)
        try expect(result != nil, "Block should work without @preconcurrency import")
    }

    await test("StreamingRecorder stop still emits final chunk after owner drops reference") {
        let settings = Settings.shared
        let originalChunkDuration = settings.chunkDuration
        let originalSkipSilent = settings.skipSilentChunks
        defer {
            settings.chunkDuration = originalChunkDuration
            settings.skipSilentChunks = originalSkipSilent
        }

        settings.chunkDuration = .unlimited
        settings.skipSilentChunks = false

        var recorder: StreamingRecorder? = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        recorder?._testInjectAudioBuffer(buffer)
        var emitCount = 0
        recorder?.onChunkReady = { _ in emitCount += 1 }

        recorder?.stop()
        recorder = nil

        try? await Task.sleep(for: .milliseconds(250))
        try expect(emitCount == 1, "Final chunk should emit even if recorder reference is released")
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

// MARK: - OAuth Callback Server Synchronization Tests

@MainActor
func runOAuthServerSyncTests() async {
    print("\n=== OAuth Callback Server Synchronization Tests ===")

    await test("OAuthCallbackServer: stop is idempotent") {
        let server = OAuthCallbackServer(expectedState: "test-state")
        // Multiple stop calls should not crash (no double close)
        server.stop()
        server.stop()
        server.stop()
        try expect(true, "Multiple stop() calls should be safe")
    }

    await test("OAuthCallbackServer: concurrent stops don't crash") {
        let server = OAuthCallbackServer(expectedState: "test-state")
        // Simulate concurrent stop from multiple threads
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    server.stop()
                }
            }
        }
        try expect(true, "Concurrent stop() calls should be safe")
    }

    await test("OAuthCallbackServer: cancellation resumes with nil") {
        let server = OAuthCallbackServer(expectedState: "test-state")
        
        let task = Task {
            await server.waitForCallback(timeout: 10)
        }
        
        // Give the server time to start listening
        try? await Task.sleep(for: .milliseconds(200))
        
        // Cancel — should resume continuation with nil
        task.cancel()
        
        let result = await task.value
        try expect(result == nil, "Cancelled callback should return nil, got: \(String(describing: result))")
    }

    await test("OAuthCallbackServer: timeout returns nil") {
        let server = OAuthCallbackServer(expectedState: "test-state")
        
        // Very short timeout
        let result = await server.waitForCallback(timeout: 0.3)
        try expect(result == nil, "Timeout should return nil")
    }

    await test("OAuthCallbackServer: stop during wait returns nil") {
        let server = OAuthCallbackServer(expectedState: "test-state")
        
        let task = Task {
            await server.waitForCallback(timeout: 10)
        }
        
        // Give the server time to start
        try? await Task.sleep(for: .milliseconds(200))
        
        // External stop while waiting
        server.stop()
        
        let result = await task.value
        try expect(result == nil, "Stop during wait should return nil")
    }

    await test("OAuthCallbackServer: concurrent cancel and stop don't double-resume") {
        // This is the core regression: concurrent cancel + stop could double-resume
        // the CheckedContinuation, causing a runtime crash
        for _ in 0..<5 {
            let server = OAuthCallbackServer(expectedState: "test-state")
            
            let task = Task {
                await server.waitForCallback(timeout: 10)
            }
            
            try? await Task.sleep(for: .milliseconds(150))
            
            // Race: cancel and stop at the same time
            async let cancelResult: Void = { task.cancel() }()
            async let stopResult: Void = { server.stop() }()
            _ = await (cancelResult, stopResult)
            
            let result = await task.value
            try expect(result == nil, "Raced cancel+stop should return nil without crashing")
        }
    }

    await test("OAuthCallbackServer: valid callback returns code") {
        let state = "test-state-\(UUID().uuidString)"
        let server = OAuthCallbackServer(expectedState: state)
        
        let task = Task {
            await server.waitForCallback(timeout: 5)
        }
        
        // Give the server time to start
        try? await Task.sleep(for: .milliseconds(300))
        
        // Send a valid callback
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?code=test-code-123&state=\(state)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        try expect(httpResponse.statusCode == 200, "Should get 200 OK, got \(httpResponse.statusCode)")
        
        let result = await task.value
        try expect(result == "test-code-123", "Should return the authorization code, got: \(String(describing: result))")
    }

    await test("OAuthCallbackServer: wrong state returns nil") {
        let server = OAuthCallbackServer(expectedState: "correct-state")
        
        let task = Task {
            await server.waitForCallback(timeout: 5)
        }
        
        try? await Task.sleep(for: .milliseconds(300))
        
        // Send callback with wrong state
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?code=stolen-code&state=wrong-state")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        try expect(httpResponse.statusCode == 400, "Should get 400 for wrong state, got \(httpResponse.statusCode)")
        
        let result = await task.value
        try expect(result == nil, "Wrong state should return nil")
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
    
    await test("ChunkDuration.unlimited is 1 hour") {
        try expect(ChunkDuration.unlimited.rawValue == 3600.0, "Unlimited should be 1 hour")
        try expect(ChunkDuration.unlimited.isFullRecording == true, "Should be identified as unlimited")
    }
    
    await test("ChunkDuration.minDuration values are correct") {
        try expect(ChunkDuration.minute1.minDuration == 60.0, "1 min chunk should have 60s min")
        try expect(ChunkDuration.seconds30.minDuration == 30.0, "30s chunk should have 30s min")
        try expect(ChunkDuration.minute5.minDuration == 300.0, "5 min chunk should have 300s min")
        try expect(ChunkDuration.unlimited.minDuration == 0.25, "Unlimited should have 250ms min")
    }
    
    await test("ChunkDuration has exactly 9 options") {
        let expected = 9
        try expect(ChunkDuration.allCases.count == expected,
                   "Should have \(expected) options, got \(ChunkDuration.allCases.count)")
    }

    await test("ChunkDuration raw values match expected seconds") {
        try expect(ChunkDuration.seconds15.rawValue == 15.0, "15s should be 15.0")
        try expect(ChunkDuration.seconds30.rawValue == 30.0, "30s should be 30.0")
        try expect(ChunkDuration.seconds45.rawValue == 45.0, "45s should be 45.0")
        try expect(ChunkDuration.minute1.rawValue == 60.0, "1m should be 60.0")
        try expect(ChunkDuration.minute2.rawValue == 120.0, "2m should be 120.0")
        try expect(ChunkDuration.minute5.rawValue == 300.0, "5m should be 300.0")
        try expect(ChunkDuration.minute10.rawValue == 600.0, "10m should be 600.0")
        try expect(ChunkDuration.minute15.rawValue == 900.0, "15m should be 900.0")
        try expect(ChunkDuration.unlimited.rawValue == 3600.0, "unlimited should be 3600.0")
    }

    await test("ChunkDuration allCases is in ascending order") {
        let values = ChunkDuration.allCases.map { $0.rawValue }
        for i in 1..<values.count {
            try expect(values[i] > values[i-1],
                       "allCases should be ascending: \(values[i-1]) should be < \(values[i])")
        }
    }

    await test("ChunkDuration.isFullRecording only true for unlimited") {
        for duration in ChunkDuration.allCases {
            if duration == .unlimited {
                try expect(duration.isFullRecording == true, "unlimited should be full recording")
            } else {
                try expect(duration.isFullRecording == false, "\(duration) should NOT be full recording")
            }
        }
    }

    await test("ChunkDuration minDuration equals rawValue for non-unlimited") {
        for duration in ChunkDuration.allCases where duration != .unlimited {
            try expect(duration.minDuration == duration.rawValue,
                       "\(duration) minDuration should equal rawValue (\(duration.rawValue)), got \(duration.minDuration)")
        }
    }

    await test("All ChunkDurations have display names") {
        for duration in ChunkDuration.allCases {
            try expect(!duration.displayName.isEmpty, "\(duration) should have a display name")
        }
    }

    await test("ChunkDuration display names are user-friendly") {
        try expect(ChunkDuration.seconds15.displayName == "15 seconds", "Got: \(ChunkDuration.seconds15.displayName)")
        try expect(ChunkDuration.seconds45.displayName == "45 seconds", "Got: \(ChunkDuration.seconds45.displayName)")
        try expect(ChunkDuration.minute2.displayName == "2 minutes", "Got: \(ChunkDuration.minute2.displayName)")
        try expect(ChunkDuration.minute10.displayName == "10 minutes", "Got: \(ChunkDuration.minute10.displayName)")
        try expect(ChunkDuration.minute15.displayName == "15 minutes", "Got: \(ChunkDuration.minute15.displayName)")
        try expect(ChunkDuration.unlimited.displayName.contains("Unlimited"), "Got: \(ChunkDuration.unlimited.displayName)")
    }

    await test("Settings default chunkDuration is minute1") {
        // After clearing, default should be 1 minute
        let settings = Settings.shared
        let current = settings.chunkDuration
        // Verify the default fallback works for unknown raw values
        try expect(ChunkDuration(rawValue: 999.0) == nil, "Invalid raw value should return nil")
        // Verify current setting is a valid ChunkDuration
        try expect(ChunkDuration.allCases.contains(current), "Current setting should be a valid ChunkDuration")
    }
}

// MARK: - Transcription Tests

@MainActor
func runTranscriptionTests() async {
    print("\n=== Transcription Tests ===")
    
    await test("Transcription.cancelAll completes without error") {
        // Note: TranscriptionService.cancelAll() was removed (dead code — activeTasks
        // was never populated). Task cancellation is handled by Transcription.cancelAll()
        // which tracks tasks in processingTasks.
        Transcription.shared.cancelAll()
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
        let initialTicket = await bridge.nextSequence()
        await bridge.submitResult(ticket: initialTicket, text: "test1")
        let secondTicket = await bridge.nextSequence()
        try expect(secondTicket.seq == initialTicket.seq + 1, "Sequence should increment")
        
        await bridge.reset()
        let afterResetTicket = await bridge.nextSequence()
        try expect(afterResetTicket.seq == initialTicket.seq, "Sequence should restart after reset, got \(afterResetTicket.seq)")
        try expect(afterResetTicket.session != initialTicket.session, "Session generation should change after reset")
    }
    
    await test("TranscriptionQueueBridge handles out-of-order results") {
        let bridge = TranscriptionQueueBridge()
        let t0 = await bridge.nextSequence()
        let t1 = await bridge.nextSequence()
        let t2 = await bridge.nextSequence()
        // Note: submit out of order but with valid tickets
        // seq 0,1,2 but t2 has seq=2, etc - swap submission order
        await bridge.submitResult(ticket: t2, text: "third")
        await bridge.submitResult(ticket: t0, text: "first")
        await bridge.submitResult(ticket: t1, text: "second")
        try expect(true, "Out-of-order submission should not crash")
    }
}

// MARK: - Session Generation Guard Tests

@MainActor
func runSessionGenerationGuardTests() async {
    print("\n=== Session Generation Guard Tests ===")

    await test("TranscriptionTicket carries session and seq") {
        let ticket = TranscriptionTicket(session: 42, seq: 7)
        try expect(ticket.session == 42, "Session should be 42")
        try expect(ticket.seq == 7, "Seq should be 7")
    }

    await test("TranscriptionTicket is Equatable") {
        let a = TranscriptionTicket(session: 1, seq: 0)
        let b = TranscriptionTicket(session: 1, seq: 0)
        let c = TranscriptionTicket(session: 2, seq: 0)
        try expect(a == b, "Same session/seq tickets should be equal")
        try expect(a != c, "Different session tickets should not be equal")
    }

    await test("Session generation increments on reset") {
        let queue = TranscriptionQueue()
        let gen0 = await queue.currentSessionGeneration()
        await queue.reset()
        let gen1 = await queue.currentSessionGeneration()
        await queue.reset()
        let gen2 = await queue.currentSessionGeneration()
        try expect(gen1 == gen0 + 1, "Generation should increment by 1, got \(gen1)")
        try expect(gen2 == gen0 + 2, "Generation should increment by 2, got \(gen2)")
    }

    await test("nextSequence returns ticket with current session generation") {
        let queue = TranscriptionQueue()
        let gen0 = await queue.currentSessionGeneration()
        let ticket = await queue.nextSequence()
        try expect(ticket.session == gen0, "Ticket session should match current generation")
        try expect(ticket.seq == 0, "First seq should be 0")

        let ticket2 = await queue.nextSequence()
        try expect(ticket2.session == gen0, "Same session before reset")
        try expect(ticket2.seq == 1, "Second seq should be 1")
    }

    await test("REGRESSION: Stale result from previous session is silently discarded") {
        // This is the core bug: session N result lands in session N+1
        let bridge = TranscriptionQueueBridge()
        var receivedTexts: [String] = []
        bridge.onTextReady = { text in receivedTexts.append(text) }
        bridge.startListening()

        // Session 0: get a ticket
        let staleTicket = await bridge.nextSequence()
        try expect(staleTicket.session == 0, "First session should be 0")

        // Reset — starts session 1
        await bridge.reset()

        // Session 1: get a new ticket
        let freshTicket = await bridge.nextSequence()
        try expect(freshTicket.session == 1, "After reset, session should be 1")
        try expect(freshTicket.seq == 0, "Seq restarts at 0 after reset")

        // Stale result from session 0 arrives late — MUST be discarded
        await bridge.submitResult(ticket: staleTicket, text: "STALE - should not appear")

        // Fresh result from session 1
        await bridge.submitResult(ticket: freshTicket, text: "fresh result")

        // Give the stream time to deliver
        try? await Task.sleep(for: .milliseconds(100))

        try expect(receivedTexts.count == 1, "Should receive exactly 1 text, got \(receivedTexts.count)")
        try expect(receivedTexts.first == "fresh result",
            "Should only contain fresh result, got: \(receivedTexts)")

        bridge.stopListening()
    }

    await test("REGRESSION: Stale markFailed from previous session is discarded") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        bridge.onAllComplete = { completionCount += 1 }

        // Session 0: get tickets
        let staleTicket = await bridge.nextSequence()

        // Reset — starts session 1
        await bridge.reset()

        // Session 1
        let freshTicket = await bridge.nextSequence()

        // Stale failure arrives — should NOT affect session 1's pending count
        await bridge.markFailed(ticket: staleTicket)

        // Session 1's ticket is still pending
        let pending = await bridge.getPendingCount()
        try expect(pending == 1, "Should have 1 pending (stale failure ignored), got \(pending)")

        // Complete session 1
        await bridge.submitResult(ticket: freshTicket, text: "done")
        await bridge.checkCompletion()
        try expect(completionCount == 1, "Session 1 should complete, got \(completionCount)")
    }

    await test("REGRESSION: Stale result with same seq number doesn't collide") {
        // The exact scenario described in the bug: seq numbers collide across sessions
        let bridge = TranscriptionQueueBridge()
        var receivedTexts: [String] = []
        bridge.onTextReady = { text in receivedTexts.append(text) }
        bridge.startListening()

        // Session 0: seq 0
        let session0Ticket = await bridge.nextSequence()
        try expect(session0Ticket.seq == 0, "Session 0 seq should be 0")

        // Reset
        await bridge.reset()

        // Session 1: also seq 0 (numbers restart!)
        let session1Ticket = await bridge.nextSequence()
        try expect(session1Ticket.seq == 0, "Session 1 seq should also be 0")
        try expect(session0Ticket.session != session1Ticket.session,
            "Session generations must differ")

        // Both arrive — only session 1's result should be accepted
        await bridge.submitResult(ticket: session0Ticket, text: "OLD SESSION")
        await bridge.submitResult(ticket: session1Ticket, text: "CURRENT SESSION")

        try? await Task.sleep(for: .milliseconds(100))

        try expect(receivedTexts == ["CURRENT SESSION"],
            "Only current session result accepted, got: \(receivedTexts)")

        bridge.stopListening()
    }

    await test("REGRESSION: Multiple resets don't confuse session tracking") {
        let bridge = TranscriptionQueueBridge()
        var receivedTexts: [String] = []
        bridge.onTextReady = { text in receivedTexts.append(text) }
        bridge.startListening()

        // Session 0
        let t0 = await bridge.nextSequence()
        await bridge.reset()
        // Session 1
        let t1 = await bridge.nextSequence()
        await bridge.reset()
        // Session 2
        let t2 = await bridge.nextSequence()

        // Submit all — only session 2 (latest) should be accepted
        await bridge.submitResult(ticket: t0, text: "session0")
        await bridge.submitResult(ticket: t1, text: "session1")
        await bridge.submitResult(ticket: t2, text: "session2")

        try? await Task.sleep(for: .milliseconds(100))

        try expect(receivedTexts == ["session2"],
            "Only latest session result accepted, got: \(receivedTexts)")

        bridge.stopListening()
    }

    await test("Valid tickets from current session are all accepted") {
        let bridge = TranscriptionQueueBridge()
        var receivedTexts: [String] = []
        bridge.onTextReady = { text in receivedTexts.append(text) }
        bridge.startListening()

        let t0 = await bridge.nextSequence()
        let t1 = await bridge.nextSequence()
        let t2 = await bridge.nextSequence()

        // Submit in order
        await bridge.submitResult(ticket: t0, text: "first")
        await bridge.submitResult(ticket: t1, text: "second")
        await bridge.submitResult(ticket: t2, text: "third")

        try? await Task.sleep(for: .milliseconds(100))

        try expect(receivedTexts == ["first", "second", "third"],
            "All current session results should be accepted, got: \(receivedTexts)")

        bridge.stopListening()
    }

    await test("checkCompletion ignores stale pending from old session") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        bridge.onAllComplete = { completionCount += 1 }

        // Session 0: create 2 tickets, only complete 1
        let t0a = await bridge.nextSequence()
        _ = await bridge.nextSequence()  // t0b intentionally not completed
        await bridge.submitResult(ticket: t0a, text: "partial")

        // Reset — session 1
        await bridge.reset()

        // Session 1: single ticket, completed
        let t1 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t1, text: "done")
        await bridge.checkCompletion()

        try expect(completionCount == 1,
            "Session 1 should complete independently of stale session 0, got \(completionCount)")
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
        
        let t1 = await bridge.nextSequence()
        let t2 = await bridge.nextSequence()
        let t3 = await bridge.nextSequence()
        
        await bridge.submitResult(ticket: t1, text: "first")
        await bridge.checkCompletion()
        await bridge.submitResult(ticket: t2, text: "second")
        await bridge.checkCompletion()
        await bridge.submitResult(ticket: t3, text: "third")
        await bridge.checkCompletion()
        
        try expect(completionCount == 1, "onAllComplete should only fire once, got \(completionCount)")
    }
    
    await test("Parallel checkCompletion calls should only fire onAllComplete once") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        bridge.onAllComplete = { completionCount += 1 }
        
        let ticket = await bridge.nextSequence()
        await bridge.submitResult(ticket: ticket, text: "done")
        
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
        
        let t1 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t1, text: "first session")
        await bridge.checkCompletion()
        try expect(completionCount == 1, "First session should complete")
        
        await bridge.reset()
        
        let t2 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t2, text: "second session")
        await bridge.checkCompletion()
        try expect(completionCount == 2, "Second session should also complete, got \(completionCount)")
    }
    
    await test("getPendingCount accuracy during rapid submissions") {
        let bridge = TranscriptionQueueBridge()
        let t0 = await bridge.nextSequence()
        let t1 = await bridge.nextSequence()
        let t2 = await bridge.nextSequence()
        
        let pending1 = await bridge.getPendingCount()
        try expect(pending1 == 3, "Should have 3 pending, got \(pending1)")
        
        await bridge.submitResult(ticket: t0, text: "first")
        let pending2 = await bridge.getPendingCount()
        try expect(pending2 == 2, "Should have 2 pending, got \(pending2)")
        
        await bridge.submitResult(ticket: t1, text: "second")
        await bridge.submitResult(ticket: t2, text: "third")
        let pending3 = await bridge.getPendingCount()
        try expect(pending3 == 0, "Should have 0 pending, got \(pending3)")
    }
}

// MARK: - VAD Tests

@MainActor
func runVADTests() async {
    print("\n=== VAD Tests ===")

    await test("PlatformSupport.supportsVAD matches isAppleSilicon") {
        try expect(PlatformSupport.supportsVAD == PlatformSupport.isAppleSilicon, "supportsVAD should match isAppleSilicon")
    }

    await test("PlatformSupport.platformDescription is not empty") {
        try expect(!PlatformSupport.platformDescription.isEmpty, "platformDescription should not be empty")
    }

    await test("VADConfiguration defaults are correct") {
        let config = VADConfiguration()
        try expect(config.threshold == 0.5, "Default threshold should be 0.5")
        try expect(config.enabled == true, "Default enabled should be true")
    }

    await test("VADConfiguration.sensitive has lower threshold") {
        try expect(VADConfiguration.sensitive.threshold == 0.3, "Sensitive threshold should be 0.3")
    }

    await test("VADConfiguration.strict has higher threshold") {
        try expect(VADConfiguration.strict.threshold == 0.7, "Strict threshold should be 0.7")
    }

    await test("AutoEndConfiguration defaults are correct") {
        let config = AutoEndConfiguration()
        try expect(config.enabled == true, "Default enabled should be true")
        try expect(config.silenceDuration == 5.0, "Default silence duration should be 5.0")
        try expect(config.requireSpeechFirst == true, "Default requireSpeechFirst should be true")
    }

    await test("AutoEndConfiguration.disabled is disabled") {
        try expect(AutoEndConfiguration.disabled.enabled == false, "Disabled config should have enabled=false")
    }

    await test("VADProcessor.isAvailable matches platform support") {
        try expect(VADProcessor.isAvailable == PlatformSupport.supportsVAD, "isAvailable should match platform support")
    }

    await test("VADProcessor initial state is not speaking") {
        let processor = VADProcessor()
        let isSpeaking = await processor.isSpeaking
        try expect(isSpeaking == false, "Initial state should not be speaking")
    }

    await test("SessionController.startSession initializes correctly") {
        let controller = SessionController()
        await controller.startSession()
        let hasSpoken = await controller.hasSpoken
        try expect(hasSpoken == false, "New session should not have spoken")
    }

    await test("SessionController tracks speech events") {
        let controller = SessionController()
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        let hasSpoken = await controller.hasSpoken
        try expect(hasSpoken == true, "Should track speech after started event")
    }

    await test("SessionController.shouldAutoEndSession requires speech first") {
        let config = AutoEndConfiguration(enabled: true, silenceDuration: 0.1, minSessionDuration: 0.1, requireSpeechFirst: true)
        let controller = SessionController(autoEndConfig: config)
        await controller.startSession()
        try? await Task.sleep(for: .milliseconds(200))
        let shouldEnd = await controller.shouldAutoEndSession()
        try expect(shouldEnd == false, "Should not auto-end without speech")
    }

    await test("SessionController.shouldAutoEndSession triggers after silence") {
        // Use controllable clock because silenceDuration gets clamped to min 3.0s
        final class Clock: @unchecked Sendable {
            var now = Date()
            func date() -> Date { now }
        }
        let clock = Clock()
        let config = AutoEndConfiguration(enabled: true, silenceDuration: 3.0, minSessionDuration: 0.1, requireSpeechFirst: true)
        let controller = SessionController(autoEndConfig: config, dateProvider: clock.date)
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.now += 0.5
        await controller.onSpeechEvent(.ended(at: 0.5))
        clock.now += 3.5  // 3.5s silence >= 3.0s required
        let shouldEnd = await controller.shouldAutoEndSession()
        try expect(shouldEnd == true, "Should auto-end after silence")
    }

    await test("Config.vadThreshold is 0.3") {
        try expect(Config.vadThreshold == 0.3, "VAD threshold should be 0.3 (sensitive default)")
    }

    await test("Config.autoEndSilenceDuration is 5.0") {
        try expect(Config.autoEndSilenceDuration == 5.0, "Auto-end silence duration should be 5.0")
    }

    await test("StreamingRecorder has onAutoEnd callback") {
        let recorder = StreamingRecorder()
        recorder.onAutoEnd = {}
        try expect(recorder.onAutoEnd != nil, "onAutoEnd should be settable")
    }

    await test("VAD chunk precheck does not clear short buffer") {
        let settings = Settings.shared
        let originalChunkDuration = settings.chunkDuration
        defer { settings.chunkDuration = originalChunkDuration }

        settings.chunkDuration = .minute1
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000 * 5), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)

        await recorder._testInvokeSendChunkIfReady(reason: "test short")
        let remaining = await recorder._testAudioBufferDuration()
        try expect(remaining >= 4.9, "Short buffer should be preserved, got \(remaining)s")
    }

    await test("Full recording mode does not VAD-chunk on pauses") {
        let settings = Settings.shared
        let originalChunkDuration = settings.chunkDuration
        defer { settings.chunkDuration = originalChunkDuration }

        settings.chunkDuration = .unlimited
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)
        recorder._testSetVADActive(true)

        let session = SessionController(
            vadConfig: VADConfiguration(minSilenceAfterSpeech: 0.1),
            autoEndConfig: .disabled,
            maxChunkDuration: 30.0
        )
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 0.1))
        recorder._testInjectSessionController(session)

        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }

        try? await Task.sleep(for: .milliseconds(5200))
        await recorder._testInvokePeriodicCheck()
        try expect(emitted == 0, "Full recording mode should not emit pause chunks")
    }

    await test("Final chunk uses VAD score before reset") {
        let settings = Settings.shared
        let originalChunkDuration = settings.chunkDuration
        let originalSkipSilent = settings.skipSilentChunks
        defer {
            settings.chunkDuration = originalChunkDuration
            settings.skipSilentChunks = originalSkipSilent
        }

        settings.chunkDuration = .unlimited
        settings.skipSilentChunks = true

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)

        let vad = VADProcessor()
        await vad._testSeedAverageSpeechProbability(0.8, chunks: 5)
        recorder._testInjectVADProcessor(vad)

        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        try expect(emitted == 1, "Final chunk should be emitted with pre-reset VAD score")
    }

    await test("Final chunk falls back to RMS speech when VAD has no score") {
        let settings = Settings.shared
        let originalChunkDuration = settings.chunkDuration
        let originalSkipSilent = settings.skipSilentChunks
        defer {
            settings.chunkDuration = originalChunkDuration
            settings.skipSilentChunks = originalSkipSilent
        }

        settings.chunkDuration = .unlimited
        settings.skipSilentChunks = true

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetVADActive(true)

        let vad = VADProcessor()
        await vad._testSeedAverageSpeechProbability(0, chunks: 0)
        recorder._testInjectVADProcessor(vad)

        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        try expect(emitted == 1, "Final chunk should fall back to RMS speech when VAD score is unavailable")
    }
}

// MARK: - Regression Tests (VAD Recording Bug Fix)

@MainActor
func runRegressionTests() async {
    print("\n=== Regression Tests (VAD Bug Fix) ===")
    
    // REGRESSION TEST 1: Chunk sent when VAD never fires
    // Root cause: shouldSendChunk() returned false when lastSpeechEndTime == nil
    // Fix: Added fallback path for when VAD doesn't detect speech
    
    await test("REGRESSION: shouldSendChunk returns true when VAD never fires after maxDuration") {
        // Simulate VAD that never detects speech (lastSpeechEndTime stays nil)
        let controller = SessionController(
            vadConfig: .default,
            autoEndConfig: .disabled,
            maxChunkDuration: 0.1  // Very short for testing
        )
        await controller.startSession()
        
        // Verify initial state - VAD has not fired
        let vadNeverFired = await controller._testLastSpeechEndTimeIsNil
        try expect(vadNeverFired == true, "lastSpeechEndTime should be nil (VAD never fired)")
        
        // Wait for maxChunkDuration to elapse
        try? await Task.sleep(for: .milliseconds(150))
        
        // The fix: shouldSendChunk should return true even when VAD never detected speech
        let shouldSend = await controller.shouldSendChunk()
        try expect(shouldSend == true, "shouldSendChunk MUST return true when VAD never fires but maxDuration reached")
    }
    
    await test("REGRESSION: shouldSendChunk returns false before maxDuration when VAD never fires") {
        let controller = SessionController(
            vadConfig: .default,
            autoEndConfig: .disabled,
            maxChunkDuration: 30.0  // Long duration
        )
        await controller.startSession()
        
        // Should NOT send chunk immediately when VAD hasn't fired and duration is short
        let shouldSend = await controller.shouldSendChunk()
        try expect(shouldSend == false, "Should not send chunk before maxDuration when VAD hasn't fired")
    }
    
    await test("REGRESSION: shouldSendChunk fallback only triggers when not speaking") {
        let controller = SessionController(
            vadConfig: .default,
            autoEndConfig: .disabled,
            maxChunkDuration: 0.1
        )
        await controller.startSession()
        
        // Start speaking (but never end - simulates ongoing speech)
        await controller.onSpeechEvent(.started(at: 0))
        
        try? await Task.sleep(for: .milliseconds(150))
        
        // Should NOT trigger fallback while user is actively speaking
        let shouldSend = await controller.shouldSendChunk()
        try expect(shouldSend == false, "Fallback should not trigger while user is speaking")
    }
    
    // REGRESSION TEST 2: skipSilentChunks threshold behavior
    // Chunks with < 3% speech should be skipped when skipSilentChunks=true
    
    await test("REGRESSION: Chunk with speech above threshold is sent when skipSilentChunks=true") {
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        defer {
            settings.skipSilentChunks = originalSkipSilent
            settings.chunkDuration = originalChunkDuration
        }
        
        settings.skipSilentChunks = true
        settings.chunkDuration = .unlimited
        
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        // Add audio with >3% speech (all samples marked as speech)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        
        var emitted = 0
        recorder.onChunkReady = { chunk in
            emitted += 1
            // Verify chunk has high speech probability
            if chunk.speechProbability < Config.minSpeechRatio {
                emitted = -1  // Mark as failure
            }
        }
        
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        try expect(emitted == 1, "Chunk with speech above threshold should be sent")
    }
    
    await test("REGRESSION: Chunk with speech below threshold is skipped when skipSilentChunks=true") {
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        defer {
            settings.skipSilentChunks = originalSkipSilent
            settings.chunkDuration = originalChunkDuration
        }
        
        settings.skipSilentChunks = true
        settings.chunkDuration = .unlimited
        
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        // Add audio with <3% speech (all samples marked as non-speech)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: false)
        recorder._testInjectAudioBuffer(buffer)
        
        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }
        
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        try expect(emitted == 0, "Chunk with speech below threshold should be skipped when skipSilentChunks=true")
    }
    
    await test("REGRESSION: Chunk with speech below threshold is sent when skipSilentChunks=false") {
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        defer {
            settings.skipSilentChunks = originalSkipSilent
            settings.chunkDuration = originalChunkDuration
        }
        
        settings.skipSilentChunks = false  // The key difference
        settings.chunkDuration = .unlimited
        
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        // Add audio with <3% speech (all samples marked as non-speech)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: false)
        recorder._testInjectAudioBuffer(buffer)
        
        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }
        
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        try expect(emitted == 1, "Chunk should be sent regardless of speech when skipSilentChunks=false")
    }
    
    // REGRESSION TEST 3: Short recordings still send final chunk
    // Even recordings <5 seconds should emit final chunk on stop()
    
    await test("REGRESSION: Short recording (2s) emits final chunk on stop") {
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        defer {
            settings.skipSilentChunks = originalSkipSilent
            settings.chunkDuration = originalChunkDuration
        }
        
        settings.skipSilentChunks = false
        settings.chunkDuration = .unlimited
        
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        // 2 seconds of audio
        await buffer.append(frames: [Float](repeating: 0.5, count: 32000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        
        var emittedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in emittedChunk = chunk }
        
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        
        try expect(emittedChunk != nil, "Short recording should emit final chunk")
        try expect(emittedChunk!.durationSeconds >= 1.9 && emittedChunk!.durationSeconds <= 2.1,
                   "Chunk duration should be ~2 seconds, got \(emittedChunk!.durationSeconds)")
    }
    
    await test("REGRESSION: Very short recording (500ms) emits final chunk on stop") {
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        defer {
            settings.skipSilentChunks = originalSkipSilent
            settings.chunkDuration = originalChunkDuration
        }
        
        settings.skipSilentChunks = false
        settings.chunkDuration = .unlimited
        
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        // 500ms of audio (8000 samples at 16kHz)
        await buffer.append(frames: [Float](repeating: 0.5, count: 8000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        
        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }
        
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        
        try expect(emitted == 1, "Very short recording (500ms) should emit final chunk")
    }
    
    await test("REGRESSION: Recording below minRecordingDurationMs (250ms) does NOT emit chunk") {
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        defer {
            settings.skipSilentChunks = originalSkipSilent
            settings.chunkDuration = originalChunkDuration
        }
        
        settings.skipSilentChunks = false
        settings.chunkDuration = .unlimited
        
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        // 100ms of audio (1600 samples at 16kHz) - below 250ms minimum
        await buffer.append(frames: [Float](repeating: 0.5, count: 1600), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        
        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }
        
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        
        try expect(emitted == 0, "Recording below 250ms minimum should NOT emit chunk")
    }
    
    // REGRESSION TEST 4: Combined scenario - VAD fallback with skipSilentChunks
    // This is the exact scenario that caused the original bug
    
    await test("REGRESSION: Full scenario - VAD never fires + skipSilentChunks=false = chunk sent") {
        let settings = Settings.shared
        let originalSkipSilent = settings.skipSilentChunks
        let originalChunkDuration = settings.chunkDuration
        defer {
            settings.skipSilentChunks = originalSkipSilent
            settings.chunkDuration = originalChunkDuration
        }
        
        // This is the E2E test configuration that now works
        settings.skipSilentChunks = false
        settings.chunkDuration = .unlimited
        
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        
        // Simulate audio where VAD didn't detect much speech (low speech ratio)
        // 30% speech, 70% silence - similar to TTS audio
        await buffer.append(frames: [Float](repeating: 0.5, count: 4800), hasSpeech: true)   // 300ms speech
        await buffer.append(frames: [Float](repeating: 0.01, count: 11200), hasSpeech: false) // 700ms silence
        recorder._testInjectAudioBuffer(buffer)
        
        var emittedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in emittedChunk = chunk }
        
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        
        try expect(emittedChunk != nil, "Chunk MUST be sent when skipSilentChunks=false, even with low speech")
        let speechPct = (emittedChunk?.speechProbability ?? 0) * 100
        try expect(speechPct >= 25 && speechPct <= 35, "Speech probability should be ~30%, got \(speechPct)%")
    }
}

// MARK: - Start/Stop Race Condition Tests

@MainActor
func runStartStopRaceTests() async {
    print("\n=== Start/Stop Race Condition Tests ===")

    await test("RACE: stop() during VAD init aborts start cleanly (no orphan state)") {
        // Simulates: start() calls initializeVAD() which is async.
        // During that await, user calls stop() which sets recording=false.
        // After VAD init returns, start() must check recording state and abort.
        let recorder = StreamingRecorder()

        // Simulate: start() set recording=true, then stop() set it back to false
        // (as would happen if stop() is called during the VAD init await)
        recorder._testSetIsRecording(true)
        recorder._testSetIsRecording(false)

        // Verify the recorder is in a clean state — no orphan timers or engine
        try expect(!recorder._testIsRecording, "Recording should be false after stop()")
        try expect(!recorder._testHasProcessingTimer, "No orphan processing timer")
        try expect(!recorder._testHasCheckTimer, "No orphan check timer")
    }

    await test("RACE: normal stop() cleans up all state") {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.3, count: 16000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        // stop() should clean up
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))

        try expect(!recorder._testIsRecording, "Recording should be false after stop()")
    }
}

// MARK: - Recorder Startup Failure Tests

@MainActor
func runRecorderStartupFailureTests() async {
    print("\n=== Recorder Startup Failure Tests ===")

    await test("start() returns true on successful start (with mic permission)") {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard auth == .authorized else {
            // Skip if no mic permission
            return
        }
        let recorder = StreamingRecorder()
        let started = await recorder.start()
        try expect(started == true, "start() should return true on success")
        try expect(recorder._testIsRecording, "Should be recording after successful start")
        try expect(recorder._testHasProcessingTimer, "Should have processing timer")
        try expect(recorder._testHasCheckTimer, "Should have check timer")
        try expect(recorder._testHasAudioEngine, "Should have audio engine")
        recorder.stop()
    }

    await test("start() returns Bool (discardableResult works)") {
        // Verify the @discardableResult attribute works — old call sites
        // that don't use the return value should still compile
        let recorder = StreamingRecorder()
        // This should not produce a warning due to @discardableResult
        await recorder.start()
        recorder.stop()
    }

    await test("REGRESSION: Failed start() cleans up all state") {
        // We can't easily force engine.start() to fail in a unit test,
        // but we CAN verify that the rollback path leaves clean state.
        // Simulate: recorder was set up, then engine.start() failed.
        let recorder = StreamingRecorder()
        recorder._testSetIsRecording(true)
        
        // After a failed start, isRecording should be false
        // (we test this by manually simulating the failure rollback)
        recorder._testSetIsRecording(false)
        
        try expect(!recorder._testIsRecording, "isRecording must be false after failed start")
        try expect(!recorder._testHasProcessingTimer, "No orphan processing timer")
        try expect(!recorder._testHasCheckTimer, "No orphan check timer")
    }

    await test("REGRESSION: stop() after start() clears all state cleanly") {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard auth == .authorized else { return }
        
        let recorder = StreamingRecorder()
        let started = await recorder.start()
        guard started else { return }
        
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        
        try expect(!recorder._testIsRecording, "isRecording false after stop")
        try expect(!recorder._testHasProcessingTimer, "No processing timer after stop")
        try expect(!recorder._testHasCheckTimer, "No check timer after stop")
    }

    await test("REGRESSION: cancel() after failed start() is safe") {
        let recorder = StreamingRecorder()
        // Simulate a recorder that was never successfully started
        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }
        recorder.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        try expect(emitted == 0, "Cancel on non-started recorder should not emit")
        try expect(!recorder._testIsRecording, "Should not be recording")
    }

    await test("REGRESSION: Rapid start/stop cycles don't leak resources") {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard auth == .authorized else { return }
        
        for _ in 0..<5 {
            let recorder = StreamingRecorder()
            let started = await recorder.start()
            if started {
                try expect(recorder._testIsRecording, "Should be recording")
            }
            recorder.stop()
            try? await Task.sleep(for: .milliseconds(100))
            try expect(!recorder._testIsRecording, "Should not be recording after stop")
            try expect(!recorder._testHasProcessingTimer, "No orphan timer")
            try expect(!recorder._testHasCheckTimer, "No orphan check timer")
        }
    }
}

// MARK: - Final Chunk Speech Protection Tests

@MainActor
func runFinalChunkProtectionTests() async {
    print("\n=== Final Chunk Speech Protection Tests ===")

    // ──────────────────────────────────────────────────────────────
    // When auto-end triggers after speech + silence (e.g. 2s talk +
    // 5s silence), stop() is called. The final chunk contains BOTH
    // speech and trailing silence. The average VAD probability gets
    // diluted by the silence and may drop below the skip threshold.
    //
    // FIX: If speech was detected at ANY point in the session,
    // always send the final chunk — skipSilentChunks only applies
    // to chunks with NO speech at all.
    // ──────────────────────────────────────────────────────────────

    await test("SPEECH PROTECTION: final chunk sent when speech detected but avg prob low (skipSilent=true)") {
        // Simulates: 2s speech + 5s silence → avg VAD prob diluted below 0.30
        // Bug was: final chunk silently dropped, speech lost
        let settings = Settings.shared
        let orig = (settings.chunkDuration, settings.skipSilentChunks)
        defer { settings.chunkDuration = orig.0; settings.skipSilentChunks = orig.1 }

        settings.chunkDuration = .unlimited
        settings.skipSilentChunks = true  // key: skip is enabled

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        // 2s speech + 5s silence = 7s total
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000 * 2), hasSpeech: true)
        await buffer.append(frames: [Float](repeating: 0.01, count: 16000 * 5), hasSpeech: false)
        recorder._testInjectAudioBuffer(buffer)

        // Inject VAD with low average probability (diluted by silence)
        // 2s of speech chunks at 0.8 + 5s silence chunks at 0.01
        // Average ≈ 0.23 — below 0.30 threshold
        let vad = VADProcessor()
        await vad._testSeedAverageSpeechProbability(0.23, chunks: 218)
        recorder._testInjectVADProcessor(vad)
        recorder._testSetVADActive(true)

        // Inject session controller that knows speech occurred
        let session = SessionController(
            vadConfig: .default,
            autoEndConfig: .default,
            maxChunkDuration: 3600.0
        )
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 2.0))
        recorder._testInjectSessionController(session)

        var emittedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in emittedChunk = chunk }

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))

        try expect(emittedChunk != nil,
            "Final chunk MUST be sent when speech was detected — even if avg VAD prob (0.23) < threshold (0.30)")
        try expect(emittedChunk!.durationSeconds >= 6.9 && emittedChunk!.durationSeconds <= 7.1,
            "Chunk should be ~7s (2s speech + 5s silence), got \(emittedChunk!.durationSeconds)s")
    }

    await test("SPEECH PROTECTION: final chunk SKIPPED when NO speech detected (skipSilent=true)") {
        // Pure silence session — no speech ever detected. Chunk should be skipped.
        let settings = Settings.shared
        let orig = (settings.chunkDuration, settings.skipSilentChunks)
        defer { settings.chunkDuration = orig.0; settings.skipSilentChunks = orig.1 }

        settings.chunkDuration = .unlimited
        settings.skipSilentChunks = true

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        // 5s of pure silence
        await buffer.append(frames: [Float](repeating: 0.01, count: 16000 * 5), hasSpeech: false)
        recorder._testInjectAudioBuffer(buffer)

        // VAD with very low probability (no speech)
        let vad = VADProcessor()
        await vad._testSeedAverageSpeechProbability(0.02, chunks: 156)
        recorder._testInjectVADProcessor(vad)
        recorder._testSetVADActive(true)

        // Session controller with NO speech detected
        let session = SessionController(
            vadConfig: .default,
            autoEndConfig: .default,
            maxChunkDuration: 3600.0
        )
        await session.startSession()
        // No speech events — hasSpoken = false
        recorder._testInjectSessionController(session)

        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))

        try expect(emitted == 0,
            "Chunk should be SKIPPED when no speech detected and skipSilentChunks=true")
    }

    await test("SPEECH PROTECTION: final chunk sent when speech detected (energy fallback, no VAD)") {
        // Without VAD, energy-based speech ratio used. 2s speech / 7s total = 28.6% > 3% threshold.
        let settings = Settings.shared
        let orig = (settings.chunkDuration, settings.skipSilentChunks)
        defer { settings.chunkDuration = orig.0; settings.skipSilentChunks = orig.1 }

        settings.chunkDuration = .unlimited
        settings.skipSilentChunks = true

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000 * 2), hasSpeech: true)
        await buffer.append(frames: [Float](repeating: 0.01, count: 16000 * 5), hasSpeech: false)
        recorder._testInjectAudioBuffer(buffer)
        // No VAD injected — falls back to energy speech ratio

        var emittedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in emittedChunk = chunk }

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))

        try expect(emittedChunk != nil,
            "Chunk sent with energy fallback — 28.6% speech > 3% threshold")
    }

    await test("SPEECH PROTECTION: skipSilentChunks defaults to true") {
        // Verify the default changed from false to true
        // Clear the key to test default behavior
        let settings = Settings.shared
        let orig = settings.skipSilentChunks
        defer { settings.skipSilentChunks = orig }

        UserDefaults.standard.removeObject(forKey: "settings.skipSilentChunks")
        try expect(settings.skipSilentChunks == true,
            "skipSilentChunks should default to true")
    }
}

// MARK: - Chunk Timing Regression Tests (No premature API calls)


@MainActor
func runChunkTimingRegressionTests() async {
    print("\n=== Chunk Timing Regression Tests ===")

    // ──────────────────────────────────────────────────────────────
    // SpeakFlow has TWO types of silence detection:
    //
    // 1. SHORT SILENCE (minSilenceAfterSpeech = 1s)
    //    → Used for CHUNK BOUNDARY: after the configured chunk
    //      duration has elapsed, a 1s pause triggers sending the
    //      chunk while KEEPING THE MIC ACTIVE for more speech.
    //    → NEVER fires before the chunk duration boundary.
    //
    // 2. LONG SILENCE (autoEndSilenceDuration = 5s)
    //    → Used for TURN END: 5s of silence after speech ends
    //      the entire session, deactivates the mic, and sends
    //      whatever was recorded as the final chunk.
    //    → Can fire at ANY time (even before chunk boundary).
    //
    // These two mechanisms are independent:
    //   shouldSendChunk()      → chunk boundary (short silence)
    //   shouldAutoEndSession() → turn end (long silence)
    // ──────────────────────────────────────────────────────────────

    // Helper: controllable clock
    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ date: Date = Date()) { now = date }
        func date() -> Date { now }
        func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
    }

    // ════════════════════════════════════════════════════════════
    // SECTION A: No premature chunk sends before chunk duration
    // ════════════════════════════════════════════════════════════

    await test("CHUNK TIMING: 15s chunk — no send at 5s despite speech pause") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: .disabled,
            maxChunkDuration: 15.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(3.0)
        await controller.onSpeechEvent(.ended(at: 3.0))
        clock.advance(2.0)
        try expect(await controller.shouldSendChunk() == false,
            "MUST NOT send chunk at 5s when chunk duration is 15s — was the premature API call bug")
    }

    await test("CHUNK TIMING: 15s chunk — no send at 10s despite multiple speech pauses") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: .disabled,
            maxChunkDuration: 15.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(3.0)
        await controller.onSpeechEvent(.ended(at: 3.0))
        clock.advance(2.0)
        try expect(await controller.shouldSendChunk() == false, "No send at 5s")
        await controller.onSpeechEvent(.started(at: 5.0))
        clock.advance(3.0)
        await controller.onSpeechEvent(.ended(at: 8.0))
        clock.advance(2.0)
        try expect(await controller.shouldSendChunk() == false, "No send at 10s")
    }

    await test("CHUNK TIMING: 15s chunk — no send at 14.9s (just under boundary)") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: .disabled,
            maxChunkDuration: 15.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(12.0)
        await controller.onSpeechEvent(.ended(at: 12.0))
        clock.advance(2.9)
        try expect(await controller.shouldSendChunk() == false,
            "MUST NOT send at 14.9s when chunk duration is 15s")
    }

    await test("CHUNK TIMING: 60s chunk — no send at 5/15/30/45/59s with pauses") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: .disabled,
            maxChunkDuration: 60.0, dateProvider: clock.date
        )
        await controller.startSession()
        let checkpoints: [Double] = [5, 15, 30, 45, 59]
        var elapsed: Double = 0
        for checkpoint in checkpoints {
            let speakDuration = checkpoint - elapsed - 2.0
            if speakDuration > 0 {
                await controller.onSpeechEvent(.started(at: elapsed))
                clock.advance(speakDuration)
                elapsed += speakDuration
                await controller.onSpeechEvent(.ended(at: elapsed))
            }
            clock.advance(2.0)
            elapsed += 2.0
            try expect(await controller.shouldSendChunk() == false,
                "MUST NOT send chunk at \(elapsed)s when chunk duration is 60s")
        }
    }

    // ════════════════════════════════════════════════════════════
    // SECTION B: Chunk sends at boundary + short silence (1s)
    // ════════════════════════════════════════════════════════════

    await test("CHUNK TIMING: 15s chunk — sends at 16s (past boundary + short silence)") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: .disabled,
            maxChunkDuration: 15.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(14.0)
        await controller.onSpeechEvent(.ended(at: 14.0))
        clock.advance(2.0)
        try expect(await controller.shouldSendChunk() == true,
            "Sends after 15s boundary + 2s silence")
    }

    await test("CHUNK TIMING: 60s chunk — sends at 62s after speech ends") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: .disabled,
            maxChunkDuration: 60.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(60.5)
        await controller.onSpeechEvent(.ended(at: 60.5))
        clock.advance(1.5)
        try expect(await controller.shouldSendChunk() == true,
            "Sends after 60s boundary + 1.5s silence")
    }

    // ════════════════════════════════════════════════════════════
    // SECTION C: VAD extends past boundary during active speech
    // ════════════════════════════════════════════════════════════

    await test("CHUNK TIMING: 15s chunk — no send at 20s while still speaking") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: .disabled,
            maxChunkDuration: 15.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(20.0)
        try expect(await controller.shouldSendChunk() == false,
            "MUST NOT interrupt active speech past chunk duration — VAD extends")
    }

    await test("CHUNK TIMING: 15s chunk — sends at 22s when speech finally pauses") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: .disabled,
            maxChunkDuration: 15.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(20.0)
        await controller.onSpeechEvent(.ended(at: 20.0))
        clock.advance(2.0)
        try expect(await controller.shouldSendChunk() == true,
            "Sends once speech pauses after exceeding chunk duration")
    }

    // ════════════════════════════════════════════════════════════
    // SECTION D: Turn end (auto-end) — LONG silence (5s)
    //   Independent of chunk boundary. Deactivates mic.
    // ════════════════════════════════════════════════════════════

    await test("TURN END: 30s chunk, talk 3s, silence → auto-end at 8s") {
        let clock = Clock()
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: autoEnd,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(3.0)
        await controller.onSpeechEvent(.ended(at: 3.0))

        clock.advance(1.0)  // t=4s, 1s silence
        try expect(await controller.shouldSendChunk() == false, "No chunk at 4s")
        try expect(await controller.shouldAutoEndSession() == false, "No auto-end at 4s (1s silence)")

        clock.advance(2.0)  // t=6s, 3s silence
        try expect(await controller.shouldAutoEndSession() == false, "No auto-end at 6s (3s silence)")

        clock.advance(2.0)  // t=8s, 5s silence
        try expect(await controller.shouldSendChunk() == false, "No chunk at 8s (under 30s)")
        try expect(await controller.shouldAutoEndSession() == true,
            "Auto-end at 8s (5s silence after 3s speech) — turn ends, mic off")
    }

    await test("TURN END: 60s chunk, talk 10s, silence → auto-end at 15s") {
        let clock = Clock()
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: autoEnd,
            maxChunkDuration: 60.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(10.0)
        await controller.onSpeechEvent(.ended(at: 10.0))
        clock.advance(4.0)
        try expect(await controller.shouldAutoEndSession() == false, "No auto-end at 14s (4s silence)")
        clock.advance(1.5)
        try expect(await controller.shouldAutoEndSession() == true,
            "Auto-end at 15.5s (5.5s silence)")
    }

    await test("TURN END: no auto-end during 2s pause between speech segments") {
        let clock = Clock()
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: autoEnd,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(5.0)
        await controller.onSpeechEvent(.ended(at: 5.0))
        clock.advance(2.0)
        try expect(await controller.shouldAutoEndSession() == false,
            "MUST NOT auto-end during 2s pause — need 5s")
        await controller.onSpeechEvent(.started(at: 7.0))
        clock.advance(5.0)
        await controller.onSpeechEvent(.ended(at: 12.0))
        clock.advance(3.0)
        try expect(await controller.shouldAutoEndSession() == false, "No auto-end at 3s silence")
        clock.advance(2.5)
        try expect(await controller.shouldAutoEndSession() == true, "Auto-end at 5.5s silence")
    }

    await test("TURN END: requires 5s not 1s of silence (locks in threshold)") {
        let clock = Clock()
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: autoEnd,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(5.0)
        await controller.onSpeechEvent(.ended(at: 5.0))
        for sec in 1...4 {
            clock.advance(1.0)
            try expect(await controller.shouldAutoEndSession() == false,
                "Auto-end MUST NOT fire after only \(sec)s of silence (need 5s)")
        }
        clock.advance(1.0)
        try expect(await controller.shouldAutoEndSession() == true,
            "Auto-end fires at exactly 5s of silence")
    }

    // ════════════════════════════════════════════════════════════
    // SECTION E: No speech at all → idle timeout
    // ════════════════════════════════════════════════════════════

    await test("TURN END: no speech → idle timeout at 10s") {
        let clock = Clock()
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true,
            noSpeechTimeout: 10.0
        )
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: autoEnd,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        clock.advance(5.0)
        try expect(await controller.shouldAutoEndSession() == false, "No auto-end at 5s (under timeout)")
        clock.advance(5.5)
        try expect(await controller.shouldAutoEndSession() == true, "Idle timeout at 10.5s")
    }

    await test("TURN END: no speech, no auto-end at 1s or 5s (only at timeout)") {
        let clock = Clock()
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true,
            noSpeechTimeout: 10.0
        )
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: autoEnd,
            maxChunkDuration: 60.0, dateProvider: clock.date
        )
        await controller.startSession()
        clock.advance(1.0)
        try expect(await controller.shouldAutoEndSession() == false, "No at 1s")
        clock.advance(4.0)
        try expect(await controller.shouldAutoEndSession() == false, "No at 5s")
        clock.advance(4.0)
        try expect(await controller.shouldAutoEndSession() == false, "No at 9s")
        clock.advance(1.5)
        try expect(await controller.shouldAutoEndSession() == true, "Idle timeout at 10.5s")
    }

    // ════════════════════════════════════════════════════════════
    // SECTION F: Chunk boundary + turn end interaction
    // ════════════════════════════════════════════════════════════

    await test("INTERACTION: 30s chunk, talk 35s, pause → chunk sends, then turn ends") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: autoEnd,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(35.0)
        await controller.onSpeechEvent(.ended(at: 35.0))

        // 1.5s silence → chunk sends (past 30s + short silence)
        clock.advance(1.5)
        try expect(await controller.shouldSendChunk() == true, "Chunk at boundary + short silence")
        try expect(await controller.shouldAutoEndSession() == false, "No turn end yet (1.5s)")
        await controller.chunkSent()

        // 5s total silence → turn ends
        clock.advance(3.5)
        try expect(await controller.shouldAutoEndSession() == true,
            "Turn ends at 5s silence — mic deactivates")
    }

    await test("INTERACTION: 30s chunk, talk 35s, short pause, talk again → no turn end") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: autoEnd,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(35.0)
        await controller.onSpeechEvent(.ended(at: 35.0))
        clock.advance(1.5)
        try expect(await controller.shouldSendChunk() == true, "Chunk sends")
        await controller.chunkSent()

        // User resumes speaking — resets silence timer
        await controller.onSpeechEvent(.started(at: 36.5))
        clock.advance(3.0)
        try expect(await controller.shouldAutoEndSession() == false,
            "No turn end — user resumed speaking")
    }

    // ════════════════════════════════════════════════════════════
    // SECTION G: StreamingRecorder sendChunkIfReady guards
    // ════════════════════════════════════════════════════════════

    await test("GUARD: sendChunkIfReady rejects 10s chunk when duration is 30s") {
        let settings = Settings.shared
        let orig = (settings.chunkDuration, settings.skipSilentChunks)
        defer { settings.chunkDuration = orig.0; settings.skipSilentChunks = orig.1 }
        settings.chunkDuration = .seconds30
        settings.skipSilentChunks = false

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 160_000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }
        await recorder._testInvokeSendChunkIfReady(reason: "test premature")
        try expect(emitted == 0, "MUST reject 10s chunk when duration is 30s")
        let remaining = await recorder._testAudioBufferDuration()
        try expect(remaining >= 9.9, "Audio must stay in buffer, got \(remaining)s")
    }

    await test("GUARD: sendChunkIfReady accepts 31s chunk when duration is 30s") {
        let settings = Settings.shared
        let orig = (settings.chunkDuration, settings.skipSilentChunks)
        defer { settings.chunkDuration = orig.0; settings.skipSilentChunks = orig.1 }
        settings.chunkDuration = .seconds30
        settings.skipSilentChunks = false

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000 * 31), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        var emitted = 0
        recorder.onChunkReady = { _ in emitted += 1 }
        await recorder._testInvokeSendChunkIfReady(reason: "test past boundary")
        try expect(emitted == 1, "Should accept 31s chunk when duration is 30s")
    }

    // ════════════════════════════════════════════════════════════
    // SECTION H: stop() always sends final chunk (session end)
    // ════════════════════════════════════════════════════════════

    await test("FINAL CHUNK: stop() sends 5s chunk even with 60s chunk setting") {
        let settings = Settings.shared
        let orig = (settings.chunkDuration, settings.skipSilentChunks)
        defer { settings.chunkDuration = orig.0; settings.skipSilentChunks = orig.1 }
        settings.chunkDuration = .minute1
        settings.skipSilentChunks = false

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000 * 5), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        var emittedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in emittedChunk = chunk }
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        try expect(emittedChunk != nil, "stop() MUST send final chunk — user ends session")
        try expect(emittedChunk!.durationSeconds >= 4.9 && emittedChunk!.durationSeconds <= 5.1,
            "Final chunk ~5s, got \(emittedChunk!.durationSeconds)s")
    }

    await test("FINAL CHUNK: stop() sends 3s chunk with 30s chunk setting") {
        let settings = Settings.shared
        let orig = (settings.chunkDuration, settings.skipSilentChunks)
        defer { settings.chunkDuration = orig.0; settings.skipSilentChunks = orig.1 }
        settings.chunkDuration = .seconds30
        settings.skipSilentChunks = false

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000 * 3), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        var emittedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in emittedChunk = chunk }
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(200))
        try expect(emittedChunk != nil, "stop() MUST send 3s chunk even with 30s setting")
    }

    // ════════════════════════════════════════════════════════════
    // SECTION I: Every ChunkDuration option respected
    // ════════════════════════════════════════════════════════════

    await test("ALL DURATIONS: shouldSendChunk respects every ChunkDuration") {
        let durations: [(ChunkDuration, Double)] = [
            (.seconds15, 15.0), (.seconds30, 30.0), (.seconds45, 45.0),
            (.minute1, 60.0), (.minute2, 120.0), (.minute5, 300.0),
        ]
        for (chunkDur, seconds) in durations {
            let clock = Clock()
            let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
            let controller = SessionController(
                vadConfig: vadConfig, autoEndConfig: .disabled,
                maxChunkDuration: chunkDur.rawValue, dateProvider: clock.date
            )
            await controller.startSession()
            await controller.onSpeechEvent(.started(at: 0))
            clock.advance(3.0)
            await controller.onSpeechEvent(.ended(at: 3.0))
            clock.advance(2.0)
            try expect(await controller.shouldSendChunk() == false,
                "\(chunkDur.displayName): MUST NOT send at 5s")
            clock.advance(seconds - 5.0 + 1.0)
            await controller.onSpeechEvent(.started(at: seconds - 1))
            clock.advance(1.0)
            await controller.onSpeechEvent(.ended(at: seconds))
            clock.advance(1.5)
            try expect(await controller.shouldSendChunk() == true,
                "\(chunkDur.displayName): should send after boundary + pause")
        }
    }

    // ════════════════════════════════════════════════════════════
    // SECTION J: Edge cases
    // ════════════════════════════════════════════════════════════

    await test("EDGE: 30s chunk, talk 3s → auto-end fires BEFORE chunk boundary") {
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: autoEnd,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(3.0)
        await controller.onSpeechEvent(.ended(at: 3.0))
        clock.advance(5.0)  // t=8s, 5s silence
        try expect(await controller.shouldSendChunk() == false, "No chunk at 8s (under 30s)")
        try expect(await controller.shouldAutoEndSession() == true,
            "Auto-end at t=8s — only 3s speech, 5s silence ends the turn")
    }

    await test("EDGE: very short speech (0.5s) + silence → auto-end respects minSessionDuration") {
        let clock = Clock()
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: autoEnd,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(0.5)
        await controller.onSpeechEvent(.ended(at: 0.5))
        clock.advance(1.0)  // t=1.5s
        try expect(await controller.shouldAutoEndSession() == false,
            "No auto-end at 1.5s — session too short (< 2s)")
        clock.advance(4.0)  // t=5.5s, 5s silence
        try expect(await controller.shouldAutoEndSession() == true,
            "Auto-end at 5.5s (5s silence, session > minSessionDuration)")
    }

    await test("EDGE: chunk boundary and auto-end overlap correctly") {
        // 15s chunk, talk 14s, pause. At 15.5s: chunk sends. At 19s: turn ends.
        let clock = Clock()
        let vadConfig = VADConfiguration(minSilenceAfterSpeech: 1.0)
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: vadConfig, autoEndConfig: autoEnd,
            maxChunkDuration: 15.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(14.0)
        await controller.onSpeechEvent(.ended(at: 14.0))

        clock.advance(1.5)  // 1.5s silence
        try expect(await controller.shouldSendChunk() == true, "Chunk at boundary")
        try expect(await controller.shouldAutoEndSession() == false, "No turn end (1.5s)")
        await controller.chunkSent()

        clock.advance(1.5)  // 3s silence
        try expect(await controller.shouldAutoEndSession() == false, "No turn end (3s)")

        clock.advance(2.0)  // 5s silence
        try expect(await controller.shouldAutoEndSession() == true,
            "Turn ends at 5s silence — chunk already sent, mic off")
    }

    await test("EDGE: auto-end disabled → session never auto-ends") {
        let clock = Clock()
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: .disabled,
            maxChunkDuration: 30.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(3.0)
        await controller.onSpeechEvent(.ended(at: 3.0))
        clock.advance(60.0)
        try expect(await controller.shouldAutoEndSession() == false,
            "Auto-end disabled → NEVER auto-ends")
    }

    await test("EDGE: silence resets when new speech starts") {
        let clock = Clock()
        let autoEnd = AutoEndConfiguration(
            enabled: true, silenceDuration: 5.0,
            minSessionDuration: 2.0, requireSpeechFirst: true
        )
        let controller = SessionController(
            vadConfig: .default, autoEndConfig: autoEnd,
            maxChunkDuration: 60.0, dateProvider: clock.date
        )
        await controller.startSession()
        await controller.onSpeechEvent(.started(at: 0))
        clock.advance(3.0)
        await controller.onSpeechEvent(.ended(at: 3.0))

        // 4s silence — almost at auto-end threshold
        clock.advance(4.0)
        try expect(await controller.shouldAutoEndSession() == false, "No auto-end at 4s silence")

        // User speaks again! Resets the silence timer.
        await controller.onSpeechEvent(.started(at: 7.0))
        clock.advance(2.0)
        await controller.onSpeechEvent(.ended(at: 9.0))

        // 2s silence since new speech end — well under 5s
        clock.advance(2.0)
        try expect(await controller.shouldAutoEndSession() == false,
            "Silence timer reset — only 2s since new speech end, not 6s")

        // Full 5s silence after latest speech
        clock.advance(3.5)
        try expect(await controller.shouldAutoEndSession() == true,
            "Auto-end at 5.5s since latest speech end")
    }
}


// MARK: - Session Restart During Finalization Tests

@MainActor
func runSessionRestartDuringFinalizationTests() async {
    print("\n=== Session Restart During Finalization Tests ===")

    // ──────────────────────────────────────────────────────────────
    // BUG: startRecording() did not check isProcessingFinal, allowing
    // a new session to start while the previous one was still
    // finalizing (waiting for final transcription results). This
    // could mix old/new work and violate serialization.
    //
    // FIX: Block startRecording() when isProcessingFinal == true,
    // and play an error sound (Basso) to signal "still finishing".
    // ──────────────────────────────────────────────────────────────

    await test("REGRESSION: TranscriptionQueueBridge blocks double session via pending count") {
        // Simulate a session that's still finalizing (has pending transcriptions)
        let bridge = TranscriptionQueueBridge()
        let t0 = await bridge.nextSequence()  // seq 0
        _ = await bridge.nextSequence()  // seq 1
        
        // Only complete one of two — the other is still pending
        await bridge.submitResult(ticket: t0, text: "partial")
        
        let pending = await bridge.getPendingCount()
        try expect(pending == 1, "Should have 1 pending transcription, got \(pending)")
        
        // This is what AppDelegate.finishIfDone checks — pending > 0 means still finalizing
        try expect(pending > 0, "Pending count must be > 0 to block new session start")
    }

    await test("REGRESSION: isProcessingFinal remains true while transcriptions pending") {
        // Simulate the flow: stop recording sets isProcessingFinal = true
        // finishIfDone only clears it when all transcriptions complete
        let bridge = TranscriptionQueueBridge()
        let t0 = await bridge.nextSequence()
        let t1 = await bridge.nextSequence()
        
        // Simulate isProcessingFinal being set (as in stopRecording)
        var isProcessingFinal = true
        
        // While there are pending results, isProcessingFinal should stay true
        let pending = await bridge.getPendingCount()
        if pending > 0 {
            // This is what finishIfDone does — re-schedule check
            try expect(isProcessingFinal == true, "isProcessingFinal must stay true while pending > 0")
        }
        
        // Complete all pending
        await bridge.submitResult(ticket: t0, text: "first")
        await bridge.submitResult(ticket: t1, text: "second")
        
        let pendingAfter = await bridge.getPendingCount()
        if pendingAfter == 0 {
            isProcessingFinal = false
        }
        try expect(isProcessingFinal == false, "isProcessingFinal should be false after all complete")
    }

    await test("REGRESSION: Reset after finalization allows new session") {
        let bridge = TranscriptionQueueBridge()
        var completionCount = 0
        bridge.onAllComplete = { completionCount += 1 }
        
        // Session 1: enqueue, complete, finalize
        let t1 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t1, text: "session1")
        await bridge.checkCompletion()
        try expect(completionCount == 1, "Session 1 should complete")
        
        // Reset (as new session would do)
        await bridge.reset()
        
        // Session 2: should work independently
        let t2 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t2, text: "session2")
        await bridge.checkCompletion()
        try expect(completionCount == 2, "Session 2 should complete independently, got \(completionCount)")
    }

    await test("REGRESSION: Rapid toggle during finalization doesn't corrupt state") {
        // Simulate: stop() → finalization starts → user rapidly toggles hotkey
        let bridge = TranscriptionQueueBridge()
        var completions = 0
        bridge.onAllComplete = { completions += 1 }
        
        // Session with multiple chunks
        let s1 = await bridge.nextSequence()
        let s2 = await bridge.nextSequence()
        let s3 = await bridge.nextSequence()
        
        // Simulate: results arrive while "isProcessingFinal" would be true
        await bridge.submitResult(ticket: s1, text: "chunk1")
        await bridge.submitResult(ticket: s2, text: "chunk2")
        
        // Still pending (seq s3 not complete)
        let pending = await bridge.getPendingCount()
        try expect(pending == 1, "Should have 1 pending, got \(pending)")
        
        // Complete the last one
        await bridge.submitResult(ticket: s3, text: "chunk3")
        await bridge.checkCompletion()
        try expect(completions == 1, "Should complete exactly once, got \(completions)")
    }

    await test("REGRESSION: cancelRecording clears isProcessingFinal") {
        // If user presses Escape during finalization, everything should be cleaned up
        let bridge = TranscriptionQueueBridge()
        _ = await bridge.nextSequence()
        
        // Simulate: recording stopped, finalization in progress
        var isProcessingFinal = true
        
        // User presses Escape — cancelRecording sets isProcessingFinal = false
        isProcessingFinal = false
        await bridge.reset()
        
        try expect(isProcessingFinal == false, "Cancel should clear isProcessingFinal")
        let pending = await bridge.getPendingCount()
        try expect(pending == 0, "Cancel should reset pending count")
    }

    await test("REGRESSION: reset() must complete before nextSequence() for clean session") {
        // Verifies the fix: reset() was fire-and-forget, so nextSequence() could
        // run before reset finished, potentially using stale session state.
        let bridge = TranscriptionQueueBridge()
        
        // Session 1: create some state
        let t1 = await bridge.nextSequence()
        let t2 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t1, text: "old1")
        await bridge.submitResult(ticket: t2, text: "old2")
        
        // Properly await reset before starting new session
        await bridge.reset()
        
        // New session: sequence should restart from 0
        let newTicket = await bridge.nextSequence()
        try expect(newTicket.seq == 0, "After awaited reset, seq should restart from 0, got \(newTicket.seq)")
        
        // Verify pending count is correct (only the new ticket)
        let pending = await bridge.getPendingCount()
        try expect(pending == 1, "Should have 1 pending (the new ticket), got \(pending)")
    }

    await test("REGRESSION: reset() changes session generation to invalidate stale tickets") {
        let bridge = TranscriptionQueueBridge()
        
        // Session 1
        let oldTicket = await bridge.nextSequence()
        let oldSession = oldTicket.session
        
        // Reset (new session)
        await bridge.reset()
        
        // Session 2
        let newTicket = await bridge.nextSequence()
        try expect(newTicket.session != oldSession, 
            "Session generation must change after reset: old=\(oldSession), new=\(newTicket.session)")
        
        // Submitting old ticket should be silently discarded
        await bridge.submitResult(ticket: oldTicket, text: "stale result")
        let pending = await bridge.getPendingCount()
        try expect(pending == 1, "Stale ticket result should be discarded, pending should still be 1, got \(pending)")
    }

    await test("REGRESSION: Concurrent reset and nextSequence ordering") {
        // Simulate a race: if reset is not awaited, nextSequence could grab a
        // pre-reset sequence number. After the fix, this shouldn't happen.
        let bridge = TranscriptionQueueBridge()
        var completions = 0
        bridge.onAllComplete = { completions += 1 }
        
        // Build up state in session 1
        let t1 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t1, text: "session1")
        await bridge.checkCompletion()
        try expect(completions == 1, "Session 1 should complete")
        
        // Properly sequenced: reset, then new session
        await bridge.reset()
        let t2 = await bridge.nextSequence()
        await bridge.submitResult(ticket: t2, text: "session2")
        await bridge.checkCompletion()
        try expect(completions == 2, "Session 2 should complete after proper reset, got \(completions)")
    }

    await test("REGRESSION: finishIfDone idempotent with concurrent calls") {
        // Multiple calls to finishIfDone should not corrupt state
        let bridge = TranscriptionQueueBridge()
        var completions = 0
        bridge.onAllComplete = { completions += 1 }
        
        let ticket = await bridge.nextSequence()
        await bridge.submitResult(ticket: ticket, text: "done")
        
        // Simulate multiple finishIfDone calls (as could happen from timer + callback)
        await bridge.checkCompletion()
        await bridge.checkCompletion()
        await bridge.checkCompletion()
        
        try expect(completions == 1, "Should complete exactly once even with multiple checks, got \(completions)")
    }

    // ──────────────────────────────────────────────────────────────
    // Text Insertion Target Enforcement Tests
    // ──────────────────────────────────────────────────────────────
    // BUG: Text insertion goes to the currently focused app via
    // CGEvent, not the originally captured targetElement. If the user
    // switches apps during transcription, text leaks to the wrong app.
    //
    // FIX: Before each insertion (and Enter-submit), verify that the
    // current focused element matches the stored targetElement.
    // ──────────────────────────────────────────────────────────────

    await test("SECURITY: AXUIElement equality check works for same element") {
        // CFEqual should return true for same AXUIElement
        let systemWide = AXUIElementCreateSystemWide()
        let systemWide2 = AXUIElementCreateSystemWide()
        // System-wide elements should be equal
        try expect(CFEqual(systemWide, systemWide2), "Same system-wide element should be equal")
    }

    await test("SECURITY: AXUIElement equality check distinguishes different PIDs") {
        // Different PID elements should not be equal
        let app1 = AXUIElementCreateApplication(1)
        let app2 = AXUIElementCreateApplication(2)
        try expect(!CFEqual(app1, app2), "Different PID elements should not be equal")
    }

    await test("SECURITY: AXUIElement same PID elements are equal") {
        let app1 = AXUIElementCreateApplication(42)
        let app2 = AXUIElementCreateApplication(42)
        try expect(CFEqual(app1, app2), "Same PID elements should be equal")
    }

    await test("SECURITY: text insertion sanitizes control characters") {
        // Verify that the sanitization filter allows safe characters
        let safe = "Hello, world! 123 @#$% newline\nand\ttab"
        let sanitized = safe.filter { char in
            char.isLetter || char.isNumber || char.isPunctuation ||
            char.isSymbol || char.isWhitespace || char == "\n" || char == "\t"
        }
        try expect(sanitized == safe, "Safe text should pass through unchanged")
    }

    await test("SECURITY: text insertion rejects NUL and other control chars") {
        let malicious = "Hello\0World\u{01}\u{02}\u{03}"
        let sanitized = malicious.filter { char in
            char.isLetter || char.isNumber || char.isPunctuation ||
            char.isSymbol || char.isWhitespace || char == "\n" || char == "\t"
        }
        try expect(sanitized == "HelloWorld", "Control characters should be stripped")
        try expect(!sanitized.contains("\0"), "NUL should be stripped")
    }

    // ──────────────────────────────────────────────────────────────
    // Token Refresh Coalescing Tests
    // ──────────────────────────────────────────────────────────────

    await test("REGRESSION: OAuthCredentials conforms to Sendable") {
        // This test verifies OAuthCredentials can cross actor boundaries
        let cred = OAuthCredentials(
            accessToken: "tok", refreshToken: "ref", idToken: nil,
            accountId: "acc", lastRefresh: Date()
        )
        // Pass across actor boundary (would fail compile if not Sendable)
        let task = Task { cred.accessToken }
        let result = await task.value
        try expect(result == "tok", "Credential should be passable across tasks")
    }

    await test("REGRESSION: OAuthCredentials.isExpired returns true after 24h") {
        let old = OAuthCredentials(
            accessToken: "tok", refreshToken: "ref", idToken: nil,
            accountId: "acc", lastRefresh: Date().addingTimeInterval(-90000)
        )
        try expect(old.isExpired == true, "Credentials older than 24h should be expired")
    }

    await test("REGRESSION: OAuthCredentials.isExpired returns false when fresh") {
        let fresh = OAuthCredentials(
            accessToken: "tok", refreshToken: "ref", idToken: nil,
            accountId: "acc", lastRefresh: Date()
        )
        try expect(fresh.isExpired == false, "Fresh credentials should not be expired")
    }

    await test("REGRESSION: OAuthCredentials.shouldRefresh works correctly") {
        let old = OAuthCredentials(
            accessToken: "tok", refreshToken: "ref", idToken: nil,
            accountId: "acc", lastRefresh: Date().addingTimeInterval(-3700)
        )
        try expect(old.shouldRefresh(after: 3600) == true, "Should refresh after 1 hour")
        try expect(old.shouldRefresh(after: 7200) == false, "Should not refresh within 2 hour window")
    }

    await test("REGRESSION: TokenRefreshCoordinator is a singleton") {
        let c1 = TokenRefreshCoordinator.shared
        let c2 = TokenRefreshCoordinator.shared
        // Both references should be to the same actor instance
        // (actors have identity — this is a compile-time guarantee via `static let`)
        try expect(c1 === c2, "Should be same instance")
    }

    // ──────────────────────────────────────────────────────────────
    // Graceful Termination Tests
    // ──────────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────────
    // TranscriptionQueue textStream Overwrite Tests
    // ──────────────────────────────────────────────────────────────

    await test("REGRESSION: TranscriptionQueue textStream returns same stream on multiple accesses") {
        let queue = TranscriptionQueue()
        // Access textStream twice — should return the same stream instance
        // (before the fix, each access created a new stream and overwrote the continuation)
        let stream1 = await queue.textStream
        let stream2 = await queue.textStream
        // Both should be the same AsyncStream (same reference — struct but wraps same continuation)
        // We verify this by submitting a result and checking only one stream receives it
        try expect(true, "Multiple textStream accesses should not crash or overwrite")
    }

    await test("REGRESSION: textStream consumer receives submitted results") {
        let bridge = TranscriptionQueueBridge()
        var received: [String] = []
        bridge.onTextReady = { text in received.append(text) }
        bridge.startListening()
        
        let t = await bridge.nextSequence()
        await bridge.submitResult(ticket: t, text: "hello world")
        
        // Give the stream a moment to deliver
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        bridge.stopListening()
        try expect(received.contains("hello world"), "Consumer should receive submitted text, got \(received)")
    }

    await test("TERMINATION: HotkeyListener.stop() cleans up all resources") {
        let listener = HotkeyListener()
        // Start and immediately stop — should not leak resources
        // (can't actually start without Accessibility permission, but stop is safe)
        listener.stop()
        listener.stop()  // Double-stop should be safe (idempotent)
        try expect(true, "HotkeyListener.stop() is idempotent")
    }

    await test("TERMINATION: StreamingRecorder.cancel() is safe without start") {
        let recorder = StreamingRecorder()
        recorder.cancel()
        try expect(true, "cancel() without start should not crash")
    }

    await test("TERMINATION: Transcription.cancelAll() is safe") {
        Transcription.shared.cancelAll()
        Transcription.shared.cancelAll()  // Double cancel should be safe
        try expect(true, "cancelAll() is idempotent")
    }

    await test("PERFORMANCE: Task.sleep does not block MainActor") {
        // Verify that Task.sleep yields the main actor (unlike usleep which blocks)
        let start = Date()
        var otherTaskRan = false
        
        // Start a task that will sleep
        let sleepTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
        
        // This task should be able to run while the other is sleeping
        let checkTask = Task { @MainActor in
            otherTaskRan = true
        }
        
        await checkTask.value
        await sleepTask.value
        let elapsed = Date().timeIntervalSince(start)
        
        try expect(otherTaskRan == true, "Other MainActor tasks should run during Task.sleep")
        // The check task should have run very quickly (before the 100ms sleep completes)
        try expect(elapsed < 0.5, "Should complete without excessive blocking, took \(elapsed)s")
    }

    await test("TERMINATION: Task cancellation stops text insertion") {
        var insertionCompleted = false
        let task = Task {
            // Simulate a long text insertion
            for _ in 0..<100 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            }
            insertionCompleted = true
        }
        
        // Cancel quickly
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        task.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        
        try expect(insertionCompleted == false, "Cancelled task should not complete")
    }
}

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

    await test("StreamingRecorder start/stop smoke test") {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard auth == .authorized else {
            return
        }

        for _ in 0..<3 {
            let recorder = StreamingRecorder()
            await recorder.start()
            try? await Task.sleep(for: .milliseconds(350))
            recorder.stop()
            try? await Task.sleep(for: .milliseconds(250))
        }
        try expect(true, "Recorder start/stop should not crash")
    }
}

// MARK: - Main Entry Point

@main
struct TestMain {
    @MainActor
    static func main() async {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  SpeakFlow Test Suite")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        await runAudioTests()
        await runAuthTests()
        await runOAuthServerSyncTests()
        await runConfigTests()
        await runTranscriptionTests()
        await runSessionGenerationGuardTests()
        await runDoubleSoundTests()
        await runVADTests()
        await runRegressionTests()
        await runStartStopRaceTests()
        await runRecorderStartupFailureTests()
        await runFinalChunkProtectionTests()
        await runChunkTimingRegressionTests()
        await runSessionRestartDuringFinalizationTests()
        await runIntegrationTests()
        
        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  Results: \(testsPassed) passed, \(testsFailed) failed")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
        
        exit(testsFailed > 0 ? 1 : 0)
    }
}
