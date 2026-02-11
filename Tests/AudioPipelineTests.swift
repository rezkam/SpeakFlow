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

@Suite("Chunk Skip Regression Tests — Source Guards")
struct ChunkSkipSourceRegressionTests {

    /// Regression: sendChunkIfReady must NOT drain the buffer before the skip decision.
    /// Previously, the buffer was drained via takeAll before checking skipSilentChunks,
    /// permanently losing audio data when an intermediate chunk was skipped.
    @Test func testSendChunkIfReadySourceDoesNotDrainBeforeSkipCheck() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        // Find the sendChunkIfReady function
        guard let funcRange = source.range(of: "private func sendChunkIfReady") else {
            Issue.record("sendChunkIfReady not found in StreamingRecorder")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // Find positions of key operations within sendChunkIfReady.
        // Use the actual runtime check pattern (not comments) for skipSilentChunks.
        guard let takeAllPos = funcBody.range(of: "buffer.takeAll()")?.lowerBound else {
            Issue.record("buffer.takeAll() not found in sendChunkIfReady")
            return
        }
        // Match the actual if-statement check (captured local variable), not comment mentions
        guard let skipCheckPos = funcBody.range(of: "skipSilentChunks && speechProbability < skipThreshold")?.lowerBound else {
            Issue.record("skipSilentChunks runtime check not found in sendChunkIfReady")
            return
        }

        // The skip check MUST come BEFORE buffer.takeAll()
        #expect(skipCheckPos < takeAllPos,
                "REGRESSION: buffer.takeAll() before skipSilentChunks causes audio loss")
    }

    /// Regression: intermediate chunks must be sent when speech was detected in session,
    /// mirroring the final-chunk protection in stop().
    @Test func testSendChunkIfReadyHasSpeechDetectedBypass() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let funcRange = source.range(of: "private func sendChunkIfReady") else {
            Issue.record("sendChunkIfReady not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // Must check speechDetectedInSession (or hasSpoken) before the skip return
        let hasSpeechBypass = funcBody.contains("speechDetectedInSession") ||
                              funcBody.contains("hasSpoken")
        #expect(hasSpeechBypass,
                "REGRESSION: sendChunkIfReady must bypass skip when speech detected in session")
    }

    /// The skip condition must include `&& !speechDetectedInSession` to avoid skipping
    /// intermediate chunks when the user has been speaking.
    @Test func testSkipConditionIncludesNegatedSpeechDetectedFlag() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let funcRange = source.range(of: "private func sendChunkIfReady") else {
            Issue.record("sendChunkIfReady not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        // The skip `if` must combine all three conditions:
        //   skipSilentChunks && probability < threshold && !speechDetectedInSession
        #expect(funcBody.contains("!speechDetectedInSession"),
                "REGRESSION: skip condition must negate speechDetectedInSession")
    }

    /// Verify the final chunk in stop() still has speechDetectedInSession protection.
    @Test func testStopFinalChunkProtected() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        guard let stopRange = source.range(of: "public func stop()") else {
            Issue.record("stop() not found")
            return
        }
        let stopBody = String(source[stopRange.lowerBound...])
        #expect(stopBody.contains("speechDetectedInSession"),
                "stop() must protect final chunk with speechDetectedInSession bypass")
    }

    /// VAD resetChunk() must only be called AFTER the buffer is drained (committed to send),
    /// never in the skip path. Otherwise, a skip resets the accumulator, and the next check
    /// cycle has no history — making the probability even lower.
    @Test func testResetChunkInBothSkipAndSendPaths() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let funcRange = source.range(of: "private func sendChunkIfReady") else {
            Issue.record("sendChunkIfReady not found")
            return
        }
        let funcBody = String(source[funcRange.lowerBound...])

        guard let takeAllPos = funcBody.range(of: "buffer.takeAll()")?.lowerBound else {
            Issue.record("buffer.takeAll() not found in sendChunkIfReady")
            return
        }

        // There must be TWO resetChunk() calls:
        // 1) In the skip branch (BEFORE takeAll — skip returns false before drain)
        // 2) In the send branch (AFTER takeAll — reset after drain)
        let resetOccurrences = funcBody.components(separatedBy: "resetChunk()").count - 1
        #expect(resetOccurrences >= 2,
                "resetChunk() must appear in BOTH skip and send paths, found \(resetOccurrences)")

        // The LAST resetChunk must be AFTER buffer.takeAll (send path)
        guard let lastResetRange = funcBody.range(of: "resetChunk()", options: .backwards) else {
            Issue.record("resetChunk() not found"); return
        }
        #expect(lastResetRange.lowerBound > takeAllPos,
                "REGRESSION: the send-path resetChunk must be after buffer drain")
    }
}

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

