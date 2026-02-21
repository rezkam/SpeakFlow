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
            defer {
                self?.processingTasks.removeValue(forKey: taskId)
            }

            let effectiveTimeout = TranscriptionService.timeout(forDataSize: chunk.wavData.count)
            let duration = String(format: "%.1f", chunk.durationSeconds)
            let timeout = String(format: "%.1f", effectiveTimeout)
            // swiftlint:disable:next line_length
            Logger.transcription.debug("Sending chunk #\(ticket.seq) session=\(ticket.session) duration=\(duration)s size=\(chunk.wavData.count)B (timeout: \(timeout)s)")

            // Track API call attempt
            self?.statistics.recordApiCall()

            do {
                let text = try await self?.service.transcribe(audio: chunk.wavData) ?? ""
                Logger.transcription.info("Chunk #\(ticket.seq) success: \(text, privacy: .private)")

                // Track successful transcription statistics
                self?.statistics.recordTranscription(text: text, audioDurationSeconds: chunk.durationSeconds)

                await self?.queueBridge.submitResult(ticket: ticket, text: text)
                // Note: checkCompletion is called from the stream consumer (startListening)
                // AFTER onTextReady delivers the text, ensuring the completion sound
                // only plays after all text has been queued for insertion.
            } catch {
                if Self.isCancellation(error) {
                    Logger.transcription.debug("Chunk #\(ticket.seq) cancelled")
                    await self?.queueBridge.markFailed(ticket: ticket)
                    await self?.queueBridge.checkCompletion()
                    return
                }

                Logger.transcription.error("Chunk #\(ticket.seq) failed: \(error.localizedDescription)")
                await self?.queueBridge.markFailed(ticket: ticket)

                // Play error sound to notify user that transcription failed
#if DEBUG
                self?.testErrorSoundPlayCount &+= 1
#endif
                SoundEffect.error.play()

                // Failed chunks don't yield text to the stream, so check completion
                // here — the stream consumer won't see this chunk.
                await self?.queueBridge.checkCompletion()
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
}

extension Transcription: TranscriptionCoordinating {}

#if DEBUG
extension Transcription {
    var _testErrorSoundPlayCount: Int { testErrorSoundPlayCount }
}
#endif
