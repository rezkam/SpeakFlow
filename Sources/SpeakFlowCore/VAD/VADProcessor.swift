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

// MARK: - VAD Processor

/// Voice Activity Detection processor using Silero VAD via FluidAudio.
///
/// This processor wraps FluidAudio's `VadManager` with three additional reliability
/// features:
///
/// **1. Periodic Silero State Reset** (prevents drift in long sessions)
///   Silero's LSTM hidden state accumulates context indefinitely. In sessions longer
///   than ~5 min, this causes probability drift. We reset the model's hidden state
///   every 5 seconds while preserving the segmentation state machine.
///   See: `VADConfiguration.stateResetInterval`.
///
/// **2. Exponential Volume Smoothing** (tames transient spikes)
///   Raw per-frame RMS spikes on clicks and pops. Smoothing with factor 0.2 means
///   each new frame contributes only 20% — transients decay within ~5 frames.
///   See: `VADConfiguration.volumeSmoothingFactor`.
///
/// **3. Volume Gate for speechStart** (blocks non-vocal triggers)
///   Silero analyzes spectral patterns, not loudness. A keyboard tap can push
///   probability above our 0.15 threshold. The volume gate requires BOTH high
///   probability AND sufficient smoothed RMS before forwarding a speechStart event.
///   See: `VADConfiguration.volumeGateEnabled`.
public actor VADProcessor {
    private var vadManager: VadManager?
    private var streamState: VadStreamState?
    private var isInitialized = false
    private let config: VADConfiguration
    private let logger = Logger(subsystem: "SpeakFlow", category: "VAD")

    // MARK: - Mock Backend (test-only)
    //
    // When set, processChunk() bypasses FluidAudio/Silero entirely and instead
    // calls mockBackend.next() to get a scripted (probability, isSpeaking, rms) triple.
    //
    // The key insight: our gate/smoothing/reset LOGIC tests must not depend on
    // Silero's non-deterministic output. By injecting scripted frames we can
    // encode exact scenarios:
    //   - "30 quiet frames → 10 drift frames → 30 quiet frames" (tests state reset)
    //   - "20 keyboard clicks (low RMS) → silence" (tests volume gate)
    //   - "1 transient spike → silence" (tests exponential smoothing)
    //
    // Set to nil (the default) to use real Silero inference.
    // Only accessible in DEBUG builds to prevent accidental use in production.
    #if DEBUG
    var mockBackend: MockVADBackend?
    #endif

    // MARK: - Public State

    public private(set) var isSpeaking = false
    public private(set) var lastSpeechEndTime: Date?
    public private(set) var lastSpeechStartTime: Date?

    // MARK: - Speech Probability Accumulator (for skip-silent-chunk decisions)

    private var cumulativeSpeechProbability: Float = 0
    private var processedChunks: Int = 0

    // MARK: - Volume Smoothing State (Feature 2 + 3)

    /// Running exponentially-smoothed RMS of the audio signal.
    ///
    /// Starts at 0 at session start and converges to the true ambient level within
    /// ~15–20 frames (~750ms–1s). Resets to 0 on `resetSession()` so each
    /// recording session starts from a clean volume baseline.
    ///
    /// WHY: Raw per-frame RMS spikes on transients (clicks, pops, keyboard sounds).
    /// Smoothing with factor 0.2 means a single spike contributes only 20% to this
    /// value, decaying over ~5 frames (~250ms). Only sustained loudness — which is
    /// characteristic of human speech — moves this value above the threshold.
    ///
    /// Updated via exponential smoothing every frame; see ``processChunk(_:)``.
    private var smoothedVolume: Float = 0

    // MARK: - Periodic State Reset State (Feature 1)

    /// Timestamp of the last Silero hidden-state reset.
    ///
    /// WHY: We track this to implement periodic resets. The actor isolation means
    /// Date() reads happen synchronously in the actor's serial executor — no race.
    private var lastStreamStateRefresh: Date = Date()

    /// Whether the last reset attempt was deferred (triggered=true). Used to log
    /// the deferral once instead of on every frame while the interval is overdue.
    private var resetDeferralLogged = false

    // MARK: - Init

    public init(config: VADConfiguration = .default) {
        self.config = config
    }

    public static var isAvailable: Bool { PlatformSupport.supportsVAD }

    // MARK: - Lifecycle

    public func initialize() async throws {
        guard !isInitialized else { return }
        guard PlatformSupport.supportsVAD else {
            throw VADError.unsupportedPlatform(PlatformSupport.vadUnavailableReason ?? "Unsupported")
        }

        do {
            // Use shared cached model instead of loading fresh each time
            vadManager = try await VADModelCache.shared.getManager(threshold: config.threshold)
            streamState = await vadManager?.makeStreamState()
            lastStreamStateRefresh = Date()
            isInitialized = true
            logger.info("""
                VAD initialized on \(PlatformSupport.platformDescription, privacy: .public) \
                [threshold=\(self.config.threshold, privacy: .public) \
                volumeGate=\(self.config.volumeGateEnabled, privacy: .public) \
                minVol=\(self.config.minVolumeForSpeech, privacy: .public) \
                resetInterval=\(self.config.stateResetInterval, privacy: .public)s]
                """)
        } catch {
            throw VADError.processingFailed("Failed to initialize VAD: \(error.localizedDescription)")
        }
    }

    // MARK: - Core Processing

    /// Process a chunk of audio samples and return VAD state.
    ///
    /// This method applies the three reliability features in order:
    ///   1. Periodic Silero state reset (prevent long-session drift)
    ///   2. Exponential RMS smoothing (tame transient spikes)
    ///   3. Volume gate on speechStart (block non-vocal triggers)
    ///
    /// - Parameter samples: Float32 PCM audio at 16 kHz mono.
    /// - Returns: `VADResult` with probability, speaking state, optional event,
    ///            processing time, and the smoothed volume used in the gate check.
    public func processChunk(_ samples: [Float]) async throws -> VADResult {
        // ── Mock backend fast-path (test mode only) ────────────────────────────
        //
        // When a MockVADBackend is injected, we skip FluidAudio/Silero entirely.
        // The mock provides scripted (probability, isSpeaking, instantRMS) values.
        // We still run our OWN logic (smoothing, volume gate) on the injected data
        // so the tests are testing OUR code, not Silero's output.
        //
        // The guard at the bottom is bypassed intentionally — mock tests do not
        // need to call initialize() first, which avoids loading CoreML in tests.
        #if DEBUG
        if let mock = mockBackend {
            return try await processChunkMocked(mock)
        }
        #endif

        guard isInitialized, let manager = vadManager, streamState != nil else {
            throw VADError.notInitialized
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // ── Feature 1: Periodic Silero State Reset ────────────────────────
            //
            // WHY: Silero's LSTM/GRU hidden state accumulates from every processed
            // frame. In sessions longer than ~5 min this causes probability drift:
            // the model's baseline shifts toward ambient environmental noise, so it
            // increasingly classifies fan hum or keyboard clicks as speech.
            //
            // SOLUTION: Reset the LSTM hidden state every `stateResetInterval`
            // seconds (default 5s) while PRESERVING the segmentation state.
            //
            // IMPORTANT: Only reset LSTM hidden state when NOT in triggered
            // (speech-active) state. Resetting during active speech causes the
            // model to lose context about the current utterance, and the fresh
            // LSTM h/c vectors can produce high probabilities on silence frames
            // during "warm-up". This clears `tempEndSample` (the in-progress
            // silence tracker), preventing speechEnd from ever firing — the
            // session gets stuck in isUserSpeaking=true permanently.
            //
            // When triggered=false (confirmed silence), resetting is safe and
            // prevents long-session drift. The next speech onset starts with a
            // clean model state that hasn't accumulated ambient noise patterns.
            //
            // processedSamples is always preserved to maintain event timestamp
            // alignment. When triggered=true, the full reset is deferred —
            // it will happen on the first interval check after speechEnd fires.
            guard var currentState = streamState else { throw VADError.notInitialized }

            let now = Date()
            if now.timeIntervalSince(lastStreamStateRefresh) >= config.stateResetInterval {
                if !currentState.triggered {
                    // Safe to reset: no active speech detection in progress.
                    // Reset modelState + tempEndSample (no silence tracking to preserve).
                    let freshModelState = VadState.initial()
                    currentState = VadStreamState(
                        modelState: freshModelState,
                        triggered: false,
                        tempEndSample: nil,
                        processedSamples: currentState.processedSamples
                    )
                    streamState = currentState
                    lastStreamStateRefresh = now
                    resetDeferralLogged = false
                    logger.debug("VAD model state reset (periodic \(self.config.stateResetInterval, privacy: .public)s interval, triggered=false → full reset)")
                } else if !resetDeferralLogged {
                    // Speech active: defer reset to avoid breaking speechEnd detection.
                    // Do NOT advance lastStreamStateRefresh — the reset must fire on
                    // the very first check after triggered goes false. Advancing the
                    // timestamp would restart the interval, potentially postponing the
                    // reset indefinitely in long dictation with short pauses.
                    resetDeferralLogged = true
                    logger.debug("VAD model state reset DEFERRED (triggered=true, speech in progress)")
                }
            }

            // ── Feature 2: Exponential Volume Smoothing ───────────────────────
            //
            // WHY: Raw RMS is computed per 50ms frame. A single loud transient
            // (pop, click, door closing) can spike RMS far above any threshold for
            // exactly one frame. If we used raw RMS in the volume gate (Feature 3),
            // transients would pass the gate despite not being speech.
            //
            // SOLUTION: Exponential smoothing with factor 0.2:
            //   smoothed = smoothed + 0.2 × (rms − smoothed)
            //
            // Effect on a single-frame spike of amplitude A:
            //   frame 0: 0.0 + 0.2 × (A − 0.0) = 0.2A
            //   frame 1: 0.2A + 0.2 × (0 − 0.2A) = 0.16A
            //   frame 2: 0.128A, frame 3: 0.102A, frame 4: 0.082A (< threshold)
            // The spike is effectively gone within 5 frames (~250ms).
            //
            // Effect on sustained speech: converges to within 1% of true RMS in
            // ~21 frames (~1 second). Speech is detected reliably.
            let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
            let instantRMS = samples.isEmpty ? 0 : sqrt(sumSq / Float(samples.count))
            smoothedVolume = expSmoothing(instantRMS, smoothedVolume, config.volumeSmoothingFactor)

            // ── FluidAudio / Silero Inference ─────────────────────────────────
            //
            // Do NOT set negativeThreshold to config.threshold here.
            // In FluidAudio, negativeThreshold is interpreted as an offset that
            // is ADDED to the positive threshold. Setting it to the threshold
            // value would double the effective trigger level, causing missed speech.
            var segmentationConfig = VadSegmentationConfig.default
            segmentationConfig.minSpeechDuration = TimeInterval(config.minSpeechDuration)
            segmentationConfig.minSilenceDuration = TimeInterval(config.minSilenceAfterSpeech)

            let result = try await manager.processStreamingChunk(
                samples,
                state: currentState,
                config: segmentationConfig,
                returnSeconds: true,
                timeResolution: 2
            )

            streamState = result.state
            processedChunks += 1
            cumulativeSpeechProbability += result.probability

            // ── Feature 3: Volume Gate on speechStart ─────────────────────────
            //
            // WHY: Silero analyzes spectral patterns, not loudness. Our threshold
            // of 0.15 is intentionally low to catch soft speech, which means Silero
            // can fire speechStart on non-vocal sounds (keyboard, fan bursts, coughs)
            // that happen to resemble voiced fricatives spectrally.
            //
            // Without a volume check, these false speechStart events:
            //   1. Set `isUserSpeaking = true` in SessionController
            //   2. Block auto-end (guarded by `!isUserSpeaking`)
            //   3. Send silent chunks to the API (wasting money, producing blanks)
            //
            // SOLUTION (dual-gate pattern):
            //   "speaking = confidence >= params.confidence AND volume >= params.min_volume"
            //
            // We require BOTH:
            //   • High Silero probability (already handled by FluidAudio)
            //   • Sufficient smoothed RMS (checked here)
            //
            // IMPORTANT: We only gate speechStart. speechEnd is NOT gated — when
            // the user stops talking and volume drops, that IS the signal to end
            // the turn. Suppressing speechEnd would cause sessions to hang.
            //
            // CRITICAL: When we suppress a speechStart, we must also roll back the
            // segmentation state. FluidAudio sets `triggered=true` when it fires
            // speechStart, and only fires speechStart on the false→true transition.
            // If we drop the event but keep `triggered=true`, later frames in the
            // same turn (even with sufficient volume) will NOT emit speechStart —
            // the state machine is already "triggered". We must reset `triggered`
            // back to false so FluidAudio can re-emit on a future qualifying frame.
            var speechEvent: SpeechEvent?
            var needsStateRollback = false

            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    // Apply volume gate when enabled
                    if config.volumeGateEnabled && smoothedVolume < config.minVolumeForSpeech {
                        // Gate closed: probability fired but volume is too low.
                        // Log the suppression so users/devs can tune the threshold.
                        logger.debug("""
                            VAD speechStart SUPPRESSED by volume gate: \
                            smoothedVol=\(String(format: "%.4f", self.smoothedVolume), privacy: .public) \
                            < minVol=\(self.config.minVolumeForSpeech, privacy: .public) \
                            prob=\(String(format: "%.3f", result.probability), privacy: .public)
                            """)
                        // Roll back triggered state so FluidAudio can re-emit speechStart
                        // on a future frame with sufficient volume.
                        needsStateRollback = true
                    } else {
                        // Gate open: both probability and volume pass. Forward the event.
                        isSpeaking = true
                        lastSpeechStartTime = Date()
                        speechEvent = .started(at: event.time ?? Double(processedChunks) * 0.032)
                        logger.debug("Speech started at \(event.time ?? 0)s vol=\(String(format: "%.4f", self.smoothedVolume))")
                    }

                case .speechEnd:
                    // speechEnd is NOT volume-gated — dropping volume IS the end signal.
                    isSpeaking = false
                    lastSpeechEndTime = Date()
                    speechEvent = .ended(at: event.time ?? Double(processedChunks) * 0.032)
                    logger.debug("Speech ended at \(event.time ?? 0)s vol=\(String(format: "%.4f", self.smoothedVolume))")
                }
            }

            // ── State rollback for suppressed speechStart ───────────────────────
            //
            // When the volume gate suppresses a speechStart, FluidAudio's internal
            // state has already transitioned to `triggered=true`. We must roll back
            // to `triggered=false` and clear `tempEndSample` so that:
            //   1. A future frame with sufficient volume can emit speechStart
            //   2. The segmentation state machine is consistent with our local state
            if needsStateRollback, let currentState = streamState {
                streamState = VadStreamState(
                    modelState: currentState.modelState,
                    triggered: false,
                    tempEndSample: nil,
                    processedSamples: currentState.processedSamples
                )
            }

            let processingTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            return VADResult(
                probability: result.probability,
                isSpeaking: isSpeaking,
                event: speechEvent,
                processingTimeMs: processingTime,
                smoothedVolume: smoothedVolume
            )
        } catch {
            throw VADError.processingFailed("VAD processing failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Reset

    /// Reset per-chunk accumulators (speech probability average).
    /// Called by StreamingRecorder after each chunk is drained and sent.
    public func resetChunk() async {
        cumulativeSpeechProbability = 0
        processedChunks = 0
    }

    /// Reset all state for a new recording session.
    ///
    /// Resets speech probability accumulators, speaking state, and the Silero
    /// hidden state (via makeStreamState). Also resets smoothedVolume to 0 so
    /// each session starts from a clean volume baseline.
    public func resetSession() async {
        await resetChunk()
        isSpeaking = false
        lastSpeechEndTime = nil
        lastSpeechStartTime = nil
        smoothedVolume = 0

        // Reset the Silero hidden state for the new session.
        // This is also done periodically during recording (see processChunk),
        // but an explicit reset here ensures a clean slate at session boundaries.
        if let manager = vadManager {
            streamState = await manager.makeStreamState()
            lastStreamStateRefresh = Date()
            resetDeferralLogged = false
        }
    }

    // MARK: - Derived Properties

    /// Average Silero speech probability across all chunks in the current window.
    /// Used by StreamingRecorder to decide whether to skip silent chunks.
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

    /// The current smoothed RMS volume (read-only, exposed for diagnostics/tests).
    public var currentSmoothedVolume: Float { smoothedVolume }
}

// MARK: - Mock Processing (test-only)

#if DEBUG
extension VADProcessor {

    /// Process one chunk using the injected MockVADBackend instead of Silero.
    ///
    /// We still run OUR logic (smoothing + volume gate) on the injected data.
    /// Only the FluidAudio/Silero inference step is replaced.
    ///
    /// WHY: Tests must verify OUR gate/smoothing/state-reset code, not the model.
    /// Injecting scripted frames makes the tests deterministic and model-independent.
    ///
    /// Uses the same mock backend injection pattern as the real processChunk path.
    func processChunkMocked(_ mock: MockVADBackend) async throws -> VADResult {
        let frame = await mock.next()

        // Apply exponential smoothing to the injected instantRMS.
        // This tests our smoothing logic with controlled RMS values.
        smoothedVolume = expSmoothing(frame.instantRMS, smoothedVolume, config.volumeSmoothingFactor)

        processedChunks += 1
        cumulativeSpeechProbability += frame.probability

        // Apply volume gate and state transitions to the injected frame.
        // Only fire events on TRANSITIONS (quiet→speaking, speaking→quiet),
        // not on every frame — mirrors the real FluidAudio state machine.
        var speechEvent: SpeechEvent?

        if frame.isSpeaking && !isSpeaking {
            // TRANSITION: quiet → speaking. Apply volume gate (speechStart only).
            if config.volumeGateEnabled && smoothedVolume < config.minVolumeForSpeech {
                // Gate closed — suppress this transition
                logger.debug("""
                    [MOCK] VAD speechStart SUPPRESSED: \
                    smoothedVol=\(String(format: "%.4f", self.smoothedVolume)) \
                    < minVol=\(self.config.minVolumeForSpeech) \
                    prob=\(String(format: "%.3f", frame.probability))
                    """)
            } else {
                // Gate open — fire speechStart
                isSpeaking = true
                lastSpeechStartTime = Date()
                speechEvent = .started(at: Double(processedChunks) * 0.05)
            }
        } else if !frame.isSpeaking && isSpeaking {
            // TRANSITION: speaking → quiet. speechEnd is never gated.
            isSpeaking = false
            lastSpeechEndTime = Date()
            speechEvent = .ended(at: Double(processedChunks) * 0.05)
        }
        // Sustained speaking or sustained silence: no event fired (same as real path)

        return VADResult(
            probability: frame.probability,
            isSpeaking: isSpeaking,
            event: speechEvent,
            processingTimeMs: 0,
            smoothedVolume: smoothedVolume
        )
    }
}

// MARK: - Test Support

extension VADProcessor {
    // swiftlint:disable:next identifier_name
    public func _testSeedAverageSpeechProbability(_ value: Float, chunks: Int = 1) {
        processedChunks = max(chunks, 0)
        cumulativeSpeechProbability = max(chunks, 0) > 0 ? value * Float(chunks) : 0
    }

    // swiftlint:disable:next identifier_name
    public func _testSetSmoothedVolume(_ value: Float) {
        smoothedVolume = value
    }

    // swiftlint:disable:next identifier_name
    public var _testSmoothedVolume: Float { smoothedVolume }

    // swiftlint:disable:next identifier_name
    public var _testLastStreamStateRefresh: Date { lastStreamStateRefresh }

    // swiftlint:disable:next identifier_name
    public func _testInjectBackend(_ backend: MockVADBackend?) {
        mockBackend = backend
    }

    // swiftlint:disable:next identifier_name
    public var _testStreamState: VadStreamState? { streamState }

    // swiftlint:disable:next identifier_name
    public func _testSetStreamState(_ state: VadStreamState?) {
        streamState = state
    }

    // swiftlint:disable:next identifier_name
    public var _testIsSpeaking: Bool { isSpeaking }

    // swiftlint:disable:next identifier_name
    public func _testSetLastStreamStateRefresh(_ date: Date) {
        lastStreamStateRefresh = date
    }
}
#endif
