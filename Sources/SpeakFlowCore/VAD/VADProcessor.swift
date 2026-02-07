import Foundation
import OSLog
import FluidAudio

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
            let vadConfig = VadConfig(defaultThreshold: config.threshold)
            vadManager = try await VadManager(config: vadConfig)
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
