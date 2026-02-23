import Foundation
import OSLog

/// Main coordinator for transcription operations (MainActor for UI updates)
@MainActor
public final class Transcription {
    public static let shared = Transcription()

    public let queueBridge = TranscriptionQueueBridge()
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private let statistics: any StatisticsProviding
    private let service: any TranscriptionServiceProviding
    private var metricsSessionId: UUID?
#if DEBUG
    private var testErrorSoundPlayCount = 0
#endif

    var queue: TranscriptionQueueBridge { queueBridge }

    public init(
        statistics: any StatisticsProviding = Statistics.shared,
        service: any TranscriptionServiceProviding = TranscriptionService.shared
    ) {
        self.statistics = statistics
        self.service = service
        queueBridge.startListening()
    }

    public func transcribe(ticket: TranscriptionTicket, chunk: AudioChunk) {
        // Use stable task IDs so each async task is removed from tracking on completion.
        let taskId = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.processingTasks.removeValue(forKey: taskId)
            }

            let effectiveTimeout = TranscriptionService.timeout(forDataSize: chunk.wavData.count)
            let duration = String(format: "%.1f", chunk.durationSeconds)
            let timeout = String(format: "%.1f", effectiveTimeout)
            // swiftlint:disable:next line_length
            Logger.transcription.debug("Sending chunk #\(ticket.seq) session=\(ticket.session) duration=\(duration)s size=\(chunk.wavData.count)B (timeout: \(timeout)s)")

            // Track API call attempt
            statistics.recordApiCall()
            let metricsId = metricsSessionId
            if let metricsId {
                await SessionMetricsStore.shared.incrementChunkSubmitted(sessionId: metricsId)
            }

            let latencyStart = ContinuousClock.now

            do {
                let text = try await service.transcribe(audio: chunk.wavData)
                let latencySeconds = Self.elapsedSeconds(since: latencyStart)
                statistics.recordSTTLatency(seconds: latencySeconds)
                if let metricsId {
                    await SessionMetricsStore.shared.recordSTTLatency(
                        sessionId: metricsId,
                        milliseconds: latencySeconds * 1000
                    )
                    await SessionMetricsStore.shared.incrementChunkSucceeded(sessionId: metricsId)
                }
                Logger.transcription.info("Chunk #\(ticket.seq) success: \(text, privacy: .private)")

                // Track successful transcription statistics
                statistics.recordTranscription(text: text, audioDurationSeconds: chunk.durationSeconds)

                await queueBridge.submitResult(ticket: ticket, text: text)
                // Note: checkCompletion is called from the stream consumer (startListening)
                // AFTER onTextReady delivers the text, ensuring the completion sound
                // only plays after all text has been queued for insertion.
            } catch {
                if Self.isCancellation(error) {
                    Logger.transcription.debug("Chunk #\(ticket.seq) cancelled")
                    await queueBridge.markFailed(ticket: ticket)
                    await queueBridge.checkCompletion()
                    return
                }

                let latencySeconds = Self.elapsedSeconds(since: latencyStart)
                statistics.recordSTTLatency(seconds: latencySeconds)
                if let metricsId {
                    await SessionMetricsStore.shared.recordSTTLatency(
                        sessionId: metricsId,
                        milliseconds: latencySeconds * 1000
                    )
                    await SessionMetricsStore.shared.incrementChunkFailed(sessionId: metricsId)
                }

                Logger.transcription.error("Chunk #\(ticket.seq) failed: \(error.localizedDescription)")
                await queueBridge.markFailed(ticket: ticket)

                // Play error sound to notify user that transcription failed
#if DEBUG
                testErrorSoundPlayCount &+= 1
#endif
                SoundEffect.error.play()

                // Failed chunks don't yield text to the stream, so check completion
                // here — the stream consumer won't see this chunk.
                await queueBridge.checkCompletion()
            }
        }
        processingTasks[taskId] = task
    }

    public func cancelAll() {
        for task in processingTasks.values {
            task.cancel()
        }
        processingTasks.removeAll()
        // Note: Individual transcription tasks are tracked here in processingTasks.
        // Cancelling them above is sufficient — the underlying URLSession requests
        // will be cancelled via cooperative Task cancellation.
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let transcriptionError = error as? TranscriptionError,
           case .cancelled = transcriptionError {
            return true
        }
        return false
    }

    public func setMetricsSession(_ sessionId: UUID?) {
        metricsSessionId = sessionId
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return TimeInterval(elapsed.components.seconds)
            + TimeInterval(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

extension Transcription: TranscriptionCoordinating {}

#if DEBUG
// swiftlint:disable identifier_name
extension Transcription {
    var _testErrorSoundPlayCount: Int { testErrorSoundPlayCount }
}
// swiftlint:enable identifier_name
#endif