// MARK: - Regression: Force-send chunks during continuous speech

@Suite("Force-send chunks during continuous speech — source regression")
struct ForceSendChunkSourceTests {

    @Test func testForceSendChunkMultiplierExists() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Config.swift")
        #expect(source.contains("forceSendChunkMultiplier"),
                "Config must define forceSendChunkMultiplier")
        #expect(source.contains("2.0"),
                "forceSendChunkMultiplier should be 2.0")
    }

    @Test func testPeriodicCheckHasForceSendPath() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        let body = extractFunctionBody(named: "periodicCheck", from: source)
        #expect(body != nil, "periodicCheck must exist")
        guard let body else { return }

        #expect(body.contains("forceSendChunkMultiplier"),
                "periodicCheck must reference forceSendChunkMultiplier for hard upper limit")
        #expect(body.contains("FORCE CHUNK"),
                "Force-send path must log a FORCE CHUNK warning")
    }

    @Test func testForceSendIgnoresSpeakingState() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        let body = extractFunctionBody(named: "periodicCheck", from: source)
        guard let body else {
            Issue.record("periodicCheck not found")
            return
        }

        // The force-send path must be in the `else if` branch after the `if !isSpeaking` check,
        // meaning it fires even when isSpeaking is true
        #expect(body.contains("} else if duration >= settings.maxChunkDuration * Config.forceSendChunkMultiplier"),
                "Force-send must be an else-if after the !isSpeaking check (fires when speaking)")
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

    /// Source-level: The audio tap must use createOneShotInputBlock, not an inline closure.
    @Test func testAudioTapUsesOneShotInputBlock() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("createOneShotInputBlock"),
                "Audio tap must use createOneShotInputBlock to prevent double-buffering")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - P2 Fix: VAD resetChunk() on skip path — source regression
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("P2 — VAD resetChunk called on skip path")
struct VADResetChunkOnSkipSourceTests {

    /// Source-level: sendChunkIfReady must call resetChunk() inside the skip branch
    /// so stale silent samples don't accumulate across consecutive skipped chunks.
    @Test func testResetChunkCalledInSkipBranch() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        // Find the skip branch
        guard let skipRange = source.range(of: "skipSilentChunks && speechProbability < skipThreshold") else {
            Issue.record("Skip check not found in sendChunkIfReady")
            return
        }

        // Locate the return false that ends the skip branch
        let afterSkip = source[skipRange.upperBound...]
        guard let returnFalseRange = afterSkip.range(of: "return false") else {
            Issue.record("return false not found after skip check")
            return
        }

