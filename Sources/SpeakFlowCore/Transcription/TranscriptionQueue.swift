import Foundation
import OSLog

/// Actor-based queue that ensures transcription results are output in order
///
/// This actor handles the sequencing of transcription chunks, ensuring they are
/// output in the order they were recorded, regardless of when API responses arrive.
public actor TranscriptionQueue {
    private var pendingResults: [UInt64: String] = [:]
    private var nextSeqToOutput: UInt64 = 0
    private var currentSeq: UInt64 = 0
    let rateLimiter = RateLimiter()

    // Continuations for async streaming
    private var textContinuation: AsyncStream<String>.Continuation?
    private var completionContinuation: CheckedContinuation<Void, Never>?

    // Create an async stream for text output
    var textStream: AsyncStream<String> {
        AsyncStream { continuation in
            self.textContinuation = continuation
        }
    }

    public func reset() {
        pendingResults.removeAll()
        nextSeqToOutput = 0
        currentSeq = 0
    }

    /// Get the next sequence number for a new chunk
    /// Uses UInt64 to handle billions of chunks without overflow
    public func nextSequence() -> UInt64 {
        let seq = currentSeq
        // Using wrapping addition for safety, though overflow is practically impossible
        // UInt64.max = 18,446,744,073,709,551,615 chunks
        currentSeq &+= 1
        return seq
    }

    public func getPendingCount() -> Int {
        // Safe subtraction - both are UInt64, result fits in Int for practical counts
        let count = currentSeq - nextSeqToOutput
        return count > Int.max ? Int.max : Int(count)
    }

    public func submitResult(seq: UInt64, text: String) {
        pendingResults[seq] = text
        flushReady()
    }

    func markFailed(seq: UInt64) {
        pendingResults[seq] = ""
        flushReady()
    }

    private func flushReady() {
        while let text = pendingResults[nextSeqToOutput] {
            pendingResults.removeValue(forKey: nextSeqToOutput)
            if !text.isEmpty {
                Logger.transcription.info("Output: \(text, privacy: .private)")
                textContinuation?.yield(text)
            }
            nextSeqToOutput &+= 1
        }

        if pendingResults.isEmpty && currentSeq == nextSeqToOutput && currentSeq > 0 {
            completionContinuation?.resume()
            completionContinuation = nil
        }
    }

    func waitForCompletion() async {
        // If already complete, return immediately
        if pendingResults.isEmpty && currentSeq == nextSeqToOutput && currentSeq > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            self.completionContinuation = continuation
        }
    }

    func finishStream() {
        // P2 Security: Resume completion continuation before clearing to prevent caller hang
        completionContinuation?.resume()
        completionContinuation = nil
        textContinuation?.finish()
        textContinuation = nil
    }
}

// MARK: - Callback Bridge

/// Bridge providing callback-based API for TranscriptionQueue
///
/// This bridge exists for backward compatibility with the existing AppDelegate
/// callback pattern. New code should use the actor directly with async/await.
/// Migration path: When fully migrating to async/await, this bridge can be removed
/// and callers can use `for await text in queue.textStream` directly.
@MainActor
public final class TranscriptionQueueBridge {
    let queue = TranscriptionQueue()
    private var streamTask: Task<Void, Never>?
    
    /// Guard to prevent onAllComplete from firing multiple times per session.
    /// Reset to false when a new session starts (via reset() or first nextSequence()).
    private var hasSignaledCompletion = false
    
    /// Track whether a session has started (at least one sequence requested)
    private var sessionStarted = false

    public var onTextReady: ((String) -> Void)?
    public var onAllComplete: (() -> Void)?

    public init() {}

    func startListening() {
        streamTask = Task {
            for await text in await queue.textStream {
                onTextReady?(text)
            }
        }
    }

    func stopListening() {
        streamTask?.cancel()
        streamTask = nil
    }

    public func reset() async {
        await queue.reset()
        hasSignaledCompletion = false
        sessionStarted = false
    }

    public func nextSequence() async -> UInt64 {
        // Mark session as started and reset completion flag for new chunks
        if !sessionStarted {
            sessionStarted = true
            hasSignaledCompletion = false
        }
        return await queue.nextSequence()
    }

    public func getPendingCount() async -> Int {
        await queue.getPendingCount()
    }

    public func submitResult(seq: UInt64, text: String) async {
        await queue.submitResult(seq: seq, text: text)
    }

    func markFailed(seq: UInt64) async {
        await queue.markFailed(seq: seq)
    }

    public func checkCompletion() async {
        // Guard: only fire completion once per session
        guard !hasSignaledCompletion else { return }
        guard sessionStarted else { return }
        
        let pending = await queue.getPendingCount()
        if pending == 0 {
            // Double-check after await (another task may have set it during suspension)
            guard !hasSignaledCompletion else { return }
            hasSignaledCompletion = true
            onAllComplete?()
        }
    }
}
