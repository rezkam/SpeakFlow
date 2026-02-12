import AVFoundation
import Foundation
import os
import Testing
@testable import SpeakFlowCore

// MARK: - AudioBuffer Tests

@Suite("AudioBuffer Tests")
struct AudioBufferTests {
    @Test func testTakeAllDrainsBuffer() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        let frames = [Float](repeating: 0.5, count: 16000) // 1s of audio
        await buffer.append(frames: frames, hasSpeech: true)

        let duration = await buffer.duration
        #expect(duration > 0.9 && duration < 1.1)

        let result = await buffer.takeAll()
        #expect(result.samples.count == 16000)
        #expect(result.speechRatio > 0.9)

        let afterDuration = await buffer.duration
        #expect(afterDuration == 0)
    }

    @Test func testSpeechRatioAvailableWithoutDrain() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        let speechFrames = [Float](repeating: 0.5, count: 8000)
        let silentFrames = [Float](repeating: 0.001, count: 8000)
        await buffer.append(frames: speechFrames, hasSpeech: true)
        await buffer.append(frames: silentFrames, hasSpeech: false)

        // speechRatio is accessible without takeAll
        let ratio = await buffer.speechRatio
        #expect(ratio > 0.4 && ratio < 0.6, "Expected ~0.5, got \(ratio)")

        // Buffer is still intact
        let duration = await buffer.duration
        #expect(duration == 1.0, "Buffer should not be drained by reading speechRatio")
    }
}

// MARK: - Chunk Skip Regression Tests (First Chunk Lost Bug)
//
// These tests guard against the "first chunk lost on long speech" bug:
//
// BUG: sendChunkIfReady() called buffer.takeAll() (permanently draining all audio)
// BEFORE checking skipSilentChunks. When an intermediate chunk's average VAD
// probability dropped below 0.30 (common with mixed speech + pauses in a 15s chunk),
// the audio was silently discarded — never sent to the API.
//
// The final chunk from stop() had protection (speechDetectedInSession bypass) but
// intermediate chunks did not.
//
// EVIDENCE: In production logs, a ~30s recording session produced 2 intermediate chunks
// + 1 final chunk, but only the final chunk's API call appeared. Task 10 sent 451KB
// (14s of audio = the final chunk) while intermediate chunks vanished.
//
// FIX: (1) Check skip BEFORE buffer.takeAll(), (2) add speechDetectedInSession bypass
// to intermediate chunks matching the final chunk's existing protection.

@Suite("Chunk Skip Regression Tests — Behavioral", .serialized)
struct ChunkSkipBehavioralRegressionTests {

    // Helper: create a buffer with 15 seconds of audio (mixed speech + silence)
    private func makeBufferWith15sAudio(speechRatio: Float = 0.5) async -> SpeakFlowCore.AudioBuffer {
        let sampleRate: Double = 16000
        let buffer = SpeakFlowCore.AudioBuffer(sampleRate: sampleRate)

        // Fill buffer to 15 seconds
        let totalFrames = Int(15.0 * sampleRate)
        let speechFrames = Int(Float(totalFrames) * speechRatio)
        let silentFrames = totalFrames - speechFrames

        if speechFrames > 0 {
            let speech = [Float](repeating: 0.5, count: speechFrames)
            await buffer.append(frames: speech, hasSpeech: true)
        }
        if silentFrames > 0 {
            let silence = [Float](repeating: 0.001, count: silentFrames)
            await buffer.append(frames: silence, hasSpeech: false)
        }

        return buffer
    }

    /// Helper: configure Settings, inject dependencies, invoke sendChunkIfReady, restore.
    /// Everything runs inside a single Task @MainActor block to keep settings, recorder,
    /// and the async sendChunkIfReady call in one atomic unit.
    @MainActor
    private func runSendChunkTest(
        chunkDuration: ChunkDuration = .seconds15,
        skipSilentChunks: Bool = true,
        buffer: SpeakFlowCore.AudioBuffer,
        session: SessionController?,
        vad: VADProcessor?,
        vadActive: Bool = true,
        reason: String
    ) async -> (chunks: [AudioChunk], remainingDuration: Double) {
        let origChunkDuration = Settings.shared.chunkDuration
        let origSkipSilent = Settings.shared.skipSilentChunks
        defer {
            Settings.shared.chunkDuration = origChunkDuration
            Settings.shared.skipSilentChunks = origSkipSilent
        }

        Settings.shared.chunkDuration = chunkDuration
        Settings.shared.skipSilentChunks = skipSilentChunks

        let rec = StreamingRecorder()
        rec._testInjectAudioBuffer(buffer)
        if let session { rec._testInjectSessionController(session) }
        if let vad { rec._testInjectVADProcessor(vad) }
        rec._testSetVADActive(vadActive)
        rec._testSetIsRecording(true)

        var collected: [AudioChunk] = []
        rec.onChunkReady = { chunk in
            collected.append(chunk)
        }

        await rec._testInvokeSendChunkIfReady(reason: reason)

        let remaining = await rec._testAudioBufferDuration()

        return (chunks: collected, remainingDuration: remaining)
    }