        // resetChunk must appear BETWEEN the skip condition and the return false
        let skipBranch = source[skipRange.upperBound..<returnFalseRange.lowerBound]
        #expect(skipBranch.contains("resetChunk()"),
                "resetChunk() must be called in skip branch to prevent stale accumulation")
    }

    /// Source-level: resetChunk() must ALSO still be called after buffer drain (send path).
    @Test func testResetChunkCalledInSendBranch() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let drainRange = source.range(of: "buffer.takeAll()") else {
            Issue.record("buffer.takeAll() not found in sendChunkIfReady")
            return
        }

        let afterDrain = source[drainRange.upperBound...]
        // resetChunk should appear after drain but within sendChunkIfReady
        let nextFuncBoundary = afterDrain.range(of: "private func ")?.lowerBound
                            ?? afterDrain.range(of: "func ")?.lowerBound
                            ?? afterDrain.endIndex
        let sendBody = afterDrain[..<nextFuncBoundary]
        #expect(sendBody.contains("resetChunk()"),
                "resetChunk() must still be called after buffer drain in send path")
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

    /// Source-level: verify AudioChunk conforms to Sendable.
    @Test func testAudioChunkIsSendable() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("struct AudioChunk: Sendable"),
                "AudioChunk must conform to Sendable for concurrent audio processing")
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

    /// Source-level: verify createWav guards against empty samples.
    @Test func testCreateWavEmptySamplesProducesEmptyData() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("guard !samples.isEmpty else { return Data() }"),
                "createWav must return empty Data for empty samples to avoid invalid WAV")
    }

    /// Source-level: verify samples are clamped to [-1, 1] before Int16 conversion.
    @Test func testCreateWavClampsToInt16Range() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("max(-1, min(1,"),
                "Samples must be clamped to [-1, 1] before Int16 conversion to prevent overflow")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: Thread-Safe State & Helpers Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — Thread-Safe State & Helpers")
struct StreamingRecorderThreadSafeStateAndHelpersTests {

    /// Source-level: verify AudioRecordingState uses NSLock for thread safety.
    @Test func testAudioRecordingStateIsThreadSafe() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        // Find AudioRecordingState class body
        guard let classStart = source.range(of: "private final class AudioRecordingState") else {
            Issue.record("AudioRecordingState class not found")
            return
        }

        let afterClass = String(source[classStart.lowerBound...])

