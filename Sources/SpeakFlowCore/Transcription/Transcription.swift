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
    /// When set, batch transcription dispatches through this provider instead of the
    /// default `service` (which is ChatGPT-only). Set by RecordingController at the
    /// start of each batch session and cleared on stop/cancel.
    private var activeBatchProvider: (any BatchTranscriptionProvider)?
    private var metricsSessionId: UUID?
#if DEBUG
    private var testErrorSoundPlayCount = 0
#endif

    var queue: TranscriptionQueueBridge { queueBridge }

    private func observabilityEvent(
        _ name: String,
        level: ObservabilityEventLevel = .info,
        sessionId: UUID? = nil,
        metadata: @autoclosure () -> [String: String] = [:]
    ) {
        let settings = Settings.shared
        guard settings.observabilityEnabled,
              settings.observabilityVerbosity.includes(level) else { return }
        let id = sessionId ?? metricsSessionId
        let payload = metadata()
        Task {
            await ObservabilityStore.shared.record(
                component: "Transcription",
                name: name,
                level: level,
                sessionId: id,
                metadata: payload
            )
        }
    }

    private func metadataForText(_ text: String) -> [String: String] {
        var metadata: [String: String] = [
            "textChars": String(text.count),
            "textWords": String(text.split(whereSeparator: \.isWhitespace).count),
            "textFingerprint": ObservabilityFingerprint.sha256(text)
        ]
        if Settings.shared.observabilityCaptureTextPayloads {
            metadata["text"] = text
        }
        return metadata
    }

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
        observabilityEvent(
            "chunk_submitted",
            level: .debug,
            metadata: [
                "taskId": taskId.uuidString,
                "ticketSeq": String(ticket.seq),
                "ticketSession": String(ticket.session),
                "bytes": String(chunk.wavData.count),
                "durationSeconds": String(format: "%.3f", chunk.durationSeconds)
            ]
        )
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
                let text: String
                if let batchProvider = self.activeBatchProvider {
                    text = try await batchProvider.transcribe(audio: chunk.wavData)
                } else {
                    text = try await service.transcribe(audio: chunk.wavData)
                }
                let latencySeconds = Self.elapsedSeconds(since: latencyStart)
                statistics.recordSTTLatency(seconds: latencySeconds)
                if let metricsId {
                    await SessionMetricsStore.shared.recordSTTLatency(
                        sessionId: metricsId,
                        milliseconds: latencySeconds * 1000
                    )
                    await SessionMetricsStore.shared.incrementChunkSucceeded(sessionId: metricsId)
                }
                self.observabilityEvent(
                    "chunk_succeeded",
                    level: .info,
                    sessionId: metricsId,
                    metadata: [
                        "taskId": taskId.uuidString,
                        "ticketSeq": String(ticket.seq),
                        "latencyMs": String(format: "%.2f", latencySeconds * 1000)
                    ].merging(self.metadataForText(text), uniquingKeysWith: { _, new in new })
                )
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
                    self.observabilityEvent(
                        "chunk_cancelled",
                        level: .warning,
                        sessionId: metricsId,
                        metadata: [
                            "taskId": taskId.uuidString,
                            "ticketSeq": String(ticket.seq)
                        ]
                    )
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
                self.observabilityEvent(
                    "chunk_failed",
                    level: .error,
                    sessionId: metricsId,
                    metadata: [
                        "taskId": taskId.uuidString,
                        "ticketSeq": String(ticket.seq),
                        "latencyMs": String(format: "%.2f", latencySeconds * 1000),
                        "error": error.localizedDescription
                    ]
                )
                await queueBridge.markFailed(ticket: ticket)

                // Play error sound to notify user that transcription failed
#if DEBUG
                testErrorSoundPlayCount &+= 1
#endif
                SoundEffect.error.play()

                // Notify UI so it can show an actionable error banner
                self.queueBridge.onChunkError?(error)

                // Failed chunks don't yield text to the stream, so check completion
                // here — the stream consumer won't see this chunk.
                await queueBridge.checkCompletion()
            }
        }
        processingTasks[taskId] = task
    }

    public func cancelAll() {
        observabilityEvent(
            "cancel_all_requested",
            level: .warning,
            metadata: ["activeTaskCount": String(processingTasks.count)]
        )
        for task in processingTasks.values {
            task.cancel()
        }
        processingTasks.removeAll()
        activeBatchProvider = nil
        // Note: Individual transcription tasks are tracked here in processingTasks.
        // Cancelling them above is sufficient — the underlying URLSession requests
        // will be cancelled via cooperative Task cancellation.
    }

    /// Set the batch provider to use for transcription dispatch.
    /// When set, chunks are sent to this provider instead of the default ChatGPT service.
    /// Pass `nil` to revert to the default service.
    public func setActiveBatchProvider(_ provider: (any BatchTranscriptionProvider)?) {
        let providerId = provider?.id ?? "nil"
        observabilityEvent(
            "active_batch_provider_set",
            level: .debug,
            metadata: ["providerId": providerId]
        )
        activeBatchProvider = provider
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
        observabilityEvent(
            "metrics_session_set",
            level: .debug,
            sessionId: sessionId,
            metadata: ["hasSession": sessionId == nil ? "false" : "true"]
        )
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