    /// CORE REGRESSION: When skipSilentChunks=true, VAD active, low speech probability,
    /// and speech WAS detected in session → chunk MUST be sent (bypass skip).
    /// This is the exact scenario from the production bug.
    @Test func testChunkSentWhenSpeechDetectedInSession() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.5)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 1.0))
        #expect(await session.hasSpoken, "Session should have recorded speech")

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.20, chunks: 10) // Below threshold

        let result = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: speech detected bypass"
        )

        #expect(result.chunks.count == 1,
                "Chunk MUST be sent when speech was detected in session, even with low VAD probability")
        if let chunk = result.chunks.first {
            #expect(chunk.durationSeconds > 14.0 && chunk.durationSeconds < 16.0,
                    "Chunk should contain ~15s of audio, got \(chunk.durationSeconds)s")
        }
        #expect(result.remainingDuration == 0, "Buffer should be drained after successful send")
    }

    /// When skipSilentChunks=true, VAD active, low probability, and NO speech detected →
    /// the chunk should be skipped AND the buffer should NOT be drained.
    @Test func testSkippedChunkPreservesBufferWhenNoSpeechDetected() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.0)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        #expect(await session.hasSpoken == false, "Sanity: no speech should be recorded for this session")

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.12, chunks: 10) // Below threshold

        let result = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: no speech detected skip"
        )

        #expect(result.chunks.isEmpty, "Chunk should be skipped when no speech has been detected in the session")
        #expect(result.remainingDuration > 14.0, "Skipped chunk must preserve buffered audio")
    }

    /// When skipSilentChunks=false, chunks are always sent regardless of probability.
    @Test func testChunkSentWhenSkipSilentChunksDisabled() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.0)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.05, chunks: 10)

        let result = await runSendChunkTest(
            skipSilentChunks: false,
            buffer: buffer, session: session, vad: vad,
            reason: "test: skip disabled"
        )

        #expect(result.chunks.count == 1,
                "With skipSilentChunks=false, all chunks must be sent")
    }

    /// Simulate the exact production bug scenario: 2 intermediate chunks with mixed speech,
    /// both have VAD probability < 0.30. With the fix, both must be sent.
    @Test func testTwoIntermediateChunksWithMixedSpeechBothSent() async {
        let sampleRate: Double = 16000

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 1.0))

        // --- Chunk 1: 15s with 27% speech probability (below 0.30 threshold) ---
        let buffer1 = AudioBuffer(sampleRate: sampleRate)
        await buffer1.append(frames: [Float](repeating: 0.5, count: Int(8.0 * sampleRate)), hasSpeech: true)
        await buffer1.append(frames: [Float](repeating: 0.001, count: Int(7.0 * sampleRate)), hasSpeech: false)

        let vad1 = VADProcessor(config: .default)
        await vad1._testSeedAverageSpeechProbability(0.27, chunks: 10) // Below threshold

        let result1 = await runSendChunkTest(
            buffer: buffer1, session: session, vad: vad1,
            reason: "test: chunk 1"
        )
        #expect(result1.chunks.count == 1,
                "First intermediate chunk must be sent (speech detected in session)")

        // --- Chunk 2: new 15s buffer, also below threshold ---
        let buffer2 = AudioBuffer(sampleRate: sampleRate)
        await buffer2.append(frames: [Float](repeating: 0.5, count: Int(6.0 * sampleRate)), hasSpeech: true)
        await buffer2.append(frames: [Float](repeating: 0.001, count: Int(9.0 * sampleRate)), hasSpeech: false)

        let vad2 = VADProcessor(config: .default)
        await vad2._testSeedAverageSpeechProbability(0.22, chunks: 10) // Even lower!

        let result2 = await runSendChunkTest(
            buffer: buffer2, session: session, vad: vad2,
            reason: "test: chunk 2"
        )
        #expect(result2.chunks.count == 1,
                "Second intermediate chunk must also be sent (speech detected in session)")

        // Both chunks have real audio
        let allChunks = result1.chunks + result2.chunks
        for (i, chunk) in allChunks.enumerated() {
            #expect(chunk.durationSeconds > 14.0,
                    "Chunk \(i) must contain ~15s of audio, got \(chunk.durationSeconds)s")
            #expect(chunk.wavData.count > 400_000,
                    "Chunk \(i) must have substantial WAV data, got \(chunk.wavData.count) bytes")
        }
    }

    /// VAD resetChunk must NOT be called when a chunk is skipped.
    /// Otherwise the accumulator resets and the next check has no speech history.
    /// After a skipped chunk, the VAD chunk accumulator MUST be reset so stale
    /// silent samples don't accumulate across skips (memory bloat + skewed probability).
    @Test func testVADAccumulatorResetOnSkip() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.0)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.15, chunks: 10)
        let probBefore = await vad.averageSpeechProbability
        #expect(probBefore > 0, "Sanity: seeded probability must be nonzero")

        let _ = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: skip resets VAD accumulator"
        )

        let probAfter = await vad.averageSpeechProbability
        #expect(probAfter == 0,
                "VAD accumulator must be reset on skip to prevent stale sample accumulation (was \(probBefore), now \(probAfter))")
    }

    /// Chunk too short → returns false immediately, no drain, no skip check.
    @Test func testShortBufferReturnsEarlyWithoutDrain() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 80_000), hasSpeech: true)

        let noSession: SessionController? = nil
        let noVAD: VADProcessor? = nil
        let result = await runSendChunkTest(
            buffer: buffer, session: noSession, vad: noVAD, vadActive: false,
            reason: "test: too short"
        )

        #expect(result.chunks.isEmpty, "Short buffer should not produce a chunk")
        #expect(result.remainingDuration > 4.9, "Short buffer must not be drained")
    }

    /// When VAD is inactive, chunks are always sent (no energy-based skip fallback).
    @Test func testNoVADAlwaysSendsChunk() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        // 15s of pure silence → speechRatio = 0.0
        await buffer.append(
            frames: [Float](repeating: 0.001, count: Int(15.0 * 16000)),
            hasSpeech: false
        )

        let noSession: SessionController? = nil
        let noVAD: VADProcessor? = nil
        let result = await runSendChunkTest(
            buffer: buffer, session: noSession, vad: noVAD, vadActive: false,
            reason: "test: no VAD always sends"
        )

        #expect(result.chunks.count == 1,
                "Without VAD, chunks must always be sent (no energy-based skip)")
        #expect(result.remainingDuration == 0,
                "Buffer must be drained when chunk is sent")
    }

    /// When VAD probability is ABOVE threshold, chunk is sent normally (no bypass needed).
    @Test func testChunkSentWhenProbabilityAboveThreshold() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.8)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        await session.onSpeechEvent(.started(at: 0))
        await session.onSpeechEvent(.ended(at: 1.0))

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(0.55, chunks: 10) // Above threshold

        let result = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: high probability"
        )

        #expect(result.chunks.count == 1,
                "Chunk with high speech probability must always be sent")
        #expect(result.remainingDuration == 0, "Buffer should be fully drained")
    }

    /// Boundary: probability exactly at threshold (0.30) should NOT trigger skip.
    @Test func testChunkAtExactThresholdIsNotSkipped() async {
        let buffer = await makeBufferWith15sAudio(speechRatio: 0.5)

        let session = SessionController(vadConfig: .default, autoEndConfig: .default, maxChunkDuration: 15.0)
        await session.startSession()
        // No speech events — but probability is at threshold

        let vad = VADProcessor(config: .default)
        await vad._testSeedAverageSpeechProbability(Config.minVADSpeechProbability, chunks: 10) // Exactly at threshold

        let result = await runSendChunkTest(
            buffer: buffer, session: session, vad: vad,
            reason: "test: exact threshold"
        )

        // speechProbability (0.30) is NOT < skipThreshold (0.30), so skip doesn't trigger
        #expect(result.chunks.count == 1,
                "Chunk at exact threshold boundary must NOT be skipped")
    }
}

