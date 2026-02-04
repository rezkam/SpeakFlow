import Foundation
import OSLog

/// Main coordinator for transcription operations (MainActor for UI updates)
@MainActor
final class Transcription {
    static let shared = Transcription()

    let queueBridge = TranscriptionQueueBridge()
    private var processingTasks: [Task<Void, Never>] = []

    var queue: TranscriptionQueueBridge { queueBridge }

    private init() {
        queueBridge.startListening()
    }

    func transcribe(seq: UInt64, audio: Data) {
        let task = Task {
            Logger.transcription.debug("Sending chunk #\(seq) (timeout: \(Config.timeout)s)")

            do {
                let text = try await TranscriptionService.shared.transcribe(audio: audio)
                Logger.transcription.info("Chunk #\(seq) success: \(text, privacy: .private)")
                await queueBridge.submitResult(seq: seq, text: text)
            } catch {
                Logger.transcription.error("Chunk #\(seq) failed: \(error.localizedDescription)")
                await queueBridge.markFailed(seq: seq)
            }

            await queueBridge.checkCompletion()
        }
        processingTasks.append(task)
    }

    func cancelAll() {
        for task in processingTasks {
            task.cancel()
        }
        processingTasks.removeAll()
        Task {
            await TranscriptionService.shared.cancelAll()
        }
    }
}
