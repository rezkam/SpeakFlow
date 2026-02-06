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

    public func transcribe(seq: UInt64, chunk: AudioChunk) {
        // P1 Security: Use UUID to track and clean up tasks to prevent memory leak
        let taskId = UUID()
        let task = Task { [weak self] in
            defer {
                // Clean up this task when complete
                Task { @MainActor in
                    self?.processingTasks.removeValue(forKey: taskId)
                }
            }

            Logger.transcription.debug("Sending chunk #\(seq) (timeout: \(Config.timeout)s)")

            // Track API call attempt
            Statistics.shared.recordApiCall()

            do {
                let text = try await TranscriptionService.shared.transcribe(audio: chunk.audioData, mimeType: chunk.mimeType)
                Logger.transcription.info("Chunk #\(seq) success: \(text, privacy: .private)")

                // Track successful transcription statistics
                Statistics.shared.recordTranscription(text: text, audioDurationSeconds: chunk.durationSeconds)

                await self?.queueBridge.submitResult(seq: seq, text: text)
            } catch {
                Logger.transcription.error("Chunk #\(seq) failed: \(error.localizedDescription)")
                await self?.queueBridge.markFailed(seq: seq)
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
        Task {
            await TranscriptionService.shared.cancelAll()
        }
    }
}