        #expect(afterClass.contains("private let lock = NSLock()"),
                "AudioRecordingState must use NSLock for thread safety")
        #expect(afterClass.contains("lock.lock()"),
                "Must call lock.lock() to protect shared state")
        #expect(afterClass.contains("lock.unlock()"),
                "Must call lock.unlock() to release lock")
    }

    /// Source-level: verify AudioRecordingState default values.
    @Test func testAudioRecordingStateDefaultValues() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let classStart = source.range(of: "private final class AudioRecordingState") else {
            Issue.record("AudioRecordingState class not found")
            return
        }

        let afterClass = String(source[classStart.lowerBound...])

        #expect(afterClass.contains("private var isRecording = false"),
                "Default state must be not recording")
        #expect(afterClass.contains("private var vadActive = false"),
                "Default VAD state must be inactive")
    }

    /// Source-level: verify fixed 16000 Hz sample rate.
    @Test func testAudioRecordingStateSampleRate() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let classStart = source.range(of: "private final class AudioRecordingState") else {
            Issue.record("AudioRecordingState class not found")
            return
        }

        let afterClass = String(source[classStart.lowerBound...])

        #expect(afterClass.contains("let sampleRate: Double = 16000"),
                "Sample rate must be fixed at 16000 Hz for ChatGPT API")
    }

    /// Source-level: verify AudioSampleQueue has bounded size and drops old samples.
    @Test func testAudioSampleQueueBounded() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let classStart = source.range(of: "private final class AudioSampleQueue") else {
            Issue.record("AudioSampleQueue class not found")
            return
        }

        let afterClass = String(source[classStart.lowerBound...])

        #expect(afterClass.contains("private let maxQueueSize = 100"),
                "Queue must have max size limit to prevent memory growth")
        #expect(afterClass.contains("samples.removeFirst()"),
                "Queue must drop oldest sample when at capacity")
    }

    /// Source-level: verify AudioSampleQueue uses NSLock for thread safety.
    @Test func testAudioSampleQueueIsThreadSafe() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let classStart = source.range(of: "private final class AudioSampleQueue") else {
            Issue.record("AudioSampleQueue class not found")
            return
        }

        let afterClass = String(source[classStart.lowerBound...])

        #expect(afterClass.contains("private let lock = NSLock()"),
                "AudioSampleQueue must use NSLock for thread safety")
    }

    /// Source-level: verify dequeueAll atomically clears the queue.
    @Test func testAudioSampleQueueDequeueAllClearsQueue() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        guard let classStart = source.range(of: "private final class AudioSampleQueue") else {
            Issue.record("AudioSampleQueue class not found")
            return
        }

        let afterClass = String(source[classStart.lowerBound...])

        #expect(afterClass.contains("samples.removeAll()"),
                "dequeueAll must atomically clear all samples")
    }

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

    /// Source-level: verify OneShotState wrapper for non-Sendable buffer.
    @Test func testOneShotStateWrapsNonSendableBuffer() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        #expect(source.contains("final class OneShotState: @unchecked Sendable"),
                "OneShotState must wrap non-Sendable buffer with @unchecked Sendable")
        #expect(source.contains("var provided = false"),
                "OneShotState must track whether buffer was provided")
    }

    /// Source-level: verify installAudioTap is a free function (not @MainActor class method).
    @Test func testInstallAudioTapIsNonisolated() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        #expect(source.contains("private func installAudioTap("),
                "installAudioTap must be a private function")

        // Verify it's NOT inside the @MainActor StreamingRecorder class
        // by checking it appears after the class closing brace
        guard let recorderClassStart = source.range(of: "@MainActor\npublic final class StreamingRecorder") else {
            Issue.record("StreamingRecorder class not found")
            return
        }

        // Find the installAudioTap function position
        guard let tapFuncPos = source.range(of: "private func installAudioTap(") else {
            Issue.record("installAudioTap function not found")
            return
        }

        // It should appear before the StreamingRecorder class (at the top level)
        #expect(tapFuncPos.lowerBound < recorderClassStart.lowerBound,
                "installAudioTap must be a free function, not a class method")
    }

    /// Source-level: verify audio tap uses Accelerate framework for RMS calculation.
    @Test func testInstallAudioTapCalculatesRMS() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")

        #expect(source.contains("vDSP_rmsqv("),
                "Audio tap must use vDSP_rmsqv from Accelerate for efficient RMS calculation")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - StreamingRecorder: start, startMock & Test Helpers
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("StreamingRecorder — start, startMock & Test Helpers")
struct StreamingRecorderStartAndMockTests {