// MARK: - Issue #9: AVAudioConverter input provider always returns .haveData

@Suite("Issue #9 — AVAudioConverter one-shot input block")
struct Issue9AudioConverterOneShotRegressionTests {

    /// REGRESSION: createOneShotInputBlock must return .haveData on first call
    /// and .noDataNow on second call. The original bug always returned .haveData,
    /// causing audio data to be doubled during sample rate conversion edge cases.
    @Test func testOneShotBlockReturnsNoDataNowOnSecondCall() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100

        let block = createOneShotInputBlock(buffer: buffer)

        // First call: should return the buffer with .haveData
        var status1 = AVAudioConverterInputStatus.noDataNow
        let result1 = block(100, &status1)
        #expect(status1 == .haveData, "First call must return .haveData")
        #expect(result1 === buffer, "First call must return the original buffer")

        // Second call: must return nil with .noDataNow
        var status2 = AVAudioConverterInputStatus.haveData
        let result2 = block(100, &status2)
        #expect(status2 == .noDataNow, "Second call must return .noDataNow — was always .haveData")
        #expect(result2 == nil, "Second call must return nil — was returning buffer again")
    }

    /// REGRESSION: Third and subsequent calls also return .noDataNow (not just second).
    @Test func testOneShotBlockStaysNoDataAfterSecondCall() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 50)!
        buffer.frameLength = 50

        let block = createOneShotInputBlock(buffer: buffer)

        // Consume the one-shot
        var status = AVAudioConverterInputStatus.noDataNow
        _ = block(50, &status)
        #expect(status == .haveData)

        // Subsequent calls: all .noDataNow
        for i in 2...5 {
            _ = block(50, &status)
            #expect(status == .noDataNow, "Call #\(i) must return .noDataNow")
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: WAV Format & AudioChunk Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — WAV Format & AudioChunk")
struct StreamingRecorderWAVFormatAndAudioChunkTests {

    /// Verify AudioChunk struct stores all properties correctly.
    @Test func testAudioChunkStructProperties() {
        let chunk = AudioChunk(wavData: Data([1,2,3]), durationSeconds: 5.0, speechProbability: 0.75)
        #expect(chunk.wavData == Data([1,2,3]))
        #expect(chunk.durationSeconds == 5.0)
        #expect(chunk.speechProbability == 0.75)
    }

    /// Verify AudioChunk default speechProbability is 0.
    @Test func testAudioChunkDefaultSpeechProbability() {
        let chunk = AudioChunk(wavData: Data(), durationSeconds: 1.0)
        #expect(chunk.speechProbability == 0, "Default speechProbability must be 0")
    }

    /// Validate WAV header structure produced by createWav().
    @Test @MainActor func testCreateWavProducesValidHeader() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)

        // 15s of audio with speech
        let samples = [Float](repeating: 0.5, count: 240_000)
        await buffer.append(frames: samples, hasSpeech: true)

        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var receivedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in receivedChunk = chunk }

        await recorder._testInvokeSendChunkIfReady(reason: "test wav")

        guard let chunk = receivedChunk else {
            Issue.record("No chunk produced")
            return
        }

        let wav = chunk.wavData

        // RIFF header
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF",
                "WAV must start with RIFF header")

        // WAVE format
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE",
                "WAV must have WAVE format identifier")

        // fmt chunk
        #expect(String(data: wav[12..<16], encoding: .ascii) == "fmt ",
                "WAV must have fmt chunk")

        // PCM format (1)
        let audioFormat = wav[20..<22].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(audioFormat == 1, "Must be PCM format (1)")

        // Mono (1 channel)
        let channels = wav[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(channels == 1, "Must be mono (1 channel)")

        // Sample rate 16000
        let sampleRate = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 16000, "Sample rate must be 16000 Hz")

        // 16-bit samples
        let bitsPerSample = wav[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(bitsPerSample == 16, "Must be 16-bit PCM")

        // data chunk
        #expect(String(data: wav[36..<40], encoding: .ascii) == "data",
                "WAV must have data chunk")
    }

    /// Verify WAV data section size matches sample count (16-bit = 2 bytes per sample).
    @Test @MainActor func testCreateWavDataSizeMatchesSamples() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)

        let expectedSamples = 240_000  // 15s at 16kHz
        let samples = [Float](repeating: 0.5, count: expectedSamples)
        await buffer.append(frames: samples, hasSpeech: true)

        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var receivedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in receivedChunk = chunk }

        await recorder._testInvokeSendChunkIfReady(reason: "test wav size")

        guard let chunk = receivedChunk else {
            Issue.record("No chunk produced")
            return
        }

        // WAV total = 44 byte header + N*2 bytes data (16-bit = 2 bytes per sample)
        let dataSize = chunk.wavData.count - 44
        #expect(dataSize == expectedSamples * 2,
                "Data section must be exactly \(expectedSamples * 2) bytes for \(expectedSamples) samples, got \(dataSize)")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: Thread-Safe State & Helpers Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — Thread-Safe State & Helpers")
struct StreamingRecorderThreadSafeStateAndHelpersTests {

    /// Behavioral: verify createOneShotInputBlock provides buffer once, then signals noDataNow.
    @Test func testCreateOneShotInputBlockProvidesBufferOnce() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        pcmBuffer.frameLength = 100

        let block = createOneShotInputBlock(buffer: pcmBuffer)

        var status = AVAudioConverterInputStatus.haveData

        // First call: should provide data
        let result1 = block(1, &status)
        #expect(result1 != nil, "First call must provide the buffer")
        #expect(status == .haveData, "First call status must be .haveData")

        // Second call: should signal no more data
        let result2 = block(1, &status)
        #expect(status == .noDataNow, "Second call must signal .noDataNow")
        #expect(result2 == nil, "Second call must return nil")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: start, startMock & Test Helpers
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — start, startMock & Test Helpers")
struct StreamingRecorderStartAndMockTests {

