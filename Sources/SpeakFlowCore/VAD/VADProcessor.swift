import Foundation
import OSLog
import FluidAudio

// MARK: - Shared VAD Model Cache

/// Caches the expensive-to-load Silero VAD CoreML model so it is only loaded once.
///
/// On first launch the model may even need to be downloaded from HuggingFace,
/// and CoreML compilation adds latency on every cold start.  Call
/// `VADModelCache.shared.warmUp()` at app launch so subsequent
/// `VADProcessor.initialize()` calls are near-instant.
public actor VADModelCache {
    public static let shared = VADModelCache()

    private var cachedManager: VadManager?
    private var cachedThreshold: Float?
    private var warmUpTask: Task<VadManager, Error>?
    /// Threshold the current warm-up task was started with.
    /// Checked in getManager to avoid returning a manager with the wrong threshold.
    private var warmUpThreshold: Float = Config.vadThreshold
    private let logger = Logger(subsystem: "SpeakFlow", category: "VADCache")

    /// Pre-load the Silero VAD model in the background.
    /// Safe to call multiple times — concurrent callers coalesce into one load.
    public func warmUp(threshold: Float = Config.vadThreshold) {
        guard cachedManager == nil, warmUpTask == nil else { return }

        warmUpThreshold = threshold
        warmUpTask = Task {
            do {
                let start = Date()
                logger.info("VAD model warm-up starting")
                let config = VadConfig(defaultThreshold: threshold)
                let manager = try await VadManager(config: config)
                let elapsed = Date().timeIntervalSince(start)
                logger.info("VAD model warm-up complete in \(String(format: "%.2f", elapsed))s")
                self.cachedManager = manager
                self.cachedThreshold = threshold
                self.warmUpTask = nil
                return manager
            } catch {
                // Clear the failed task so subsequent warmUp()/getManager() calls
                // can retry instead of being permanently stuck on the failed task.
                self.warmUpTask = nil
                logger.error("VAD model warm-up failed: \(error.localizedDescription). Will retry on next attempt.")
                throw error
            }
        }
    }

    /// Get a cached or freshly-loaded VadManager.
    /// Invalidates the cache when the threshold changes.
    func getManager(threshold: Float) async throws -> VadManager {
        if let cached = cachedManager, cachedThreshold == threshold {
            return cached
        }

        // Threshold changed — invalidate stale cache
        if cachedThreshold != nil && cachedThreshold != threshold {
            logger.info("VAD threshold changed, reloading model")
            cachedManager = nil
            cachedThreshold = nil
            warmUpTask?.cancel()
            warmUpTask = nil
        }

        // Await warm-up only if threshold matches
        if let pending = warmUpTask {
            if warmUpThreshold == threshold {
                let manager = try await pending.value
                return manager
            } else {
                pending.cancel()
                warmUpTask = nil
            }
        }

        // Cold path — load on demand, coalescing concurrent callers via warmUpTask
        logger.warning("VAD model loaded on demand (no warm-up)")
        let task = Task {
            let config = VadConfig(defaultThreshold: threshold)
            let manager = try await VadManager(config: config)
            self.cachedManager = manager
            self.cachedThreshold = threshold
            self.warmUpTask = nil
            return manager
        }
        warmUpTask = task
        warmUpThreshold = threshold
        return try await task.value
    }
}

/// Voice Activity Detection processor using Silero VAD via FluidAudio
public actor VADProcessor {
    private var vadManager: VadManager?
    private var streamState: VadStreamState?
    private var isInitialized = false
    private let config: VADConfiguration
    private let logger = Logger(subsystem: "SpeakFlow", category: "VAD")

    public private(set) var isSpeaking = false
    public private(set) var lastSpeechEndTime: Date?
    public private(set) var lastSpeechStartTime: Date?

    private var cumulativeSpeechProbability: Float = 0
    private var processedChunks: Int = 0

    public init(config: VADConfiguration = .default) {
        self.config = config
    }

    public static var isAvailable: Bool { PlatformSupport.supportsVAD }

    public func initialize() async throws {
        guard !isInitialized else { return }
        guard PlatformSupport.supportsVAD else {
            throw VADError.unsupportedPlatform(PlatformSupport.vadUnavailableReason ?? "Unsupported")
        }

        do {
            // Use shared cached model instead of loading fresh each time
            vadManager = try await VADModelCache.shared.getManager(threshold: config.threshold)
            streamState = await vadManager?.makeStreamState()
            isInitialized = true
            logger.info("VAD initialized with FluidAudio Silero on \(PlatformSupport.platformDescription)")
        } catch {
            throw VADError.processingFailed("Failed to initialize VAD: \(error.localizedDescription)")
        }
    }

    public func processChunk(_ samples: [Float]) async throws -> VADResult {
        guard isInitialized, let manager = vadManager, let state = streamState else {
            throw VADError.notInitialized
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // Use user-configured segmentation timings while keeping threshold from VadManager config.
            // IMPORTANT: Do NOT set negativeThreshold to config.threshold here.
            // In FluidAudio, negativeThreshold is used to derive the *positive* threshold via +offset,
            // which would unintentionally raise threshold and cause false speech-end detections.
            var segmentationConfig = VadSegmentationConfig.default
            segmentationConfig.minSpeechDuration = TimeInterval(config.minSpeechDuration)
            segmentationConfig.minSilenceDuration = TimeInterval(config.minSilenceAfterSpeech)

            let result = try await manager.processStreamingChunk(
                samples,
                state: state,
                config: segmentationConfig,
                returnSeconds: true,
                timeResolution: 2
            )

            streamState = result.state
            processedChunks += 1
            cumulativeSpeechProbability += result.probability

            var speechEvent: SpeechEvent?

            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    isSpeaking = true
                    lastSpeechStartTime = Date()
                    speechEvent = .started(at: event.time ?? Double(processedChunks) * 0.032)
                    logger.debug("Speech started at \(event.time ?? 0)s")
                case .speechEnd:
                    isSpeaking = false
                    lastSpeechEndTime = Date()
                    speechEvent = .ended(at: event.time ?? Double(processedChunks) * 0.032)
                    logger.debug("Speech ended at \(event.time ?? 0)s")
                }
            }

            let processingTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            return VADResult(
                probability: result.probability,
                isSpeaking: isSpeaking,
                event: speechEvent,
                processingTimeMs: processingTime
            )
        } catch {
            throw VADError.processingFailed("VAD processing failed: \(error.localizedDescription)")
        }
    }

    public func resetChunk() async {
        cumulativeSpeechProbability = 0
        processedChunks = 0
    }

    public func resetSession() async {
        await resetChunk()
        isSpeaking = false
        lastSpeechEndTime = nil
        lastSpeechStartTime = nil
        // Reset stream state for new session
        if let manager = vadManager {
            streamState = await manager.makeStreamState()
        }
    }

    public var averageSpeechProbability: Float {
        processedChunks > 0 ? cumulativeSpeechProbability / Float(processedChunks) : 0
    }

    public func hasSignificantSpeech(threshold: Float = 0.3) -> Bool {
        averageSpeechProbability >= threshold
    }

    public var currentSilenceDuration: TimeInterval? {
        guard !isSpeaking, let lastEnd = lastSpeechEndTime else { return nil }
        return Date().timeIntervalSince(lastEnd)
    }
}

#if DEBUG
extension VADProcessor {
    public func _testSeedAverageSpeechProbability(_ value: Float, chunks: Int = 1) {
        processedChunks = max(chunks, 0)
        cumulativeSpeechProbability = max(chunks, 0) > 0 ? value * Float(chunks) : 0
    }
}
#endif