    /// start() must be marked @discardableResult.
    @Test func testStartReturnsDiscardableResult() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("@discardableResult") && source.contains("public func start() async -> Bool"))
    }

    /// start() must set sessionStartDate as the first action.
    @Test func testStartSetsSessionStartDate() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "start", from: source)
        #expect(body?.contains("sessionStartDate = Date()") == true)
    }

    /// start() must roll back all state in catch block on engine.start() failure.
    @Test func testStartRollsBackOnEngineFailure() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "start", from: source)
        #expect(body?.contains("engine.inputNode.removeTap(onBus: 0)") == true)
        #expect(body?.contains("audioEngine = nil") == true)
        #expect(body?.contains("audioBuffer = nil") == true)
        #expect(body?.contains("state.setRecording(false)") == true)
        #expect(body?.contains("vadProcessor = nil") == true)
        #expect(body?.contains("sessionController = nil") == true)
        #expect(body?.contains("sessionStartDate = nil") == true)
    }

    /// start() must re-check recording state after VAD initialization.
    @Test func testStartAbortsIfStoppedDuringVADInit() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "start", from: source)
        // After initializeVAD(), must re-check recording state
        #expect(body?.contains("guard state.getRecording() else") == true,
                "start() must re-check recording state after VAD init")
        #expect(body?.contains("Recording cancelled during VAD initialization") == true)
    }

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

    /// startMock() must feed audio in 50ms chunks.
    @Test func testStartMockFeedsAudioIn50msChunks() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "startMock", from: source)
        #expect(body?.contains("sampleRate * 0.05") == true, "Mock must feed 50ms chunks")
        #expect(body?.contains("Task.sleep(for: .milliseconds(50))") == true, "Mock must sleep 50ms between chunks")
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

    /// Test helpers must be guarded by #if DEBUG.
    @Test func testTestHelpersOnlyAvailableInDebug() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        #expect(source.contains("#if DEBUG\n@MainActor\nextension StreamingRecorder") ||
                source.contains("#if DEBUG\n@MainActor extension StreamingRecorder"),
                "Test helpers must be behind #if DEBUG")
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

    /// stop() must invalidate and clear both timers.
    @Test func testStopInvalidatesTimers() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("checkTimer?.invalidate()") == true,
                "stop() must invalidate checkTimer")
        #expect(stopBody?.contains("processingTimer?.invalidate()") == true,
                "stop() must invalidate processingTimer")
        #expect(stopBody?.contains("checkTimer = nil") == true,
                "stop() must clear checkTimer")
        #expect(stopBody?.contains("processingTimer = nil") == true,
                "stop() must clear processingTimer")
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

    /// stop() must protect final chunk when speech detected in session.
    @Test func testStopProtectsFinalChunkWithSpeechDetectedInSession() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("speechDetectedInSession") == true,
                "stop() must check speechDetectedInSession for final chunk protection")
        #expect(stopBody?.contains("|| speechDetectedInSession") == true,
                "speechDetectedInSession must be in the send condition")
    }

    /// stop() must reset VAD session.
    @Test func testStopResetsVADSession() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("resetSession()") == true,
                "stop() must call resetSession() on VAD processor")
    }

    /// stop() must reset isCancelled flag for next session.
    @Test func testCancelResetsIsCancelledFlag() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("isCancelled = false") == true,
                "stop() must reset isCancelled so next recording isn't affected")
    }

    /// stop() must drain pending sample queue before evaluating final chunk.
    @Test func testStopDrainsPendingSampleQueue() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        #expect(stopBody?.contains("sampleQueue.dequeueAll()") == true,
                "stop() must drain pending sample queue before evaluating final chunk")
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

    /// TranscriptionQueueBridge has the required completion flow.
    @Test func testQueueBridgeCompletionFlow() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Transcription/TranscriptionQueue.swift")
        #expect(source.contains("class TranscriptionQueueBridge"))
        #expect(source.contains("func checkCompletion()"))
        #expect(source.contains("hasSignaledCompletion"))
        #expect(source.contains("sessionStarted"))
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

    /// Source-level: sendChunkIfReady checks skipSilentChunks before sending.
    @Test func testSendChunkIfReadySkipsSilentChunkWithSkipEnabled() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "sendChunkIfReady", from: source)
        // The skip condition must check skipSilentChunks && low probability && no session speech
        #expect(body?.contains("skipSilentChunks && speechProbability < skipThreshold && !speechDetectedInSession") == true,
                "sendChunkIfReady must skip silent chunks when skipSilentChunks is enabled and no speech detected")
        // When skipping, buffer must NOT be drained (no takeAll before return false)
        #expect(body?.contains("return false") == true,
                "Skip branch must return false without draining buffer")
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

    @Test func testSendChunkIfReadyBypassesSkipWhenSpeechDetectedInSession() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "sendChunkIfReady", from: source)
        #expect(body?.contains("&& !speechDetectedInSession") == true,
                "Skip logic must check speechDetectedInSession bypass")
    }

    @Test func testSendChunkIfReadyResetsVADOnSkip() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        guard let body = extractFunctionBody(named: "sendChunkIfReady", from: source) else {
            Issue.record("sendChunkIfReady body not found")
            return
        }
        guard let skipLogRange = body.range(of: "Skipping silent chunk") else {
            Issue.record("skip log not found")
            return
        }
        let beforeSkipLog = String(body[..<skipLogRange.lowerBound])
        #expect(beforeSkipLog.contains("resetChunk()"),
                "resetChunk() must be called in skip branch before logging")
    }

    @Test func testSendChunkIfReadyResetsVADOnSend() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        guard let body = extractFunctionBody(named: "sendChunkIfReady", from: source) else {
            Issue.record("sendChunkIfReady body not found")
            return
        }
        guard let drainRange = body.range(of: "Drain buffer and send") else {
            Issue.record("Drain buffer and send section not found")
            return
        }
        let afterDrain = String(body[drainRange.lowerBound...])
        #expect(afterDrain.contains("resetChunk()"),
                "resetChunk() must be called after draining buffer")
    }

    @Test func testSendChunkIfReadyUsesVADProbabilityOnly() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "sendChunkIfReady", from: source)
        #expect(body?.contains("speechProbability = await vad.averageSpeechProbability") == true,
                "Must use VAD probability directly (no energy-based fallback)")
        #expect(body?.contains("energySpeechRatio") != true,
                "sendChunkIfReady must not reference energy-based speech ratio")
    }

    @Test func testPeriodicCheckDoesNothingWhenNotRecording() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "periodicCheck", from: source)
        #expect(body?.contains("guard state.getRecording()") == true,
                "periodicCheck must guard on recording state")
    }

    @Test func testPeriodicCheckForceSendAtHardLimit() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "periodicCheck", from: source)
        #expect(body?.contains("Config.forceSendChunkMultiplier") == true,
                "periodicCheck must have force-send at hard upper limit")
        #expect(body?.contains("FORCE CHUNK") == true,
                "Force-send must log a FORCE CHUNK warning")
    }

    @Test func testPeriodicCheckFallbackChunkOnSilenceWithoutVAD() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Audio/StreamingRecorder.swift")
        let body = extractFunctionBody(named: "periodicCheck", from: source)
        #expect(body?.contains("Config.silenceDuration") == true,
                "Fallback path must use Config.silenceDuration for chunk timing")
        #expect(body?.contains("reason: \"silence (fallback)\"") == true,
                "Fallback silence chunk must use 'silence (fallback)' reason")
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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LiveStreamingController: Source-Level Tests
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@Suite("LiveStreamingController — Source-Level Invariants")
struct LiveStreamingSourceTests {

