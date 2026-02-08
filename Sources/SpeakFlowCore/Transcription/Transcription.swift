import AppKit
import Foundation
import OSLog

/// Main coordinator for transcription operations (MainActor for UI updates)
@MainActor
public final class Transcription {
    public static let shared = Transcription()

    public let queueBridge = TranscriptionQueueBridge()
    private var processingTasks: [UUID: Task<Void, Never>] = [:]

    var queue: TranscriptionQueueBridge { queueBridge }

    private init() {
        queueBridge.startListening()
    }

    public func transcribe(ticket: TranscriptionTicket, chunk: AudioChunk) {
        // P1 Security: Use UUID to track and clean up tasks to prevent memory leak
        let taskId = UUID()
        let task = Task { [weak self] in
            defer {
                // Clean up this task when complete
                Task { @MainActor in
                    self?.processingTasks.removeValue(forKey: taskId)
                }
            }

            let effectiveTimeout = TranscriptionService.timeout(forDataSize: chunk.wavData.count)
            Logger.transcription.debug("Sending chunk #\(ticket.seq) session=\(ticket.session) duration=\(String(format: "%.1f", chunk.durationSeconds))s size=\(chunk.wavData.count)B (timeout: \(String(format: "%.1f", effectiveTimeout))s)")

            // Track API call attempt
            Statistics.shared.recordApiCall()

            do {
                let text = try await TranscriptionService.shared.transcribe(audio: chunk.wavData)
                Logger.transcription.info("Chunk #\(ticket.seq) success: \(text, privacy: .private)")

                // Track successful transcription statistics
                Statistics.shared.recordTranscription(text: text, audioDurationSeconds: chunk.durationSeconds)

                await self?.queueBridge.submitResult(ticket: ticket, text: text)
            } catch {
                Logger.transcription.error("Chunk #\(ticket.seq) failed: \(error.localizedDescription)")
                await self?.queueBridge.markFailed(ticket: ticket)
                
                // Play error sound to notify user that transcription failed
                _ = await MainActor.run {
                    NSSound(named: "Basso")?.play()
                }
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
