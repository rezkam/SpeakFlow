import Foundation
import OSLog

/// Ticket that binds a sequence number to a specific session generation.
/// This prevents stale async results from session N being accepted after
/// a reset for session N+1 (even if sequence numbers collide).
public struct TranscriptionTicket: Sendable, Equatable {
    public let session: UInt64
    public let seq: UInt64
}

/// Text yielded by `TranscriptionQueue`, tagged with the session that produced
/// it so a consumer can drop text buffered before a reset.
struct SessionText: Sendable {
    let session: UInt64
    let text: String
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

    // Continuations for async streaming
    private var textContinuation: AsyncStream<SessionText>.Continuation?

    /// Lazily-initialized text stream. Only one consumer is supported.
    /// Accessing this property multiple times returns the same stream;
    /// the continuation is bound once on first access.
    private var _textStream: AsyncStream<SessionText>?

    var textStream: AsyncStream<SessionText> {
        if let existing = _textStream {
            return existing
        }
        let stream = AsyncStream<SessionText> { continuation in
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

    func resetForDelivery() -> UInt64 {
        reset()
        return sessionGeneration
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

    /// A retired caller receives a retired ticket without consuming current work.
    func nextSequence(in requestedSession: UInt64) -> TranscriptionTicket {
        guard requestedSession == sessionGeneration else {
            return TranscriptionTicket(session: requestedSession, seq: 0)
        }
        return nextSequence()
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

    /// True when no ticket is outstanding and the consumer has taken every
    /// text yielded this session.
    func isIdle(consumedCount: UInt64) -> Bool {
        pendingResults.isEmpty && currentSeq == nextSeqToOutput && consumedCount >= yieldedCount
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
                textContinuation?.yield(SessionText(session: sessionGeneration, text: text))
                yieldedCount &+= 1
            }
            nextSeqToOutput &+= 1
        }
    }

    func finishStream() {
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
    
    /// Signal once per idle transition, rearming whenever new work is allocated.
    private var hasSignaledCompletion = false
    private var workRevision: UInt64 = 0
    private var pendingAllocations = 0
    private var deliveryRevision: UInt64 = 0
    private var acceptedQueueSession: UInt64? = 0
    private var allocationSession: UInt64 = 0

    /// Track whether a session has started (at least one sequence requested)
    private var sessionStarted = false

    /// Number of texts consumed from the stream this session.
    /// Compared against the actor's yieldedCount to detect unconsumed buffered items.
    private var consumedCount: UInt64 = 0

    public var onTextReady: ((String) -> Void)?
    public var onAllComplete: (() -> Void)?
    /// Called on the main actor when a chunk fails with a non-cancellation error.
    /// The error is passed so the UI can show targeted guidance.
    public var onChunkError: ((Error) -> Void)?

    public init() {}

    #if DEBUG
    var beforeTextDeliveryForTesting: (@MainActor () async -> Void)?
    var beforeSequenceAllocationForTesting: (@MainActor () async -> Void)?
    #endif

    func startListening() {
        streamTask = Task {
            for await item in await queue.textStream {
                // Text buffered before a reset belongs to a finished session;
                // delivering it would type it into the next recording.
                #if DEBUG
                await beforeTextDeliveryForTesting?()
                #endif
                // Validation and callback are one synchronous MainActor operation.
                // No actor-hop snapshot may authorize text after cancellation/reset.
                guard !Task.isCancelled, item.session == acceptedQueueSession else { continue }
                self.consumedCount &+= 1
                onTextReady?(item.text)
                // Check completion AFTER delivering text, ensuring onAllComplete
                // fires only when all text has been passed to the inserter.
                await checkCompletion()
            }
        }
    }

    /// Synchronous consumer-side ownership check, including cancellation.
    func accepts(_ ticket: TranscriptionTicket) -> Bool {
        acceptedQueueSession == ticket.session
    }

    public func stopListening() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Immediately retires buffered delivery, even before actor reset can run.
    public func invalidateDelivery() {
        acceptedQueueSession = nil
        deliveryRevision &+= 1
        pendingAllocations = 0
        workRevision &+= 1
        hasSignaledCompletion = false
        sessionStarted = false
        consumedCount = 0
    }

    public func reset() async {
        invalidateDelivery()
        let revision = deliveryRevision
        let generation = await queue.resetForDelivery()
        guard deliveryRevision == revision else { return }
        acceptedQueueSession = generation
        allocationSession = generation
    }

    public func nextSequence() async -> TranscriptionTicket {
        let requestedSession = allocationSession
        let revision = deliveryRevision
        workRevision &+= 1
        sessionStarted = true
        hasSignaledCompletion = false
        pendingAllocations += 1
        defer {
            if deliveryRevision == revision { pendingAllocations -= 1 }
        }
        #if DEBUG
        await beforeSequenceAllocationForTesting?()
        #endif
        return await queue.nextSequence(in: requestedSession)
    }

    public func getPendingCount() async -> Int {
        await queue.getPendingCount()
    }

    /// True when every ticket of this session is transcribed and its text
    /// has been delivered through `onTextReady`.
    public func isIdle() async -> Bool {
        guard pendingAllocations == 0 else { return false }
        // Retired delivery has no work in the current recording. In particular,
        // stop-before-start need not wait for an actor reset that never began.
        guard acceptedQueueSession != nil else { return true }
        let revision = workRevision
        let idle = await queue.isIdle(consumedCount: consumedCount)
        return idle && workRevision == revision && pendingAllocations == 0
    }

    public func submitResult(ticket: TranscriptionTicket, text: String) async {
        await queue.submitResult(ticket: ticket, text: text)
    }

    func markFailed(ticket: TranscriptionTicket) async {
        await queue.markFailed(ticket: ticket)
    }

    public func checkCompletion() async {
        guard acceptedQueueSession != nil, !hasSignaledCompletion,
              sessionStarted, pendingAllocations == 0 else { return }
        let revision = workRevision
        let delivered = await queue.isFullyDelivered(consumedCount: consumedCount)
        if delivered {
            // New allocations or resets invalidate a suspended completion check.
            guard !hasSignaledCompletion, workRevision == revision, pendingAllocations == 0 else { return }
            hasSignaledCompletion = true
            onAllComplete?()
        }
    }
}