    /// startMock() must set up all required state correctly.
    @Test @MainActor func testStartMockSetsUpCorrectly() async {
        let recorder = StreamingRecorder()
        let testAudio = [Float](repeating: 0.5, count: 16000)
        await recorder.startMock(audioData: testAudio)

        defer { recorder.stop() }

        #expect(recorder._testIsRecording, "startMock must set recording=true")
        #expect(recorder._testHasAudioBuffer, "startMock must create audio buffer")
        #expect(recorder._testHasProcessingTimer, "startMock must start processing timer")
        #expect(recorder._testHasCheckTimer, "startMock must start check timer")
        #expect(recorder.sessionStartDate != nil, "startMock must set sessionStartDate")
    }

    /// Test helper _testInjectAudioBuffer must set/clear audioBuffer.
    @Test @MainActor func testTestHelperInjectAudioBuffer() async {
        let recorder = StreamingRecorder()
        #expect(!recorder._testHasAudioBuffer)

        let buffer = AudioBuffer(sampleRate: 16000)
        recorder._testInjectAudioBuffer(buffer)
        #expect(recorder._testHasAudioBuffer)

        recorder._testInjectAudioBuffer(nil)
        #expect(!recorder._testHasAudioBuffer)
    }

    /// Test helper _testSetIsRecording must control recording state.
    @Test @MainActor func testTestHelperSetRecordingState() async {
        let recorder = StreamingRecorder()
        #expect(!recorder._testIsRecording)
        recorder._testSetIsRecording(true)
        #expect(recorder._testIsRecording)
        recorder._testSetIsRecording(false)
        #expect(!recorder._testIsRecording)
    }

    /// Test helper _testAudioBufferDuration must return correct duration.
    @Test @MainActor func testTestHelperBufferDuration() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        recorder._testInjectAudioBuffer(buffer)

        let dur0 = await recorder._testAudioBufferDuration()
        #expect(dur0 == 0)

        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)
        let dur1 = await recorder._testAudioBufferDuration()
        #expect(dur1 > 0.9 && dur1 < 1.1, "1s of 16kHz audio = ~1.0s duration")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder — stop() & cancel() Behavior
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — stop() & cancel() Behavior", .serialized)
struct StreamingRecorderStopCancelTests {

    /// stop() must set recording flag to false.
    @Test @MainActor func testStopSetsRecordingToFalse() async {
        let recorder = StreamingRecorder()
        recorder._testSetIsRecording(true)
        recorder.stop()
        #expect(!recorder._testIsRecording, "stop() must set recording to false")
    }

    /// cancel() must suppress final chunk emission.
    @Test @MainActor func testCancelSuppressesFinalChunk() async {
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 240_000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var chunkReceived = false
        recorder.onChunkReady = { _ in chunkReceived = true }

        recorder.cancel()

        // Give the stop() Task time to run
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!chunkReceived, "cancel() must suppress final chunk emission")
    }

    /// stop() must emit final chunk when speech is present.
    @Test @MainActor func testStopEmitsFinalChunkWhenSpeechPresent() async {
        // Prepare buffer BEFORE changing settings to avoid await suspension races
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        // 1s of audio (above minRecordingDurationMs=250ms)
        await buffer.append(frames: [Float](repeating: 0.3, count: 16000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var receivedChunk: AudioChunk?
        recorder.onChunkReady = { chunk in receivedChunk = chunk }

        // Set settings with NO await between setting and stop()
        let origSkip = Settings.shared.skipSilentChunks
        let origChunk = Settings.shared.chunkDuration
        defer {
            Settings.shared.skipSilentChunks = origSkip
            Settings.shared.chunkDuration = origChunk
        }
        Settings.shared.skipSilentChunks = false
        Settings.shared.chunkDuration = .minute10

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(receivedChunk != nil, "stop() must emit final chunk when audio has speech")
        if let chunk = receivedChunk {
            #expect(chunk.durationSeconds > 0.9 && chunk.durationSeconds < 1.1)
        }
    }

    /// stop() must skip final chunk when audio is too short.
    @Test @MainActor func testStopSkipsFinalChunkWhenTooShort() async {
        let origChunk = Settings.shared.chunkDuration
        defer { Settings.shared.chunkDuration = origChunk }
        Settings.shared.chunkDuration = .minute10

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        // 100ms of audio — too short
        await buffer.append(frames: [Float](repeating: 0.5, count: 1600), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var chunkReceived = false
        recorder.onChunkReady = { _ in chunkReceived = true }

        recorder.stop()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!chunkReceived, "Audio shorter than minRecordingDurationMs must be discarded")
    }
}

// MARK: - Integration — Recorder to Queue Pipeline

@Suite("Integration — Recorder to Queue Pipeline", .serialized)
struct IntegrationRecorderToQueueTests {

    /// TranscriptionQueue accepts and flushes a result (recorder→queue seam).
    @Test func testRecorderChunkFlowsToQueue() async throws {
        let queue = TranscriptionQueue()

        // Simulate: recorder produces a chunk → gets a ticket → submits result
        let ticket = await queue.nextSequence()
        await queue.submitResult(ticket: ticket, text: "transcribed: 15.0s")

        // submitResult auto-flushes via flushReady()
        let pending = await queue.getPendingCount()
        #expect(pending == 0, "Queue must have flushed the result (0 pending)")
    }

    /// Multiple chunks maintain ordering through the queue (queue-level integration).
    @Test func testMultipleChunksProcessedInOrder() async throws {
        let queue = TranscriptionQueue()

        // Get 3 tickets
        let t0 = await queue.nextSequence()
        let t1 = await queue.nextSequence()
        let t2 = await queue.nextSequence()

        // Submit out of order: t2 first, then t0, then t1
        await queue.submitResult(ticket: t2, text: "chunk-2")
        await queue.submitResult(ticket: t0, text: "chunk-0")

        // At this point, chunk-0 should have flushed, chunk-1 is blocking chunk-2
        let pending1 = await queue.getPendingCount()
        #expect(pending1 == 2, "chunk-1 not yet submitted, so 2 pending (seq 1 and 2)")

        await queue.submitResult(ticket: t1, text: "chunk-1")

        // Now all 3 should have flushed in order
        let pending2 = await queue.getPendingCount()
        #expect(pending2 == 0, "All chunks must be flushed")
    }

    /// The textStream AsyncStream emits flushed results.
    @Test func testQueueTextStreamReceivesResults() async throws {
        let queue = TranscriptionQueue()

        // Consume stream in background
        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let streamTask = Task {
            for await text in await queue.textStream {
                received.withLock { $0.append(text) }
            }
        }

        // Small delay to let stream task start consuming
        try? await Task.sleep(for: .milliseconds(50))

        let ticket = await queue.nextSequence()
        await queue.submitResult(ticket: ticket, text: "hello world")

        // submitResult calls flushReady which yields to textStream
        await queue.finishStream()
        try? await Task.sleep(for: .milliseconds(100))

        streamTask.cancel()
        let values = received.withLock { $0 }
        #expect(values.contains("hello world"), "textStream must emit flushed results")
    }

    /// Buffer stores samples → takeAll returns them correctly.
    @Test func testAudioBufferRoundTrip() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        let original = (0..<16000).map { Float(sin(Double($0) * 2.0 * .pi * 440.0 / 16000.0)) }
        await buffer.append(frames: original, hasSpeech: true)

        let result = await buffer.takeAll()
        #expect(result.samples.count == 16000, "All samples must be returned")
        #expect(result.speechRatio == 1.0, "All frames had speech")

        // Buffer should be empty after takeAll
        let second = await buffer.takeAll()
        #expect(second.samples.isEmpty, "Buffer must be empty after takeAll")
    }

    /// Speech ratio calculated correctly with mixed speech/silence.
    @Test func testAudioBufferSpeechRatioCalculation() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        // 50% speech, 50% silence
        await buffer.append(frames: [Float](repeating: 0.5, count: 8000), hasSpeech: true)
        await buffer.append(frames: [Float](repeating: 0.001, count: 8000), hasSpeech: false)

        let ratio = await buffer.speechRatio
        #expect(ratio == 0.5, "50/50 speech ratio must be exactly 0.5")
    }