    @Test func testNoLocalVADInController() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Providers/LiveStreamingController.swift")
        #expect(!source.contains("VADProcessor"), "Must not use local VADProcessor")
        #expect(!source.contains("VADConfiguration"), "Must not use VADConfiguration")
        #expect(!source.contains("SessionController"), "Must not use SessionController (local auto-end)")
        #expect(!source.contains("speechProbability"), "Must not compute local speech probability")
    }

    @Test func testSmartDiffUsed() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Providers/LiveStreamingController.swift")
        #expect(source.contains("diffFromEnd"), "Must use smart diff for text replacement")
        #expect(source.contains("commonLen"), "Diff must find common prefix length")
    }

    @Test func testSilenceTimerImplementation() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Providers/LiveStreamingController.swift")
        #expect(source.contains("silenceTimer"), "Must have silence timer")
        #expect(source.contains("autoEndSilenceDuration"), "Must reference silence duration config")
        #expect(source.contains("hasSpeechOccurred"), "Must track whether speech has occurred")
        #expect(source.contains("cancelSilenceTimer"), "Must cancel timer on speech events")
        #expect(source.contains("startSilenceTimer"), "Must start timer on silence events")
    }

    @Test func testAutoEndNotFiringWithoutSpeech() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Providers/LiveStreamingController.swift")
        // The startSilenceTimer must guard on hasSpeechOccurred
        #expect(source.contains("hasSpeechOccurred") && source.contains("guard"),
                "startSilenceTimer must check hasSpeechOccurred before starting")
    }

    @Test func testTimerCancelledOnCleanup() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Providers/LiveStreamingController.swift")
        let stopBody = extractFunctionBody(named: "stop", from: source)
        let cancelBody = extractFunctionBody(named: "cancel", from: source)
        #expect(stopBody?.contains("cancelSilenceTimer") == true, "stop() must cancel silence timer")
        #expect(cancelBody?.contains("cancelSilenceTimer") == true, "cancel() must cancel silence timer")
    }

    @Test func testAppDelegateWiresAutoEnd() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        #expect(source.contains("autoEndSilenceDuration"), "RecordingController must set autoEndSilenceDuration")
        #expect(source.contains("onAutoEnd"), "RecordingController must handle onAutoEnd callback")
    }

    @Test func testCallbackSignatureIncludesFullText() throws {
        let source = try readProjectSource("Sources/SpeakFlowCore/Providers/LiveStreamingController.swift")
        #expect(source.contains("fullText: String"), "onTextUpdate must include fullText parameter")
    }

    @Test func testProviderMenuShowsMode() throws {
        let source = try readProjectSource("Sources/App/AppState.swift")
        #expect(source.contains("Batch"), "Provider list must indicate 'Batch' mode")
        #expect(source.contains("Streaming"), "Provider list must indicate 'Streaming' mode")
        // Verify provider picker is data-driven via ProviderInfo.all
        let pickerSource = try readProjectSource("Sources/App/TranscriptionSettingsView.swift")
        #expect(pickerSource.contains("ProviderInfo.all"), "Provider picker must use data-driven ProviderInfo.all")
    }

    @Test func testAudioSubsystemPreWarmed() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        #expect(source.contains("Audio subsystem pre-warmed") || source.contains("pre-warm"),
                "App launch must pre-warm audio subsystem to avoid first-recording delay")
        #expect(source.contains("engine.inputNode"),
                "Pre-warm must access inputNode to trigger CoreAudio initialization")
    }

    // MARK: - Bug Fix Regression Tests

    @Test func testStreamingStopAwaitsInsertionsBeforeReleasingKeyListener() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        // The streaming stop path must await pending text insertions before releasing
        // the key listener — otherwise Enter can fire before text is fully inserted.
        #expect(source.contains("pendingInsertion?.value"),
                "Streaming stop must await pendingInsertion before cleanup")
        #expect(source.contains("self.stopKeyListener()"),
                "Key listener must be stopped after awaiting insertions")
        // Scope ordering check to the streaming stop block (after liveStreamingController != nil)
        guard let blockStart = source.range(of: "pendingInsertion?.value") else { return }
        let blockSource = String(source[blockStart.lowerBound...])
        let awaitPos = blockSource.startIndex
        let stopRange = blockSource.range(of: "self.stopKeyListener()")
        #expect(stopRange != nil, "stopKeyListener must appear after pendingInsertion await")
        if let s = stopRange {
            #expect(awaitPos < s.lowerBound,
                    "Must await pendingInsertion BEFORE calling stopKeyListener")
        }
    }

    @Test func testStreamingStopResetsQueueCountAfterAwait() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        // queuedInsertionCount must only be reset after pending insertions complete,
        // otherwise deferred decrements in Task closures drive the count negative.
        let awaitRange = source.range(of: "pendingInsertion?.value")
        let resetRange = source.range(of: "self.queuedInsertionCount = 0")
        #expect(awaitRange != nil, "Must await pendingInsertion before resetting queue count")
        #expect(resetRange != nil, "Must reset queuedInsertionCount to 0")
        if let a = awaitRange, let r = resetRange {
            #expect(a.lowerBound < r.lowerBound,
                    "Must await pendingInsertion BEFORE resetting queuedInsertionCount")
        }
    }

    @Test func testUpdateKeyButtonUsesEditingFlag() throws {
        let source = try readProjectSource("Sources/App/AccountsSettingsView.swift")
        // "Update Key..." must use an isEditingKey flag to force the key entry visible,
        // rather than relying on deepgramApiKey being non-empty (which fails because
        // the button clears the key field).
        #expect(source.contains("isEditingKey = true"),
                "Update Key button must set isEditingKey flag")
        #expect(source.contains("isEditingKey") && source.contains("@State"),
                "isEditingKey must be a @State property")
        #expect(source.contains("isEditingKey || keyValidationError"),
                "Key entry visibility must check isEditingKey flag")
        #expect(source.contains("isEditingKey = false"),
                "isEditingKey must be cleared on save/remove")
    }

    @Test func testStreamingStopSetsProcessingFinalBeforeAsyncCleanup() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        // The streaming stop path must set isProcessingFinal = true synchronously
        // so the key handler's Enter/Escape branches still work during the wind-down gap
        // (isRecording is already false, but the event tap is still active).
        guard let streamingBlock = source.range(of: "if liveStreamingController != nil") else {
            #expect(Bool(false), "Must have streaming stop block"); return
        }
        let afterBlock = String(source[streamingBlock.lowerBound...])
        let processingRange = afterBlock.range(of: "isProcessingFinal = true")
        let taskRange = afterBlock.range(of: "Task { @MainActor in")
        #expect(processingRange != nil, "Streaming stop must set isProcessingFinal = true")
        #expect(taskRange != nil, "Streaming stop must have deferred cleanup Task")
        if let p = processingRange, let t = taskRange {
            #expect(p.lowerBound < t.lowerBound,
                    "isProcessingFinal must be set BEFORE the async cleanup Task")
        }
        // shouldPressEnterOnComplete must be read inside the Task (late), not captured early
        let enterRead = afterBlock.range(of: "self.shouldPressEnterOnComplete")
        if let e = enterRead, let t = taskRange {
            #expect(e.lowerBound > t.lowerBound,
                    "shouldPressEnterOnComplete must be read INSIDE the Task, not captured early")
        }
    }

    @Test func testWindowVisibilityUsesStableAPI() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // Window visibility must not rely on private AppKit class names
        #expect(!source.contains("className.contains"), "Must not filter windows by private class names")
        #expect(source.contains(".titled"), "Must use styleMask.titled for window visibility check")
    }

    @Test func testNotificationObserverTokenStored() throws {
        let source = try readProjectSource("Sources/App/AppDelegate.swift")
        // Closure-based NotificationCenter observers return tokens that must be stored
        // for proper removal — discarding the token makes removeObserver ineffective.
        #expect(source.contains("windowCloseObserver"), "Must store notification observer token")
    }

    @Test func testLoginFailureBannerIsGeneric() throws {
        let source = try readProjectSource("Sources/App/AuthController.swift")
        // User-facing login failure must use a stable generic message, not error.localizedDescription
        #expect(!source.contains("error.localizedDescription"),
                "Must not show locale-dependent error description to user")
    }

    @Test func testStreamingStopGuardsAgainstSessionClobbering() throws {
        let source = try readProjectSource("Sources/App/RecordingController.swift")
        // The deferred cleanup Task must guard against clobbering a new session that
        // started after cancel cleared isProcessingFinal. Without this guard, the old
        // Task resumes and calls stopKeyListener()/targetElement=nil on the new session.
        guard let taskBlock = source.range(of: "await pendingInsertion?.value") else {
            #expect(Bool(false), "Streaming stop must await pendingInsertion"); return
        }
        let afterAwait = String(source[taskBlock.upperBound...])
        // Must check isProcessingFinal before doing cleanup
        #expect(afterAwait.contains("guard self.isProcessingFinal"),
                "Deferred cleanup must verify isProcessingFinal before clobbering state")
        // Must also check isRecording to avoid clobbering a newly started session
        #expect(afterAwait.contains("self.isRecording"),
                "Deferred cleanup must check isRecording to protect new sessions")
    }

    @Test func testLaunchAtLoginShowsBannerOnFailure() throws {
        let source = try readProjectSource("Sources/App/GeneralSettingsView.swift")
        // SMAppService register/unregister failures must show a user-visible banner
        // instead of silently swallowing the error.
        #expect(source.contains("showBanner") && source.contains("catch"),
                "Launch-at-login catch block must show a banner on failure")
    }
}
