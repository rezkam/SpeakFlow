import Foundation
import OSLog

/// Ticket that binds a sequence number to a specific session generation.
/// This prevents stale async results from session N being accepted after
/// a reset for session N+1 (even if sequence numbers collide).
public struct TranscriptionTicket: Sendable, Equatable {
    public let session: UInt64
    public let seq: UInt64
}

/// Actor-based queue that ensures transcription results are output in order
///
/// This actor handles the sequencing of transcription chunks, ensuring they are
/// output in the order they were recorded, regardless of when API responses arrive.
public actor TranscriptionQueue {
    private static let maxPendingResults = 100
    private var pendingResults: [UInt64: String] = [:]
    private var nextSeqToOutput: UInt64 = 0
    private var currentSeq: UInt64 = 0
    /// Monotonically increasing session generation. Incremented on every reset().
    private var sessionGeneration: UInt64 = 0
    /// Number of non-empty texts yielded to the AsyncStream this session.
    /// Used by the bridge to detect when all yielded items have been consumed.
    private var yieldedCount: UInt64 = 0
    let rateLimiter = RateLimiter()

    // Continuations for async streaming
    private var textContinuation: AsyncStream<String>.Continuation?
    private var completionContinuation: CheckedContinuation<Void, Never>?

    /// Lazily-initialized text stream. Only one consumer is supported.
    /// Accessing this property multiple times returns the same stream;
    /// the continuation is bound once on first access.
    private var _textStream: AsyncStream<String>?

    var textStream: AsyncStream<String> {
        if let existing = _textStream {
            return existing
        }
        let stream = AsyncStream<String> { continuation in
            self.textContinuation = continuation
        }
        _textStream = stream
        return stream
    }

    /// Current session generation (for testing/inspection)
    public func currentSessionGeneration() -> UInt64 {
        sessionGeneration
    }

    public func reset() {
        pendingResults.removeAll()
        nextSeqToOutput = 0
        currentSeq = 0
        yieldedCount = 0
        sessionGeneration &+= 1
    }

    /// Get the next sequence number for a new chunk, bound to the current session.
    /// Returns a `TranscriptionTicket` that must be passed back on submit/markFailed.
    public func nextSequence() -> TranscriptionTicket {
        let ticket = TranscriptionTicket(session: sessionGeneration, seq: currentSeq)
        // Using wrapping addition for safety, though overflow is practically impossible
        // UInt64.max = 18,446,744,073,709,551,615 chunks
        currentSeq &+= 1
        return ticket
    }

    public func getPendingCount() -> Int {
        // Safe subtraction - both are UInt64, result fits in Int for practical counts
        let count = currentSeq - nextSeqToOutput
        return count > Int.max ? Int.max : Int(count)
    }

    /// Check if all flushed items have been consumed by the stream consumer.
    /// The bridge passes its consumed count; this returns true only when
    /// the actor has flushed everything AND the consumer has processed all yields.
    public func isFullyDelivered(consumedCount: UInt64) -> Bool {
        pendingResults.isEmpty
            && currentSeq == nextSeqToOutput
            && currentSeq > 0
            && consumedCount >= yieldedCount
    }

    /// Submit a transcription result. Silently discards if the ticket's session
    /// doesn't match the current session (stale result from a previous session).
    public func submitResult(ticket: TranscriptionTicket, text: String) {
        guard ticket.session == sessionGeneration else {
            Logger.transcription.warning("Discarding stale result for seq \(ticket.seq) from session \(ticket.session) (current: \(self.sessionGeneration))")
            return
        }
        if pendingResults.count >= Self.maxPendingResults {
            Logger.transcription.warning("Pending results overflow (\(self.pendingResults.count) items)")
        }
        pendingResults[ticket.seq] = text
        flushReady()
    }

    /// Mark a sequence as failed. Silently discards if the ticket is stale.
    func markFailed(ticket: TranscriptionTicket) {
        guard ticket.session == sessionGeneration else {
            Logger.transcription.warning("Discarding stale failure for seq \(ticket.seq) from session \(ticket.session) (current: \(self.sessionGeneration))")
            return
        }
        pendingResults[ticket.seq] = ""
        flushReady()
    }

    private func flushReady() {
        while let text = pendingResults[nextSeqToOutput] {
            pendingResults.removeValue(forKey: nextSeqToOutput)
            if !text.isEmpty {
                Logger.transcription.info("Output: \(text, privacy: .private)")
                textContinuation?.yield(text)
                yieldedCount &+= 1
            }
            nextSeqToOutput &+= 1
        }

        if pendingResults.isEmpty && currentSeq == nextSeqToOutput && currentSeq > 0 {
            completionContinuation?.resume()
            completionContinuation = nil
        }
    }

    private static let completionTimeoutSeconds: UInt64 = 30

    func waitForCompletion() async {
        if pendingResults.isEmpty && currentSeq == nextSeqToOutput && currentSeq > 0 {
            return
        }

        // Schedule a timeout to prevent indefinite hang if flushReady() never fires
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(Self.completionTimeoutSeconds))
            if self.completionContinuation != nil {
                Logger.transcription.warning("waitForCompletion timed out after \(Self.completionTimeoutSeconds)s")
                self.completionContinuation?.resume()
                self.completionContinuation = nil
            }
        }

        await withCheckedContinuation { continuation in
            self.completionContinuation = continuation
        }

        timeoutTask.cancel()
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

/// Bridge adapting the actor-based `TranscriptionQueue` to a callback API
/// for `RecordingController`, which dispatches text via `TextInserter` callbacks.
@MainActor
public final class TranscriptionQueueBridge {
    let queue = TranscriptionQueue()
    private var streamTask: Task<Void, Never>?
    
    /// Guard to prevent onAllComplete from firing multiple times per session.
    /// Reset to false when a new session starts (via reset() or first nextSequence()).
    private var hasSignaledCompletion = false

    /// Track whether a session has started (at least one sequence requested)
    private var sessionStarted = false

    /// Number of texts consumed from the stream this session.
    /// Compared against the actor's yieldedCount to detect unconsumed buffered items.
    private var consumedCount: UInt64 = 0

    public var onTextReady: ((String) -> Void)?
    public var onAllComplete: (() -> Void)?

    public init() {}

    func startListening() {
        streamTask = Task {
            for await text in await queue.textStream {
                self.consumedCount &+= 1
                onTextReady?(text)
                // Check completion AFTER delivering text, ensuring onAllComplete
                // fires only when all text has been passed to the inserter.
                await checkCompletion()
            }
        }
    }

    public func stopListening() {
        streamTask?.cancel()
        streamTask = nil
    }

    public func reset() async {
        await queue.reset()
        hasSignaledCompletion = false
        sessionStarted = false
        consumedCount = 0
    }

    public func nextSequence() async -> TranscriptionTicket {
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

    public func submitResult(ticket: TranscriptionTicket, text: String) async {
        await queue.submitResult(ticket: ticket, text: text)
    }

    func markFailed(ticket: TranscriptionTicket) async {
        await queue.markFailed(ticket: ticket)
    }

    public func checkCompletion() async {
        // Guard: only fire completion once per session
        guard !hasSignaledCompletion else { return }
        guard sessionStarted else { return }

        let delivered = await queue.isFullyDelivered(consumedCount: consumedCount)
        if delivered {
            // Double-check after await (another task may have set it during suspension)
            guard !hasSignaledCompletion else { return }
            hasSignaledCompletion = true
            onAllComplete?()
        }
    }
}