    /// Duration calculated correctly from sample count and sample rate.
    @Test func testAudioBufferDurationCalculation() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.0, count: 48000), hasSpeech: false)
        let duration = await buffer.duration
        #expect(abs(duration - 3.0) < 0.001, "48000 samples at 16kHz = 3.0s")
    }

    /// Cancel doesn't corrupt queue state — queue remains usable after recorder cancel.
    @Test func testRecorderCancelDoesNotCorruptQueue() async throws {
        let queue = TranscriptionQueue()

        // Simulate a cancelled recording session: queue gets no submissions
        // but should still be in clean state for next session
        let ticket = await queue.nextSequence()
        #expect(ticket.seq == 0, "First ticket must be seq 0")

        // Simulate: cancel happened, but queue is reused
        await queue.reset()

        // After reset, queue should accept new work
        let newTicket = await queue.nextSequence()
        #expect(newTicket.seq == 0, "After reset, sequence must restart at 0")
        // Session generation should have incremented
        let gen = await queue.currentSessionGeneration()
        #expect(gen == 1, "Reset must increment session generation")

        await queue.submitResult(ticket: newTicket, text: "post-cancel")
        let pending = await queue.getPendingCount()
        #expect(pending == 0, "Queue must accept new results after reset")
    }

    /// Recorder produces chunk with valid WAV data via sendChunkIfReady integration.
    @Test @MainActor func testRecorderChunkContainsValidWAV() async throws {
        // Prepare buffer BEFORE changing settings to avoid await suspension races
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)

        var chunkData: Data?
        recorder.onChunkReady = { c in
            chunkData = c.wavData
        }

        await buffer.append(frames: [Float](repeating: 0.5, count: 240_000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        // Set settings with NO await between setting and sendChunkIfReady
        let origChunk = Settings.shared.chunkDuration
        let origSkip = Settings.shared.skipSilentChunks
        defer {
            Settings.shared.chunkDuration = origChunk
            Settings.shared.skipSilentChunks = origSkip
        }
        Settings.shared.chunkDuration = .seconds15
        Settings.shared.skipSilentChunks = false

        await recorder._testInvokeSendChunkIfReady(reason: "wav integration test")

        guard let wav = chunkData else {
            Issue.record("No chunk produced")
            return
        }

        // Validate WAV header structure
        #expect(wav.count > 44, "WAV must have header + data")
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        let sampleRate: UInt32 = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 16000, "Sample rate must be 16000")
        let channels: UInt16 = wav[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(channels == 1, "Must be mono")
        let bitsPerSample: UInt16 = wav[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(bitsPerSample == 16, "Must be 16-bit PCM")
        // Data section: 240,000 samples * 2 bytes = 480,000 bytes
        let expectedDataSize = 240_000 * 2
        #expect(wav.count == 44 + expectedDataSize, "WAV size must be header + data")
    }

    /// Failed chunk doesn't block subsequent successful chunks in the queue.
    @Test func testFullPipelineWithFailedChunk() async {
        let queue = TranscriptionQueue()

        let t0 = await queue.nextSequence() // will fail
        let t1 = await queue.nextSequence() // will succeed
        let t2 = await queue.nextSequence() // will succeed

        // Collect results via textStream
        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let streamTask = Task {
            for await text in await queue.textStream {
                received.withLock { $0.append(text) }
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        await queue.markFailed(ticket: t0)
        await queue.submitResult(ticket: t1, text: "first")
        await queue.submitResult(ticket: t2, text: "second")

        // Give stream time to receive
        try? await Task.sleep(for: .milliseconds(100))

        await queue.finishStream()
        streamTask.cancel()

        let values = received.withLock { $0 }
        #expect(values == ["first", "second"],
                "Failed chunk must be skipped, subsequent chunks must flush in order")
    }

    /// AudioBuffer reset clears all state.
    @Test func testAudioBufferReset() async {
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16000), hasSpeech: true)

        let durBefore = await buffer.duration
        #expect(durBefore > 0.9)

        await buffer.reset()
        let durAfter = await buffer.duration
        #expect(durAfter == 0, "Reset must clear all samples")
        let ratio = await buffer.speechRatio
        #expect(ratio == 0, "Reset must clear speech ratio")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: sendChunkIfReady & periodicCheck
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — sendChunkIfReady & periodicCheck", .serialized)
struct StreamingRecorderSendChunkIfReadyPeriodicCheckTests {

    @Test @MainActor func testSendChunkIfReadyReturnsFalseWhenBufferTooShort() async {
        let origChunkDuration = Settings.shared.chunkDuration
        defer { Settings.shared.chunkDuration = origChunkDuration }
        Settings.shared.chunkDuration = .seconds15

        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.5, count: 16_000), hasSpeech: true)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var chunkReceived = false
        recorder.onChunkReady = { _ in chunkReceived = true }

        await recorder._testInvokeSendChunkIfReady(reason: "test")

        let remaining = await recorder._testAudioBufferDuration()
        #expect(!chunkReceived, "Chunk shorter than minChunkDuration must be rejected")
        #expect(remaining > 0.9, "Rejected chunk must remain buffered")
    }

    @Test @MainActor func testSendChunkIfReadySendsWhenSkipDisabled() async {
        // Prepare buffer BEFORE changing settings to avoid await suspension points
        // between setting skipSilentChunks and sendChunkIfReady reading it.
        let recorder = StreamingRecorder()
        let buffer = AudioBuffer(sampleRate: 16000)
        await buffer.append(frames: [Float](repeating: 0.001, count: 240_000), hasSpeech: false)
        recorder._testInjectAudioBuffer(buffer)
        recorder._testSetIsRecording(true)

        var chunkReceived = false
        recorder.onChunkReady = { _ in chunkReceived = true }

        // Set settings and invoke sendChunkIfReady with NO await in between —
        // this prevents concurrent @MainActor tasks from changing skipSilentChunks.
        let origSkip = Settings.shared.skipSilentChunks
        let origChunkDuration = Settings.shared.chunkDuration
        defer {
            Settings.shared.skipSilentChunks = origSkip
            Settings.shared.chunkDuration = origChunkDuration
        }
        Settings.shared.skipSilentChunks = false
        Settings.shared.chunkDuration = .seconds15

        await recorder._testInvokeSendChunkIfReady(reason: "test")

        let remaining = await recorder._testAudioBufferDuration()

        #expect(chunkReceived, "With skipSilentChunks=false, silent chunk must still be sent")
        #expect(remaining == 0, "Sent chunk must drain buffer")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LiveStreamingController: Smart Diff Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("LiveStreamingController — Smart Diff")
struct SmartDiffTests {

    // MARK: - diffFromEnd unit tests

    @MainActor @Test func testDiffIdenticalStrings() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "Hello world", new: "Hello world")
        #expect(del == 0)
        #expect(suffix == "")
    }

    @MainActor @Test func testDiffAppendOnly() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "Hello", new: "Hello world")
        #expect(del == 0)
        #expect(suffix == " world")
    }

    @MainActor @Test func testDiffLastWordChanges() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "Hello worl", new: "Hello world!")
        #expect(del == 0)
        #expect(suffix == "d!")
    }

    @MainActor @Test func testDiffMiddleCorrection() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "Helo world", new: "Hello world")
        #expect(del == 7, "Must delete from divergence point: 'o world' = 7 chars")
        #expect(suffix == "lo world")
    }

    @MainActor @Test func testDiffCompleteReplacement() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "abc", new: "xyz")
        #expect(del == 3)
        #expect(suffix == "xyz")
    }

    @MainActor @Test func testDiffEmptyOld() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "", new: "Hello")
        #expect(del == 0)
        #expect(suffix == "Hello")
    }

    @MainActor @Test func testDiffEmptyNew() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "Hello", new: "")
        #expect(del == 5)
        #expect(suffix == "")
    }

    @MainActor @Test func testDiffBothEmpty() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "", new: "")
        #expect(del == 0)
        #expect(suffix == "")
    }

    @MainActor @Test func testDiffShorterNewText() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "Hello world", new: "Hello")
        #expect(del == 6, "Must delete ' world' = 6 chars")
        #expect(suffix == "")
    }

    @MainActor @Test func testDiffUnicodeCharacters() {
        let c = LiveStreamingController()
        let (del, suffix) = c.diffFromEnd(old: "Héllo wörld", new: "Héllo wörld!")
        #expect(del == 0)
        #expect(suffix == "!")
    }

    // MARK: - handleEvent smart diff integration

    @MainActor @Test func testInterimToInterimAppendOnly() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)
        c.hasSpeechOccurred = false // simulate fresh start

        // First interim: "Hello"
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9, words: [])))
        #expect(col.entries.count == 1)
        #expect(col.entries[0].textToType == "Hello")
        #expect(col.entries[0].replacingChars == 0)

        // Second interim: "Hello world" — should only type " world"
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello world", confidence: 0.9, words: [])))
        #expect(col.entries.count == 2)
        #expect(col.entries[1].textToType == " world")
        #expect(col.entries[1].replacingChars == 0, "Common prefix preserved — no deletions needed")
    }

    @MainActor @Test func testInterimToInterimCorrection() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.interim(TranscriptionResult(transcript: "I like cots", confidence: 0.9, words: [])))
        c.handleEvent(.interim(TranscriptionResult(transcript: "I like cats", confidence: 0.95, words: [])))

        #expect(col.entries.count == 2)
        #expect(col.entries[1].replacingChars == 3, "Delete 'ots' from 'cots'")
        #expect(col.entries[1].textToType == "ats", "Type 'ats' to form 'cats'")
    }

    @MainActor @Test func testInterimToIdenticalFinalNoKeystrokes() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Interim shows the text
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello world", confidence: 0.9, words: [])))
        // Final is identical — should NOT delete and retype
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello world", confidence: 0.99, words: [])))

        #expect(col.entries.count == 2)
        let final = col.entries[1]
        #expect(final.isFinal == true)
        #expect(final.replacingChars == 0, "No chars deleted — text was identical")
        #expect(final.textToType == "", "No text typed — text was identical")
        #expect(final.fullText == "Hello world", "Full text still tracked for transcript")
    }

    @MainActor @Test func testInterimToSlightlyDifferentFinal() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.interim(TranscriptionResult(transcript: "hello world", confidence: 0.9, words: [])))
        // Final adds punctuation
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello world.", confidence: 0.99, words: [])))

        let final = col.entries[1]
        #expect(final.isFinal == true)
        // "hello world" vs "Hello world." diverge at index 0
        #expect(final.replacingChars == 11, "Delete all of 'hello world'")
        #expect(final.textToType == "Hello world.", "Retype with correction")
    }

    @MainActor @Test func testInterimToFinalAppendOnly() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello world", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello world.", confidence: 0.99, words: [])))

        let final = col.entries[1]
        #expect(final.replacingChars == 0, "No deletions — final just appends period")
        #expect(final.textToType == ".", "Only type the period")
    }

    @MainActor @Test func testFinalWithNoInterimTypesFullText() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Final arrives without any preceding interim
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello world.", confidence: 0.99, words: [])))

        #expect(col.entries.count == 1)
        #expect(col.entries[0].textToType == "Hello world.")
        #expect(col.entries[0].replacingChars == 0)
        #expect(col.entries[0].isFinal == true)
    }

    @MainActor @Test func testEmptyFinalRemovesInterim() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.interim(TranscriptionResult(transcript: "um", confidence: 0.5, words: [])))
        // Empty final — server decided interim was noise
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "", confidence: 0.0, words: [])))

        #expect(col.entries.count == 2)
        let final = col.entries[1]
        #expect(final.replacingChars == 2, "Delete 'um'")
        #expect(final.textToType == "")
        #expect(final.fullText == "")
    }

    @MainActor @Test func testMultipleSegmentsScreenText() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Segment 1: "Hello" interim → "Hello." final
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello.", confidence: 0.99, words: [])))

        // Segment 2: "World" interim → "World!" final
        c.handleEvent(.interim(TranscriptionResult(transcript: "World", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "World!", confidence: 0.99, words: [])))

        // Verify screen text is correct
        #expect(col.screenText == "Hello. World! ", "Segments separated by spaces from finals")
    }

    @MainActor @Test func testProgressiveInterimGrowthMinimalKeystrokes() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Simulate natural interim progression
        let interims = ["H", "He", "Hel", "Hell", "Hello", "Hello ", "Hello w", "Hello wo", "Hello wor", "Hello worl", "Hello world"]
        for text in interims {
            c.handleEvent(.interim(TranscriptionResult(transcript: text, confidence: 0.9, words: [])))
        }

        // Every update after the first should be append-only (0 deletions)
        for i in 1..<col.entries.count {
            #expect(col.entries[i].replacingChars == 0,
                    "Entry \(i): progressive growth should never need deletions, got \(col.entries[i].replacingChars)")
            #expect(col.entries[i].textToType.count <= 2,
                    "Entry \(i): should type at most 1-2 chars, typed '\(col.entries[i].textToType)'")
        }
    }

    @MainActor @Test func testIdenticalConsecutiveInterimsNoOp() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9, words: [])))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9, words: [])))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9, words: [])))

        #expect(col.entries.count == 1, "Identical interims produce no additional callbacks")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LiveStreamingController: Silence Auto-End Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("LiveStreamingController — Silence Auto-End")
