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
        // P1 Security: Use UUID to track and clean up tasks to prevent memory leak
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
            await self?.statistics.recordApiCall()

            do {
                let text = try await self?.service.transcribe(audio: chunk.wavData) ?? ""
                Logger.transcription.info("Chunk #\(ticket.seq) success: \(text, privacy: .private)")

                // Track successful transcription statistics
                await self?.statistics.recordTranscription(text: text, audioDurationSeconds: chunk.durationSeconds)

                await self?.queueBridge.submitResult(ticket: ticket, text: text)
            } catch {
                Logger.transcription.error("Chunk #\(ticket.seq) failed: \(error.localizedDescription)")
                await self?.queueBridge.markFailed(ticket: ticket)
                
                // Play error sound to notify user that transcription failed
                await SoundEffect.error.play()
            }

            await self?.queueBridge.checkCompletion()
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
}

extension Transcription: TranscriptionCoordinating {}