struct SilenceAutoEndTests {

    @MainActor @Test func testAutoEndDisabledByDefault() {
        let c = LiveStreamingController()
        #expect(c.autoEndSilenceDuration == 0, "Auto-end disabled by default")
    }

    @MainActor @Test func testNoAutoEndWhenDisabled() async throws {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)
        c.autoEndSilenceDuration = 0

        // Simulate speech then utterance end
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello.", confidence: 0.99, words: [], speechFinal: true)))

        // Wait well past any potential timer
        try await Task.sleep(for: .milliseconds(200))
        #expect(col.autoEndCount == 0, "Should never auto-end when duration is 0")
    }

    @MainActor @Test func testNoAutoEndBeforeSpeech() async throws {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)
        c.autoEndSilenceDuration = 0.1

        // utteranceEnd without any prior speech — should NOT trigger timer
        c.handleEvent(.utteranceEnd(lastWordEnd: 0))
        try await Task.sleep(for: .milliseconds(200))
        #expect(col.autoEndCount == 0, "Should not auto-end if no speech has occurred")
    }

    @MainActor @Test func testAutoEndFiresAfterSilence() async throws {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c, simulateActive: true)
        c.autoEndSilenceDuration = 0.15  // 150ms for fast test

        // Simulate: speech → utterance end → silence
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello.", confidence: 0.99, words: [], speechFinal: true)))

        // Wait for auto-end to fire (generous margin for thread-pool scheduling jitter)
        try await Task.sleep(for: .milliseconds(600))
        #expect(col.autoEndCount == 1, "Auto-end should fire after silence duration")
    }

    @MainActor @Test func testAutoEndCancelledBySpeechResuming() async throws {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c, simulateActive: true)
        c.autoEndSilenceDuration = 0.2  // 200ms

        // Speech → utterance end
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hello", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello.", confidence: 0.99, words: [], speechFinal: true)))

        // Wait 100ms, then speech starts again
        try await Task.sleep(for: .milliseconds(100))
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "World", confidence: 0.9, words: [])))

        // Wait past the original 200ms deadline
        try await Task.sleep(for: .milliseconds(200))
        #expect(col.autoEndCount == 0, "Auto-end cancelled because speech resumed")
    }

    @MainActor @Test func testAutoEndCancelledByInterim() async throws {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c, simulateActive: true)
        c.autoEndSilenceDuration = 0.2

        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Test", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Test.", confidence: 0.99, words: [], speechFinal: true)))

        // Timer started. New interim cancels it.
        try await Task.sleep(for: .milliseconds(100))
        c.handleEvent(.interim(TranscriptionResult(transcript: "More", confidence: 0.9, words: [])))

        try await Task.sleep(for: .milliseconds(200))
        #expect(col.autoEndCount == 0, "Interim text cancels silence timer")
    }

    @MainActor @Test func testAutoEndFiresOnUtteranceEnd() async throws {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c, simulateActive: true)
        c.autoEndSilenceDuration = 0.15

        // Speech occurred, then utteranceEnd (not speechFinal)
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "Hi", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hi.", confidence: 0.99, words: [])))
        c.handleEvent(.utteranceEnd(lastWordEnd: 0))

        try await Task.sleep(for: .milliseconds(600))
        #expect(col.autoEndCount == 1, "utteranceEnd should also start the silence timer")
    }

    @MainActor @Test func testAutoEndFiresExactlyOnce() async throws {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c, simulateActive: true)
        c.autoEndSilenceDuration = 0.1

        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Test.", confidence: 0.99, words: [], speechFinal: true)))

        // Wait much longer than the timer (generous margin for scheduling jitter)
        try await Task.sleep(for: .milliseconds(600))
        #expect(col.autoEndCount == 1, "Should fire exactly once, not repeatedly")
    }

    @MainActor @Test func testSilenceTimerResetOnMultipleUtteranceEnds() async throws {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c, simulateActive: true)
        c.autoEndSilenceDuration = 0.3

        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "A.", confidence: 0.99, words: [], speechFinal: true)))
        // Timer starts: T=0

        try await Task.sleep(for: .milliseconds(150))
        // Another utteranceEnd at T=150ms — timer should RESET
        c.handleEvent(.utteranceEnd(lastWordEnd: 0))

        // At T=250ms: only 100ms since last reset — should NOT have fired
        try await Task.sleep(for: .milliseconds(100))
        #expect(col.autoEndCount == 0, "Timer was reset by second utteranceEnd")

        // At T=550ms: 400ms since last reset — should have fired (300ms timer)
        try await Task.sleep(for: .milliseconds(300))
        #expect(col.autoEndCount == 1, "Timer fires after reset duration")
    }

    @MainActor @Test func testHasSpeechOccurredTracking() {
        let c = LiveStreamingController()
        #expect(c.hasSpeechOccurred == false)

        c.handleEvent(.speechStarted(timestamp: 0))
        #expect(c.hasSpeechOccurred == true)
    }

    @MainActor @Test func testHasSpeechOccurredSetByInterim() {
        let c = LiveStreamingController()
        #expect(c.hasSpeechOccurred == false)

        c.handleEvent(.interim(TranscriptionResult(transcript: "Hi", confidence: 0.9, words: [])))
        #expect(c.hasSpeechOccurred == true)
    }

    @MainActor @Test func testSilenceTimerNilAfterCancel() {
        let c = LiveStreamingController()
        c.autoEndSilenceDuration = 1.0
        c.hasSpeechOccurred = true

        c.handleEvent(.utteranceEnd(lastWordEnd: 0))
        #expect(c.silenceTimer != nil, "Timer should be active")

        c.handleEvent(.speechStarted(timestamp: 0))
        #expect(c.silenceTimer == nil, "Timer should be nil after cancel")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LiveStreamingController: Event Handling Integration Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("LiveStreamingController — Event Handling")
struct EventHandlingTests {

    @MainActor @Test func testSpeechStartedCallback() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c, simulateActive: true)

        c.handleEvent(.speechStarted(timestamp: 0))
        #expect(col.speechStartCount == 1)
    }

    @MainActor @Test func testUtteranceEndCallback() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.utteranceEnd(lastWordEnd: 0))
        #expect(col.utteranceEndCount == 1)
    }

    @MainActor @Test func testSpeechFinalTriggersUtteranceEnd() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Done.", confidence: 0.99, words: [], speechFinal: true)))
        #expect(col.utteranceEndCount == 1, "speechFinal should trigger onUtteranceEnd")
    }

    @MainActor @Test func testNonSpeechFinalDoesNotTriggerUtteranceEnd() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.finalResult(TranscriptionResult(transcript: "Hello.", confidence: 0.99, words: [])))
        #expect(col.utteranceEndCount == 0, "Non-speechFinal should not trigger onUtteranceEnd")
    }

    @MainActor @Test func testEmptyInterimIgnored() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.interim(TranscriptionResult(transcript: "", confidence: 0.0, words: [])))
        #expect(col.entries.isEmpty, "Empty interim should be ignored")
    }

    @MainActor @Test func testMetadataEventIgnored() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        c.handleEvent(.metadata(requestId: "test"))
        #expect(col.entries.isEmpty)
        #expect(col.speechStartCount == 0)
        #expect(col.utteranceEndCount == 0)
    }

    @MainActor @Test func testErrorCallback() {
        let c = LiveStreamingController()
        var errorReceived: Error?
        c.onError = { errorReceived = $0 }

        let testError = NSError(domain: "test", code: 42)
        c.handleEvent(.error(testError))
        #expect(errorReceived != nil)
        #expect((errorReceived as? NSError)?.code == 42)
    }

    @MainActor @Test func testFullConversationFlow() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Sentence 1: progressive interims → final
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "I", confidence: 0.8, words: [])))
        c.handleEvent(.interim(TranscriptionResult(transcript: "I like", confidence: 0.85, words: [])))
        c.handleEvent(.interim(TranscriptionResult(transcript: "I like cats", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "I like cats.", confidence: 0.99, words: [], speechFinal: true)))
        c.handleEvent(.utteranceEnd(lastWordEnd: 0))

        // Sentence 2
        c.handleEvent(.speechStarted(timestamp: 0))
        c.handleEvent(.interim(TranscriptionResult(transcript: "They", confidence: 0.8, words: [])))
        c.handleEvent(.interim(TranscriptionResult(transcript: "They are", confidence: 0.85, words: [])))
        c.handleEvent(.interim(TranscriptionResult(transcript: "They are cute", confidence: 0.9, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "They are cute.", confidence: 0.99, words: [], speechFinal: true)))

        // Verify callbacks
        #expect(col.speechStartCount == 2)
        #expect(col.utteranceEndCount >= 2, "speechFinal + utteranceEnd")
        #expect(col.finals.count == 2)

        // Verify screen text is correct
        #expect(col.screenText == "I like cats. They are cute. ")

        // Verify minimal keystrokes (progressive interims = append-only)
        let interimsForSentence1 = col.entries.prefix(while: { !$0.isFinal })
        for (i, entry) in interimsForSentence1.enumerated() where i > 0 {
            #expect(entry.replacingChars == 0,
                    "Progressive interim \(i) should be append-only")
        }
    }

    @MainActor @Test func testInterimCorrectionMidWord() {
        let c = LiveStreamingController()
        let col = TextUpdateCollector()
        col.wire(c)

        // Deepgram corrects mid-word
        c.handleEvent(.interim(TranscriptionResult(transcript: "recognise", confidence: 0.7, words: [])))
        c.handleEvent(.interim(TranscriptionResult(transcript: "recognize", confidence: 0.85, words: [])))
        c.handleEvent(.finalResult(TranscriptionResult(transcript: "recognize", confidence: 0.99, words: [])))

        // First interim → second should correct 'se' → 'ze'
        #expect(col.entries[1].replacingChars == 2, "Delete 'se' from 'recognise'")
        #expect(col.entries[1].textToType == "ze", "Type 'ze' to form 'recognize'")

        // Final identical to last interim — no keystrokes
        #expect(col.entries[2].replacingChars == 0)
        #expect(col.entries[2].textToType == "")
    }
}
